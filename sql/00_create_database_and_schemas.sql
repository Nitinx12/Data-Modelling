-- ============================================================
-- 1. Create Database
-- ============================================================
CREATE DATABASE data_warehouse;

-- ============================================================
-- 2. Connect to the Database
-- ============================================================
\c data_warehouse

-- ============================================================
-- 3. Create Schemas
-- ============================================================
DO $$
BEGIN
    -- Staging: raw, unmodeled data landed from sources
    IF NOT EXISTS (
        SELECT 1
        FROM pg_namespace
        WHERE nspname = 'staging'
    ) THEN
        CREATE SCHEMA staging;
    END IF;

    -- Warehouse: cleaned, conformed data layer
    IF NOT EXISTS (
        SELECT 1
        FROM pg_namespace
        WHERE nspname = 'core'
    ) THEN
        CREATE SCHEMA warehouse;
    END IF;

    -- Analytics: presentation/mart layer for reporting
    IF NOT EXISTS (
        SELECT 1
        FROM pg_namespace
        WHERE nspname = 'analytics'
    ) THEN
        CREATE SCHEMA analytics;
    END IF;
END $$;