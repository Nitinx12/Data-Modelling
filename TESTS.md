# Data-Quality Tests

The `tests/` directory contains five read-only PostgreSQL `DO` loops. They
scan every base table in the `core` and `staging` schemas and report aggregate
failures with `RAISE NOTICE`; they do not create procedures, schemas, tables,
or audit records.

Run the checks in numeric order after the warehouse load:

```sql
\i tests/01_lp_required_text_checks.sql
\i tests/02_lp_future_date_checks.sql
\i tests/03_lp_negative_numeric_checks.sql
\i tests/04_lp_duplicate_key_checks.sql
\i tests/05_lp_orphan_foreign_key_checks.sql
```

Or run all five from the project root:

```bash
uv run python scripts/run_data_quality_loops.py
```

The loops check required text values, future dates, negative numeric values,
duplicate primary/unique keys, and unresolved foreign keys. A non-zero count
in a `FAILED` notice means the affected model data should be investigated.
