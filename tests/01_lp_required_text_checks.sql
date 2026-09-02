-- ============================================================================
-- Loop 1 of 5: required text columns must not contain blank values.
-- Reads core and staging only. Creates no database object.
-- ============================================================================

DO $$
DECLARE
    v_table RECORD;
    v_column RECORD;
    v_failed_rows BIGINT;
    v_failed_checks INTEGER := 0;
    v_total_failed_rows BIGINT := 0;
BEGIN
    FOR v_table IN
        SELECT
            n.nspname AS schema_name
            , c.relname AS table_name
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n
            ON n.oid = c.relnamespace
        WHERE n.nspname IN ('core', 'staging')
          AND c.relkind IN ('r', 'p')
        ORDER BY
            n.nspname
            , c.relname
    LOOP
        FOR v_column IN
            SELECT
                cols.column_name
            FROM information_schema.columns AS cols
            WHERE cols.table_schema = v_table.schema_name
              AND cols.table_name = v_table.table_name
              AND cols.is_nullable = 'NO'
              AND cols.data_type IN ('character', 'character varying', 'text')
            ORDER BY cols.ordinal_position
        LOOP
            EXECUTE format(
                'SELECT COUNT(*) FROM %I.%I AS t WHERE NULLIF(BTRIM(t.%I), '''') IS NULL'
                , v_table.schema_name
                , v_table.table_name
                , v_column.column_name
            )
            INTO v_failed_rows;

            IF v_failed_rows > 0 THEN
                v_failed_checks := v_failed_checks + 1;
                v_total_failed_rows := v_total_failed_rows + v_failed_rows;
                RAISE NOTICE '[FAILED] %.%.% has % blank required value(s).'
                    , v_table.schema_name
                    , v_table.table_name
                    , v_column.column_name
                    , v_failed_rows;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Required-text loop complete: % failed check(s), % failed row(s).'
        , v_failed_checks
        , v_total_failed_rows;
END;
$$;
