-- =====================================================================
-- DIMENSION LOAD SCRIPT
-- Target : core.dim_campaign  (grain: one row per campaign)
-- Source : staging.campaing_logs
-- Pattern: SCD Type 1 — upsert on (campaign_name)
-- Note   : staging.campaing_logs is denormalized (one row per campaign
--          per day). This dedups down to the latest attributes per
--          campaign_name before loading the dimension.
-- Order  : Run this BEFORE fact_campaign_spend_load.sql — the fact load
--          resolves campaign_key via a join against this table.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.dim_campaign
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.dim_campaign (
    campaign_key         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_name        VARCHAR(200) NOT NULL,
    channel              VARCHAR(100),
    start_date           DATE,
    end_date             DATE,
    budget               NUMERIC(18,2),
    source_updated_at    TIMESTAMP,
    dw_created_at        TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at        TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_campaign_name UNIQUE (campaign_name)
);

COMMENT ON TABLE core.dim_campaign IS 'Campaign dimension, SCD Type 1 (overwrite on change). Grain: one row per campaign.';

CREATE INDEX IF NOT EXISTS ix_dim_campaign_channel ON core.dim_campaign (channel);


-- =====================================================================
-- 2. UPSERT — core.dim_campaign
-- =====================================================================
WITH campaign_dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY "CampaignName" ORDER BY "update_at" DESC
        ) AS rnk
    FROM staging.campaing_logs
),
campaign_final AS (
    SELECT * FROM campaign_dedup WHERE rnk = 1
)
INSERT INTO core.dim_campaign (
    campaign_name,
    channel,
    start_date,
    end_date,
    budget,
    source_updated_at
)
SELECT
    "CampaignName",
    "Channel",
    NULLIF("StartDate", '')::DATE,
    NULLIF("EndDate", '')::DATE,
    "Budget",
    NULLIF("update_at", '')::TIMESTAMP
FROM campaign_final
ON CONFLICT (campaign_name) DO UPDATE SET
    channel             = EXCLUDED.channel,
    start_date          = EXCLUDED.start_date,
    end_date            = EXCLUDED.end_date,
    budget              = EXCLUDED.budget,
    source_updated_at   = EXCLUDED.source_updated_at,
    dw_updated_at       = now()
WHERE core.dim_campaign.source_updated_at IS DISTINCT FROM EXCLUDED.source_updated_at;


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.dim_campaign;
-- SELECT * FROM core.dim_campaign ORDER BY campaign_name LIMIT 20;