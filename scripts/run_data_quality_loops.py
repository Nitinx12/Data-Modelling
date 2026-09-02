"""Run the repository's read-only PostgreSQL data-quality SQL loops."""

from __future__ import annotations

import logging
import sys
from pathlib import Path


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
    """Return the numbered data-quality loop files in execution order."""
    loop_files = sorted((project_root / "tests").glob("*_lp_*.sql"))
    if not loop_files:
        raise FileNotFoundError("No data-quality loop files matching '*_lp_*.sql' were found.")
    return loop_files


def run_data_quality_loops(loop_files: list[Path]) -> None:
    """Execute every supplied read-only SQL loop using the shared Postgres connection."""
    engine = get_postgres_engine()
    raw_connection = engine.raw_connection()

    try:
        cursor = raw_connection.cursor()
        try:
            for loop_file in loop_files:
                sql_text = loop_file.read_text(encoding="utf-8")
                notice_count_before = len(raw_connection.notices)
                cursor.execute(sql_text)

                summary = (
                    raw_connection.notices[-1].strip()
                    if len(raw_connection.notices) > notice_count_before
                    else "completed without a database notice"
                )
                log.info("%s: %s", loop_file.name, summary)
        except Exception:
            raw_connection.rollback()
            log.exception("Data-quality loop execution failed; transaction rolled back.")
            raise
        finally:
            cursor.close()
    finally:
        raw_connection.rollback()
        raw_connection.close()


def main() -> None:
    """Run all available data-quality loops and log their summaries."""
    loop_files = get_loop_files(PROJECT_ROOT)
    log.info("Running %s data-quality loop(s).", len(loop_files))
    run_data_quality_loops(loop_files)
    log.info("Data-quality loop run completed successfully.")


if __name__ == "__main__":
    main()
