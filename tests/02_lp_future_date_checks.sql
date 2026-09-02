-- ============================================================================
-- Loop 2 of 5: date and timestamp columns must not contain future values.
-- Reads core and staging only. Creates no database object.
-- ============================================================================

DO $$
DECLARE
    v_table RECORD;
    v_column RECORD;
    v_failed_rows BIGINT;
    v_future_expression TEXT;
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
                , cols.data_type
            FROM information_schema.columns AS cols
            WHERE cols.table_schema = v_table.schema_name
              AND cols.table_name = v_table.table_name
              AND cols.data_type IN (
                  'date'
                  , 'timestamp without time zone'
                  , 'timestamp with time zone'
              )
            ORDER BY cols.ordinal_position
        LOOP
            v_future_expression := CASE
                WHEN v_column.data_type = 'date' THEN 'CURRENT_DATE'
                ELSE 'CURRENT_TIMESTAMP'
            END;

            EXECUTE format(
                'SELECT COUNT(*) FROM %I.%I AS t WHERE t.%I > %s'
                , v_table.schema_name
                , v_table.table_name
                , v_column.column_name
                , v_future_expression
            )
            INTO v_failed_rows;

            IF v_failed_rows > 0 THEN
                v_failed_checks := v_failed_checks + 1;
                v_total_failed_rows := v_total_failed_rows + v_failed_rows;
                RAISE NOTICE '[FAILED] %.%.% has % future value(s).'
                    , v_table.schema_name
                    , v_table.table_name
                    , v_column.column_name
                    , v_failed_rows;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Future-date loop complete: % failed check(s), % failed row(s).'
        , v_failed_checks
        , v_total_failed_rows;
END;
$$;
