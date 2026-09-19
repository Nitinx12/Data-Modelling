"""Run the repository's read only PostgreSQL data quality SQL loops.
NOTE: This script is intended to be run from the repository root, e.g.
     uv run scripts/python/run_data_quality_loops.py
     uv run scripts/python/run_data_quality_loops.py --strict
"""

from __future__ import annotations

import argparse
import logging
import re
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path

from rich.console import Console
from rich.table import Table
from sqlalchemy import text

console = Console()

# Strips the "NOTICE:  " severity prefix libpq adds to every raised message.
NOTICE_PREFIX = re.compile(r"^(NOTICE|WARNING|INFO):\s*")

# Matches the rollup line each loop prints last, e.g.
# "Required text loop complete: 2 failed check(s), 16 failed row(s)."
SUMMARY_PATTERN = re.compile(
    r"loop complete: (?P<checks>\d+) failed check\(s\), (?P<rows>\d+) failed row\(s\)\."
)


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

log = get_logger("data_quality", subdir="tests", console_level=logging.INFO)


def _log_quality(engine, run_id, model_name, checks_failed, rows_failed, duration_ms, status, started_at, finished_at):
    try:
        with engine.begin() as conn:
            conn.execute(
                text(
                    """
                    CREATE TABLE IF NOT EXISTS core.pipeline_run_log (
                        log_id BIGSERIAL PRIMARY KEY,
                        run_id UUID NOT NULL, stage VARCHAR(50) NOT NULL, model_name VARCHAR(100),
                        row_count BIGINT, duration_ms INT, status VARCHAR(20) NOT NULL,
                        started_at TIMESTAMP NOT NULL, finished_at TIMESTAMP NOT NULL, error TEXT
                    )
                    """
                )
            )
            conn.execute(
                text(
                    """
                    INSERT INTO core.pipeline_run_log
                        (run_id, stage, model_name, row_count, duration_ms, status, started_at, finished_at)
                    VALUES (:run_id, 'quality', :model_name, :row_count, :duration_ms, :status, :started_at, :finished_at)
                    """
                ),
                {
                    "run_id": str(run_id),
                    "model_name": model_name,
                    "row_count": rows_failed,
                    "duration_ms": duration_ms,
                    "status": status,
                    "started_at": started_at,
                    "finished_at": finished_at,
                },
            )
    except Exception:
        log.warning("Failed to log quality for %s — ignored.", model_name, exc_info=True)


def get_loop_files(project_root: Path) -> list[Path]:
    """Return the numbered data quality loop files in execution order."""
    loop_files = sorted(
        (project_root / "tests" / "sql" / "data_quality").glob("*_lp_*.sql")
    )
    if not loop_files:
        raise FileNotFoundError(
            "No data quality loop files matching '*_lp_*.sql' were found in tests/sql/data_quality/."
        )
    return loop_files


def clean_notice(raw_notice: str) -> str:
    """Strip the libpq severity prefix and surrounding whitespace from a notice."""
    return NOTICE_PREFIX.sub("", raw_notice).strip()


def run_single_loop(cursor, raw_connection, loop_file: Path) -> dict:
    """Execute one loop file and return its failure lines plus a parsed summary."""
    sql_text = loop_file.read_text(encoding="utf-8")
    notices_before = len(raw_connection.notices)

    cursor.execute(sql_text)

    # Only look at notices raised by this loop, not earlier ones on the connection.
    new_notices = [clean_notice(n) for n in raw_connection.notices[notices_before:]]
    failed_lines = [
        n.removeprefix("[FAILED] ") for n in new_notices if n.startswith("[FAILED]")
    ]
    summary_line = (
        new_notices[-1] if new_notices else "completed without a database notice"
    )

    summary_match = SUMMARY_PATTERN.search(summary_line)
    checks_failed = (
        int(summary_match.group("checks")) if summary_match else len(failed_lines)
    )
    rows_failed = int(summary_match.group("rows")) if summary_match else 0

    return {
        "file": loop_file.name,
        "failed_lines": failed_lines,
        "summary": summary_line,
        "checks_failed": checks_failed,
        "rows_failed": rows_failed,
    }


def run_data_quality_loops(loop_files: list[Path]) -> list[dict]:
    """Execute every supplied read only SQL loop and return each loop's result."""
    engine = get_postgres_engine()
    raw_connection = engine.raw_connection()
    results: list[dict] = []

    try:
        cursor = raw_connection.cursor()
        try:
            for loop_file in loop_files:
                console.rule(f"[bold cyan]{loop_file.name}")
                result = run_single_loop(cursor, raw_connection, loop_file)
                results.append(result)

                # Detail lines in red, then the loop's own summary line.
                for line in result["failed_lines"]:
                    console.print(f"  [red]FAIL[/red]  {line}")
                    log.warning(line)

                status_color = "green" if result["checks_failed"] == 0 else "yellow"
                console.print(f"  [{status_color}]{result['summary']}[/{status_color}]")
                log.info("%s: %s", result["file"], result["summary"])
        except Exception:
            raw_connection.rollback()
            log.exception(
                "Data quality loop execution failed; transaction rolled back."
            )
            raise
        finally:
            cursor.close()
    finally:
        raw_connection.rollback()
        raw_connection.close()

    return results


def print_summary_table(results: list[dict]) -> None:
    """Print a final Rich table rolling up every loop's outcome."""
    table = Table(title="Data Quality Summary")
    table.add_column("Loop")
    table.add_column("Failed Checks", justify="right")
    table.add_column("Failed Rows", justify="right")
    table.add_column("Status")

    total_checks = 0
    total_rows = 0
    for result in results:
        total_checks += result["checks_failed"]
        total_rows += result["rows_failed"]
        status = (
            "[green]PASS[/green]" if result["checks_failed"] == 0 else "[red]FAIL[/red]"
        )
        table.add_row(
            result["file"],
            str(result["checks_failed"]),
            str(result["rows_failed"]),
            status,
        )

    console.print()
    console.print(table)

    # One line overall verdict below the table.
    if total_checks == 0:
        console.print("\n[bold green]ALL CHECKS PASSED[/bold green]")
    else:
        console.print(
            f"\n[bold red]{total_checks} CHECK(S) FAILED[/bold red] ({total_rows} row(s) affected)"
        )


def main() -> int:
    """Run all available data quality loops, print a Rich summary, and exit.

    Exit code is 0 unless --strict is passed and any check failed.
    """
    parser = argparse.ArgumentParser(
        description="Run the read only data quality SQL loops."
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 if any data quality check failed (for CI / main.py).",
    )
    args = parser.parse_args()

    loop_files = get_loop_files(PROJECT_ROOT)
    console.print(f"[bold]Running {len(loop_files)} data quality loop(s)[/bold]")
    log.info("Running %s data quality loop(s).", len(loop_files))

    t0 = datetime.now(UTC)
    import time as _time

    _t = _time.perf_counter()
    results = run_data_quality_loops(loop_files)
    _dur = int((_time.perf_counter() - _t) * 1000)
    print_summary_table(results)

    # Observability — log each loop file as a separate row + an aggregate
    try:
        from utils.connection import get_postgres_engine

        eng = get_postgres_engine()
        rid = uuid.uuid4()
        t1 = datetime.now(UTC)
        for r in results:
            _log_quality(
                eng,
                rid,
                r["file"],
                r["checks_failed"],
                r["rows_failed"],
                None,
                "PASS" if r["checks_failed"] == 0 else "FAIL",
                t0,
                t1,
            )
        _log_quality(eng, rid, "quality_all", sum(rr["checks_failed"] for rr in results), sum(rr["rows_failed"] for rr in results), _dur, "PASS" if all(rr["checks_failed"] == 0 for rr in results) else "FAIL", t0, t1)
    except Exception:
        log.warning("Quality observability logging failed — ignored.", exc_info=True)

    total_failed_checks = sum(result["checks_failed"] for result in results)
    if args.strict and total_failed_checks > 0:
        log.error(
            "%d data quality check(s) failed; failing the run (--strict).",
            total_failed_checks,
        )
        console.print(
            f"\n[bold red]{total_failed_checks} CHECK(S) FAILED — exiting 1 (--strict)[/bold red]"
        )
        return 1

    log.info("Data quality loop run completed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
