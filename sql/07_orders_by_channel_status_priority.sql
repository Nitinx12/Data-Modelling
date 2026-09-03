-- =====================================================================
-- AD HOC: Revenue and line count by channel / status / priority
-- Source : core.fact_orders + core.dim_orders_flag (junk dimension)
-- Use    : "Which channel/status/priority combos drive the business,
--          and where is revenue stuck in a non-terminal status?"
-- =====================================================================
SELECT
    COALESCE(dof.channel_name, 'Unknown') AS channel_name,
    dof.status,
    dof.priority,
    COUNT(*)                              AS line_count,
    SUM(fo.line_total)                    AS revenue
FROM core.fact_orders fo
JOIN core.dim_orders_flag dof
    ON fo.flag_key = dof.flag_key
GROUP BY dof.channel_name, dof.status, dof.priority
ORDER BY revenue DESC NULLS LAST;
