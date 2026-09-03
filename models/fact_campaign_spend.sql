-- =====================================================================
-- FACT TABLE LOAD SCRIPT
-- Target : core.fact_campaign_spend (grain: one row per campaign per day)
-- Source : staging.campaing_logs
-- Dim    : core.dim_campaign
-- Pattern: SCD Type 1 — upsert on (campaign_name, spend_date)
-- Note   : staging.campaing_logs is denormalized (campaign attributes +
--          daily metrics on every row). This dedups down to the latest
--          metrics per campaign_name + date before loading the fact.
-- Order  : Run dim_campaign_load.sql FIRST — this script joins to
--          core.dim_campaign to resolve campaign_key.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.fact_campaign_spend
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.fact_campaign_spend (
    spend_key            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_key         BIGINT REFERENCES core.dim_campaign(campaign_key),
    campaign_name        VARCHAR(200),
    spend_date           DATE        NOT NULL,
    impressions          BIGINT,
    clicks               BIGINT,
    spend                NUMERIC(18,2),
    source_updated_at    TIMESTAMP,
    dw_created_at        TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at        TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_campaign_spend_name_date UNIQUE (campaign_name, spend_date)
);

COMMENT ON TABLE core.fact_campaign_spend IS 'Campaign spend/performance fact, SCD Type 1 (overwrite on change). Grain: one row per campaign per day.';

CREATE INDEX IF NOT EXISTS ix_fact_campaign_spend_campaign ON core.fact_campaign_spend (campaign_key);
CREATE INDEX IF NOT EXISTS ix_fact_campaign_spend_date     ON core.fact_campaign_spend (spend_date);


-- =====================================================================
-- 2. UPSERT — core.fact_campaign_spend
-- =====================================================================
WITH spend_dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY "CampaignName", "Date" ORDER BY "update_at" DESC
        ) AS rnk
    FROM staging.campaing_logs
),
spend_final AS (
    SELECT * FROM spend_dedup WHERE rnk = 1
)
INSERT INTO core.fact_campaign_spend (
    campaign_key,
    campaign_name,
    spend_date,
    impressions,
    clicks,
    spend,
    source_updated_at
)
SELECT
    D.campaign_key,
    S."CampaignName",
    NULLIF(S."Date", '')::DATE,
    S."Impressions",
    S."Clicks",
    S."Spend",
    NULLIF(S."update_at", '')::TIMESTAMP
FROM spend_final AS S
LEFT JOIN core.dim_campaign AS D
    ON D.campaign_name = S."CampaignName"
ON CONFLICT (campaign_name, spend_date) DO UPDATE SET
    campaign_key         = EXCLUDED.campaign_key,
    impressions          = EXCLUDED.impressions,
    clicks               = EXCLUDED.clicks,
    spend                = EXCLUDED.spend,
    source_updated_at    = EXCLUDED.source_updated_at,
    dw_updated_at        = now()
WHERE core.fact_campaign_spend.source_updated_at IS DISTINCT FROM EXCLUDED.source_updated_at;


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.fact_campaign_spend;
-- SELECT * FROM core.fact_campaign_spend ORDER BY spend_date, campaign_name LIMIT 20;
-- SELECT COUNT(*) FROM core.fact_campaign_spend WHERE campaign_key IS NULL;  -- unmatched campaigns