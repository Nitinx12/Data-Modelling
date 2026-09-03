-- Customer-level sales metrics with optional filters
CREATE SCHEMA IF NOT EXISTS analytics;

DROP FUNCTION IF EXISTS analytics.fn_customer_metrics(
    DATE, DATE, VARCHAR, VARCHAR, VARCHAR
);

CREATE OR REPLACE FUNCTION analytics.fn_customer_metrics(
    p_start_date  DATE DEFAULT NULL,
    p_end_date    DATE DEFAULT NULL,
    p_segment     VARCHAR DEFAULT NULL,
    p_region      VARCHAR DEFAULT NULL,
    p_customer_id VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    customer_id     VARCHAR,
    customer_name   VARCHAR,
    segment         VARCHAR,
    region_name     VARCHAR,
    account_manager VARCHAR,
    order_count     BIGINT,
    total_revenue   NUMERIC,
    avg_order_value NUMERIC,
    last_order_date DATE
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN

    -- Date filters stay in JOIN so customers with no orders remain visible.
    RETURN QUERY
    SELECT
        c.customer_id,
        c.customer_name,
        c.segment,
        c.region_name,
        c.account_manager,

        COUNT(DISTINCT fo.order_id) AS order_count,

        COALESCE(SUM(fo.line_total), 0)::NUMERIC AS total_revenue,

        ROUND(
            (
                COALESCE(SUM(fo.line_total), 0)
                / NULLIF(COUNT(DISTINCT fo.order_id), 0)
            )::NUMERIC,
            2
        ) AS avg_order_value,

        MAX(fo.order_date)::DATE AS last_order_date

    FROM core.dim_customers AS c

    LEFT JOIN core.fact_orders AS fo
        ON fo.customer_key = c.customer_key
        AND (
            p_start_date IS NULL
            OR fo.order_date >= p_start_date
        )
        AND (
            p_end_date IS NULL
            OR fo.order_date <= p_end_date
        )

    WHERE
        (p_segment IS NULL OR c.segment = p_segment)
        AND (p_region IS NULL OR c.region_name = p_region)
        AND (p_customer_id IS NULL OR c.customer_id = p_customer_id)

    GROUP BY
        c.customer_id,
        c.customer_name,
        c.segment,
        c.region_name,
        c.account_manager

    ORDER BY
        total_revenue DESC NULLS LAST;

END;
$$;

COMMENT ON FUNCTION analytics.fn_customer_metrics(
    DATE, DATE, VARCHAR, VARCHAR, VARCHAR
)
IS 'Returns customer sales metrics with optional date, segment, region, and customer ID filters.';

-- -- All customers
-- SELECT *
-- FROM analytics.fn_customer_metrics();

-- -- Filter customers
-- SELECT *
-- FROM analytics.fn_customer_metrics(
--     p_start_date := '2026-01-01',
--     p_end_date   := '2026-12-31',
--     p_segment    := 'Enterprise'
-- );