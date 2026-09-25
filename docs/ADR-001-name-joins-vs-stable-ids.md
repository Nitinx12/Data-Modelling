# ADR-001: Name-joins vs stable IDs — why facts still resolve by name

Date: 2026-09-19
Status: Decided (resolves DECISIONS.md O5)
Deciders: Warehouse team

## Context

Facts resolve `dim_customers`/`dim_products` by **name** (`customer_name`, `product_name`) rather than the stable business keys (`customer_id`, `product_code`). Names are not guaranteed unique or stable; IDs are. This is logged as `DECISIONS.md O5` and noted in `data_catlog.md §4` as a join-key inconsistency.

The reason name-joins exist is upstream: the staging sources carry names, not IDs.

- `staging.orders_2025` / `orders_2026` carry `CustomerName`, not `CustomerID` (see `staging.orders_2025."CustomerName"`). There is no `CustomerID` column to join on.
- `staging.order_line_items` carries `ProductName`, not `ProductCode`.
- The same is true for `fact_order_process` (also name-joins to `dim_customers`).

Moving to ID-joins would require either (a) the source Mongo collections to emit IDs, or (b) a synonym/mapping table that resolves `CustomerName → CustomerID` with its own dedup and history rules — essentially reimplementing the customer entity resolution we already defer to `dim_customers`.

## Decision

**Keep name-joins, but make them collision-safe. Do not move to ID-joins until the source emits IDs.**

- `dim_products` product_name is not unique — `Kitchen M006` and `Audio M020` each map to two `product_code`s. The naïve `JOIN dim_products ON product_name` fans out to two rows per fact line and can fail the `ON CONFLICT (order_id, line_id)` upsert. Fixed in `models/fact_orders.sql:181` by collapsing `dim_products` to one `MIN(product_key)` per `product_name` and adding `DISTINCT ON (order_id, line_id) ORDER BY update_at DESC` so fan-out can never fail the upsert (keep most recent source row).
- `dim_customers` is now SCD2 (`valid_from`/`valid_to`/`is_current`, `models/dim_customers.sql:14`), so `fact_orders` must resolve **as-of** `order_date`, not just `is_current`. Fixed in `models/fact_orders.sql:172` via `LATERAL` pick: `valid_from <= order_date < valid_to`, fallback to `is_current` when no as-of range matches or `order_date` is null. This tests SCD2 understanding — a naïve SCD2 implementation forgets the as-of join.
- No change to `staging` typos or to `dim_orders_flag`/`dim_geo` — they are already stable.

The single implementation in `models/fact_orders.sql` keeps name-joins intentionally; the guard rails above are what make them safe.

## Consequences

- **Positive:** Pipeline stays compatible with current Mongo extracts (no source change). Collisions are no longer silent — they are collapsed deterministically and guarded by `DISTINCT ON`. SCD2 history is now honored per order date, which was the real correctness gap.
- **Negative:** Name stability risk remains — renaming a customer in Mongo will orphan its old facts until a mapping table exists. If the source later emits `CustomerID`/`ProductCode` in `orders`/`order_line_items`, this ADR should be revisited and the joins switched to `customer_id`/`product_code` with the same as-of semantics.
- **What broke when we changed it:** Switching the product join from plain `JOIN` to the `MIN`+`DISTINCT ON` exposed two product_name collisions (Kitchen M006, Audio M020) that previously produced duplicate `(order_id, line_id)` rows and relied on `MIN` accidentally not being there. Switching the customer join to `LATERAL` as-of exposed that `fact_orders` previously always used the current customer version, so historical address changes were invisible in sales-by-region analysis. Both are now visible as orphan checks in `dashboard/pages/5_Pipeline_Health.py`, and duplicate `(order_id, line_id)` rows would be caught by SQL loop 4 and `gx/expectations/duplicate_key_suite.yaml`.

## Alternatives considered

1. **Map table `CustomerName → CustomerID`** — adds an entity-resolution layer and its own history; deferred until source emits IDs or mapping is owned by a data steward.
2. **Join by ID after enriching staging** — requires Mongo schema change; request filed, not yet available.
3. **Move all joins to ID now and fail facts where ID missing** — would drop ~100% of current facts (no IDs in source), so rejected.

## References

- `models/fact_orders.sql:172` (SCD2 as-of LATERAL) and `:181` (MIN(product_key) + DISTINCT ON)
- `models/dim_customers.sql:14` (SCD2)
- `docs/data_catlog.md:245` (join-key inconsistency note)
- `DECISIONS.md D2/D3` (SCD2 + name-joins)
