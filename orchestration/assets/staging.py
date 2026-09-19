"""Staging assets — MongoDB -> Postgres staging.

Each collection becomes an asset; a grouped asset `staging_all` wraps the
existing incremental logic in pg_staging.py so the Dagster graph still
benefits from isolated retries per collection when needed.

For the interview demo, the per-collection assets are defined dynamically
from the live collection list, but the default run materializes all via
`staging_all`.
"""

from __future__ import annotations

import sys
from pathlib import Path

from dagster import asset

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


@asset(group_name="staging", compute_kind="python")
def staging_all(context) -> dict:
    """Load every Mongo collection into staging (incremental, watermarked).

    Wraps scripts/python/pg_staging.py `run_load` loop. Returns a summary
    dict so the Dagster UI shows row counts.
    """
    from scripts.python.pg_staging import run_load
    from utils.connection import get_mongo_db, get_postgres_engine

    engine = get_postgres_engine()
    raw_conn = engine.raw_connection()
    cur = raw_conn.cursor()

    try:
        db = get_mongo_db()
        collections = sorted(db.list_collection_names())
        context.log.info(
            f"Staging load: {len(collections)} collections — {collections}"
        )

        results: list[dict] = []
        for name in collections:
            try:
                result = run_load(cur, name)
                raw_conn.commit()
                context.log.info(
                    f"{name}: {result['mode']} extracted={result['rows_extracted']}"
                )
            except Exception as exc:
                raw_conn.rollback()
                context.log.error(f"{name} failed: {exc}")
                raise
            results.append(result)

        total_extracted = sum(r["rows_extracted"] for r in results)
        total_loaded = sum(r["rows_loaded"] for r in results)
        context.log.info(
            f"Staging complete: {total_extracted} extracted, {total_loaded} loaded"
        )
        return {
            "collections": len(results),
            "total_extracted": total_extracted,
            "total_loaded": total_loaded,
            "results": results,
        }
    finally:
        cur.close()
        raw_conn.close()


# Dynamic per-collection assets (one asset per Mongo collection) for
# granular retries/backfills. Created lazily so Dagster's graph reflects
# the actual source. Fallback to staging_all if Mongo is unavailable at
# definition time (e.g. CI import without services).


def _make_collection_asset(collection: str):
    @asset(name=f"staging_{collection}", group_name="staging", compute_kind="python")
    def _asset(context) -> dict:
        from scripts.python.pg_staging import run_load
        from utils.connection import get_postgres_engine

        engine = get_postgres_engine()
        raw_conn = engine.raw_connection()
        cur = raw_conn.cursor()
        try:
            result = run_load(cur, collection)
            raw_conn.commit()
            context.log.info(f"{collection}: {result}")
            return result
        except Exception:
            raw_conn.rollback()
            raise
        finally:
            cur.close()
            raw_conn.close()

    return _asset


# Attempt to define per-collection assets; gracefully degrade to just staging_all
# if Mongo isn't reachable at import (local import without running services).
try:
    from utils.connection import get_mongo_db as _get_db

    _cols = sorted(_get_db().list_collection_names())
    for _c in _cols:
        globals()[f"staging_{_c}"] = _make_collection_asset(_c)
except Exception:  # noqa: BLE001, S110
    pass
