"""Run the Great Expectations suites in gx/expectations/ against the warehouse.

Each suite file is a flat YAML list of expectations whose ``meta.schema``
field names the target table (``core.fact_orders`` and so on).  Because one
suite spans several tables, this script groups the expectations by table and
validates each group as its own batch.  Two kinds of placeholder are
resolved at run time:

  - ``$today`` / ``$now`` in any kwarg become ``date.today()`` /
    ``datetime.now()`` when the run starts.
  - an empty ``value_set`` on an expectation with ``meta.fk_to`` (e.g.
    ``core.dim_campaign(campaign_key)``) is populated with the live key set
    from the referenced dimension, which is what turns
    ``expect_column_values_to_be_in_set`` into an orphan FK check.

Expectations that cannot be executed as written (empty ``value_set`` with no
``fk_to``, or no ``meta.schema`` target) are skipped with a warning instead
of being guessed at.  Like the SQL loops, this script only ever reads from
the database.

Usage:
    uv run scripts/python/gx_run.py                      # all suites, report only
    uv run scripts/python/gx_run.py --strict             # exit 1 if any expectation failed
    uv run scripts/python/gx_run.py --suite orphan_fk_suite
    uv run scripts/python/gx_run.py --list-suites

Exit codes:
    0   all expectations passed (or report only without --strict)
    1   a suite could not be loaded/run, or --strict and expectations failed
    2   usage / argument error (e.g. unknown suite name)
"""

from __future__ import annotations

import argparse
import logging
import re
import sys
from collections.abc import Callable
from datetime import date, datetime
from pathlib import Path
from typing import Any

import yaml
from rich.console import Console
from rich.table import Table

console = Console()

# A reference to another table's key, e.g. "core.dim_campaign(campaign_key)",
# used to resolve empty value_set placeholders at run time.
FK_REF_PATTERN = re.compile(r"^(?P<schema>\w+)\.(?P<table>\w+)\((?P<column>\w+)\)$")


def find_project_root(marker: str = "pyproject.toml") -> Path:
    """Return the project root by searching upward from this script."""
    script_path = Path(__file__).resolve()
    for parent in (script_path.parent, *script_path.parents):
        if (parent / marker).exists():
            return parent
    raise RuntimeError(f"Could not find project root containing {marker!r}.")


PROJECT_ROOT = find_project_root()
sys.path.insert(0, str(PROJECT_ROOT))

from utils.connection import get_postgres_engine
from utils.logger import get_logger

log = get_logger("gx_data_quality", subdir="tests", console_level=logging.INFO)

GX_SUITE_DIR = PROJECT_ROOT / "gx" / "expectations"


class UnresolvableExpectation(Exception):
    """Raised when a suite expectation is a placeholder that cannot run."""


def get_suite_files() -> list[Path]:
    """Return the checked in suite files, in name order."""
    return sorted(GX_SUITE_DIR.glob("*.yaml"))


def load_suite(suite_file: Path) -> list[dict]:
    """Return the raw expectation dicts from one suite file."""
    doc = yaml.safe_load(suite_file.read_text(encoding="utf-8")) or {}
    return doc.get("expectations") or []


def group_expectations_by_table(
    expectations: list[dict],
) -> tuple[dict[tuple[str, str], list[dict]], list[str]]:
    """Bucket expectations by their meta.schema target, e.g. core.fact_orders.

    Returns the groups keyed by (schema, table) plus one skip reason string
    per expectation that names no target table.
    """
    groups: dict[tuple[str, str], list[dict]] = {}
    skipped: list[str] = []
    for expectation in expectations:
        target = (expectation.get("meta") or {}).get("schema") or ""
        schema, _, table = target.partition(".")
        if not schema or not table:
            name = expectation.get("expectation_type", "<unnamed>")
            skipped.append(f"{name}: no meta.schema target, cannot pick a table")
            continue
        groups.setdefault((schema, table), []).append(expectation)
    return groups, skipped


def resolve_runtime_tokens(value: Any) -> Any:
    """Recursively replace $today / $now tokens with the current date/time."""
    if isinstance(value, dict):
        return {key: resolve_runtime_tokens(val) for key, val in value.items()}
    if isinstance(value, list):
        return [resolve_runtime_tokens(item) for item in value]
    if value == "$today":
        # Local wall clock, like CURRENT_DATE in the SQL loops — a UTC date
        # would still be "yesterday" for hours after local midnight.
        return date.today()  # noqa: DTZ011
    if value == "$now":
        # Naive local time on purpose: the warehouse stores naive
        # timestamps, and an aware datetime would force a session timezone
        # cast on every comparison.
        return datetime.now()  # noqa: DTZ005
    return value


def parse_fk_ref(fk_ref: str) -> tuple[str, str, str]:
    """Split a meta.fk_to reference into (schema, table, column)."""
    match = FK_REF_PATTERN.match(fk_ref.strip())
    if not match:
        raise UnresolvableExpectation(f"unparsable fk_to reference {fk_ref!r}")
    return match.group("schema"), match.group("table"), match.group("column")


def fetch_fk_value_set(engine: Any, fk_ref: str) -> list[Any]:
    """Return the distinct key values from the table an fk_ref points at."""
    schema, table, column = parse_fk_ref(fk_ref)
    from sqlalchemy import text

    sql = f"SELECT DISTINCT {column} FROM {schema}.{table}"
    with engine.connect() as connection:
        rows = connection.execute(text(sql)).fetchall()
    return [row[0] for row in rows]


def expectation_class(gxe: Any, expectation_type: str) -> Any:
    """Resolve a snake_case expectation type to its gxe class."""
    camel = "".join(part.capitalize() for part in expectation_type.split("_"))
    expectation_cls = getattr(gxe, camel, None)
    if expectation_cls is None:
        raise UnresolvableExpectation(f"unknown expectation type {expectation_type!r}")
    return expectation_cls


def prepare_expectation(
    gxe: Any, expectation: dict, fetch_fk: Callable[[str], list[Any]]
) -> Any:
    """Build one runnable GX expectation from a raw suite entry.

    Raises UnresolvableExpectation for placeholders this runner cannot
    execute (empty value_set with no fk_to, unknown expectation type).
    Anything else that goes wrong propagates, so the caller can surface it
    as a failed check rather than silently dropping it.
    """
    expectation_type = expectation.get("expectation_type") or ""
    if not expectation_type:
        raise UnresolvableExpectation("entry has no expectation_type")
    kwargs = resolve_runtime_tokens(expectation.get("kwargs") or {})
    meta = expectation.get("meta") or {}

    value_set = kwargs.get("value_set")
    if value_set is None or value_set == []:
        # An expectation with a fk_to reference gets its value_set resolved
        # from the referenced table. An explicitly empty value_set without
        # one (the composite uniqueness placeholders) is unresolvable. A
        # missing value_set on an expectation that takes none at all (e.g.
        # expect_column_values_to_not_be_null) is simply not a placeholder.
        fk_ref = meta.get("fk_to")
        if fk_ref is not None:
            kwargs["value_set"] = fetch_fk(fk_ref)
        elif "value_set" in kwargs:
            raise UnresolvableExpectation(
                f"{expectation_type} on column {kwargs.get('column')!r}: "
                "empty value_set and no meta.fk_to to resolve it from"
            )

    expectation_cls = expectation_class(gxe, expectation_type)

    # Drop kwargs the GX class does not accept, e.g. allow_null, which the
    # suites carry for documentation only — column map expectations already
    # skip null rows.  GX expectation classes use a pydantic v1 style
    # compat layer, so the accepted field names live in __fields__, not
    # model_fields.
    fields = getattr(expectation_cls, "__fields__", None) or getattr(
        expectation_cls, "model_fields", {}
    )
    valid_fields = set(fields)
    accepted = {key: val for key, val in kwargs.items() if key in valid_fields}
    dropped = sorted(key for key in kwargs if key not in valid_fields)
    if dropped:
        log.debug(
            "%s: dropping kwargs not accepted by GX: %s", expectation_type, dropped
        )
    return expectation_cls(**accepted)


def run_gx_suites(
    suite_files: list[Path],
) -> tuple[list[dict], list[tuple[str, str]]]:
    """Validate every supplied suite; return per table results and skips."""
    import os

    # GX's tqdm progress bars fight with the Rich console output; the
    # summary table carries the same information.
    os.environ.setdefault("TQDM_DISABLE", "1")

    import great_expectations as gx
    import great_expectations.expectations as gxe

    engine = get_postgres_engine()
    context = gx.get_context(mode="ephemeral")
    datasource = context.data_sources.add_postgres(
        name="warehouse",
        connection_string=engine.url.render_as_string(hide_password=False),
    )

    # One query asset per target table, shared across suites.  Query assets
    # sidestep the deprecated schema_name argument on add_table_asset — the
    # schema is spelled out in the query itself.
    batch_definitions: dict[tuple[str, str], Any] = {}

    def get_batch(schema: str, table: str) -> Any:
        key = (schema, table)
        if key not in batch_definitions:
            asset = datasource.add_query_asset(
                name=f"{schema}__{table}",
                query=f"SELECT * FROM {schema}.{table}",
            )
            batch_definitions[key] = asset.add_batch_definition_whole_table(
                "whole_table"
            )
        return batch_definitions[key].get_batch()

    def fetch_fk(fk_ref: str) -> list[Any]:
        return fetch_fk_value_set(engine, fk_ref)

    results: list[dict] = []
    skipped: list[tuple[str, str]] = []

    for suite_file in suite_files:
        console.rule(f"[bold cyan]{suite_file.stem}")
        log.info("Running GX suite %s.", suite_file.name)

        groups, group_skips = group_expectations_by_table(load_suite(suite_file))
        skipped.extend((suite_file.stem, reason) for reason in group_skips)

        for (schema, table), table_expectations in groups.items():
            target = f"{schema}.{table}"
            built: list[Any] = []
            build_errors: list[str] = []
            for expectation in table_expectations:
                try:
                    built.append(prepare_expectation(gxe, expectation, fetch_fk))
                except UnresolvableExpectation as exc:
                    skipped.append((suite_file.stem, f"{target}: {exc}"))
                except Exception:
                    # A broken expectation must fail the run, not vanish.
                    log.exception(
                        "Failed to build %s for %s.",
                        expectation.get("expectation_type"),
                        target,
                    )
                    build_errors.append(
                        f"{expectation.get('expectation_type')}: could not build "
                        "expectation (see log)"
                    )

            if not built and not build_errors:
                skipped.append((suite_file.stem, f"{target}: no runnable expectations"))
                continue

            entry = {
                "suite": suite_file.stem,
                "table": target,
                "evaluated": 0,
                "failed": 0,
                "failed_lines": list(build_errors),
            }
            if built:
                try:
                    suite = gx.ExpectationSuite(
                        name=f"{suite_file.stem}__{schema}_{table}",
                        expectations=built,
                    )
                    batch = get_batch(schema, table)
                    validation = batch.validate(suite)
                except Exception as exc:
                    log.exception("GX validation failed for %s.", target)
                    entry["evaluated"] = len(built)
                    entry["failed"] = len(built)
                    entry["failed_lines"].append(f"validation error: {exc}")
                    results.append(entry)
                    continue

                for expectation_result in validation.results:
                    if expectation_result.success:
                        continue
                    config = expectation_result.expectation_config
                    column = config.kwargs.get("column", "?")
                    unexpected = (expectation_result.result or {}).get(
                        "unexpected_count", "?"
                    )
                    entry["failed_lines"].append(
                        f"{column}: {config.type} — {unexpected} unexpected value(s)"
                    )
                stats = validation.statistics or {}
                entry["evaluated"] = stats.get("evaluated_expectations", len(built))
                entry["failed"] = stats.get(
                    "unsuccessful_expectations", len(entry["failed_lines"])
                )
            else:
                entry["failed"] = len(build_errors)
            results.append(entry)

    return results, skipped


def print_summary_table(results: list[dict], skipped: list[tuple[str, str]]) -> None:
    """Print a final Rich table rolling up every table validation's outcome."""
    table = Table(title="GX Data Quality Summary")
    table.add_column("Suite")
    table.add_column("Table")
    table.add_column("Expectations", justify="right")
    table.add_column("Failed", justify="right")
    table.add_column("Status")

    total_failed = 0
    for result in results:
        total_failed += result["failed"]
        for line in result["failed_lines"]:
            console.print(f"  [red]FAIL[/red]  {result['table']} {line}")
            log.warning("%s %s: %s", result["suite"], result["table"], line)
        status = "[green]PASS[/green]" if result["failed"] == 0 else "[red]FAIL[/red]"
        table.add_row(
            result["suite"],
            result["table"],
            str(result["evaluated"]),
            str(result["failed"]),
            status,
        )

    console.print()
    console.print(table)

    for suite, reason in skipped:
        console.print(f"  [yellow]SKIP[/yellow]  {suite}: {reason}")
        log.warning("%s: skipped — %s", suite, reason)

    if total_failed == 0:
        console.print("\n[bold green]ALL EXPECTATIONS PASSED[/bold green]")
    else:
        console.print(f"\n[bold red]{total_failed} EXPECTATION(S) FAILED[/bold red]")
    if skipped:
        console.print(
            f"[yellow]{len(skipped)} expectation(s) skipped (see SKIP lines above)[/yellow]"
        )


def main() -> int:
    """Run the GX suites, print a Rich summary, and exit.

    Exit code is 0 unless a suite fails to run, or --strict is passed and
    any expectation failed.
    """
    parser = argparse.ArgumentParser(
        description="Run the Great Expectations suites in gx/expectations/."
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 if any GX expectation failed (for CI / main.py).",
    )
    parser.add_argument(
        "--suite",
        action="append",
        default=[],
        metavar="NAME",
        help="Run only the named suite (repeatable).",
    )
    parser.add_argument(
        "--list-suites",
        action="store_true",
        help="List the available suite names and exit.",
    )
    args = parser.parse_args()

    suite_files = get_suite_files()

    if args.list_suites:
        for suite_file in suite_files:
            print(suite_file.stem)
        return 0

    if not suite_files:
        console.print(f"[red]No GX suites found in {GX_SUITE_DIR}[/red]")
        return 1

    known = {suite_file.stem for suite_file in suite_files}
    unknown = sorted(set(args.suite) - known)
    if unknown:
        console.print(
            f"[red]Unknown suite(s): {', '.join(unknown)}. "
            f"Available: {', '.join(sorted(known))}[/red]"
        )
        return 2

    if args.suite:
        wanted = set(args.suite)
        selected = [f for f in suite_files if f.stem in wanted]
    else:
        selected = suite_files

    console.print(f"[bold]Running {len(selected)} GX suite(s)[/bold]")
    log.info("Running %s GX suite(s).", len(selected))

    try:
        results, skipped = run_gx_suites(selected)
    except Exception:
        log.exception("GX suite run failed.")
        console.print(
            "[bold red]GX suite run failed — see the log for details[/bold red]"
        )
        return 1

    print_summary_table(results, skipped)

    total_failed = sum(result["failed"] for result in results)
    if args.strict and total_failed > 0:
        log.error(
            "%d GX expectation(s) failed; failing the run (--strict).", total_failed
        )
        console.print(
            f"\n[bold red]{total_failed} EXPECTATION(S) FAILED — exiting 1 (--strict)[/bold red]"
        )
        return 1

    log.info("GX suite run completed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
