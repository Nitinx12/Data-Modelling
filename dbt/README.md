# dbt — core transforms with lineage

Hand-built PL/pgSQL in `models/` is the source of truth — it taught the mechanics (catalog loops, `ON CONFLICT` upserts, SCD2 close+insert). This `dbt/` project is a **framework-native mirror** that gives you lineage + docs for free.

```
dbt/
├── dbt_project.yml      # warehouse profile, staging→view, core→table
├── profiles.yml.example # postgres via env_var(POSTGRES_*) — no secrets committed
├── packages.yml         # dbt_utils for unique_combination_of_columns
├── models/
│   ├── staging/
│   │   ├── sources.yml  # 17 staging tables (typos preserved: campaing_logs etc.)
│   │   └── stg_*.sql    # thin views: select * from {{ source('staging', '...') }}
│   └── core/
│       ├── dim_*.sql    # {{ ref('stg_*') }} — same logic as models/dim_*.sql
│       ├── fact_*.sql   # {{ ref('dim_*') }} for FKs — dims before facts enforced by dbt
│       └── schema.yml   # not_null / unique / relationships — mirrors SQL loops 1,3,5
```

## Why keep both?

> "I hand-wrote catalog-driven quality loops because I wanted to understand the mechanics before reaching for a framework that does it for me."

The custom loops in `tests/sql/data_quality/` and `gx/` remain the **second** quality gate. `schema.yml` is a dbt-native mirror you can show in `dbt docs`.

## Run

```bash
# dbt/profiles.yml is gitignored — the dbt-* targets generate it from
# profiles.yml.example and source POSTGRES_* from .env in the same shell,
# so there is no manual cp / export step any more.
make dbt-deps    # install dbt_utils package (once)
make dbt-build   # build staging views -> core tables via ref lineage
make dbt-test    # tests only (framework mirror of loops 1,3,5)
make dbt-docs    # generate docs + serve on :8080
```

Schemas come from `models/*/… schema=` plus `macros/generate_schema_name.sql`,
which keeps dbt's default `<target.schema>_<custom>` prefix from splitting the
mirror off into `analytics_staging` / `analytics_core`. Models land in the same
`staging` / `core` schemas the hand-built pipeline uses.

With Docker:

```bash
docker compose run --rm pipeline uv run dbt build --project-dir dbt
```

## Lineage

`stg_*` → `dim_*` → `fact_*` — `dbt docs` auto-generates the graph. Compare to `orchestration/definitions.py` (Dagster assets) — same dims-before-facts DAG, different framework.

## SCD2 note

`dim_customers` is SCD2 in the hand-built model (`valid_from/to/is_current`). The dbt mirror here uses `table` materialization (recompute) for simplicity; a production SCD2 would be a dbt `snapshot` (see `snapshots/`). The hand-built version is intentionally retained to show you understand the mechanics.

> **Warning:** since the macro above maps dbt into `core`, `make dbt-build`
> rewrites `core.dim_customers` as a current-state table (`valid_from = now()`,
> one row per customer) and **discards any SCD2 history** the hand-built load
> has accumulated. Load the warehouse with `make models` / `make pipeline`;
> treat `dbt build` as the lineage/docs mirror, not as a warehouse load.
