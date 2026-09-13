# Operations Runbook

How to run and look after the warehouse day to day. Point to point; for
script flags and log locations see `docs/scripts.md`.

## First run on a new machine

```bash
make setup-dev        # uv sync, .env scaffold, health check
make config           # confirm resolved variables
make pipeline         # staging -> models -> data quality -> GX
```

## The pipeline

| Command | What it does | Fails when |
|---|---|---|
| `make staging` | Mongo → `staging`, incremental via `update_at` | Mongo unreachable, bad `.env` |
| `make models` | Runs `models/*.sql` in dependency order | Any model errors |
| `make quality` | Read only DQ loops | Nothing (report only) |
| `make gx` | Great Expectations suites, read only | Nothing (report only) |
| `make pipeline` | All four, in order | Any stage fails — DQ and GX run `--strict`, so red data fails the run |

Re-run any single stage on its own; every stage is idempotent.

## Daily checks

```bash
make health-check-deep   # deps, .env, both databases, row counts per table
make security-check      # .env not tracked, no secrets, .gitignore coverage
make logs-summary        # size and age of logs/
```

Run these before and after a pipeline run on a schedule.

## Logs

Everything logs under `logs/<subdir>/` via `utils.logger`.

```bash
make logs-summary      # read only report
make logs-clean-dry    # preview, deletes nothing
make logs-clean        # interactive delete of flagged logs
```

## When `make pipeline` exits 1

1. Read the console output — the failing stage and check name are printed.
2. Open the log under `logs/` for that stage for full detail.
3. Query the failing rows (the DQ loops print the exact table and predicate).
4. Fix the source or the model, re-run `make models`, then `make quality`.
5. Do not edit `core` tables by hand to make a check pass — fix the cause.

## Scheduling (cron)

```cron
0 2 * * *  cd /path/to/repo && make pipeline >> logs/cron.log 2>&1
0 8 * * 1  cd /path/to/repo && make logs-clean-force MAX_AGE_DAYS=30
```

A non-zero exit from `make pipeline` means the run failed — alert on it.
