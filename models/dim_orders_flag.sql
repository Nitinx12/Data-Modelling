-- =====================================================================
-- JUNK / FLAG DIMENSION LOAD SCRIPT
-- Target : core.dim_orders_flag
-- Source : staging.orders_2025, staging.orders_2026, staging.channels
-- Pattern: One row per distinct (channel, status, priority) combination.
--          Idempotent load — existing combinations are never duplicated
--          or updated (the combination itself IS the identity).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.dim_orders_flag
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.dim_orders_flag (
    flag_key        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_code    BIGINT,
    channel_name    VARCHAR(100),
    status          VARCHAR(50),
    priority        VARCHAR(50),
    dw_created_at   TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_orders_flag UNIQUE (channel_code, status, priority)
);

COMMENT ON TABLE core.dim_orders_flag IS 'Junk dimension: distinct combinations of order channel, status, and priority.';


-- =====================================================================
-- 2. LOAD — core.dim_orders_flag
-- =====================================================================
WITH append_queries AS(
    SELECT
        "OrderChannel",
        "Status",
        "Priority",
        "update_at"
    FROM staging.orders_2025

    UNION ALL

    SELECT
        "OrderChannel",
        "Status",
        "Priority",
        "update_at"
    FROM staging.orders_2026
),
duplicate_check AS(
    SELECT
        *,
        ROW_NUMBER() OVER(
            PARTITION BY "OrderChannel", "Status", "Priority"
            ORDER BY "update_at"
        ) AS rnk
    FROM append_queries
)
INSERT INTO core.dim_orders_flag (channel_code, channel_name, status, priority)
SELECT
    D."OrderChannel",
    C.channel_name,
    D."Status",
    D."Priority"
FROM duplicate_check AS D
LEFT JOIN staging.channels AS C
    ON D."OrderChannel" = C.channel_id
WHERE D.rnk = 1
ON CONFLICT (channel_code, status, priority) DO NOTHING;


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT * FROM core.dim_orders_flag ORDER BY flag_key;