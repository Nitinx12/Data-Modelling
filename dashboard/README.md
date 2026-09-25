# Dashboard — Streamlit on `core`

Live view over the `core` warehouse (see `docs/data_catlog.md`). Pages map directly onto fact tables so the dashboard feels intentional.

## Pages

| Page | File | Fact | What it shows |
|------|------|------|---------------|
| Overview | `Home.py` | all | KPI cards + revenue trend, order funnel, revenue treemap, line-value boxplot, spend bar, channel×month heatmap |
| Order Fulfillment | `pages/1_Order_Fulfillment.py` | `fact_order_process` | Funnel Ordered→Paid, avg days per stage, cycle-time boxplot by ship mode (accumulating snapshot) |
| Sales | `pages/2_Sales.py` | `fact_orders` | Revenue trend, product treemap, boxplot by channel, price-vs-value scatter, weekday×month heatmap, ship/bill split |
| Marketing | `pages/3_Marketing.py` | `fact_campaign_spend` + `fact_less_fact` | Spend trend, channel▸campaign sunburst, daily-spend boxplot, impressions-vs-clicks scatter, spend/sku |
| Inventory | `pages/4_Inventory.py` | `fact_inventory` | Monthly stock trend, latest-month table, category boxplot, product×month heatmap |
| Pipeline Health | `pages/5_Pipeline_Health.py` | all + quarantines | Counts, stage outcome bars, SCD2 history, orphan keys, future-dated quarantines |

Every chart is built by `lib/charts.py` on one shared Plotly theme and palette; `Home.py` carries a `↻ Refresh` button that clears the 10-minute query cache.

If the app fails while importing `lib/`, `Home.py` prints the real exception with `st.exception` instead of Streamlit Cloud's redacted message — check `dashboard/requirements.txt` first.

## Setup — cloud Postgres for the deployed app

Streamlit Community Cloud cannot reach `localhost`. Host a read-only copy of `core` on Neon/Supabase:

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

## Local run

```bash
pip install -r dashboard/requirements.txt
# or: uv sync --group dev && uv run streamlit run dashboard/Home.py
cp dashboard/.streamlit/secrets.toml.example dashboard/.streamlit/secrets.toml
# edit secrets.toml [postgres] to point at Neon or localhost via env fallback
streamlit run dashboard/Home.py
```

The app resolves creds in order: `st.secrets["postgres"]` → `utils.engine` / `POSTGRES_*` env (Docker Compose `localhost`) → error with hint.

## Deploy on Streamlit Community Cloud

1. Push `dashboard/` to GitHub (ensure `dashboard/.streamlit/secrets.toml` is gitignored).
2. https://share.streamlit.io → New app → repo/branch → Main file `dashboard/Home.py`.
3. Advanced → Secrets → paste `[postgres]` TOML (same as local secrets.toml).
4. Deploy → `https://data-modelling-uclgdbxwbuwhw9dtk4q9t8.streamlit.app` — verify every page loads against the **cloud** DB.

Add the URL to the top of `README.md` next to the CI badge.

## Refresh

- Manual: re-run `pg_dump`/`psql` after each pipeline run.
- Scheduled: GitHub Actions cron that runs `make pipeline` and pushes `core` nightly.
- Direct: point the dashboard at a cloud-hosted warehouse (no sync).

## Structure

```
dashboard/
├── Home.py               # inserts dashboard/ on sys.path before importing lib
├── pages/1_*.py … 5_*.py # same bootstrap (parents[1])
├── lib/db.py      # st.cache_resource engine + st.cache_data run_query
├── lib/charts.py  # treemap/box/scatter/heatmap/sunburst/funnel/bar/line builders
├── .streamlit/config.toml   # theme
├── .streamlit/secrets.toml.example
└── requirements.txt
```

Every entry file bootstraps `sys.path` itself, so `from lib.…` works the same
way locally, under `streamlit run`, on Streamlit Community Cloud, and in
`AppTest` — the repo tracks no `__init__.py` (`.gitignore` has `**/__init__.py`),
so `lib` only resolves from `dashboard/`.

Grounded in your model: each page’s caption names its grain/pattern (transaction fact, accumulating snapshot, factless fact, periodic snapshot, role-playing dimension) — that’s what makes it yours, not a generic BI template.
