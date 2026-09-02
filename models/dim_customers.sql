-- =====================================================================
-- SCD TYPE 1 DIMENSION LOAD SCRIPT
-- Target : core.dim_customers
-- Source : staging.cust_master, staging.customer_contach,
--          staging.user_details, staging.addres, staging.cities
-- Pattern: Full overwrite on conflict (no history retained)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.dim_customers
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.dim_customers (
    customer_key            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id             VARCHAR(50)     NOT NULL,
    customer_name           VARCHAR(150),
    segment                 VARCHAR(50),
    account_manager         VARCHAR(150),
    payment_terms           VARCHAR(50),
    email                   VARCHAR(150),
    phone                   VARCHAR(30),
    credit_limit            NUMERIC(14,2),
    street                  VARCHAR(200),
    city_name               VARCHAR(100),
    region_name             VARCHAR(100),
    source_updated_at       TIMESTAMP,
    dw_created_at           TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at           TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_customers_customer_id UNIQUE (customer_id)
);

COMMENT ON TABLE core.dim_customers IS 'Customer dimension, SCD Type 1 (overwrite on change).';

CREATE INDEX IF NOT EXISTS ix_dim_customers_region ON core.dim_customers (region_name);


-- =====================================================================
-- 2. UPSERT — core.dim_customers
-- =====================================================================
WITH merge_quries AS (
    SELECT
        CU."CustomerID",
        CU."CustomerName",
        CU."Segment",
        CU."AccountManager",
        CU."PaymentTerms",
        CC."Email",
        UD."Phone",
        UD."CreditLimit",
        A."Street",
        C."CityName",
        C."RegionName",
        A."update_at"
    FROM staging.cust_master AS CU
    LEFT JOIN staging.customer_contach AS CC
        ON CU."CustomerID" = CC."CustomerID"
        AND CC."IsPrimary" = true
    LEFT JOIN staging.user_details AS UD
        ON UD."UserID" = CU."CustomerID"
    LEFT JOIN staging.addres AS A
        ON A."AddressID" = CU."AddressID"
    LEFT JOIN staging.cities AS C
        ON C."CityName" = A."CityName"
),
duplicate_check AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY "CustomerID"
            ORDER BY "update_at" DESC
        ) AS rnk
    FROM merge_quries
    WHERE "update_at" IS NOT NULL
),
final_customers AS (
    SELECT *
    FROM duplicate_check
    WHERE rnk = 1
)
INSERT INTO core.dim_customers (
    customer_id, 
    customer_name, 
    segment, 
    account_manager, 
    payment_terms,
    email, phone, 
    credit_limit, 
    street, 
    city_name, 
    region_name, 
    source_updated_at
)
SELECT
    "CustomerID",
    "CustomerName",
    "Segment",
    "AccountManager",
    "PaymentTerms",
    "Email",
    "Phone",
    NULLIF("CreditLimit", 0)::NUMERIC(14,2),
    "Street",
    "CityName",
    "RegionName",
    NULLIF("update_at", '')::TIMESTAMP
FROM final_customers
ON CONFLICT (customer_id) DO UPDATE SET
    customer_name       = EXCLUDED.customer_name,
    segment             = EXCLUDED.segment,
    account_manager     = EXCLUDED.account_manager,
    payment_terms       = EXCLUDED.payment_terms,
    email               = EXCLUDED.email,
    phone               = EXCLUDED.phone,
    credit_limit        = EXCLUDED.credit_limit,
    street              = EXCLUDED.street,
    city_name           = EXCLUDED.city_name,
    region_name         = EXCLUDED.region_name,
    source_updated_at   = EXCLUDED.source_updated_at,
    dw_updated_at       = now()
WHERE core.dim_customers.source_updated_at IS DISTINCT FROM EXCLUDED.source_updated_at;

-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.dim_customers;
-- SELECT * FROM core.dim_customers ORDER BY dw_updated_at DESC LIMIT 10;