# Decision Log

Design decisions for the warehouse, one line each. **D#** entries are decided —
do not reverse them in passing. **O#** entries are open and need a data owner
decision before anything changes.

## Decided

| # | Decision |
|---|---|
| D1 | Kimball dimensional model in `core`: five conformed dimensions, five facts, fact constellation rather than one star. |
| D2 | All dimensions are SCD Type 1 (overwrite in place). No history is retained anywhere; add SCD2 only if a requirement appears. |
| D3 | Every fact stores surrogate keys. Dimensions are resolved at load time via name joins because the staging sources carry names, not IDs. |
| D4 | `fact_order_process` is an accumulating snapshot: one row per order, mutated in place as milestones arrive. Milestones are COALESCE-guarded so a source NULL cannot erase a loaded milestone. |
| D5 | `dim_orders_flag` is a junk dimension, insert only (`ON CONFLICT DO NOTHING`) — the attribute combination is the identity. |
| D6 | `fact_less_fact` carries no measures on purpose — it records only that a campaign promoted a SKU. |
| D7 | Staging keeps source typos (`campaing_logs`, `addres`, …) exactly as they arrive; renaming would break every consumer. |
| D8 | Data quality loops are read only and catalog driven; `main.py` runs them with `--strict` so red data fails the pipeline. |
| D9 | Future dated source values are quarantined in reject tables and self healed out of the fact on later runs, rather than failing the load. |
| D10 | `fact_inventory` unpivots a hard coded 2025 month list; extend it when 2026 columns land in staging. |

## Open — needs a data owner decision

| # | Question | Evidence |
|---|---|---|
| O1 | How should MongoDB deletions propagate? Options: soft delete flag in Mongo, periodic full refresh, or a delete log collection. | `staging.campaing_sku` holds 30 rows against 6 live Mongo documents. |
| O2 | What are the seven unconsumed staging tables for (`dim_orders`, `exchange_rate`, `invoice_inlines`, `region`, `security`, `sheet_1`, `target_revenue`) — future models, or stop extracting them? | No model reads them. |
| O3 | Should `dim_customers` dedup rank on `GREATEST` of master and address `update_at` instead of the address timestamp alone? | `cust_master.update_at` exists but is unused in the ranking. |
| O4 | Should regions become a conformed dimension wired to `staging.region`? | `region_name` is free text on `dim_geo` and `dim_customers`; current drift is zero. |
| O5 | Should dimension resolution move from name joins to business IDs? | Names are not guaranteed unique or stable; IDs are. |

When an O item is decided, move it to the Decided table with its outcome and
date, and update `CLAUDE.md` known issues if applicable.
