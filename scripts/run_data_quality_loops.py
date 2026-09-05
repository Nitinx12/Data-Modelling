"""Run the repository's read only PostgreSQL data quality SQL loops.
NOTE: This script is intended to be run from the repository root, e.g.
     uv run scripts/run_data_quality_loops.py
"""

from __future__ import annotations

import logging
import re
import sys
from pathlib import Path

from rich.console import Console
from rich.table import Table

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


def get_loop_files(project_root: Path) -> list[Path]:
    """Return the numbered data quality loop files in execution order."""
    loop_files = sorted((project_root / "tests" / "data_quality").glob("*_lp_*.sql"))
    if not loop_files:
        raise FileNotFoundError(
            "No data quality loop files matching '*_lp_*.sql' were found in tests/data_quality/."
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


def main() -> None:
    """Run all available data quality loops and print a Rich summary."""
    loop_files = get_loop_files(PROJECT_ROOT)
    console.print(f"[bold]Running {len(loop_files)} data quality loop(s)[/bold]")
    log.info("Running %s data quality loop(s).", len(loop_files))

    results = run_data_quality_loops(loop_files)
    print_summary_table(results)

    log.info("Data quality loop run completed.")


if __name__ == "__main__":
    main()
