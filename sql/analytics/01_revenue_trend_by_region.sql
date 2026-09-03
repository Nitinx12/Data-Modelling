-- =====================================================================
-- AD HOC: Monthly revenue trend by shipping region
-- Source : core.fact_orders + core.dim_geo
-- Use    : "How is revenue trending, and where?" — feed into a
--          line/area chart with order_month on X, one series per region.
-- =====================================================================
SELECT
    date_trunc('month', fo.order_date)::date AS order_month,
    COALESCE(g.region_name, 'Unknown')       AS region_name,
    SUM(fo.line_total)                       AS revenue,
    SUM(fo.quantity)                         AS units_sold,
    COUNT(DISTINCT fo.order_id)              AS order_count
FROM core.fact_orders fo
LEFT JOIN core.dim_geo g
    ON fo.ship_geo_key = g.geo_key
WHERE fo.order_date IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;
