# sql/analytics/ — SQL scripts

Hand-written queries for exploration and reporting against the `core`
schema, plus the few one-time DDL scripts that used to sit loose in `sql/`.
These are **not** part of the pipeline in `scripts/run_models.py` —
nothing here writes warehouse data. Run them directly with `psql`, DBeaver, a BI
tool, or paste into a notebook.

| File | Answers |
|---|---|
| `00_create_database_and_schemas.sql` | One-time bootstrap: `CREATE DATABASE` + `staging`/`core` schemas. Run manually, never as part of `make analytics`. |
| `01_revenue_trend_by_region.sql` | How is revenue trending over time, by shipping region? |
| `02_top_products_by_revenue.sql` | What are the best-selling products? |
| `03_top_customers_by_revenue.sql` | Who are the highest-value customers? |
| `04_order_fulfillment_sla.sql` | How fast are orders shipped/delivered/paid, by ship mode? |
| `05_campaign_performance.sql` | Spend, reach, CTR, and budget pacing per campaign. |
| `06_inventory_mom_change.sql` | Which products are gaining/losing stock month over month? |
| `07_orders_by_channel_status_priority.sql` | Where does revenue sit across channel/status/priority? |
| `08_data_quality_checks.sql` | Any unmatched dim keys or quarantined rows to be aware of? |
| `09_fn_customer_function.sql` | Dynamic SQL function for customer |
| `10_fn_products_function.sql` | Dynamic SQL function for products |
| `11_pipeline_run_log.sql` | Creates `core.pipeline_run_log` (also created automatically by the pipeline). |


## Conventions
- All queries are read only `SELECT`s — safe to run anytime, no locks held.
- `LIMIT`s on top-N queries are a starting point; adjust as needed.
- `08_data_quality_checks.sql` is worth running first if a number looks
  off — it flags rows where a dimension lookup failed at load time.