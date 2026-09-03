-- =====================================================================
-- AD HOC: Data quality checks across core facts
-- Source : all core.fact_* tables
-- Use    : Quick health check before trusting a number in a report —
--          run this first if a total looks off. Non-zero counts mean
--          a dim lookup failed (late-arriving dim, bad source key, etc).
-- =====================================================================
SELECT 'fact_orders - missing customer_key'    AS check_name, COUNT(*) AS row_count FROM core.fact_orders WHERE customer_key IS NULL
UNION ALL
SELECT 'fact_orders - missing product_key',                    COUNT(*) FROM core.fact_orders WHERE product_key IS NULL
UNION ALL
SELECT 'fact_orders - missing flag_key',                       COUNT(*) FROM core.fact_orders WHERE flag_key IS NULL
UNION ALL
SELECT 'fact_orders - missing ship_geo_key',                   COUNT(*) FROM core.fact_orders WHERE ship_geo_key IS NULL
UNION ALL
SELECT 'fact_orders - missing bill_geo_key',                   COUNT(*) FROM core.fact_orders WHERE bill_geo_key IS NULL
UNION ALL
SELECT 'fact_order_process - missing customer_id',             COUNT(*) FROM core.fact_order_process WHERE customer_id IS NULL
UNION ALL
SELECT 'fact_order_process - undelivered orders',              COUNT(*) FROM core.fact_order_process WHERE delivery_date IS NULL
UNION ALL
SELECT 'fact_inventory - missing product_key',                 COUNT(*) FROM core.fact_inventory WHERE product_key IS NULL
UNION ALL
SELECT 'fact_campaign_spend - missing campaign_key',           COUNT(*) FROM core.fact_campaign_spend WHERE campaign_key IS NULL
UNION ALL
SELECT 'fact_less_fact - orphan rows (bad campaign/product)',  COUNT(*) FROM core.fact_less_fact WHERE campaign_key IS NULL OR product_key IS NULL
UNION ALL
SELECT 'fact_orders_rejects - quarantined future orders',      COUNT(*) FROM core.fact_orders_rejects
UNION ALL
SELECT 'fact_order_process_rejects - quarantined future orders', COUNT(*) FROM core.fact_order_process_rejects
ORDER BY row_count DESC;
