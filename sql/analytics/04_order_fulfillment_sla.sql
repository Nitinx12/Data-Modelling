-- =====================================================================
-- AD HOC: Order fulfillment SLA by ship mode
-- Source : core.fact_order_process (accumulating snapshot)
-- Use    : Ops review — where is the pipeline slow, and how many
--          orders are stuck (never delivered / never paid)?
-- =====================================================================
SELECT
    COALESCE(ship_mode, 'Unknown')                       AS ship_mode,
    COUNT(*)                                              AS order_count,
    ROUND(AVG(days_order_to_ship), 1)                     AS avg_days_to_ship,
    ROUND(AVG(days_ship_to_delivery), 1)                  AS avg_days_to_deliver,
    ROUND(AVG(days_order_to_invoice), 1)                  AS avg_days_to_invoice,
    ROUND(AVG(days_invoice_to_pay), 1)                    AS avg_days_to_pay,
    COUNT(*) FILTER (WHERE ship_date IS NULL)             AS not_yet_shipped,
    COUNT(*) FILTER (WHERE delivery_date IS NULL)         AS not_yet_delivered,
    COUNT(*) FILTER (WHERE pay_date IS NULL)              AS not_yet_paid
FROM core.fact_order_process
GROUP BY ship_mode
ORDER BY order_count DESC;
