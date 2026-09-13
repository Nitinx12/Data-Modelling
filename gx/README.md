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

## Running the suites

`scripts/python/gx_run.py` runs every suite (or one named suite) against
the warehouse. It is also the fourth pipeline stage — `main.py` runs it
with `--strict` right after the SQL loops, so a failed expectation fails
the pipeline.

```bash
uv run scripts/python/gx_run.py                      # all suites, report only
uv run scripts/python/gx_run.py --strict             # exit 1 if any expectation failed
uv run scripts/python/gx_run.py --suite orphan_fk_suite
uv run scripts/python/gx_run.py --list-suites

make gx                                              # all suites
make gx SUITE=required_text_suite                    # one suite
```

Suites must be executed against a populated warehouse — run
`make pipeline` first.

## How the runner works

Each suite file is a flat list of expectations whose `meta.schema` names
the target table (`core.fact_orders` and so on). Since one suite spans
several tables, the runner groups expectations by table and validates each
group as its own batch, using an ephemeral GX context and a query asset per
table (`SELECT * FROM <schema>.<table>`). Two placeholders are resolved at
run time:

- `$today` / `$now` in any kwarg become the current date / time.
- An empty `value_set` together with `meta.fk_to` (e.g.
  `core.dim_campaign(campaign_key)`) is populated with the live key set
  from the referenced dimension — that is what turns
  `expect_column_values_to_be_in_set` into an orphan FK check.

Expectations that cannot run as written (an empty `value_set` with no
`fk_to`, or no `meta.schema` target) are skipped with a `SKIP` line in the
summary — the two composite uniqueness entries in
`duplicate_key_suite.yaml` are examples; the SQL loop covers them. Like the
SQL loops, the runner only ever reads from the database.

`great_expectations.yml` is not used by `gx_run.py` — the ephemeral
context is configured entirely in code — but documents the layout you
would get from `gx init` if you later want a persistent file context.
