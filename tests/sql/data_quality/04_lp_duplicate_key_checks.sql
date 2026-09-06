-- ============================================================================
-- Loop 4 of 5: primary and unique keys must not contain duplicate values.
-- Reads core and staging only. Creates no database object.
-- ============================================================================

DO $$
DECLARE
    v_table RECORD;
    v_constraint RECORD;
    v_failed_rows BIGINT;
    v_failed_checks INTEGER := 0;
    v_total_failed_rows BIGINT := 0;
BEGIN
    FOR v_table IN
        SELECT
            n.nspname AS schema_name
            , c.relname AS table_name
            , c.oid AS table_oid
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n
            ON n.oid = c.relnamespace
        WHERE n.nspname IN ('core', 'staging')
          AND c.relkind IN ('r', 'p')
        ORDER BY
            n.nspname
            , c.relname
    LOOP
        FOR v_constraint IN
            SELECT
                con.conname AS constraint_name
                , STRING_AGG(
                    format('%I', att.attname)
                    , ', '
                    ORDER BY key_column.ordinality
                ) AS column_list
                , STRING_AGG(
                    format('t.%I IS NOT NULL', att.attname)
                    , ' AND '
                    ORDER BY key_column.ordinality
                ) AS populated_condition
            FROM pg_catalog.pg_constraint AS con
            JOIN LATERAL UNNEST(con.conkey) WITH ORDINALITY AS key_column(attnum, ordinality)
                ON TRUE
            JOIN pg_catalog.pg_attribute AS att
                ON att.attrelid = con.conrelid
               AND att.attnum = key_column.attnum
            WHERE con.conrelid = v_table.table_oid
              AND con.contype IN ('p', 'u')
            GROUP BY
                con.conname
                , con.oid
            ORDER BY con.conname
        LOOP
            EXECUTE format(
                'SELECT COALESCE(SUM(duplicate_rows), 0) '
                || 'FROM ('
                || 'SELECT COUNT(*) - 1 AS duplicate_rows '
                || 'FROM %I.%I AS t '
                || 'WHERE %s '
                || 'GROUP BY %s '
                || 'HAVING COUNT(*) > 1'
                || ') AS duplicate_groups'
                , v_table.schema_name
                , v_table.table_name
                , v_constraint.populated_condition
                , v_constraint.column_list
            )
            INTO v_failed_rows;

            IF v_failed_rows > 0 THEN
                v_failed_checks := v_failed_checks + 1;
                v_total_failed_rows := v_total_failed_rows + v_failed_rows;
                RAISE NOTICE '[FAILED] %.% constraint % has % duplicate key row(s).'
                    , v_table.schema_name
                    , v_table.table_name
                    , v_constraint.constraint_name
                    , v_failed_rows;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Duplicate-key loop complete: % failed check(s), % failed row(s).'
        , v_failed_checks
        , v_total_failed_rows;
END;
$$;
