# Data Catalog — Core Warehouse (`core` schema)

Source layer: `staging` &nbsp;|&nbsp; Target layer: `core` &nbsp;|&nbsp; Pattern: SCD Type 1 dimensions + a fact constellation (multiple fact tables sharing conformed dimensions)

---

## 1. Architecture at a Glance

| # | Table | Type | Grain | Depends on |
|---|-------|------|-------|------------|
| 1 | `core.dim_campaign` | Dimension (SCD1) | 1 row per campaign | — |
| 2 | `core.dim_customers` | Dimension (SCD1) | 1 row per customer | — |
| 3 | `core.dim_geo` | Dimension (SCD1) | 1 row per city | — |
| 4 | `core.dim_orders_flag` | Junk dimension (insert-only) | 1 row per distinct (channel, status, priority) | — |
| 5 | `core.dim_products` | Dimension (SCD1) | 1 row per product | — |
| 6 | `core.fact_campaign_spend` | Transaction fact | 1 row per campaign per day | `dim_campaign` |
| 7 | `core.fact_inventory` | Periodic snapshot fact | 1 row per product per month | `dim_products` |
| 8 | `core.fact_less_fact` | Factless fact | 1 row per campaign–promoted‑SKU pair | `dim_campaign`, `dim_products` |
| 9 | `core.fact_order_process` | Accumulating snapshot fact | 1 row per order | `dim_customers` |
| 10 | `core.fact_orders` | Transaction fact | 1 row per order line | `dim_customers`, `dim_products`, `dim_orders_flag`, `dim_geo` (×2) |

**Required load order:** the five dimensions first (any order among themselves), then the five facts — each fact script resolves its dimension keys via a join, so a dimension must be populated before its dependent fact runs.

```
dim_campaign ─┐
dim_customers ─┤
dim_geo ────────┼──►  fact_campaign_spend, fact_inventory, fact_less_fact,
dim_orders_flag ┤      fact_order_process, fact_orders
dim_products ───┘
```

`fact_campaign_spend` and `fact_less_fact` are **never joined to each other directly** — they connect only through the shared `dim_campaign` / `dim_products` dimensions. This is the defining trait of a fact constellation (galaxy schema) rather than a single star.

---

## 2. Dimension Tables

### 2.1 `core.dim_campaign`
- **Purpose:** One row per marketing campaign (attributes only — no metrics).
- **Source:** `staging.campaing_logs` *(sic — staging table name has a typo; see §5)*, which is denormalized (one row per campaign per day). Deduped to the latest row per `CampaignName` by `update_at` before loading.
- **Load pattern:** SCD Type 1 upsert on `campaign_name`; overwritten only when `source_updated_at` changes.

| Column | Type | Notes |
|---|---|---|
| campaign_key | BIGINT (PK, identity) | Surrogate key |
| campaign_name | VARCHAR(200) | **Business key**, UNIQUE |
| channel | VARCHAR(100) | |
| start_date / end_date | DATE | |
| budget | NUMERIC(18,2) | |
| source_updated_at | TIMESTAMP | Drives change detection |
| dw_created_at / dw_updated_at | TIMESTAMP | Audit columns |

---

### 2.2 `core.dim_customers`
- **Purpose:** One row per customer, denormalizing contact, credit, and address/geo attributes.
- **Source:** `staging.cust_master` (base) LEFT JOIN `staging.customer_contach` *(typo)* (primary contact only), `staging.user_details` (phone/credit limit), `staging.addres` *(typo)* (street), `staging.cities` (city/region).
- **Load pattern:** SCD Type 1 upsert on `customer_id`. **Caveat:** rows with a NULL `update_at` in the joined source are filtered out entirely before load — a customer whose address/contact join produces no `update_at` will not be inserted or refreshed that run.

| Column | Type | Notes |
|---|---|---|
| customer_key | BIGINT (PK, identity) | Surrogate key |
| customer_id | VARCHAR(50) | **Business key**, UNIQUE |
| customer_name | VARCHAR(150) | |
| segment | VARCHAR(50) | |
| account_manager | VARCHAR(150) | |
| payment_terms | VARCHAR(50) | |
| email | VARCHAR(150) | From primary contact only (`IsPrimary = true`) |
| phone | VARCHAR(30) | |
| credit_limit | NUMERIC(14,2) | `0` is treated as NULL (`NULLIF(...,0)`) |
| street | VARCHAR(200) | |
| city_name / region_name | VARCHAR(100) | Denormalized copy of geo, independent of `dim_geo` |
| source_updated_at | TIMESTAMP | Taken from the **address** record's `update_at`, not the customer master |
| dw_created_at / dw_updated_at | TIMESTAMP | Audit columns |

---

### 2.3 `core.dim_geo`
- **Purpose:** City/region reference dimension. Used twice in `fact_orders` as a **role‑playing dimension** (ship-to and bill-to).
- **Source:** `staging.cities`, deduped to latest per `CityName`.
- **Load pattern:** SCD Type 1 upsert on `city_name`.

| Column | Type | Notes |
|---|---|---|
| geo_key | BIGINT (PK, identity) | Surrogate key |
| city_name | VARCHAR(100) | **Business key**, UNIQUE |
| region_name | VARCHAR(100) | |
| source_updated_at | TIMESTAMP | |
| dw_created_at / dw_updated_at | TIMESTAMP | Audit columns |

---

### 2.4 `core.dim_orders_flag`
- **Purpose:** Junk dimension collapsing three low-cardinality order attributes into one key, keeping them off the fact row directly.
- **Source:** Union of `staging.orders_2025` + `staging.orders_2026`, LEFT JOIN `staging.channels` to resolve a friendly channel name.
- **Load pattern:** Insert-only / idempotent — `ON CONFLICT DO NOTHING`. The (channel, status, priority) combination **is** the identity, so existing rows are never updated even if `channel_name` changes upstream.

| Column | Type | Notes |
|---|---|---|
| flag_key | BIGINT (PK, identity) | Surrogate key |
| channel_code | BIGINT | Raw code from orders |
| channel_name | VARCHAR(100) | Resolved via `staging.channels`; NULL if code unmatched |
| status | VARCHAR(50) | |
| priority | VARCHAR(50) | |
| dw_created_at | TIMESTAMP | No `dw_updated_at` — rows are immutable once created |

**Business key / uniqueness:** (`channel_code`, `status`, `priority`)

---

### 2.5 `core.dim_products`
- **Purpose:** One row per product/SKU.
- **Source:** `staging.products` LEFT JOIN `staging.subcategory` on `INITCAP("SubcategoryName") = INITCAP("subcategory")`.
- **Load pattern:** SCD Type 1 upsert on `product_code`. **Caveat:** the load explicitly filters `WHERE "UnitPrice" IS NOT NULL AND "UnitPrice" > 0` — any product with a missing or zero price is silently excluded from the dimension, which will cause unmatched (`product_key IS NULL`) rows downstream in `fact_orders`, `fact_inventory`, and `fact_less_fact`. **Also note:** the `category` column is populated from the *subcategory* staging table (`S."category"`) while the join key compares subcategory names — worth confirming this is intentional and not a mismatched join.

| Column | Type | Notes |
|---|---|---|
| product_key | BIGINT (PK, identity) | Surrogate key |
| product_code | VARCHAR(50) | **Business key**, UNIQUE |
| product_name | VARCHAR(200) | Used as the join key from fact tables (not `product_code`) |
| brand | VARCHAR(100) | |
| category | VARCHAR(100) | `INITCAP`'d; sourced from `subcategory` table — see caveat above |
| subcategory_name | VARCHAR(100) | |
| primary_supplier | VARCHAR(150) | |
| unit_price | NUMERIC(14,2) | Rows with NULL/0 never reach the dimension |
| source_updated_at | TIMESTAMP | |
| dw_created_at / dw_updated_at | TIMESTAMP | Audit columns |

---

## 3. Fact Tables

### 3.1 `core.fact_campaign_spend`
- **Grain:** one row per campaign per day.
- **Source:** `staging.campaing_logs`, deduped by (`CampaignName`, `Date`).
- **Load pattern:** SCD Type 1 upsert on (`campaign_name`, `spend_date`).

| Column | Type | Notes |
|---|---|---|
| spend_key | BIGINT (PK, identity) | |
| campaign_key | BIGINT (FK → dim_campaign) | NULL if campaign name unmatched |
| campaign_name | VARCHAR(200) | Degenerate copy, also part of the natural key |
| spend_date | DATE | NOT NULL |
| impressions / clicks | BIGINT | |
| spend | NUMERIC(18,2) | |
| source_updated_at | TIMESTAMP | |

**Uniqueness:** (`campaign_name`, `spend_date`)

---

### 3.2 `core.fact_inventory`
- **Grain:** one row per product per month.
- **Source:** `staging.inventory`, wide/pivoted (columns `"2025-01"` … `"2025-12"`), deduped per `ProductName`, then unpivoted via `CROSS JOIN LATERAL (VALUES ...)`.
- **Load pattern:** SCD Type 1 upsert on (`product_name`, `period_month`). **Note:** the unique constraint is on `product_name`, not `product_key` — `product_key` is a resolved, non-authoritative column.
- **Coverage note:** hard-coded to 2025 months only; a new source column per year will need a script change.

| Column | Type | Notes |
|---|---|---|
| inventory_key | BIGINT (PK, identity) | |
| product_key | BIGINT (FK → dim_products) | NULL if product unmatched (incl. filtered-out $0/NULL-price products) |
| product_name | VARCHAR(200) | Part of natural key |
| period_month | DATE | First-of-month, derived from pivoted column name |
| quantity | BIGINT | |
| source_updated_at | TIMESTAMP | |

**Uniqueness:** (`product_name`, `period_month`)

---

### 3.3 `core.fact_less_fact`
- **Grain:** one row per campaign–promoted‑SKU relationship. **No measures** — this is a classic factless fact, recording that an event/relationship occurred.
- **Source:** `staging.campaing_sku`.
- **Load pattern:** Insert-only, `ON CONFLICT (campaign_key, product_key) DO NOTHING`. **Caveat:** because unmatched campaigns/products resolve to `NULL` keys and Postgres treats `NULL <> NULL` for uniqueness purposes, multiple unmatched rows can insert as duplicates (the conflict target won't catch NULL/NULL pairs).

| Column | Type | Notes |
|---|---|---|
| fact_less_fact_key | BIGINT (PK, identity) | |
| campaign_key | BIGINT (FK → dim_campaign) | Nullable |
| product_key | BIGINT (FK → dim_products) | Nullable |
| campaign_name | VARCHAR(200) | Degenerate copy |
| promoted_sku | VARCHAR(200) | Degenerate copy |
| dw_created_at | TIMESTAMP | No `dw_updated_at` — immutable rows |

**Uniqueness:** (`campaign_key`, `product_key`) — see caveat above

---

### 3.4 `core.fact_order_process`
- **Grain:** one row per order — an **accumulating snapshot**, revisited and overwritten in place as the order moves order → ship → deliver → invoice → pay.
- **Source:** union of `staging.orders_2025` + `staging.orders_2026`, LEFT JOIN latest `staging.shipments`, `staging.invoices`, `staging.payments` (each deduped to one row per key).
- **Load pattern:** upsert on `order_id`; refreshed only when any milestone date or `amount` changes.
- **Assumption stated in source:** `OrderID` is unique across the union of the two yearly order tables (no overlap).

| Column | Type | Notes |
|---|---|---|
| order_process_key | BIGINT (PK, identity) | |
| order_id | VARCHAR(100) | **Business key**, UNIQUE. Degenerate dimension — no separate order dim |
| customer_id | VARCHAR(50) (FK → `dim_customers.customer_id`) | ⚠️ References the **natural key**, not `customer_key` — inconsistent with every other fact table in this model, which uses surrogate keys |
| ship_mode | VARCHAR(100) | |
| invoice_id | VARCHAR(100) | Degenerate dimension |
| order_date / ship_date / delivery_date / invoice_date / pay_date | DATE | Milestone dates; later ones are NULL until the order reaches that stage |
| amount | NUMERIC(18,2) | From invoice |
| days_order_to_ship / days_ship_to_delivery / days_order_to_invoice / days_invoice_to_pay | INT | Derived milestone lags |

---

### 3.5 `core.fact_orders`
- **Grain:** one row per order line.
- **Source:** union of `staging.orders_2025` + `staging.orders_2026` (order header) deduped by `OrderID`, joined to deduped `staging.order_line_items` by `OrderID`.
- **Load pattern:** SCD Type 1 upsert on (`order_id`, `line_id`).
- **Dimensions joined:** `dim_customers` (by name), `dim_products` (by name), `dim_orders_flag` (by channel/status/priority), `dim_geo` joined **twice** — once for ship-to city, once for bill-to city (role-playing dimension).

| Column | Type | Notes |
|---|---|---|
| order_line_key | BIGINT (PK, identity) | |
| order_id / line_id | VARCHAR(50) | Together form the natural key |
| order_date | DATE | |
| quantity | BIGINT | |
| unit_price / unit_cost | NUMERIC(14,2) | |
| discount_pct | NUMERIC(6,4) | |
| line_total | NUMERIC(14,2) | |
| customer_key | BIGINT (FK → dim_customers) | Joined by name, not `customer_id` |
| product_key | BIGINT (FK → dim_products) | Joined by name |
| flag_key | BIGINT (FK → dim_orders_flag) | |
| ship_geo_key | BIGINT (FK → dim_geo) | Role-playing: ship-to |
| bill_geo_key | BIGINT (FK → dim_geo) | Role-playing: bill-to |
| source_updated_at | TIMESTAMP | `COALESCE` of line-item and header `update_at` |

**Uniqueness:** (`order_id`, `line_id`)

---

## 4. Data Quality & Design Notes Worth Tracking

| Area | Note |
|---|---|
| Join key inconsistency | Most facts join to `dim_customers`/`dim_products` by **name** (`customer_name`, `product_name`) rather than the stable business ID (`customer_id`, `product_code`). Names are not guaranteed unique/stable, unlike IDs. |
| Surrogate key inconsistency | `fact_order_process.customer_id` is a FK to the customer dimension's **natural key**, while `fact_orders.customer_key` uses the **surrogate key**. Two different join conventions for the same relationship. |
| Silent row exclusion | `dim_products` load drops any product with NULL or ≤ 0 `unit_price`; `dim_customers` load drops any joined row with NULL `update_at`. Both are silent — worth monitoring via the commented-out unmatched-key verification queries in each script. |
| Possible mismatched join | `dim_products.category` is sourced from `staging.subcategory."category"`, joined on a subcategory-name match — confirm this is intentional rather than a copy-paste of the wrong source column. |
| Duplicate risk on NULL FKs | `fact_less_fact`'s `ON CONFLICT (campaign_key, product_key) DO NOTHING` will not deduplicate rows where either key is NULL (unmatched campaign/product), since SQL NULLs are never equal. |
| Yearly table dependency | `fact_inventory`'s unpivot is hard-coded to `2025-01`…`2025-12` columns; `fact_orders`/`fact_order_process` already union `orders_2025` + `orders_2026`, so a `2026-*` inventory pattern should be added when available. |
| Fact-to-fact linkage | `fact_campaign_spend` and `fact_less_fact` share `dim_campaign` and `dim_products` but are never joined to each other directly — analysis connecting spend to promoted SKUs must go through the shared dimensions. |

---

## 5. Staging Source Glossary

Several staging table/column names carry typos inherited from the source system — noted here so they aren't "fixed" accidentally in a future edit.

| Staging table | Apparent intended name | Used by |
|---|---|---|
| `staging.campaing_logs` | campaign_logs | `dim_campaign`, `fact_campaign_spend` |
| `staging.campaing_sku` | campaign_sku | `fact_less_fact` |
| `staging.customer_contach` | customer_contact | `dim_customers` |
| `staging.addres` | address | `dim_customers` |
| `staging.cust_master` | customer_master | `dim_customers` |
| `staging.user_details` | — (phone/credit limit) | `dim_customers` |
| `staging.cities` | — (city/region reference) | `dim_geo`, `dim_customers` |
| `staging.channels` | — (channel code reference) | `dim_orders_flag` |
| `staging.orders_2025` / `staging.orders_2026` | — (yearly order headers) | `dim_orders_flag`, `fact_order_process`, `fact_orders` |
| `staging.order_line_items` | — (order line detail) | `fact_orders` |
| `staging.products` / `staging.subcategory` | — | `dim_products` |
| `staging.inventory` | — (wide/pivoted monthly qty) | `fact_inventory` |
| `staging.shipments` / `staging.invoices` / `staging.payments` | — | `fact_order_process` |

---

*See `ERD.md` for the entity-relationship diagram.*