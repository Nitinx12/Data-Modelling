-- =====================================================================
-- FACT TABLE LOAD SCRIPT
-- Target : core.fact_inventory   (grain: one row per product per month)
-- Source : staging.inventory
-- Dim    : core.dim_products
-- Pattern: SCD Type 1 — upsert on (product_key, period_month)
-- Note   : Source columns "2025-01".."2025-12" are wide/pivoted monthly
--          quantities. This unpivots them into long format via a
--          CROSS JOIN LATERAL (VALUES ...) before loading.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.fact_inventory
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.fact_inventory (
    inventory_key       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_key         BIGINT REFERENCES core.dim_products(product_key),
    product_name        VARCHAR(200),
    period_month        DATE        NOT NULL,
    quantity            BIGINT,
    source_updated_at   TIMESTAMP,
    dw_created_at       TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at       TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_inventory_product_period UNIQUE (product_name, period_month)
);

COMMENT ON TABLE core.fact_inventory IS 'Product inventory fact, SCD Type 1 (overwrite on change). Grain: one row per product per month.';

CREATE INDEX IF NOT EXISTS ix_fact_inventory_product ON core.fact_inventory (product_key);
CREATE INDEX IF NOT EXISTS ix_fact_inventory_period  ON core.fact_inventory (period_month);


-- =====================================================================
-- 2. UPSERT — core.fact_inventory
-- =====================================================================
WITH inventory_dedup AS(
    SELECT
        *,
        ROW_NUMBER() OVER(
            PARTITION BY "ProductName" ORDER BY "update_at" DESC
        ) AS rnk
    FROM staging.inventory
),
inventory_final AS(
    SELECT * FROM inventory_dedup WHERE rnk = 1
),
inventory_unpivoted AS(
    SELECT
        T."ProductName",
        U.period,
        U.quantity,
        T."update_at"
    FROM inventory_final AS T
    CROSS JOIN LATERAL (VALUES
        ('2025-01', T."2025-01"),
        ('2025-02', T."2025-02"),
        ('2025-03', T."2025-03"),
        ('2025-04', T."2025-04"),
        ('2025-05', T."2025-05"),
        ('2025-06', T."2025-06"),
        ('2025-07', T."2025-07"),
        ('2025-08', T."2025-08"),
        ('2025-09', T."2025-09"),
        ('2025-10', T."2025-10"),
        ('2025-11', T."2025-11"),
        ('2025-12', T."2025-12")
    ) AS U(period, quantity)
)
INSERT INTO core.fact_inventory (
    product_key, 
    product_name, 
    period_month, 
    quantity, 
    source_updated_at
)
SELECT
    P.product_key,
    I."ProductName",
    TO_DATE(I.period || '-01', 'YYYY-MM-DD'),
    I.quantity,
    NULLIF(I."update_at", '')::TIMESTAMP
FROM inventory_unpivoted AS I
LEFT JOIN core.dim_products AS P
    ON P.product_name = I."ProductName"
ON CONFLICT (product_name, period_month) DO UPDATE SET
    product_key         = EXCLUDED.product_key,
    quantity            = EXCLUDED.quantity,
    source_updated_at   = EXCLUDED.source_updated_at,
    dw_updated_at       = now()
WHERE core.fact_inventory.source_updated_at IS DISTINCT FROM EXCLUDED.source_updated_at;


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.fact_inventory;
-- SELECT * FROM core.fact_inventory ORDER BY period_month, product_name LIMIT 20;
-- SELECT COUNT(*) FROM core.fact_inventory WHERE product_key IS NULL;  -- unmatched products