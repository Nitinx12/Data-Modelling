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
```

`make pipeline` runs the staging → models → quality chain above in one
command. For how the pieces fit together and what each script does in
detail, see **[Docs](#docs)** below.

## Requirements

- [`uv`](https://github.com/astral-sh/uv)
- `bash`
- `psql` (only needed for `make analytics`)
- A `.env` file at the project root (copy `.env.example` and fill it in)

> **Windows:** run everything from inside WSL — the Makefile shells out
> to `bash`, and `monitor_logs.sh` needs a real POSIX shell, not
> PowerShell/cmd.exe.

## Quickstart

```bash
make install        # uv sync — install project dependencies
make config          # sanity-check resolved paths/vars before running anything
make pipeline        # staging load -> models -> data quality, in order
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