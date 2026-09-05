-- ============================================================================
-- Loop 5 of 5: every foreign-key value must resolve to a referenced row.
-- A NULL fact key is reported as unresolved for this warehouse.
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
                , ref_namespace.nspname AS referenced_schema_name
                , ref_class.relname AS referenced_table_name
                , STRING_AGG(
                    format('t.%I = r.%I', local_att.attname, referenced_att.attname)
                    , ' AND '
                    ORDER BY local_key.ordinality
                ) AS join_condition
            FROM pg_catalog.pg_constraint AS con
            JOIN pg_catalog.pg_class AS ref_class
                ON ref_class.oid = con.confrelid
            JOIN pg_catalog.pg_namespace AS ref_namespace
                ON ref_namespace.oid = ref_class.relnamespace
            JOIN LATERAL UNNEST(con.conkey) WITH ORDINALITY AS local_key(attnum, ordinality)
                ON TRUE
            JOIN LATERAL UNNEST(con.confkey) WITH ORDINALITY AS referenced_key(attnum, ordinality)
                ON referenced_key.ordinality = local_key.ordinality
            JOIN pg_catalog.pg_attribute AS local_att
                ON local_att.attrelid = con.conrelid
               AND local_att.attnum = local_key.attnum
            JOIN pg_catalog.pg_attribute AS referenced_att
                ON referenced_att.attrelid = con.confrelid
               AND referenced_att.attnum = referenced_key.attnum
            WHERE con.conrelid = v_table.table_oid
              AND con.contype = 'f'
            GROUP BY
                con.conname
                , con.oid
                , ref_namespace.nspname
                , ref_class.relname
            ORDER BY con.conname
        LOOP
            EXECUTE format(
                'SELECT COUNT(*) '
                || 'FROM %I.%I AS t '
                || 'LEFT JOIN %I.%I AS r ON %s '
                || 'WHERE r.ctid IS NULL'
                , v_table.schema_name
                , v_table.table_name
                , v_constraint.referenced_schema_name
                , v_constraint.referenced_table_name
                , v_constraint.join_condition
            )
            INTO v_failed_rows;

            IF v_failed_rows > 0 THEN
                v_failed_checks := v_failed_checks + 1;
                v_total_failed_rows := v_total_failed_rows + v_failed_rows;
                RAISE NOTICE '[FAILED] %.% foreign key % has % unresolved row(s).'
                    , v_table.schema_name
                    , v_table.table_name
                    , v_constraint.constraint_name
                    , v_failed_rows;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Foreign-key loop complete: % failed check(s), % failed row(s).'
        , v_failed_checks
        , v_total_failed_rows;
END;
$$;
