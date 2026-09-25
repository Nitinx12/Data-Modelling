# Decision Log

Design decisions for the warehouse, one line each. **D#** entries are decided —
do not reverse them in passing. **O#** entries are open and need a data owner
decision before anything changes.

## Decided

| # | Decision |
|---|---|
| D1 | Kimball dimensional model in `core`: five conformed dimensions, five facts, fact constellation rather than one star. |
| D2 | Four dimensions are SCD Type 1 (overwrite in place); `dim_customers` is SCD Type 2 (history retained via `valid_from`/`valid_to`/`is_current`, as-of join in `fact_orders`). Added 2026-09-19 — address/region changes matter for historical order analysis, other dims keep SCD1 for simplicity. |
| D3 | Every fact stores surrogate keys. Dimensions are resolved at load time via name joins because the staging sources carry names, not IDs. `fact_orders` resolves `dim_customers` as-of `order_date` (LATERAL, `valid_from <= order_date < valid_to`, fallback to current) to honor SCD2. |
| D4 | `fact_order_process` is an accumulating snapshot: one row per order, mutated in place as milestones arrive. Milestones are COALESCE-guarded so a source NULL cannot erase a loaded milestone. |
| D5 | `dim_orders_flag` is a junk dimension, insert only (`ON CONFLICT DO NOTHING`) — the attribute combination is the identity. |
| D6 | `fact_less_fact` carries no measures on purpose — it records only that a campaign promoted a SKU. |
| D7 | Staging keeps source typos (`campaing_logs`, `addres`, …) exactly as they arrive; renaming would break every consumer. |
| D8 | Data quality is double gated: the read only, catalog driven SQL loops and the Great Expectations suites in `gx/`, both run by `main.py` with `--strict` so red data fails the pipeline. |
| D9 | Future dated source values are quarantined in reject tables and self healed out of the fact on later runs, rather than failing the load. |
| D10 | `fact_inventory` unpivots a hard coded 2025 month list; extend it when 2026 columns land in staging. |
| D11 | Keep name-joins (customer_name/product_name) with collision guards (MIN+DISTINCT ON) and SCD2 as-of (LATERAL) until source emits IDs. See ADR-001 (2026-09-19) — product_name collisions (Kitchen M006) and as-of vs current were the breakages when hardening. |
| D12 | dbt is dropped (2026-09-25) — the `dbt/` mirror and its deps duplicated the hand-built PL/pgSQL without matching it (simplified `table` materialization instead of SCD2 history and `ON CONFLICT` upserts), so `models/` is now the only transform layer. Load order stays enforced by the `MODEL_SEQUENCE` in `run_models.py`, lineage lives in `docs/ERD.md` / `docs/Schema.md`. Added 2026-09-19 as a lineage/docs mirror, reversed deliberately on 2026-09-25. |

## Open — needs a data owner decision

| # | Question | Evidence |
|---|---|---|
| O1 | How should MongoDB deletions propagate? Options: soft delete flag in Mongo, periodic full refresh, or a delete log collection. | `staging.campaing_sku` holds 30 rows against 6 live Mongo documents. |
| O2 | What are the seven unconsumed staging tables for (`dim_orders`, `exchange_rate`, `invoice_inlines`, `region`, `security`, `sheet_1`, `target_revenue`) — future models, or stop extracting them? | No model reads them. |
| O3 | Should `dim_customers` dedup rank on `GREATEST` of master and address `update_at` instead of the address timestamp alone? | `cust_master.update_at` exists but is unused in the ranking. |
| O4 | Should regions become a conformed dimension wired to `staging.region`? | `region_name` is free text on `dim_geo` and `dim_customers`; current drift is zero. |

When an O item is decided, move it to the Decided table with its outcome and
date, and update `CLAUDE.md` known issues if applicable.
