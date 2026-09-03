-- =====================================================================
-- AD HOC: Top products by revenue
-- Source : core.fact_orders + core.dim_products
-- Use    : "What's actually selling?" — top-N list for merch/category
--          reviews. Change the LIMIT or add a WHERE on category as needed.
-- =====================================================================
SELECT
    p.product_name,
    p.category,
    p.brand,
    p.primary_supplier,
    SUM(fo.quantity)                       AS units_sold,
    SUM(fo.line_total)                     AS revenue,
    ROUND(AVG(fo.discount_pct), 4)         AS avg_discount_pct,
    ROUND(
        SUM(fo.line_total) / NULLIF(SUM(fo.quantity), 0), 2
    )                                       AS revenue_per_unit
FROM core.fact_orders fo
JOIN core.dim_products p
    ON fo.product_key = p.product_key
WHERE p.product_code <> 'UNKNOWN'   -- exclude the placeholder for missing/retired SKUs
GROUP BY p.product_name, p.category, p.brand, p.primary_supplier
ORDER BY revenue DESC
LIMIT 25;
