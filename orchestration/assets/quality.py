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
    """Run Great Expectations suites (read-only, --strict)."""
    from scripts.python.gx_run import get_suite_files, run_gx_suites

    suite_files = get_suite_files()
    context.log.info(f"Running {len(suite_files)} GX suites")
    results, skipped = run_gx_suites(suite_files)
    total_failed = sum(r["failed"] for r in results)
    context.log.info(f"GX: {total_failed} failed expectations, {len(skipped)} skipped")
    if total_failed > 0:
        raise RuntimeError(f"{total_failed} GX expectations failed")
    return {"suites": len(results), "failed": total_failed, "skipped": skipped}
