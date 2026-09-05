# Great Expectations — Warehouse Data Quality

This directory holds the [Great Expectations](https://greatexpectations.io)
suites that validate the `core` warehouse in parallel with the SQL
loops in `tests/`.

| SQL loop | GX suite |
|---|---|
| `01_lp_required_text_checks.sql` | `gx/expectations/required_text_suite.yaml` |
| `02_lp_future_date_checks.sql` | `gx/expectations/future_date_suite.yaml` |
| `03_lp_negative_numeric_checks.sql` | `gx/expectations/negative_numeric_suite.yaml` |
| `04_lp_duplicate_key_checks.sql` | `gx/expectations/duplicate_key_suite.yaml` |
| `05_lp_orphan_foreign_key_checks.sql` | `gx/expectations/orphan_fk_suite.yaml` |

## Running a suite

```bash
make gx SUITE=required_text_suite
make gx SUITE=future_date_suite
make gx SUITE=duplicate_key_suite
# ...
```

`make gx` (no arg) prints the available suites. Suites must be
executed against a populated warehouse — run `make pipeline` first.

## Initial setup

The expectation files here are checked in as the project's source of
truth. The interactive `gx init` wizard is therefore **not** required —
just sync dependencies and run a suite:

```bash
uv sync
make gx SUITE=required_text_suite
```

If you want to author new suites interactively, run:

```bash
make gx-init
```

…which calls `gx init` against the current directory.