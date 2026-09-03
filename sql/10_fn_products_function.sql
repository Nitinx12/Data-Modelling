-- Product-level sales metrics with optional filters
CREATE SCHEMA IF NOT EXISTS analytics;

DROP FUNCTION IF EXISTS analytics.fn_product_metrics(
    DATE, DATE, VARCHAR, VARCHAR, VARCHAR
);

CREATE OR REPLACE FUNCTION analytics.fn_product_metrics(
    p_start_date   DATE DEFAULT NULL,
    p_end_date     DATE DEFAULT NULL,
    p_category     VARCHAR DEFAULT NULL,
    p_brand        VARCHAR DEFAULT NULL,
    p_product_code VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    product_code     VARCHAR,
    product_name     VARCHAR,
    category         VARCHAR,
    brand            VARCHAR,
    units_sold       BIGINT,
    revenue          NUMERIC,
    avg_discount_pct NUMERIC,
    last_sold_date   DATE
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN

    -- Date filters stay in JOIN so products with no sales remain visible.
    RETURN QUERY
    SELECT
        p.product_code,
        p.product_name,
        p.category,
        p.brand,

        COALESCE(SUM(fo.quantity), 0)::BIGINT AS units_sold,

        COALESCE(SUM(fo.line_total), 0)::NUMERIC AS revenue,

        ROUND(
            AVG(fo.discount_pct)::NUMERIC,
            4
        ) AS avg_discount_pct,

        MAX(fo.order_date)::DATE AS last_sold_date

    FROM core.dim_products AS p

    LEFT JOIN core.fact_orders AS fo
        ON fo.product_key = p.product_key
        AND (
            p_start_date IS NULL
            OR fo.order_date >= p_start_date
        )
        AND (
            p_end_date IS NULL
            OR fo.order_date <= p_end_date
        )

    WHERE
        (p_category IS NULL OR p.category = p_category)
        AND (p_brand IS NULL OR p.brand = p_brand)
        AND (
            p_product_code IS NOT NULL
            OR p.product_code <> 'UNKNOWN'
        )
        AND (
            p_product_code IS NULL
            OR p.product_code = p_product_code
        )

    GROUP BY
        p.product_code,
        p.product_name,
        p.category,
        p.brand

    ORDER BY
        revenue DESC NULLS LAST;

END;
$$;

COMMENT ON FUNCTION analytics.fn_product_metrics(
    DATE, DATE, VARCHAR, VARCHAR, VARCHAR
)
IS 'Returns product sales metrics with optional date, category, brand, and product code filters.';

-- -- All products
-- SELECT *
-- FROM analytics.fn_product_metrics();

-- -- Filter products
-- SELECT *
-- FROM analytics.fn_product_metrics(
--     p_start_date := '2026-01-01',
--     p_end_date   := '2026-12-31',
--     p_category   := 'Electronics',
--     p_brand      := 'Samsung'
-- );