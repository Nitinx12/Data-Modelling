# Hosting — live Postgres + live dashboard

This is the "Host it live" step (roadmap Tier 3 item 10). Goal: a link an interviewer can open with zero setup, showing live, current data from `core`.

## Architecture

```
GitHub Actions (refresh.yml, 06:30 UTC)
  → ephemeral Postgres+Mongo (docker/* seed)
  → make pipeline (staging → models → quality → GX --strict)
  → pg_dump -n core → psql $NEON_CONNECTION_STRING
  → Neon/Supabase (free tier, `core` schema only)

Streamlit Community Cloud (dashboard/Home.py)
  → reads Neon via st.secrets["postgres"] (dashboard_reader, SELECT only)
```

## One-time setup

### 1. Neon (or Supabase) project

- Create at https://neon.tech (free tier) or Supabase.
- Copy the connection string: `postgres://user:pass@host/db?sslmode=require`.

### 2. GitHub Secrets

Repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|--------|-------|
| `NEON_CONNECTION_STRING` | `postgres://...` from above |
| `MONGO_URI` | Atlas free tier URI, or keep ephemeral seed (demo) |
| `MONGO_DB` | `source` |

Without `NEON_CONNECTION_STRING`, `refresh.yml` still runs the pipeline and uploads `core_dump.sql` as an artifact — you can download and `psql` manually.

### 3. Prepare Neon `core` for the dashboard

One-time, from your local machine (after a local pipeline run):

```bash
pg_dump -h localhost -U user -d data_warehouse -n core --no-owner --no-privileges -f core_dump.sql
psql "$NEON_CONNECTION_STRING" -f core_dump.sql
psql "$NEON_CONNECTION_STRING" <<'SQL'
CREATE ROLE dashboard_reader WITH LOGIN PASSWORD 'strong-password';
GRANT USAGE ON SCHEMA core TO dashboard_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA core TO dashboard_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT SELECT ON TABLES TO dashboard_reader;
SQL
```

Use `dashboard_reader` in Streamlit Secrets — never the owner.

### 4. Streamlit Community Cloud

- Push `dashboard/` to GitHub (ensure `dashboard/.streamlit/secrets.toml` is gitignored).
- https://share.streamlit.io → New app → repo/branch → Main file `dashboard/Home.py`.
- Advanced → Secrets → paste `[postgres]` TOML for `dashboard_reader` (same Neon creds):

```toml
[postgres]
host = "ep-xxx.neon.tech"
port = 5432
database = "data_warehouse"
user = "dashboard_reader"
password = "..."
sslmode = "require"
```

Deploy → `https://data-modelling-uclgdbxwbuwhw9dtk4q9t8.streamlit.app`.

### 5. Verify

- Actions → Refresh Live Warehouse → Run workflow → check `core.fact_orders` count on Neon.
- Open the Streamlit URL, click through every page (Fulfillment, Sales, Marketing, Inventory, Health).
- Put the live link + CI badge at the top of `README.md` (see Live Dashboard placeholder).

## Refresh

- Automatic: `refresh.yml` cron `30 6 * * *` (06:30 UTC, after Dagster's 06:00 job) does the full pipeline + Neon push.
- Manual: `workflow_dispatch` or download `core_dump.sql` artifact and `psql` yourself.

## Local alternative

```bash
docker compose up --build          # pipeline + seeded DBs
# or
uv sync --group dev && make pipeline  # against your local Postgres+Mongo (.env)
```
