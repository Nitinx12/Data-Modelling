-- =====================================================================
-- FACT TABLE LOAD SCRIPT
-- Target : core.fact_orders   (grain: one row per order line)
-- Source : staging.orders_2025, staging.orders_2026, staging.order_line_items
-- Dims   : core.dim_customers, core.dim_products, core.dim_orders_flag,
--          core.dim_geo (joined twice — ship-to and bill-to)
-- Pattern: SCD Type 1 — upsert on (order_id, line_id), overwrite on change
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.fact_orders
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.fact_orders (
    order_line_key      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            VARCHAR(50)  NOT NULL,
    line_id             VARCHAR(50)  NOT NULL,
    order_date          DATE,
    quantity            BIGINT,
    unit_price          NUMERIC(14,2),
    unit_cost           NUMERIC(14,2),
    discount_pct        NUMERIC(6,4),
    line_total          NUMERIC(14,2),
    customer_key        BIGINT REFERENCES core.dim_customers(customer_key),
    product_key         BIGINT REFERENCES core.dim_products(product_key),
    flag_key            BIGINT REFERENCES core.dim_orders_flag(flag_key),
    ship_geo_key        BIGINT REFERENCES core.dim_geo(geo_key),
    bill_geo_key        BIGINT REFERENCES core.dim_geo(geo_key),
    source_updated_at   TIMESTAMP,
    dw_created_at       TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at       TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_orders_order_line UNIQUE (order_id, line_id)
);

COMMENT ON TABLE core.fact_orders IS 'Order line fact, SCD Type 1 (overwrite on change). Grain: one row per order line.';

CREATE INDEX IF NOT EXISTS ix_fact_orders_customer      ON core.fact_orders (customer_key);
CREATE INDEX IF NOT EXISTS ix_fact_orders_product       ON core.fact_orders (product_key);
CREATE INDEX IF NOT EXISTS ix_fact_orders_flag          ON core.fact_orders (flag_key);
CREATE INDEX IF NOT EXISTS ix_fact_orders_ship_geo      ON core.fact_orders (ship_geo_key);
CREATE INDEX IF NOT EXISTS ix_fact_orders_bill_geo      ON core.fact_orders (bill_geo_key);
CREATE INDEX IF NOT EXISTS ix_fact_orders_order_date    ON core.fact_orders (order_date);


-- =====================================================================
-- 2. UPSERT — core.fact_orders
-- =====================================================================
WITH orders_union AS(
    SELECT
        "_id",
        "OrderID",
        "CustomerName",
        "CustomerCity",
        "RegionName",
        "ShipToCity",
        "BillToCity",
        "OrderDate",
        "OrderChannel",
        "Status",
        "Priority",
        "OrderTotal",
        "OrderNotes",
        "GiftMessage",
        "SourceFile",
        "update_at",
        "source_sheet"
    FROM staging.orders_2025

    UNION ALL

    SELECT
        "_id",
        "OrderID",
        "CustomerName",
        "CustomerCity",
        "RegionName",
        "ShipToCity",
        "BillToCity",
        "OrderDate",
        "OrderChannel",
        "Status",
        "Priority",
        "OrderTotal",
        "OrderNotes",
        "GiftMessage",
        NULL AS "SourceFile",
        "update_at",
        "source_sheet"
    FROM staging.orders_2026
),
orders_dedup AS(
    SELECT
        *,
        ROW_NUMBER() OVER(
            PARTITION BY "OrderID" ORDER BY "update_at" DESC
        ) AS rnk
    FROM orders_union
),
orders_final AS(
    SELECT * FROM orders_dedup WHERE rnk = 1
),
line_items_dedup AS(
    SELECT
        *,
        ROW_NUMBER() OVER(
            PARTITION BY "LineID" ORDER BY "update_at" DESC
        ) AS rnk
    FROM staging.order_line_items
),
line_items_final AS(
    SELECT * FROM line_items_dedup WHERE rnk = 1
)
INSERT INTO core.fact_orders (
    order_id, 
    line_id, 
    order_date, 
    quantity, 
    unit_price, 
    unit_cost,
    discount_pct, 
    line_total, 
    customer_key, 
    product_key, 
    flag_key,
    ship_geo_key, 
    bill_geo_key, 
    source_updated_at
)
SELECT
    O."OrderID",
    OI."LineID",
    NULLIF(O."OrderDate", '')::DATE,
    OI."Quantity",
    OI."UnitPrice",
    OI."UnitCost",
    OI."DiscountPct",
    OI."LineTotal",
    C.customer_key,
    P.product_key,
    F.flag_key,
    SG.geo_key AS ship_geo_key,
    BG.geo_key AS bill_geo_key,
    COALESCE(NULLIF(OI."update_at", ''), NULLIF(O."update_at", ''))::TIMESTAMP
FROM orders_final AS O
LEFT JOIN line_items_final AS OI
    ON O."OrderID" = OI."OrderID"
LEFT JOIN core.dim_customers AS C
    ON C.customer_name = O."CustomerName"
LEFT JOIN core.dim_products AS P
    ON P.product_name = OI."ProductName"
LEFT JOIN core.dim_orders_flag AS F
    ON O."OrderChannel" = F.channel_code
    AND O."Status" = F.status
    AND O."Priority" = F.priority
LEFT JOIN core.dim_geo AS SG
    ON SG.city_name = O."ShipToCity"
LEFT JOIN core.dim_geo AS BG
    ON BG.city_name = O."BillToCity"
WHERE OI."LineID" IS NOT NULL
ON CONFLICT (order_id, line_id) DO UPDATE SET
    order_date         = EXCLUDED.order_date,
    quantity            = EXCLUDED.quantity,
    unit_price          = EXCLUDED.unit_price,
    unit_cost           = EXCLUDED.unit_cost,
    discount_pct        = EXCLUDED.discount_pct,
    line_total          = EXCLUDED.line_total,
    customer_key        = EXCLUDED.customer_key,
    product_key         = EXCLUDED.product_key,
    flag_key            = EXCLUDED.flag_key,
    ship_geo_key        = EXCLUDED.ship_geo_key,
    bill_geo_key        = EXCLUDED.bill_geo_key,
    source_updated_at   = EXCLUDED.source_updated_at,
    dw_updated_at        = now()
WHERE core.fact_orders.source_updated_at IS DISTINCT FROM EXCLUDED.source_updated_at;


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.fact_orders;
-- SELECT * FROM core.fact_orders ORDER BY dw_updated_at DESC LIMIT 10;
-- SELECT COUNT(*) FROM core.fact_orders WHERE customer_key IS NULL;   -- unmatched customers
-- SELECT COUNT(*) FROM core.fact_orders WHERE product_key IS NULL;    -- unmatched products
-- SELECT COUNT(*) FROM core.fact_orders WHERE ship_geo_key IS NULL;   -- unmatched ship cities
-- SELECT COUNT(*) FROM core.fact_orders WHERE bill_geo_key IS NULL;   -- unmatched bill cities