# Orchestration — Dagster

`main.py`/`Makefile` was a hand-rolled DAG (`pg_staging → run_models → quality → gx`). This package replaces it with software-defined assets so failures are isolated per model, retries/backfills are built in, and the dims-before-facts order is enforced by the framework.

## Layout

```
orchestration/
├── assets/
│   ├── staging.py      # staging_all (+ dynamic staging_<collection> per Mongo coll)
│   ├── core.py         # 5 dims → 5 facts, deps = conformed dimensions
│   └── quality.py      # sql_dq_loops + gx_suites (both deps=*_core)
├── definitions.py      # Definitions(assets, jobs, schedules) + daily 06:00
└── README.md
```

## Assets

| Group    | Asset(s) | Deps |
|----------|----------|------|
| `staging` | `staging_all` (grouped incremental load via `pg_staging.run_load`) + `staging_<coll>` per collection (dynamic, for granular retries) | — |
| `core` | `dim_products`, `dim_customers`, `dim_geo`, `dim_orders_flag`, `dim_campaign` | `staging_all` |
| `core` | `fact_campaign_spend` (→ `dim_campaign`), `fact_inventory` (→ `dim_products`), `fact_order_process` (→ `dim_customers`), `fact_orders` (→ 4 dims), `fact_less_fact` (→ `dim_campaign`+`dim_products`) | dims |
| `quality` | `sql_dq_loops`, `gx_suites` | all 10 core assets |

`MODEL_SEQUENCE` from `scripts/python/run_models.py` is preserved — just expressed as `deps=[...]`.

## Run

Local (no Docker):

```bash
uv sync --group dev
uv run dagster dev -m orchestration.definitions   # http://localhost:3000
# or materialize headless:
uv run dagster job execute -m orchestration.definitions --job full_pipeline
```

Docker (with seeded DBs):

```bash
docker compose up --build -d postgres mongo      # start DBs
docker compose --profile dagster up dagster      # UI at http://localhost:3000
# or one-shot via pipeline container:
docker compose run --rm pipeline uv run dagster job execute -m orchestration.definitions --job full_pipeline
```

## Schedule

`daily_schedule` cron `0 6 * * *` runs `full_pipeline` (`selection="*"`). Dagster's daemon handles it when `dagster dev` is running; otherwise trigger manually from the UI or CLI.

## Interview talking point

> "I moved from a linear Python script to an asset-based DAG so failures are isolated per model, retries and backfills are built in, and the dependency graph — dims before facts — is enforced by the framework instead of a hardcoded `MODEL_SEQUENCE` list."

Pick Airflow instead only if the target company runs Airflow — matching their stack is a legit reason. The asset model maps 1:1 to Airflow DAG tasks.
