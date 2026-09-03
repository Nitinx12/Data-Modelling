-- =====================================================================
-- AD HOC: Top customers by lifetime revenue
-- Source : core.fact_orders + core.dim_customers
-- Use    : Account review / renewal prioritization. avg_order_value
--          helps tell "big but infrequent" apart from "steady" accounts.
-- =====================================================================
SELECT
    c.customer_name,
    c.segment,
    c.account_manager,
    c.region_name,
    COUNT(DISTINCT fo.order_id)                                      AS order_count,
    SUM(fo.line_total)                                                AS lifetime_revenue,
    ROUND(SUM(fo.line_total) / NULLIF(COUNT(DISTINCT fo.order_id), 0), 2) AS avg_order_value,
    MAX(fo.order_date)                                                AS last_order_date
FROM core.fact_orders fo
JOIN core.dim_customers c
    ON fo.customer_key = c.customer_key
GROUP BY c.customer_name, c.segment, c.account_manager, c.region_name
ORDER BY lifetime_revenue DESC
LIMIT 25;
