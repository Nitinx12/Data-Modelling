-- =====================================================================
-- SCD TYPE 2 DIMENSION LOAD SCRIPT
-- Target : core.dim_customers
-- Source : staging.cust_master, staging.customer_contach,
--          staging.user_details, staging.addres, staging.cities
-- Pattern: SCD Type 2 — history retained via valid_from/valid_to/is_current.
--          All other dimensions remain SCD1 by design; dim_customers is
--          SCD2 because address/region changes matter for historical order
--          analysis (see roadmap Tier 1 item 3).
--          valid_from/to are TIMESTAMP (wall clock at load time), is_current
--          marks the open row per customer_id.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.dim_customers
-- =====================================================================
-- Fresh install — create with SCD2 columns and correct uniqueness.
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
    valid_from              TIMESTAMP       NOT NULL DEFAULT now(),
    valid_to                TIMESTAMP,
    is_current              BOOLEAN         NOT NULL DEFAULT true,
    dw_created_at           TIMESTAMP       NOT NULL DEFAULT now(),
    dw_updated_at           TIMESTAMP       NOT NULL DEFAULT now()
);

-- Migration — add SCD2 columns to existing SCD1 tables (idempotent).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'dim_customers' AND column_name = 'valid_from'
    ) THEN
        ALTER TABLE core.dim_customers ADD COLUMN valid_from TIMESTAMP NOT NULL DEFAULT now();
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'dim_customers' AND column_name = 'valid_to'
    ) THEN
        ALTER TABLE core.dim_customers ADD COLUMN valid_to TIMESTAMP;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'dim_customers' AND column_name = 'is_current'
    ) THEN
        ALTER TABLE core.dim_customers ADD COLUMN is_current BOOLEAN NOT NULL DEFAULT true;
    END IF;
END $$;

-- Backfill existing rows that predate SCD2 (valid_from was DEFAULT now() at insert,
-- but older rows inserted before this migration have it set via DEFAULT; ensure
-- is_current/valid_to are coherent).
UPDATE core.dim_customers
SET is_current = true
WHERE is_current IS NULL;

UPDATE core.dim_customers
SET valid_from = COALESCE(valid_from, dw_created_at, now())
WHERE valid_from IS NULL;

-- Uniqueness: SCD1 had UNIQUE (customer_id). SCD2 allows history, so replace
-- with UNIQUE (customer_id, valid_from) and a partial index for the open row.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_dim_customers_customer_id'
          AND conrelid = 'core.dim_customers'::regclass
    ) THEN
        ALTER TABLE core.dim_customers DROP CONSTRAINT uq_dim_customers_customer_id;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_dim_customers_customer_valid_from'
          AND conrelid = 'core.dim_customers'::regclass
    ) THEN
        ALTER TABLE core.dim_customers
            ADD CONSTRAINT uq_dim_customers_customer_valid_from UNIQUE (customer_id, valid_from);
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_dim_customers_customer_current
    ON core.dim_customers (customer_id) WHERE is_current;

COMMENT ON TABLE core.dim_customers IS 'Customer dimension, SCD Type 2 (history retained via valid_from/valid_to/is_current). One current row per customer_id; closed rows keep history for as-of joins.';

CREATE INDEX IF NOT EXISTS ix_dim_customers_region ON core.dim_customers (region_name);
CREATE INDEX IF NOT EXISTS ix_dim_customers_current ON core.dim_customers (customer_id) WHERE is_current;


-- =====================================================================
-- 2. SCD2 UPSERT — core.dim_customers
--    a) Stage final_customers into a TEMP table (reused for close + insert)
--    b) Close out changed current rows (valid_to = now(), is_current = false)
--    c) Insert new versions (including brand-new customers)
--    Idempotent: re-running with no source changes touches zero rows.
-- =====================================================================
DROP TABLE IF EXISTS tmp_final_customers;
CREATE TEMP TABLE tmp_final_customers AS
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
            ORDER BY "update_at" DESC NULLS LAST
        ) AS rnk
    FROM merge_quries
)
SELECT *
FROM duplicate_check
WHERE rnk = 1;

-- b) Close out current rows whose attributes are DISTINCT from staged row.
UPDATE core.dim_customers AS d
SET valid_to = now()
    , is_current = false
    , dw_updated_at = now()
FROM tmp_final_customers AS s
WHERE d.customer_id = s."CustomerID"
  AND d.is_current = true
  AND (
        d.customer_name, d.segment, d.account_manager, d.payment_terms
        , d.email, d.phone, d.credit_limit, d.street, d.city_name, d.region_name
        , d.source_updated_at
    ) IS DISTINCT FROM (
        s."CustomerName", s."Segment", s."AccountManager", s."PaymentTerms"
        , s."Email", s."Phone", NULLIF(s."CreditLimit", 0)::NUMERIC(14,2)
        , s."Street", s."CityName", s."RegionName"
        , NULLIF(s."update_at", '')::TIMESTAMP
    );

-- c) Insert new current rows — either brand-new customer_id or a new version
--    after a close-out. Guarded to skip when an identical current row already exists.
INSERT INTO core.dim_customers (
    customer_id
    , customer_name
    , segment
    , account_manager
    , payment_terms
    , email
    , phone
    , credit_limit
    , street
    , city_name
    , region_name
    , source_updated_at
    , valid_from
    , valid_to
    , is_current
)
SELECT
    s."CustomerID"
    , s."CustomerName"
    , s."Segment"
    , s."AccountManager"
    , s."PaymentTerms"
    , s."Email"
    , s."Phone"
    , NULLIF(s."CreditLimit", 0)::NUMERIC(14,2)
    , s."Street"
    , s."CityName"
    , s."RegionName"
    , NULLIF(s."update_at", '')::TIMESTAMP
    , now()
    , NULL
    , true
FROM tmp_final_customers AS s
WHERE NOT EXISTS (
    SELECT 1
    FROM core.dim_customers AS d
    WHERE d.customer_id = s."CustomerID"
      AND d.is_current = true
      AND (
            d.customer_name, d.segment, d.account_manager, d.payment_terms
            , d.email, d.phone, d.credit_limit, d.street, d.city_name, d.region_name
            , d.source_updated_at
        ) IS NOT DISTINCT FROM (
            s."CustomerName", s."Segment", s."AccountManager", s."PaymentTerms"
            , s."Email", s."Phone", NULLIF(s."CreditLimit", 0)::NUMERIC(14,2)
            , s."Street", s."CityName", s."RegionName"
            , NULLIF(s."update_at", '')::TIMESTAMP
        )
);

DROP TABLE IF EXISTS tmp_final_customers;

-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.dim_customers;
-- SELECT * FROM core.dim_customers ORDER BY dw_updated_at DESC LIMIT 10;