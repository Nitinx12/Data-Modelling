# Entity-Relationship Diagram — `core` Schema

A fact constellation (galaxy schema): five conformed dimensions shared across five fact tables of different types (transaction, periodic snapshot, accumulating snapshot, factless).

```mermaid
erDiagram
    dim_campaign ||--o{ fact_campaign_spend : "campaign_key"
    dim_campaign ||--o{ fact_less_fact : "campaign_key"
    dim_products ||--o{ fact_less_fact : "product_key"
    dim_products ||--o{ fact_inventory : "product_key"
    dim_products ||--o{ fact_orders : "product_key"
    dim_customers ||--o{ fact_orders : "customer_key"
    dim_customers ||--o{ fact_order_process : "customer_id (natural key, not surrogate)"
    dim_orders_flag ||--o{ fact_orders : "flag_key"
    dim_geo ||--o{ fact_orders : "ship_geo_key"
    dim_geo ||--o{ fact_orders : "bill_geo_key"

    dim_campaign {
        bigint campaign_key PK
        varchar campaign_name UK "business key"
        varchar channel
        date start_date
        date end_date
        numeric budget
        timestamp source_updated_at
    }

    dim_customers {
        bigint customer_key PK
        varchar customer_id UK "business key"
        varchar customer_name
        varchar segment
        varchar account_manager
        varchar payment_terms
        varchar email
        varchar phone
        numeric credit_limit
        varchar street
        varchar city_name
        varchar region_name
        timestamp source_updated_at
    }

    dim_geo {
        bigint geo_key PK
        varchar city_name UK "business key"
        varchar region_name
        timestamp source_updated_at
    }

    dim_orders_flag {
        bigint flag_key PK
        bigint channel_code UK "part of composite business key"
        varchar channel_name
        varchar status UK "part of composite business key"
        varchar priority UK "part of composite business key"
    }

    dim_products {
        bigint product_key PK
        varchar product_code UK "business key"
        varchar product_name
        varchar brand
        varchar category
        varchar subcategory_name
        varchar primary_supplier
        numeric unit_price
        timestamp source_updated_at
    }

    fact_campaign_spend {
        bigint spend_key PK
        bigint campaign_key FK
        varchar campaign_name
        date spend_date UK "part of composite key"
        bigint impressions
        bigint clicks
        numeric spend
        timestamp source_updated_at
    }

    fact_inventory {
        bigint inventory_key PK
        bigint product_key FK
        varchar product_name UK "part of composite key"
        date period_month UK "part of composite key"
        bigint quantity
        timestamp source_updated_at
    }

    fact_less_fact {
        bigint fact_less_fact_key PK
        bigint campaign_key FK
        bigint product_key FK
        varchar campaign_name
        varchar promoted_sku
    }

    fact_order_process {
        bigint order_process_key PK
        varchar order_id UK "business key"
        varchar customer_id FK
        varchar ship_mode
        varchar invoice_id
        date order_date
        date ship_date
        date delivery_date
        date invoice_date
        date pay_date
        numeric amount
        int days_order_to_ship
        int days_ship_to_delivery
        int days_order_to_invoice
        int days_invoice_to_pay
    }

    fact_orders {
        bigint order_line_key PK
        varchar order_id UK "part of composite key"
        varchar line_id UK "part of composite key"
        date order_date
        bigint quantity
        numeric unit_price
        numeric unit_cost
        numeric discount_pct
        numeric line_total
        bigint customer_key FK
        bigint product_key FK
        bigint flag_key FK
        bigint ship_geo_key FK
        bigint bill_geo_key FK
        timestamp source_updated_at
    }
```

---

## Reading the Diagram

- **`||--o{`** = one dimension row relates to zero-or-many fact rows (standard star-schema cardinality). No fact table in this model has a mandatory-one-to-mandatory-one relationship back to a dimension — every FK is nullable, since a join can fail to resolve.
- **Role-playing dimension:** `dim_geo` appears **twice** against `fact_orders` (`ship_geo_key`, `bill_geo_key`) — the same physical table used in two different business roles on one fact row.
- **Fact constellation, not a single star:** `fact_campaign_spend` and `fact_less_fact` both reference `dim_campaign`/`dim_products` but are **never joined to each other**. They're connected only by conforming to the same dimensions — the defining feature of a galaxy schema over a single star schema.
- **Odd one out:** `fact_order_process.customer_id` is the only fact-to-dimension link in the model built on a **natural/business key** (`dim_customers.customer_id`) rather than the surrogate key (`dim_customers.customer_key`) that every other fact table uses. Functionally fine (it's still unique + indexed), but inconsistent with the rest of the model's key strategy.
- **Degenerate dimensions:** `order_id` (on `fact_orders` and `fact_order_process`) and `invoice_id` (on `fact_order_process`) are degenerate — carried directly on the fact with no dimension table of their own.

## Fact Table Types in This Model

| Fact table | Type | Why |
|---|---|---|
| `fact_campaign_spend` | Transaction fact | New measurable event per campaign per day |
| `fact_orders` | Transaction fact | New measurable event per order line |
| `fact_inventory` | Periodic snapshot | Quantity measured at a fixed monthly interval, regardless of activity |
| `fact_order_process` | Accumulating snapshot | Single row per order, overwritten in place as it moves through order → ship → deliver → invoice → pay |
| `fact_less_fact` | Factless fact | Records that a relationship occurred (SKU promoted in campaign); carries no numeric measures |

## Load Order (topological)

```
1. dim_campaign
2. dim_customers
3. dim_geo
4. dim_orders_flag
5. dim_products
   ── all dimensions must complete before any fact below ──
6. fact_campaign_spend   (needs dim_campaign)
7. fact_inventory        (needs dim_products)
8. fact_less_fact        (needs dim_campaign, dim_products)
9. fact_order_process    (needs dim_customers)
10. fact_orders          (needs dim_customers, dim_products, dim_orders_flag, dim_geo)
```

*See `data_catalog.md` for full column-level definitions, business keys, and known data-quality caveats.*