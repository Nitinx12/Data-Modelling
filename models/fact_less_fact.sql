-- =====================================================================
-- FACTLESS FACT LOAD SCRIPT
-- Target : core.fact_less_fact (grain: one row per campaign-promoted-SKU pair)
-- Source : staging.campaing_sku
-- Dims   : core.dim_campaign, core.dim_products
-- Pattern: Factless fact table — records that a relationship/event
--          occurred (SKU X was promoted in Campaign Y) with NO numeric
--          measures. core.fact_campaign_spend and core.fact_less_fact
--          are not joined to each other directly — they're linked
--          through the shared conformed dimensions (dim_campaign,
--          dim_products), which is what makes this a star schema.
-- Order  : Run dim_campaign_load.sql AND the dim_products load FIRST —
--          this script resolves both keys via joins to those dims.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.fact_less_fact
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.fact_less_fact (
    fact_less_fact_key   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_key         BIGINT REFERENCES core.dim_campaign(campaign_key),
    product_key          BIGINT REFERENCES core.dim_products(product_key),
    campaign_name        VARCHAR(200),
    promoted_sku         VARCHAR(200),
    dw_created_at        TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_less_fact UNIQUE (campaign_key, product_key)
);

COMMENT ON TABLE core.fact_less_fact IS 'Factless fact — records which SKUs were promoted in which campaigns. No measures. Grain: one row per campaign-per-promoted-product relationship.';

CREATE INDEX IF NOT EXISTS ix_fact_less_fact_campaign ON core.fact_less_fact (campaign_key);
CREATE INDEX IF NOT EXISTS ix_fact_less_fact_product  ON core.fact_less_fact (product_key);


-- =====================================================================
-- 2. LOAD — core.fact_less_fact
-- No source_updated_at to compare against (no measures to overwrite),
-- so duplicates are just skipped rather than updated.
-- =====================================================================
INSERT INTO core.fact_less_fact (
    campaign_key,
    product_key,
    campaign_name,
    promoted_sku
)
SELECT DISTINCT
    DC.campaign_key,
    P.product_key,
    CS."CampaignName",
    CS."PromotedSKUs"
FROM staging.campaing_sku AS CS
JOIN core.dim_campaign AS DC
    ON CS."CampaignName" = DC.campaign_name
JOIN core.dim_products AS P
    ON CS."PromotedSKUs" = P.product_code
ON CONFLICT (campaign_key, product_key) DO NOTHING;

DELETE FROM core.fact_less_fact
WHERE campaign_key IS NULL
   OR product_key IS NULL;


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.fact_less_fact;
-- SELECT * FROM core.fact_less_fact ORDER BY campaign_name, promoted_sku LIMIT 20;
-- SELECT COUNT(*) FROM core.fact_less_fact WHERE campaign_key IS NULL;  -- unmatched campaigns
-- SELECT COUNT(*) FROM core.fact_less_fact WHERE product_key  IS NULL;  -- unmatched products