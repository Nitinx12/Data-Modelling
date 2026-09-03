-- =====================================================================
-- AD HOC: Campaign performance summary
-- Source : core.dim_campaign + core.fact_campaign_spend + core.fact_less_fact
-- Use    : Marketing review — spend, reach, CTR, budget pacing, and
--          how many SKUs each campaign promoted (via the factless fact,
--          linked through the shared dim_campaign/dim_products keys).
-- =====================================================================
SELECT
    dc.campaign_name,
    dc.channel,
    dc.start_date,
    dc.end_date,
    dc.budget,
    SUM(fcs.spend)                                                 AS total_spend,
    ROUND(dc.budget - SUM(fcs.spend), 2)                           AS budget_remaining,
    SUM(fcs.impressions)                                           AS total_impressions,
    SUM(fcs.clicks)                                                AS total_clicks,
    ROUND(
        SUM(fcs.clicks)::NUMERIC / NULLIF(SUM(fcs.impressions), 0) * 100, 2
    )                                                               AS ctr_pct,
    COUNT(DISTINCT flf.product_key)                                AS promoted_sku_count
FROM core.dim_campaign dc
LEFT JOIN core.fact_campaign_spend fcs
    ON fcs.campaign_key = dc.campaign_key
LEFT JOIN core.fact_less_fact flf
    ON flf.campaign_key = dc.campaign_key
GROUP BY dc.campaign_key, dc.campaign_name, dc.channel, dc.start_date, dc.end_date, dc.budget
ORDER BY total_spend DESC NULLS LAST;
