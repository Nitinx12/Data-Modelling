-- =====================================================================
-- SCD TYPE 1 DIMENSION LOAD SCRIPT
-- Target : core.dim_geo
-- Source : staging.cities
-- Pattern: Full overwrite on conflict (no history retained)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.dim_geo
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.dim_geo (
    geo_key             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_name           VARCHAR(100)  NOT NULL,
    region_name         VARCHAR(100),
    source_updated_at   TIMESTAMP,
    dw_created_at        TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at        TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_geo_city_name UNIQUE (city_name)
);

COMMENT ON TABLE core.dim_geo IS 'Geography dimension (city/region), SCD Type 1 (overwrite on change).';

CREATE INDEX IF NOT EXISTS ix_dim_geo_region ON core.dim_geo (region_name);


-- =====================================================================
-- 2. UPSERT — core.dim_geo
-- =====================================================================
WITH duplicate_check AS(
    SELECT
        "CityName",
        "RegionName",
        "update_at",
        ROW_NUMBER() OVER(
            PARTITION BY "CityName"
            ORDER BY "update_at" DESC
        ) AS rnk
    FROM staging.cities
),
final_geo AS(
    SELECT *
    FROM duplicate_check
    WHERE rnk = 1
)
INSERT INTO core.dim_geo (city_name, region_name, source_updated_at)
SELECT
    "CityName",
    "RegionName",
    NULLIF("update_at", '')::TIMESTAMP
FROM final_geo
ON CONFLICT (city_name) DO UPDATE SET
    region_name       = EXCLUDED.region_name,
    source_updated_at = EXCLUDED.source_updated_at,
    dw_updated_at      = now()
WHERE core.dim_geo.source_updated_at IS DISTINCT FROM EXCLUDED.source_updated_at;


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.dim_geo;
-- SELECT * FROM core.dim_geo ORDER BY dw_updated_at DESC LIMIT 10;