-- postgres-init/01_schemas.sql
-- Runs automatically on first `docker compose up` via
-- /docker-entrypoint-initdb.d. Creates the three warehouse schemas.
-- NOTE: Do NOT include CREATE DATABASE or \c here — the entrypoint already
-- runs as POSTGRES_USER against POSTGRES_DB (data_warehouse). The original
-- sql/00_create_database_and_schemas.sql contains those statements for
-- manual `psql` bootstrap, but they break inside docker-entrypoint-initdb.d.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'staging') THEN
        CREATE SCHEMA staging;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'core') THEN
        CREATE SCHEMA core;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'analytics') THEN
        CREATE SCHEMA analytics;
    END IF;
END $$;
