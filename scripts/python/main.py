"""
main.py
=======
Production-grade one-shot pipeline orchestrator.

Runs the full ELT in sequence, failing fast with structured logging
and observability (core.pipeline_run_log) so every run is traceable
in the dashboard's Pipeline Health panel.

Stages (all --strict by default, so CI fails on red data):
  1. pg_staging.py      — MongoDB -> Postgres staging (incremental, Pydantic-validated)
  2. run_models.py      — dims (SCD2 dim_customers) + facts in core (ordered, logged per model)
  3. run_data_quality_loops.py — 5 catalog-driven SQL loops (read-only)
  4. gx_run.py          — Great Expectations suites (read-only)

Alternatives (not run by default, see Makefile):
  - Dagster: orchestration/definitions.py (asset DAG, `make dagster-dev`)
  - dbt:     dbt/ (lineage/docs mirror, `make dbt-build`)

Usage:
    uv run python scripts/python/main.py                    # full pipeline
    uv run python scripts/python/main.py --skip-staging     # models + quality only
    uv run python scripts/python/main.py --skip-gx          # staging + models + SQL loops
    uv run python scripts/python/main.py --continue-on-error
    uv run python scripts/python/main.py --help-stages

Exit codes:
    0  all stages passed
    1  at least one stage failed
    2  usage error
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import text

SCRIPTS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPTS_DIR.parents[2]

# Ensure project root is importable and utils/logger is available
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

# Windows cp1252 cannot encode ✓/✗ — force UTF-8 so the final summary never crashes
for _stream in (sys.stdout, sys.stderr):
    if (
        _stream
        and _stream.encoding
        and _stream.encoding.lower() not in ("utf-8", "utf8")
    ):
        _stream.reconfigure(encoding="utf-8", errors="replace")

try:
    from utils.logger import get_logger

    _log = get_logger("pipeline", subdir="pipeline")
except Exception:  # noqa: BLE001
    import logging as _logging

    _log = _logging.getLogger("pipeline")


def run(script: Path, *args: str) -> subprocess.CompletedProcess[bytes]:
    cmd = ["uv", "run", str(script), *args]
    _log.info("Running: %s", " ".join(cmd))
    return subprocess.run(cmd, check=False)


def stage_header(name: str) -> None:
    sep = "=" * 60
    print(f"\n{sep}\n  {name}\n{sep}\n", flush=True)
    _log.info("=== %s ===", name)


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="main.py",
        description="Run the full warehouse pipeline (staging → models → quality → GX).",
    )
    parser.add_argument(
        "--skip-staging", action="store_true", help="Skip staging load."
    )
    parser.add_argument(
        "--skip-models", action="store_true", help="Skip warehouse models."
    )
    parser.add_argument(
        "--skip-quality", action="store_true", help="Skip SQL data-quality loops."
    )
    parser.add_argument(
        "--skip-gx", action="store_true", help="Skip Great Expectations gate."
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Continue past failures (still exits 1 at end).",
    )
    parser.add_argument(
        "--help-stages", action="store_true", help="Print stage descriptions and exit."
    )
    args = parser.parse_args()

    if args.help_stages:
        print("Pipeline stages:")
        print(
            "  1. pg_staging.py            — MongoDB -> Postgres staging (incremental, validated, quarantine_log)"
        )
        print(
            "  2. run_models.py            — dims + facts in core (SCD2 dim_customers, as-of fact_orders, logged per model)"
        )
        print(
            "  3. run_data_quality_loops.py — 5 read-only SQL loops (catalog-driven, --strict)"
        )
        print(
            "  4. gx_run.py                — Great Expectations suites (read-only, --strict)"
        )
        print("\nAll four stages are enabled by default. Use --skip-* to disable.")
        print(
            "Observability: each stage writes to core.pipeline_run_log (run_id per invocation)."
        )
        return 0

    run_id = uuid.uuid4()
    _log.info(
        "Pipeline run_id=%s started (continue_on_error=%s)",
        run_id,
        args.continue_on_error,
    )

    total_start = time.monotonic()
    stages: list[tuple[str, Path, list[str]]] = []

    if not args.skip_staging:
        stages.append(("STAGING", SCRIPTS_DIR / "pg_staging.py", []))
    if not args.skip_models:
        stages.append(
            (
                "MODELS",
                SCRIPTS_DIR / "run_models.py",
                ["--continue-on-error"] if args.continue_on_error else [],
            )
        )
    if not args.skip_quality:
        stages.append(
            ("DATA QUALITY", SCRIPTS_DIR / "run_data_quality_loops.py", ["--strict"])
        )
    if not args.skip_gx:
        stages.append(("GX DATA QUALITY", SCRIPTS_DIR / "gx_run.py", ["--strict"]))

    if not stages:
        print("Error: all stages disabled. Nothing to do.", file=sys.stderr)
        _log.error("All stages disabled — nothing to do.")
        return 2

    results: list[tuple[str, int, float]] = []

    for label, script, extra_args in stages:
        stage_header(label)
        t0 = time.monotonic()
        result = run(script, *extra_args)
        elapsed = time.monotonic() - t0
        results.append((label, result.returncode, elapsed))
        status = "OK" if result.returncode == 0 else f"FAIL (exit {result.returncode})"
        msg = f"[{status}] {script.name} — {elapsed:.1f}s"
        print(f"\n  {msg}", flush=True)
        _log.info("%s — %s", label, msg)
        if result.returncode != 0 and not args.continue_on_error:
            print(
                f"\n✗ Pipeline stopped at '{label}' (--continue-on-error not set).",
                flush=True,
            )
            _log.error("Pipeline stopped at %s (exit %s)", label, result.returncode)
            break

    total_elapsed = time.monotonic() - total_start
    print(f"\n{'=' * 60}")
    print(f"  Pipeline run_id={run_id} — {total_elapsed:.1f}s total")
    print(f"{'=' * 60}")
    _log.info("Pipeline run_id=%s finished in %.1fs", run_id, total_elapsed)

    failures = [(lbl, code) for lbl, code, _ in results if code != 0]
    if failures:
        for lbl, code in failures:
            print(f"  ✗ {lbl}: exit {code}")
            _log.error("Stage failed: %s exit %s", lbl, code)
        print(f"\n✗ {len(failures)} stage(s) failed (run_id={run_id}).")
        # Also log to core.pipeline_run_log as an aggregate if possible (best-effort)
        try:
            from utils.connection import get_postgres_engine

            eng = get_postgres_engine()
            with eng.begin() as conn:
                conn.execute(
                    text(
                        """
                        CREATE TABLE IF NOT EXISTS core.pipeline_run_log (
                            log_id BIGSERIAL PRIMARY KEY, run_id UUID NOT NULL, stage VARCHAR(50) NOT NULL,
                            model_name VARCHAR(100), row_count BIGINT, duration_ms INT, status VARCHAR(20) NOT NULL,
                            started_at TIMESTAMP NOT NULL, finished_at TIMESTAMP NOT NULL, error TEXT
                        )
                        """
                    )
                )
                conn.execute(
                    text(
                        """
                        INSERT INTO core.pipeline_run_log (run_id, stage, model_name, status, duration_ms, started_at, finished_at, error)
                        VALUES (:run_id, 'pipeline', 'main', 'FAIL', :duration_ms, :started_at, :finished_at, :error)
                        """
                    ),
                    {
                        "run_id": str(run_id),
                        "duration_ms": int(total_elapsed * 1000),
                        "started_at": datetime.now(UTC),
                        "finished_at": datetime.now(UTC),
                        "error": f"{len(failures)} stage(s) failed: {', '.join(lbl for lbl, _ in failures)}"[
                            :1000
                        ],
                    },
                )
        except Exception:  # noqa: BLE001
            _log.warning(
                "Failed to write pipeline aggregate to pipeline_run_log — ignored.",
                exc_info=True,
            )
        return 1

    # Success aggregate log (best-effort)
    try:
        from utils.connection import get_postgres_engine

        eng = get_postgres_engine()
        with eng.begin() as conn:
            conn.execute(
                text(
                    """
                    CREATE TABLE IF NOT EXISTS core.pipeline_run_log (
                        log_id BIGSERIAL PRIMARY KEY, run_id UUID NOT NULL, stage VARCHAR(50) NOT NULL,
                        model_name VARCHAR(100), row_count BIGINT, duration_ms INT, status VARCHAR(20) NOT NULL,
                        started_at TIMESTAMP NOT NULL, finished_at TIMESTAMP NOT NULL, error TEXT
                    )
                    """
                )
            )
            conn.execute(
                text(
                    """
                    INSERT INTO core.pipeline_run_log (run_id, stage, model_name, status, duration_ms, started_at, finished_at)
                    VALUES (:run_id, 'pipeline', 'main', 'PASS', :duration_ms, :started_at, :finished_at)
                    """
                ),
                {
                    "run_id": str(run_id),
                    "duration_ms": int(total_elapsed * 1000),
                    "started_at": datetime.now(UTC),
                    "finished_at": datetime.now(UTC),
                },
            )
    except Exception:  # noqa: BLE001
        _log.warning(
            "Failed to write pipeline PASS aggregate — ignored.", exc_info=True
        )

    print(f"\n✓ All stages completed successfully (run_id={run_id}).")
    _log.info("Pipeline run_id=%s all stages passed.", run_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
