"""DB helpers — cached engine + query runner over core.

Connection priority:
1. st.secrets["postgres"] (Streamlit Cloud / local secrets.toml)
2. env vars / .env via utils.engine (local Docker Compose: localhost)
3. Streamlit secrets fallback for sslmode

All queries are read-only against core.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pandas as pd
import streamlit as st
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

# Allow importing utils/ when running as `streamlit run dashboard/Home.py`
_DASHBOARD_ROOT = Path(__file__).resolve().parents[2]
if str(_DASHBOARD_ROOT) not in sys.path:
    sys.path.insert(0, str(_DASHBOARD_ROOT))


def _creds_from_secrets() -> dict | None:
    try:
        s = st.secrets["postgres"]  # type: ignore[index]
        return {
            "host": s.get("host") or s.get("POSTGRES_HOST"),
            "port": s.get("port") or s.get("POSTGRES_PORT") or 5432,
            "database": s.get("database")
            or s.get("POSTGRES_DATABASE")
            or s.get("database"),
            "user": s.get("user") or s.get("POSTGRES_USERNAME") or s.get("username"),
            "password": s.get("password")
            or s.get("POSTGRES_PASSWORD")
            or s.get("pass"),
            "sslmode": s.get("sslmode"),
        }
    except Exception:
        return None


def _creds_from_env() -> dict | None:
    try:
        from utils import engine as cfg

        if not cfg.POSTGRES_HOST:
            return None
        return {
            "host": cfg.POSTGRES_HOST,
            "port": cfg.POSTGRES_PORT or 5432,
            "database": cfg.POSTGRES_DATABASE,
            "user": cfg.POSTGRES_USERNAME,
            "password": cfg.POSTGRES_PASSWORD,
            "sslmode": getattr(cfg, "POSTGRES_SSLMODE", None),
        }
    except Exception:
        # Fallback to raw env (outside utils)
        host = os.getenv("POSTGRES_HOST") or os.getenv("POSTGRES_HOSTNAME")
        if not host:
            return None
        return {
            "host": host,
            "port": int(os.getenv("POSTGRES_PORT", "5432")),
            "database": os.getenv("POSTGRES_DATABASE") or os.getenv("POSTGRES_DB"),
            "user": os.getenv("POSTGRES_USERNAME") or os.getenv("POSTGRES_USER"),
            "password": os.getenv("POSTGRES_PASSWORD") or os.getenv("POSTGRES_PASS"),
            "sslmode": os.getenv("POSTGRES_SSLMODE"),
        }


@st.cache_resource(show_spinner=False)
def get_engine() -> Engine:
    """Create a cached SQLAlchemy engine (pool_pre_ping for cloud DB)."""
    creds = _creds_from_secrets() or _creds_from_env()
    if not creds or not creds.get("host"):
        raise RuntimeError(
            "No Postgres credentials found. Set dashboard/.streamlit/secrets.toml "
            "[postgres] or POSTGRES_HOST env (see dashboard/.streamlit/secrets.toml.example)."
        )
    # Build URL — include sslmode only when set (Neon/Supabase require it)
    query = {}
    if creds.get("sslmode"):
        query["sslmode"] = creds["sslmode"]
    # Cloud hosts (neon.tech, supabase) default to require if not specified
    elif creds["host"] and (
        "neon.tech" in creds["host"] or "supabase" in creds["host"]
    ):
        query["sslmode"] = "require"

    from sqlalchemy.engine import URL

    url = URL.create(
        "postgresql+psycopg2",
        username=creds["user"],
        password=creds["password"],
        host=creds["host"],
        port=int(creds["port"]),
        database=creds["database"],
        query=query,
    )
    engine = create_engine(url, pool_pre_ping=True, pool_recycle=300)
    # Quick ping to surface auth/network errors early (cached, so once per session)
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    return engine


@st.cache_data(ttl=600, show_spinner=False)
def run_query(sql: str, params: dict | None = None) -> pd.DataFrame:
    """Run a read-only SQL query against core and return a DataFrame.

    10-minute cache (ttl=600) — tune to how often you refresh core.
    Use params for sidebar filters (never string-format user input).
    """
    engine = get_engine()
    with engine.connect() as conn:
        return pd.read_sql(text(sql), conn, params=params or {})


def last_refresh() -> str | None:
    """Try to infer last pipeline refresh from core table timestamps."""
    try:
        df = run_query(
            """
            SELECT MAX(dw_updated_at) AS last_updated
            FROM (
                SELECT dw_updated_at FROM core.dim_customers
                UNION ALL SELECT dw_updated_at FROM core.fact_orders
                UNION ALL SELECT dw_updated_at FROM core.fact_order_process
            ) AS t
            """
        )
        v = df.iloc[0]["last_updated"]
        return str(v) if pd.notna(v) else None
    except Exception:
        return None
