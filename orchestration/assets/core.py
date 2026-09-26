"""Core assets — dims then facts, deps enforced by Dagster.

Each model in MODEL_SEQUENCE becomes an asset. Dimension assets have no
deps (or only staging_all); fact assets depend on their conformed
dimensions. This replaces the hardcoded MODEL_SEQUENCE order with a
framework-enforced DAG — failures are isolated, retries are per-model,
and backfills are built in.

Business keys, grains, and SCD1 semantics are unchanged (see models/*.sql).
"""

from __future__ import annotations

import sys
from pathlib import Path

from dagster import asset

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from orchestration.assets.staging import staging_all

MODELS_DIR = PROJECT_ROOT / "models"


def _ensure_project_root() -> None:
    """Re-apply the project-root sys.path edit inside compute functions.

    Module-level sys.path edits do not propagate to Dagster's spawned step
    worker processes, so every compute function calls this first. PROJECT_ROOT
    is an absolute path baked in at definition time, so it stays correct no
    matter which cwd a worker starts from.
    """
    if str(PROJECT_ROOT) not in sys.path:
        sys.path.insert(0, str(PROJECT_ROOT))


def _run_model_sql(model_name: str, context) -> dict:
    """Execute one model SQL file via run_models logic."""
    _ensure_project_root()
    from utils.connection import get_postgres_engine

    path = MODELS_DIR / model_name
    sql_text = path.read_text(encoding="utf-8")
    context.log.info(f"Running model {model_name}")

    engine = get_postgres_engine()
    raw_conn = engine.raw_connection()
    try:
        if hasattr(raw_conn, "notices"):
            raw_conn.notices.clear()
        cur = raw_conn.cursor()
        cur.execute(sql_text)
        raw_conn.commit()
        notices = [n.strip() for n in getattr(raw_conn, "notices", [])]
        for n in notices:
            context.log.info(f"{model_name} notice: {n}")
        return {"model": model_name, "status": "PASS", "notices": notices}
    except Exception as exc:
        raw_conn.rollback()
        context.log.error(f"{model_name} failed: {exc}")
        raise
    finally:
        raw_conn.close()


# ------------------------------------------------------------------
# Dimensions — depend only on staging_all (any order among themselves)
# ------------------------------------------------------------------


@asset(deps=[staging_all], group_name="core", compute_kind="sql")
def dim_products(context) -> dict:
    return _run_model_sql("dim_products.sql", context)


@asset(deps=[staging_all], group_name="core", compute_kind="sql")
def dim_customers(context) -> dict:
    return _run_model_sql("dim_customers.sql", context)


@asset(deps=[staging_all], group_name="core", compute_kind="sql")
def dim_geo(context) -> dict:
    return _run_model_sql("dim_geo.sql", context)


@asset(deps=[staging_all], group_name="core", compute_kind="sql")
def dim_orders_flag(context) -> dict:
    return _run_model_sql("dim_orders_flag.sql", context)


@asset(deps=[staging_all], group_name="core", compute_kind="sql")
def dim_campaign(context) -> dict:
    return _run_model_sql("dim_campaign.sql", context)


# ------------------------------------------------------------------
# Facts — depend on their conformed dimensions
# ------------------------------------------------------------------


@asset(deps=[dim_campaign], group_name="core", compute_kind="sql")
def fact_campaign_spend(context) -> dict:
    return _run_model_sql("fact_campaign_spend.sql", context)


@asset(deps=[dim_products], group_name="core", compute_kind="sql")
def fact_inventory(context) -> dict:
    return _run_model_sql("fact_inventory.sql", context)


@asset(deps=[dim_customers], group_name="core", compute_kind="sql")
def fact_order_process(context) -> dict:
    return _run_model_sql("fact_order_process.sql", context)


@asset(
    deps=[dim_customers, dim_products, dim_orders_flag, dim_geo],
    group_name="core",
    compute_kind="sql",
)
def fact_orders(context) -> dict:
    return _run_model_sql("fact_orders.sql", context)


@asset(deps=[dim_campaign, dim_products], group_name="core", compute_kind="sql")
def fact_less_fact(context) -> dict:
    return _run_model_sql("fact_less_fact.sql", context)
