# TESTS.md

## Data Quality Test Suite

This project ships five standalone PL/pgSQL scripts that audit the `core` and `staging` schemas for common data quality problems. Each script is a self contained anonymous block (`DO $$ ... $$`) that discovers its own targets by walking `information_schema` and `pg_catalog`, so no table or column names are hardcoded anywhere. Run each one independently, in any order, against a live PostgreSQL database. None of them creates, alters, or drops a database object; they only read.

## How the loops work

Every script follows the same two level loop pattern:

1. Loop over every table in `core` and `staging` (ordinary and partitioned tables only).
2. Loop over every column or constraint on that table relevant to the check.
3. Run one dynamic `EXECUTE` per column or constraint and count the failing rows.
4. `RAISE NOTICE` a line for every failure, then print a summary line at the end.

Because everything is driven by catalog metadata rather than a fixed list, the scripts automatically pick up new tables and columns as the schema grows. Nothing needs to be updated by hand when a new table lands in `core` or `staging`.

## The five checks

### 1. Required text checks — `01_lp_required_text_checks.sql`
Scans every `NOT NULL` `character`, `character varying`, and `text` column and flags rows where the trimmed value is empty. Uses `NULLIF(BTRIM(value), '')` so a whitespace only string counts as blank even though it satisfies a plain `NOT NULL` constraint.

### 2. Future date checks — `02_lp_future_date_checks.sql`
Scans every `date`, `timestamp`, and `timestamptz` column and flags rows where the value is later than the current moment. Plain dates are compared against `CURRENT_DATE`; timestamps are compared against `CURRENT_TIMESTAMP`.

### 3. Negative numeric checks — `03_lp_negative_numeric_checks.sql`
Scans every numeric type column (`smallint`, `integer`, `bigint`, `numeric`, `real`, `double precision`) and flags rows where the value is below zero. Catches columns like quantities, amounts, or ages that should never go negative even without an explicit `CHECK` constraint.

### 4. Duplicate key checks — `04_lp_duplicate_key_checks.sql`
Reads primary key and unique constraints straight from `pg_constraint`, then groups each table by the constraint's columns and counts groups with more than one row. A `IS NOT NULL` guard on every key column keeps nullable unique columns from producing false positives, since two NULLs never count as duplicates under a unique constraint.

### 5. Orphan foreign key checks — `05_lp_orphan_foreign_key_checks.sql`
Reads foreign key constraints from `pg_constraint`, then left joins each table to its referenced table on the constraint's columns and counts rows with no match. A NULL foreign key value is treated as unresolved for this warehouse, so it gets reported here instead of quietly passing.

## Output format

All five scripts share one format. A failing check prints one line:

```
NOTICE:  [FAILED] core.orders.customer_id has 3 blank required value(s).
```

and each script ends with a rollup line:

```
NOTICE:  Required text loop complete: 1 failed check(s), 3 failed row(s).
```

A clean run produces only that summary line, with both counts at zero.

## Snapshot: a sample run

```
NOTICE:  [FAILED] core.customers.email has 4 blank required value(s).
NOTICE:  [FAILED] staging.orders.order_status has 12 blank required value(s).
NOTICE:  Required text loop complete: 2 failed check(s), 16 failed row(s).

NOTICE:  [FAILED] core.orders.ship_date has 7 future value(s).
NOTICE:  Future date loop complete: 1 failed check(s), 7 failed row(s).

NOTICE:  Negative numeric loop complete: 0 failed check(s), 0 failed row(s).

NOTICE:  [FAILED] core.customers pk_customers has 2 duplicate key row(s).
NOTICE:  Duplicate key loop complete: 1 failed check(s), 2 failed row(s).

NOTICE:  [FAILED] core.order_items fk_order_items_order_id has 5 unresolved row(s).
NOTICE:  Foreign key loop complete: 1 failed check(s), 5 failed row(s).
```

Reading that snapshot: emails and order statuses have blanks, a ship date is set in the future, no numeric column has gone negative, one duplicate customer slipped past the primary key, and five order items point at an order that does not exist.

## Running the scripts

Each file is a plain `DO` block, so run it with `psql`:

```
psql -d your_database -f 01_lp_required_text_checks.sql
```

Run all five back to back for a full picture of `core` and `staging` in one pass:

```
for f in 0*_lp_*.sql; do psql -d your_database -f "$f"; done
```

## Design notes

- Every check is read only, so the scripts are safe to run against production for an audit.
- Failures are reported through `RAISE NOTICE`, not exceptions, so one bad column never stops the rest of the loop.
- Because the loops walk catalog metadata rather than a fixed list of tables, adding a new table to `core` or `staging` is covered automatically on the next run.
- The duplicate key and orphan foreign key checks build their `EXECUTE` strings from `pg_constraint`, so they always match whatever primary key, unique, and foreign key constraints exist right now, even after a schema change.