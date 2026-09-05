<p align="center">
  <img src="assets/data_modelling_logo.png" alt="Data Modelling logo" width="320">
</p>

<h1 align="center">Warehouse Pipeline</h1>

<p align="center">
  MongoDB → Postgres staging → dimensional models → data quality checks,
  orchestrated with a thin Makefile.
</p>

---

## Overview

This project moves data from MongoDB into a Postgres warehouse and keeps
it trustworthy:

1. **Stage** — copy MongoDB collections into Postgres staging tables,
   incrementally where possible.
2. **Model** — build dimension and fact tables in dependency order.
3. **Check** — run read-only SQL data-quality loops over the result.
4. **Maintain** — keep the logs all of the above produce from growing
   unbounded.

Every stage is a standalone script under `scripts/`, and the `Makefile`
wires them into single-command targets (and a full pipeline).

```mermaid
flowchart LR
    Mongo[(MongoDB)] -->|make staging| Staging["pg_staging.py"]
    Staging --> Bronze[(Postgres<br/>staging)]
    Bronze -->|make models| Models["run_models.py<br/>dims → facts"]
    Models --> DW[(Postgres<br/>dims & facts)]
    DW -->|make quality| DQ["run_data_quality_loops.py"]

    Staging -.logs.-> Logs[(logs/)]
    Models -.logs.-> Logs
    DQ -.logs.-> Logs

    Logs -->|make logs-summary /<br/>logs-clean| Monitor["monitor_logs.sh"]
    Staging -.verify.-> HC["health_check.sh"]
    Models -.verify.-> HC
    DQ -.verify.-> HC
    HC -.scan.-> Sec["security_check.sh"]
    Setup["setup_dev.sh"] -.one-time.-> Env[".env + venv"]
    Setup -.then.-> HC
```

`make pipeline` runs the staging → models → quality chain above in one
command. `make health-check` and `make security-check` are read-only
pre-flight checks you can run before or after any stage.
For how the pieces fit together and what each script does in
detail, see **[Docs](#docs)** below.

## Requirements

- [`uv`](https://github.com/astral-sh/uv)
- `bash`
- `psql` (for `make analytics` and `make health-check`)
- `mongosh` (for `make health-check`)
- A `.env` file at the project root (copy `.env.example` and fill it in)

> **Windows:** run everything from inside WSL — the Makefile shells out
> to `bash`, and all `scripts/*.sh` need a real POSIX shell, not
> PowerShell/cmd.exe.

## Quickstart

```bash
# One-time setup for a new checkout
make setup-dev        # uv sync + .env scaffold + health check

# Sanity-check resolved paths/vars before running anything
make config

# Full pipeline
make pipeline         # staging load -> models -> data quality, in order
```

## Docs

| Doc | What's in it |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The pipeline end-to-end, with a diagram, stage-by-stage explanation, shared conventions, and directory layout. |
| [`scripts.md`](docs/scripts.md) | Per-script reference — usage, flags, where each one logs to. |
| [`data_catlog.md`](docs/data_catlog.md) | Data Catlog of dim and fact tables. |
| [`ERD.md`](docs/ERD.md) | A visual flowchart that maps out how data objects, or entities, relate to each other within a database system. |
| [`TESTS.md`](docs/TESTS.md) | SQL data-quality loop reference (runs from `tests/data_quality/`). |

## Makefile commands

Run `make` or `make help` at any time to print this list from the
Makefile itself.

### Setup

| Command | Description |
|---|---|
| `make install` | Install/sync all project dependencies via uv |
| `make check-env` | Verify a `.env` file exists before running anything DB-related |
| `make config` | Print resolved variables (useful before running with overrides) |

### Code quality

| Command | Description |
|---|---|
| `make lint` | Run ruff checks over the codebase (no changes made) |
| `make lint-fix` | Run ruff checks and auto-fix what it safely can |
| `make format-check` | Check formatting with ruff without changing files |

### Staging load (`pg_staging.py`)

| Command | Description |
|---|---|
| `make staging` | Load every Mongo collection into staging |
| `make staging-one COLLECTION=<name>` | Load a single collection |

### Warehouse models (`run_models.py`)

| Command | Description |
|---|---|
| `make models` | Run every model in sequence, in dependency order |
| `make models-only MODELS="a.sql b.sql"` | Run specific models only |
| `make models-continue` | Run every model, continuing past failures instead of stopping |

### Data quality (`run_data_quality_loops.py`)

| Command | Description |
|---|---|
| `make quality` | Run the read-only data quality SQL loops |
| `make dq` | Alias for `quality` |

### Analytics schema

| Command | Description |
|---|---|
| `make analytics` | Apply every `.sql` file in `sql/analytics/` via `psql` and print any KPI results; builds `DATABASE_URL` from `.env` if not passed explicitly |

### Health & security checks

| Command | Description |
|---|---|
| `make health-check` | Verify `uv`, `psql`, `mongosh`, Python 3.13, `.env`, Postgres + MongoDB reachability, and `logs/` + `.venv/` disk usage |
| `make health-check-deep` | Same as `make health-check`, plus row counts for every `staging.*` and `core.*` table |
| `make security-check` | Surface common security mistakes — `.env` tracked, hard-coded secrets, private keys, missing `.gitignore` patterns |
| `make security-check-shellcheck` | Same as `make security-check`, plus `shellcheck` on every `scripts/*.sh` |
| `make setup-dev` | Idempotent local setup — `uv sync`, copy `.env.example` → `.env`, placeholder detection, then `make health-check` |

All four use `scripts/health_check.sh` and `scripts/security_check.sh`
under the hood. Run them directly from WSL or Linux if you need to pass
flags not exposed through the Makefile.

### Log maintenance (`monitor_logs.sh`)

| Command | Description |
|---|---|
| `make logs-summary` | Read-only summary report of `logs/` |
| `make logs-clean-dry` | Preview what a log cleanup would delete (deletes nothing) |
| `make logs-clean` | Delete flagged logs (interactive confirmation) |
| `make logs-clean-force` | Delete flagged logs without confirmation (CI/cron use) |

### Full pipeline

| Command | Description |
|---|---|
| `make pipeline` | Run staging load → models → data quality, in order |
| `make pipeline-continue` | Same as `pipeline`, but models keep running past failures |

### Housekeeping

| Command | Description |
|---|---|
| `make clean` | Remove Python cache artifacts (safe — no data or log deletion) |
| `make distclean` | `clean` + force-delete flagged logs (destructive) |

### Useful overrides

```bash
make staging-one COLLECTION=Address
make models-only MODELS="fact_orders.sql fact_less_fact.sql"
make logs-clean MAX_AGE_DAYS=14 MAX_SIZE_MB=10
make analytics DATABASE_URL=postgresql://user:pass@host:5432/db
```