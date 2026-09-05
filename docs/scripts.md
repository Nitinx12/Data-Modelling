# Scripts

Reference for the scripts in this repo. For how they fit together,
see `ARCHITECTURE.md`.

## `pg_staging.py`

Extracts documents from MongoDB and loads them into Postgres staging
tables — one table per collection, same name, no suffixes.

- **First run for a collection:** full extract → `CREATE TABLE` → bulk
  insert.
- **Later runs:** pulls only docs where `update_at` is greater than the
  max `update_at` already in the target table, then upserts by `_id`.
- **No `update_at` field:** treated as non-incremental — full extract
  every run, upserted by `_id`.

```bash
uv run pg_staging.py                       # every collection in the Mongo db
uv run pg_staging.py --collection Address  # just one collection
```

| | |
|---|---|
| Target schema | `POSTGRES_SCHEMA_STAGING` if set, else `POSTGRES_SCHEMA_BRONZE` |
| Logs | `logs/staging/staging_<date>.log` |
| Console | Rich live status per collection + summary table |
| Exit code | `1` if any collection fails; other failures don't stop the run |

## `run_models.py`

Runs the warehouse model `.sql` files in `models/` against Postgres, in
a fixed dependency order (dims before the facts that use them).

```bash
uv run scripts/run_models.py
uv run scripts/run_models.py --only fact_orders.sql fact_less_fact.sql
uv run scripts/run_models.py --continue-on-error
```

- `--only` restricts the run to the listed files, still in sequence order.
- `--continue-on-error` keeps running later models after a failure;
  by default, a failed model causes everything after it to be skipped.
- Each model runs as one script in its own transaction — a failure rolls
  back just that model.

| | |
|---|---|
| Model files | `models/*.sql`, order defined by `MODEL_SEQUENCE` |
| Logs | via `utils.logger`, `core` subdir |
| Console | Rich status line per model + summary table |
| Exit code | `1` if any model fails |

## `run_data_quality_loops.py`

Runs every read-only SQL loop file matching `tests/data_quality/*_lp_*.sql`,
in order. Each loop raises a `NOTICE` per failed check plus a rollup line
like `"... loop complete: 2 failed check(s), 16 failed row(s)."`; this
script parses those notices — it never writes to the database.

```bash
uv run scripts/run_data_quality_loops.py
```

| | |
|---|---|
| Loop files | `tests/data_quality/*_lp_*.sql` |
| Logs | via `utils.logger`, `tests` subdir |
| Console | Rich rule per loop, red `FAIL` lines, final summary table |
| Exit behavior | Prints an overall PASS/FAIL summary; does not raise on failed checks |

## `monitor_logs.sh`

Reports on, or cleans up, the log files written by the three scripts
above. The most recently modified log file is always kept, no matter its
age or size.

```bash
./monitor_logs.sh                 # summary report (default, read-only)
./monitor_logs.sh summary         # same as above
./monitor_logs.sh clean           # delete flagged logs (asks to confirm)
./monitor_logs.sh clean --dry-run # preview only, deletes nothing
./monitor_logs.sh clean -y        # delete without confirmation
./monitor_logs.sh -h              # help
```

A file is flagged for deletion if it's older than `MAX_AGE_DAYS` (default
`7`) **or** larger than `MAX_SIZE_MB` (default `5`) — override either
with an environment variable:

```bash
MAX_AGE_DAYS=14 MAX_SIZE_MB=10 ./monitor_logs.sh clean
```

| | |
|---|---|
| Log directory | `../logs` relative to the script (i.e. project root `logs/`) |
| Default age limit | 7 days |
| Default size limit | 5 MB |
| Always kept | the single most recently modified file |

## `main.py`

One-shot pipeline orchestrator. Runs `pg_staging.py` → `run_models.py` →
`run_data_quality_loops.py` in sequence, as a single Python process that
invokes each script via `uv run` and inspects the exit code before
proceeding. Useful for cron, CI, and ad-hoc end-to-end runs without
typing three `make` invocations.

```bash
uv run main.py                            # full pipeline, stop on first failure
uv run main.py --skip-staging             # models + quality only
uv run main.py --skip-quality             # staging + models only
uv run main.py --continue-on-error        # keep going past model failures
uv run main.py --help-stages              # show what each stage does
```

Or via the registered entry point: `uv run pipeline` (or just `pipeline`
after `uv sync`).

| | |
|---|---|
| Exit code | `0` all stages passed, `1` at least one stage failed, `2` usage error |
| Output | each stage's stdout/stderr streamed live, final rollup line |

## `health_check.sh`

Read-only pre-flight check for the entire toolchain. Verifies that every
external dependency (CLI, Python interpreter, `.env`, Postgres,
MongoDB) is reachable and reports disk usage on the project's
high-churn directories. Does not modify any data.

```bash
./health_check.sh                # quick checks
./health_check.sh --deep         # also count rows in staging.* and core.*
./health_check.sh -h             # help
```

Builds `DATABASE_URL` from `.env` automatically if not passed on the
command line.

| | |
|---|---|
| Exit code | `0` all required checks passed, `1` at least one failed, `2` usage error |
| Output | colour-coded `[ OK ]` / `[WARN]` / `[FAIL]` per check + summary |

## `security_check.sh`

Scans the working tree for common security mistakes — `.env` tracked by
git, hard-coded credentials in source, embedded PostgreSQL DSN
passwords, private key files, missing `.gitignore` patterns. Read-only:
never modifies any files.

```bash
./security_check.sh                  # all checks
./security_check.sh --shellcheck   # also run shellcheck on scripts/*.sh
./security_check.sh -h              # help
```

| | |
|---|---|
| Exit code | `0` clean, `1` at least one finding, `2` usage error |
| Coverage | `models/`, `scripts/`, `sql/`, `utils/`, `*.py`, `*.sql`, `*.sh` |

## `setup_dev.sh`

One-shot local environment setup for a fresh checkout. Idempotent — safe
to re-run after pulling. Designed to replace the "what do I install
first?" boilerplate for new contributors.

```bash
./setup_dev.sh                  # full: uv sync + .env + placeholder check + health check
./setup_dev.sh --no-sync       # skip uv sync
./setup_dev.sh --skip-health   # skip the final health check
./setup_dev.sh -h              # help
```

| | |
|---|---|
| Exit code | `0` all steps ok, `1` required step failed, `2` usage error |
| Order | uv sync → `.env` scaffold → placeholder detection → `health_check.sh` |
