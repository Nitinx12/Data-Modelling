"""
pg_staging.py

Extract documents from MongoDB and load them into Postgres staging tables,
using this project's shared utils.connection / utils.engine / utils.logger.

Naming rule : target table = exact Mongo collection name. No suffixes
              (no "_stg", no "_staging"), no renaming of any kind.

Incremental strategy (per collection):
    - Merge key      : _id        (Mongo ObjectId, stored as TEXT)
    - Watermark col  : update_at

    First run for a collection -> full extract, CREATE TABLE, bulk insert.
    Later runs                 -> pull only docs where update_at is greater
                                   than the max update_at already in the
                                   target table, then upsert by _id.
    If a collection has no `update_at` field at all, it's treated as
    non-incremental: every run does a full extract and upserts by _id only.

Collection selection:
    --collection <name>  -> load just that one collection.
    (omitted)             -> load every collection in the Mongo database.

Logs full detail (queries, row counts, tracebacks) to
logs/staging/staging_<date>.log via utils.logger.get_logger(...). The
terminal itself is rendered with Rich: a live status line per collection
and a colored summary table at the end - the plain logger's console
output is silenced to avoid duplicating that.

NOTE ON SCHEMA: utils/engine.py currently only defines
POSTGRES_SCHEMA_BRONZE / SILVER / GOLD - there's no POSTGRES_SCHEMA_STAGING.
This script targets BRONZE as the raw-landing equivalent of "staging". If
your bronze schema isn't literally named "staging" in .env, either rename
it there or add a POSTGRES_SCHEMA_STAGING var and swap PG_SCHEMA below.

Can be run from anywhere inside the project (project root is auto-detected
via pyproject.toml, so `utils` always resolves regardless of cwd).

Usage:
    uv run pg_staging.py                       # every collection
    uv run pg_staging.py --collection Address   # just one
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def _find_project_root(marker: str = "pyproject.toml") -> Path:
    """Walk upward from this file until a directory containing `marker` is found."""
    path = Path(__file__).resolve().parent
    for parent in [path, *path.parents]:
        if (parent / marker).exists():
            return parent
    raise RuntimeError(f"Could not locate project root (no {marker} found above {path})")


sys.path.insert(0, str(_find_project_root()))

import polars as pl
from psycopg2 import sql
from psycopg2.extras import execute_values
from rich.console import Console
from rich.progress import SpinnerColumn, TextColumn, TimeElapsedColumn
from rich.progress import Progress as RichProgress
from rich.table import Table

from utils import engine as config
from utils.connection import get_mongo_db, get_postgres_engine
from utils.logger import get_logger

console = Console()

# Full detail (queries, row counts, tracebacks) still goes to logs/staging/ -
# the console is silenced here because Rich renders the human-facing output.
log = get_logger("staging", subdir="staging", console_level=logging.CRITICAL)

MERGE_KEY = "_id"
WATERMARK_COL = "update_at"

# See NOTE ON SCHEMA above. Try POSTGRES_SCHEMA_STAGING first (the correct
# name for this use case), then fall back to POSTGRES_SCHEMA_BRONZE if
# that's what your .env actually defines.
PG_SCHEMA = os.getenv("POSTGRES_SCHEMA_STAGING") or config.POSTGRES_SCHEMA_BRONZE

# Polars dtype -> Postgres column type, for first-run table creation
PG_TYPE_MAP = {
    pl.Utf8: "TEXT",
    pl.Int32: "INTEGER",
    pl.Int64: "BIGINT",
    pl.Float64: "DOUBLE PRECISION",
    pl.Boolean: "BOOLEAN",
    pl.Datetime: "TIMESTAMP",
}


def table_exists(cur, table: str) -> bool:
    cur.execute(
        "SELECT 1 FROM information_schema.tables "
        "WHERE table_schema = %s AND table_name = %s",
        (PG_SCHEMA, table),
    )
    return cur.fetchone() is not None


def has_column(cur, table: str, column: str) -> bool:
    cur.execute(
        "SELECT 1 FROM information_schema.columns "
        "WHERE table_schema = %s AND table_name = %s AND column_name = %s",
        (PG_SCHEMA, table, column),
    )
    return cur.fetchone() is not None


def get_watermark(cur, table: str):
    cur.execute(
        sql.SQL("SELECT MAX({col}) FROM {schema}.{table}").format(
            col=sql.Identifier(WATERMARK_COL),
            schema=sql.Identifier(PG_SCHEMA),
            table=sql.Identifier(table),
        )
    )
    return cur.fetchone()[0]


def extract_from_mongo(collection: str, watermark) -> pl.DataFrame:
    db = get_mongo_db()
    coll = db[collection]

    query = {}
    if watermark is not None:
        query[WATERMARK_COL] = {"$gt": watermark}

    log.info(f"[{collection}] querying (watermark={watermark})")
    docs = list(coll.find(query))

    for d in docs:
        d[MERGE_KEY] = str(d[MERGE_KEY])  # ObjectId -> str, field name kept as-is

    log.info(f"[{collection}] extracted {len(docs)} document(s)")
    return pl.DataFrame(docs) if docs else pl.DataFrame()


def _bulk_insert(cur, table: str, df: pl.DataFrame, schema: str | None):
    if df.is_empty():
        return
    cols = list(df.schema.keys())
    target = (
        sql.SQL("{}.{}").format(sql.Identifier(schema), sql.Identifier(table))
        if schema
        else sql.Identifier(table)
    )
    stmt = sql.SQL("INSERT INTO {target} ({cols}) VALUES %s").format(
        target=target,
        cols=sql.SQL(", ").join(sql.Identifier(c) for c in cols),
    )
    execute_values(cur, stmt.as_string(cur), df.rows())


def create_table(cur, table: str, df: pl.DataFrame):
    cols_sql = []
    for name, dtype in df.schema.items():
        pg_type = PG_TYPE_MAP.get(dtype, "TEXT")
        cols_sql.append(sql.SQL("{} {}").format(sql.Identifier(name), sql.SQL(pg_type)))

    stmt = sql.SQL("CREATE TABLE {schema}.{table} ({cols}, PRIMARY KEY ({key}))").format(
        schema=sql.Identifier(PG_SCHEMA),
        table=sql.Identifier(table),
        cols=sql.SQL(", ").join(cols_sql),
        key=sql.Identifier(MERGE_KEY),
    )
    log.info(f"Creating table {PG_SCHEMA}.{table}")
    cur.execute(stmt)


def load_full(cur, table: str, df: pl.DataFrame):
    create_table(cur, table, df)
    _bulk_insert(cur, table, df, schema=PG_SCHEMA)


def load_incremental(cur, table: str, df: pl.DataFrame):
    tmp = f"{table}__incoming"
    cur.execute(
        sql.SQL("CREATE TEMP TABLE {tmp} (LIKE {schema}.{table} INCLUDING ALL)").format(
            tmp=sql.Identifier(tmp),
            schema=sql.Identifier(PG_SCHEMA),
            table=sql.Identifier(table),
        )
    )
    _bulk_insert(cur, tmp, df, schema=None)

    cols = list(df.schema.keys())
    non_key_cols = [c for c in cols if c != MERGE_KEY]
    set_clause = sql.SQL(", ").join(
        sql.SQL("{c} = EXCLUDED.{c}").format(c=sql.Identifier(c)) for c in non_key_cols
    )

    log.info(f"Upserting into {PG_SCHEMA}.{table} via temp table {tmp}")
    cur.execute(
        sql.SQL(
            "INSERT INTO {schema}.{table} ({cols}) "
            "SELECT {cols} FROM {tmp} "
            "ON CONFLICT ({key}) DO UPDATE SET {set_clause}"
        ).format(
            schema=sql.Identifier(PG_SCHEMA),
            table=sql.Identifier(table),
            cols=sql.SQL(", ").join(sql.Identifier(c) for c in cols),
            tmp=sql.Identifier(tmp),
            key=sql.Identifier(MERGE_KEY),
            set_clause=set_clause,
        )
    )


def run_load(cur, collection: str) -> dict:
    """Extract + load one collection. Does NOT commit - caller controls the transaction."""
    table = collection
    start = time.time()

    exists = table_exists(cur, table)
    watermark_eligible = exists and has_column(cur, table, WATERMARK_COL)
    watermark = get_watermark(cur, table) if watermark_eligible else None

    if exists and not watermark_eligible:
        log.warning(f"[{collection}] no '{WATERMARK_COL}' column on target - doing a full refresh")

    df = extract_from_mongo(collection, watermark)
    rows_extracted = df.height
    rows_loaded = 0

    if not exists:
        if df.is_empty():
            mode = "skipped (empty, no table created)"
            log.warning(f"[{collection}] {mode}")
        else:
            load_full(cur, table, df)
            mode = "full load (table created)"
            rows_loaded = rows_extracted
    else:
        if df.is_empty():
            mode = "incremental (no new/updated rows)"
        else:
            load_incremental(cur, table, df)
            mode = "incremental (upsert)" if watermark_eligible else "full refresh (upsert)"
            rows_loaded = rows_extracted

    new_watermark = (
        df[WATERMARK_COL].max() if (not df.is_empty() and WATERMARK_COL in df.schema) else watermark
    )
    elapsed = time.time() - start

    log.info(
        f"[{collection}] {mode} - extracted={rows_extracted} loaded={rows_loaded} "
        f"watermark {watermark} -> {new_watermark} ({elapsed:.2f}s)"
    )

    return {
        "collection": collection,
        "table": table,
        "mode": mode,
        "rows_extracted": rows_extracted,
        "rows_loaded": rows_loaded,
        "watermark_before": watermark,
        "watermark_after": new_watermark,
        "elapsed": elapsed,
    }


def _status_style(mode: str) -> tuple[str, str]:
    """Return (icon, color) for a result's mode string."""
    if mode.startswith("FAILED"):
        return "✗", "red"
    if "skipped" in mode or "no new" in mode:
        return "•", "yellow"
    return "✓", "green"


def main():
    parser = argparse.ArgumentParser(description="Mongo -> Postgres staging loader")
    parser.add_argument(
        "--collection",
        default=None,
        help=(
            "Exact Mongo collection name, used as-is for the target table. "
            "If omitted, every collection in the Mongo database is loaded."
        ),
    )
    args = parser.parse_args()

    console.rule("[bold blue]Postgres Staging Load[/bold blue]")

    if not PG_SCHEMA:
        console.print(
            "[bold red]✗ No target schema configured.[/bold red] Set "
            "POSTGRES_SCHEMA_STAGING (or POSTGRES_SCHEMA_BRONZE) in your .env "
            "before running this script."
        )
        log.error("No target schema configured (POSTGRES_SCHEMA_STAGING / POSTGRES_SCHEMA_BRONZE unset)")
        sys.exit(1)

    engine = get_postgres_engine()
    raw_conn = engine.raw_connection()
    cur = raw_conn.cursor()

    if args.collection:
        collections = [args.collection]
    else:
        db = get_mongo_db()
        collections = sorted(db.list_collection_names())
        console.print(f"No --collection given - running all [bold]{len(collections)}[/bold] collection(s)")
        log.info(f"No --collection given - running all {len(collections)} collection(s): {collections}")

    overall_start = time.time()
    results = []

    with RichProgress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        TimeElapsedColumn(),
        console=console,
    ) as progress:
        task = progress.add_task(f"Loading {len(collections)} collection(s)...", total=len(collections))

        for name in collections:
            progress.update(task, description=f"Loading [bold]{name}[/bold]...")
            try:
                result = run_load(cur, name)
                raw_conn.commit()
            except Exception as exc:
                raw_conn.rollback()
                log.exception(f"[{name}] load failed; rolled back, continuing with next collection")
                result = {
                    "collection": name,
                    "table": name,
                    "mode": f"FAILED: {exc}",
                    "rows_extracted": 0,
                    "rows_loaded": 0,
                    "watermark_before": None,
                    "watermark_after": None,
                    "elapsed": 0.0,
                }
            results.append(result)

            icon, style = _status_style(str(result["mode"]))
            progress.console.print(
                f"[{style}]{icon}[/{style}] {result['collection']:<25} "
                f"[{style}]{result['mode']}[/{style}]  "
                f"extracted={result['rows_extracted']} loaded={result['rows_loaded']}"
            )
            progress.advance(task)

    cur.close()
    raw_conn.close()

    total_elapsed = time.time() - overall_start
    total_extracted = sum(r["rows_extracted"] for r in results)
    total_loaded = sum(r["rows_loaded"] for r in results)
    failed = [r["collection"] for r in results if str(r["mode"]).startswith("FAILED")]

    table = Table(title="Load Summary")
    table.add_column("Collection", style="bold")
    table.add_column("Mode")
    table.add_column("Extracted", justify="right")
    table.add_column("Loaded", justify="right")
    table.add_column("Elapsed (s)", justify="right")

    for r in results:
        _, style = _status_style(str(r["mode"]))
        table.add_row(
            r["collection"],
            f"[{style}]{r['mode']}[/{style}]",
            str(r["rows_extracted"]),
            str(r["rows_loaded"]),
            f"{r['elapsed']:.2f}",
        )

    console.print(table)
    console.print(
        f"[bold]Collections:[/bold] {len(results)}   "
        f"[bold]Failed:[/bold] [{'red' if failed else 'green'}]{len(failed)}[/{'red' if failed else 'green'}]   "
        f"[bold]Total extracted:[/bold] {total_extracted}   "
        f"[bold]Total loaded:[/bold] {total_loaded}   "
        f"[bold]Elapsed:[/bold] {total_elapsed:.2f}s"
    )

    log.info(
        f"Run complete: {len(results)} collection(s), {len(failed)} failed, "
        f"{total_extracted} extracted, {total_loaded} loaded, {total_elapsed:.2f}s, "
        f"run at (UTC) {datetime.now(timezone.utc).isoformat()}"
    )

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()