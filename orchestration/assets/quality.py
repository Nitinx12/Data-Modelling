"""Quality assets — both gates depend on all core assets."""

from __future__ import annotations

import sys
from pathlib import Path

from dagster import asset

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from orchestration.assets.core import (
    dim_campaign,
    dim_customers,
    dim_geo,
    dim_orders_flag,
    dim_products,
    fact_campaign_spend,
    fact_inventory,
    fact_less_fact,
    fact_order_process,
    fact_orders,
)

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _ensure_project_root() -> None:
    """Re-apply the project-root sys.path edit inside compute functions.

    Module-level sys.path edits do not propagate to Dagster's spawned step
    worker processes, so every compute function calls this first. PROJECT_ROOT
    is an absolute path baked in at definition time, so it stays correct no
    matter which cwd a worker starts from.
    """
    if str(PROJECT_ROOT) not in sys.path:
        sys.path.insert(0, str(PROJECT_ROOT))


_ALL_CORE = [
    dim_products,
    dim_customers,
    dim_geo,
    dim_orders_flag,
    dim_campaign,
    fact_campaign_spend,
    fact_inventory,
    fact_order_process,
    fact_orders,
    fact_less_fact,
]


@asset(deps=_ALL_CORE, group_name="quality", compute_kind="sql")
def sql_dq_loops(context) -> dict:
    """Run the five catalog-driven SQL loops (read-only, --strict)."""
    _ensure_project_root()
    from scripts.python.run_data_quality_loops import (
        get_loop_files,
        run_data_quality_loops,
    )

    root = Path(__file__).resolve().parents[2]
    loop_files = get_loop_files(root)
    context.log.info(f"Running {len(loop_files)} DQ loops")
    results = run_data_quality_loops(loop_files)
    total_failed = sum(r["checks_failed"] for r in results)
    context.log.info(f"DQ loops: {total_failed} failed checks")
    if total_failed > 0:
        # --strict semantics: fail the asset so Dagster marks it red
        raise RuntimeError(f"{total_failed} data-quality checks failed")
    return {"loops": len(results), "failed": total_failed, "results": results}


@asset(deps=_ALL_CORE, group_name="quality", compute_kind="python")
def gx_suites(context) -> dict:
    """Run Great Expectations suites in a child process (read-only, --strict).

    GX runs via its CLI instead of an in-worker import: importing
    great_expectations pulls in pyspark.sql.connect, whose doctest guard
    calls sys.exit(0) in spawned step workers whose __main__ has no
    __file__. A real script child process always has one, so the suites run
    exactly as `make gx-strict` does. Nonzero exit fails the asset.
    """
    import subprocess

    _ensure_project_root()
    from scripts.python.gx_run import get_suite_files

    root = PROJECT_ROOT
    suite_files = get_suite_files()
    cmd = [sys.executable, str(root / "scripts" / "python" / "gx_run.py"), "--strict"]
    context.log.info(f"Running {len(suite_files)} GX suites via: {' '.join(cmd)}")
    proc = subprocess.run(
        cmd, cwd=str(root), capture_output=True, text=True, check=False
    )
    for line in proc.stdout.splitlines():
        context.log.info(line)
    for line in proc.stderr.splitlines():
        context.log.warning(line)
    if proc.returncode != 0:
        raise RuntimeError(f"GX suites failed with exit code {proc.returncode}")
    # --strict guarantees zero failures on a zero exit.
    return {"suites": len(suite_files), "failed": 0, "skipped": []}
