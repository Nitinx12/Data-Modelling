"""
scripts/run_models.py
======================
Runs the warehouse model SQL scripts in sequence against Postgres.

Each model is a single .sql file in the project root (DDL + upsert logic
together, same as dim_products.sql / fact_orders.sql / fact_less_fact.sql).
Order matters — dims must load before the facts that reference them — so
the sequence below is explicit rather than auto-discovered.

Usage:
    uv run scripts/run_models.py
    uv run scripts/run_models.py --only fact_orders.sql fact_less_fact.sql
    uv run scripts/run_models.py --continue-on-error
"""

import argparse
import logging
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from rich.console import Console
from rich.table import Table
from sqlalchemy import text

BASE_DIR = (
    Path(__file__).resolve().parents[2]
)  # project root, two levels up from scripts/python/
MODELS_DIR = BASE_DIR / "models"  # change if your .sql files live elsewhere

# make the project root importable no matter how/where this script is invoked
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

from utils.connection import get_postgres_engine
from utils.logger import get_logger

# Dependency order. Add new dims/facts here in the position they need to
# run — e.g. dim_customers.sql / dim_geo.sql / dim_orders_flag.sql before
# fact_orders.sql, dim_campaign.sql before fact_less_fact.sql.
MODEL_SEQUENCE = [
    "dim_products.sql",
    "dim_customers.sql",
    "dim_geo.sql",
    "dim_orders_flag.sql",
    "dim_campaign.sql",
    "fact_campaign_spend.sql",
    "fact_inventory.sql",
    "fact_order_process.sql",
    "fact_orders.sql",
    "fact_less_fact.sql",
]

log = get_logger("model_runner", console_level=logging.WARNING, subdir="core")

# Map model file → core table for row_count (best-effort; quarantine tables ignored)
MODEL_TO_TABLE = {
    "dim_products.sql": "core.dim_products",
    "dim_customers.sql": "core.dim_customers",
    "dim_geo.sql": "core.dim_geo",
    "dim_orders_flag.sql": "core.dim_orders_flag",
    "dim_campaign.sql": "core.dim_campaign",
    "fact_campaign_spend.sql": "core.fact_campaign_spend",
    "fact_inventory.sql": "core.fact_inventory",
    "fact_order_process.sql": "core.fact_order_process",
    "fact_orders.sql": "core.fact_orders",
    "fact_less_fact.sql": "core.fact_less_fact",
}


def _ensure_log_table(engine) -> None:
    ddl = """
    CREATE SCHEMA IF NOT EXISTS core;
    CREATE TABLE IF NOT EXISTS core.pipeline_run_log (
        log_id BIGSERIAL PRIMARY KEY,
        run_id UUID NOT NULL,
        stage VARCHAR(50) NOT NULL,
        model_name VARCHAR(100),
        row_count BIGINT,
        duration_ms INT,
        status VARCHAR(20) NOT NULL,
        started_at TIMESTAMP NOT NULL DEFAULT now(),
        finished_at TIMESTAMP NOT NULL DEFAULT now(),
        error TEXT
    );
    CREATE INDEX IF NOT EXISTS ix_pipeline_run_log_run_id ON core.pipeline_run_log (run_id);
    CREATE INDEX IF NOT EXISTS ix_pipeline_run_log_started ON core.pipeline_run_log (started_at DESC);
    """
    try:
        with engine.begin() as conn:
            conn.execute(text(ddl))
    except Exception:
        log.warning(
            "Could not ensure pipeline_run_log table — logging will be best-effort.",
            exc_info=True,
        )


def _log_run(
    engine,
    run_id,
    stage: str,
    model_name: str | None,
    row_count: int | None,
    duration_ms: int | None,
    status: str,
    started_at: datetime,
    finished_at: datetime,
    error: str | None = None,
) -> None:
    try:
        with engine.begin() as conn:
            conn.execute(
                text(
                    """
                    INSERT INTO core.pipeline_run_log
                        (run_id, stage, model_name, row_count, duration_ms, status, started_at, finished_at, error)
                    VALUES
                        (:run_id, :stage, :model_name, :row_count, :duration_ms, :status, :started_at, :finished_at, :error)
                    """
                ),
                {
                    "run_id": str(run_id),
                    "stage": stage,
                    "model_name": model_name,
                    "row_count": row_count,
                    "duration_ms": duration_ms,
                    "status": status,
                    "started_at": started_at,
                    "finished_at": finished_at,
                    "error": (error[:1000] if error else None),
                },
            )
    except Exception:
        log.warning(
            "Failed to write pipeline_run_log for %s — ignored.",
            model_name,
            exc_info=True,
        )


def _row_count(engine, table: str) -> int | None:
    try:
        with engine.connect() as conn:
            return conn.execute(text(f"SELECT COUNT(*) FROM {table}")).scalar()
    except Exception:  # noqa: BLE001
        return None


@dataclass
class ModelResult:
    name: str
    status: str  # "PASS", "FAIL", "SKIP"
    duration: float = 0.0
    notices: list = field(default_factory=list)
    error: str | None = None


def run_model(engine, path: Path) -> ModelResult:
    """Execute one .sql file as a single script against one connection."""
    sql_text = path.read_text()
    start = time.perf_counter()
    raw_conn = engine.raw_connection()
    try:
        if hasattr(raw_conn, "notices"):
            raw_conn.notices.clear()
        cursor = raw_conn.cursor()
        cursor.execute(sql_text)
        raw_conn.commit()
        duration = time.perf_counter() - start
        notices = [n.strip() for n in getattr(raw_conn, "notices", [])]
        return ModelResult(path.name, "PASS", duration, notices)
    except Exception as exc:  # noqa: BLE001
        raw_conn.rollback()
        duration = time.perf_counter() - start
        return ModelResult(path.name, "FAIL", duration, [], str(exc))
    finally:
        raw_conn.close()


def print_summary(console: Console, results: list[ModelResult]) -> None:
    table = Table(title="Model Run Summary")
    table.add_column("Model")
    table.add_column("Status")
    table.add_column("Duration")

    colors = {"PASS": "green", "FAIL": "red", "SKIP": "yellow"}
    for r in results:
        color = colors.get(r.status, "white")
        duration_text = f"{r.duration:.2f}s" if r.status != "SKIP" else "-"
        table.add_row(r.name, f"[{color}]{r.status}[/{color}]", duration_text)

    console.print(table)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run warehouse model SQL scripts in sequence."
    )
    parser.add_argument(
        "--only",
        nargs="+",
        metavar="MODEL.sql",
        help="Run only these models (still in their defined sequence order).",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Keep running later models even if an earlier one fails.",
    )
    args = parser.parse_args()

    sequence = MODEL_SEQUENCE
    if args.only:
        sequence = [m for m in MODEL_SEQUENCE if m in args.only]

    console = Console()
    console.rule("[bold cyan]Running models")
    log.info(f"Running {len(sequence)} model(s) in sequence.")

    engine = get_postgres_engine()
    run_id = uuid.uuid4()
    _ensure_log_table(engine)
    log.info(f"Pipeline run_id={run_id}")

    results: list[ModelResult] = []
    stop = False

    for name in sequence:
        t0 = datetime.now(UTC)
        start_perf = time.perf_counter()
        path = MODELS_DIR / name

        if stop and not args.continue_on_error:
            console.print(f"[yellow]  SKIP  {name}[/yellow]  (earlier model failed)")
            log.warning(f"{name}: skipped, earlier model failed.")
            result = ModelResult(name, "SKIP", error="earlier model failed")
            results.append(result)
            _log_run(
                engine,
                run_id,
                "models",
                name,
                None,
                None,
                "SKIP",
                t0,
                datetime.now(UTC),
                result.error,
            )
            continue

        if not path.exists():
            console.print(f"[yellow]  SKIP  {name}[/yellow]  (file not found: {path})")
            log.warning(f"{name}: file not found at {path}, skipping.")
            result = ModelResult(name, "SKIP", error="file not found")
            results.append(result)
            _log_run(
                engine,
                run_id,
                "models",
                name,
                None,
                None,
                "SKIP",
                t0,
                datetime.now(UTC),
                result.error,
            )
            continue

        with console.status(f"[cyan]Running {name}..."):
            result = run_model(engine, path)
        results.append(result)

        duration_ms = int((time.perf_counter() - start_perf) * 1000)
        t1 = datetime.now(UTC)
        row_count = (
            _row_count(engine, MODEL_TO_TABLE.get(name))
            if result.status == "PASS"
            else None
        )

        if result.status == "PASS":
            console.print(f"[green]  PASS  {name}[/green]  ({result.duration:.2f}s)")
            log.info(f"{name}: completed in {result.duration:.2f}s.")
            for notice in result.notices:
                log.info(f"{name} notice: {notice}")
        else:
            console.print(f"[red]  FAIL  {name}[/red]  ({result.duration:.2f}s)")
            console.print(f"[red]{result.error}[/red]")
            log.error(f"{name}: failed after {result.duration:.2f}s — {result.error}")
            stop = True

        _log_run(
            engine,
            run_id,
            "models",
            name,
            row_count,
            duration_ms,
            result.status,
            t0,
            t1,
            result.error,
        )

    console.print()
    print_summary(console, results)

    failed = sum(1 for r in results if r.status == "FAIL")
    if failed:
        console.print(f"\n[bold red]{failed} model(s) failed.[/bold red]")
        log.error(f"Model run completed with {failed} failure(s).")
        return 1

    console.print("\n[bold green]All models completed successfully.[/bold green]")
    log.info("Model run completed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
