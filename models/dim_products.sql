-- =====================================================================
-- SCD TYPE 1 DIMENSION LOAD SCRIPT
-- Target : core.dim_products
-- Source : staging.products, staging.subcategory
-- Pattern: Full overwrite on conflict (no history retained)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.dim_products
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.dim_products (
    product_key             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_code            VARCHAR(50)     NOT NULL,
    product_name            VARCHAR(200),
    brand                   VARCHAR(100),
    category                VARCHAR(100),
    subcategory_name        VARCHAR(100),
    primary_supplier        VARCHAR(150),
    unit_price              NUMERIC(14,2),
    source_updated_at       TIMESTAMP,
    dw_created_at           TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at           TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_products_product_code UNIQUE (product_code)
);

COMMENT ON TABLE core.dim_products IS 'Product dimension, SCD Type 1 (overwrite on change).';

CREATE INDEX IF NOT EXISTS ix_dim_products_category ON core.dim_products (category);


-- =====================================================================
-- 2. UPSERT — core.dim_products
-- =====================================================================
-- placeholder for products referenced by facts but missing from the source catalog (e.g. retired SKUs)
INSERT INTO core.dim_products (product_code, product_name, category)
VALUES ('UNKNOWN', 'Unknown / Retired Product', 'Unknown')
ON CONFLICT (product_code) DO NOTHING;

WITH merge_queries AS (
    SELECT
        P."ProductCode",
        P."ProductName",
        P."Brand",
        INITCAP(S."category") AS category,
        P."SubcategoryName",
        P."PrimarySupplier",
        P."UnitPrice",
        P."update_at"
    FROM staging.products AS P
    LEFT JOIN staging.subcategory AS S
        ON P."SubcategoryName" = INITCAP(S."subcategory")
    -- drop known placeholder/test rows (e.g. ZZZ-000 "DO NOT USE")
    WHERE P."ProductCode" NOT ILIKE 'ZZZ%'
      AND P."ProductName" NOT ILIKE 'DO NOT USE%'
),
duplicate_check AS (
    -- no price filter here: every product must get a key, bad price just means NULL price below
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY "ProductCode"
            ORDER BY "update_at" DESC NULLS LAST
        ) AS rnk
    FROM merge_queries
),
final_products AS (
    SELECT *
    FROM duplicate_check
    WHERE rnk = 1
)
INSERT INTO core.dim_products (
    product_code, 
    product_name, 
    brand, category, 
    subcategory_name,
    primary_supplier, 
    unit_price, 
    source_updated_at
)
SELECT
    "ProductCode",
    "ProductName",
    "Brand",
    category,
    "SubcategoryName",
    "PrimarySupplier",
    -- invalid price (blank/zero/negative) -> NULL, product row is kept either way
    CASE WHEN NULLIF("UnitPrice"::TEXT, '')::NUMERIC(14,2) > 0
         THEN NULLIF("UnitPrice"::TEXT, '')::NUMERIC(14,2)
         ELSE NULL END,
    NULLIF("update_at", '')::TIMESTAMP
FROM final_products
ON CONFLICT (product_code) DO UPDATE SET
    product_name        = EXCLUDED.product_name,
    brand               = EXCLUDED.brand,
    category            = EXCLUDED.category,
    subcategory_name    = EXCLUDED.subcategory_name,
    primary_supplier    = EXCLUDED.primary_supplier,
    unit_price          = EXCLUDED.unit_price,  -- NULL if source price was invalid
    source_updated_at   = EXCLUDED.source_updated_at,
    dw_updated_at       = now()
WHERE core.dim_products.source_updated_at IS DISTINCT FROM EXCLUDED.source_updated_at;

-- cleanup: remove placeholder/test rows inserted before this filter existed
DELETE FROM core.dim_products
WHERE product_code ILIKE 'ZZZ%'
   OR product_name ILIKE 'DO NOT USE%';


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.dim_products;
-- SELECT * FROM core.dim_products ORDER BY dw_updated_at DESC LIMIT 10;