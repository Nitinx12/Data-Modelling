<p align="center">
  <img src="assets/new_logo.png" alt="Data Modelling logo" width="320">
</p>

<h1 align="center">Warehouse Pipeline</h1>

<p align="center">
  MongoDB → Postgres staging → dimensional models → data quality checks,
  orchestrated with a thin Makefile.
</p>

---

## Overview

A Kimball-style analytics warehouse where MongoDB documents flow into PostgreSQL staging and are transformed into a core fact constellation with five conformed dimensions and five fact tables. A catalog-driven, read-only PL/pgSQL test suite audits both schemas after each load, failing the pipeline on any red check.

---
## Tech stack

<p align="center">
  <a href="https://www.mongodb.com/"><img src="https://img.shields.io/badge/MongoDB-47A248?style=for-the-badge&logo=mongodb&logoColor=white" alt="MongoDB"></a>
  <a href="https://www.postgresql.org/"><img src="https://img.shields.io/badge/PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL"></a>
  <a href="https://www.python.org/"><img src="https://img.shields.io/badge/Python%203.13-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python 3.13"></a>
  <a href="https://pandas.pydata.org/"><img src="https://img.shields.io/badge/pandas-150458?style=for-the-badge&logo=pandas&logoColor=white" alt="pandas"></a>
  <a href="https://www.sqlalchemy.org/"><img src="https://img.shields.io/badge/SQLAlchemy-D71F00?style=for-the-badge&logo=sqlalchemy&logoColor=white" alt="SQLAlchemy"></a>
</p>

<p align="center">
  <a href="https://docs.astral.sh/uv/"><img src="https://img.shields.io/badge/uv-DE5FE9?style=for-the-badge&logo=uv&logoColor=white" alt="uv"></a>
  <a href="https://pymongo.readthedocs.io/"><img src="https://img.shields.io/badge/PyMongo-499E34?style=for-the-badge&logo=pymongo&logoColor=white" alt="PyMongo"></a>
  <a href="https://github.com/Textualize/rich"><img src="https://img.shields.io/badge/Rich-3D4451?style=for-the-badge&logo=rich&logoColor=white" alt="Rich"></a>
  <a href="https://docs.astral.sh/ruff/"><img src="https://img.shields.io/badge/ruff-261230?style=for-the-badge&logo=ruff&logoColor=FCC24B" alt="ruff"></a>
  <a href="https://docs.pytest.org/"><img src="https://img.shields.io/badge/pytest-0A9EDC?style=for-the-badge&logo=pytest&logoColor=white" alt="pytest"></a>
  <a href="https://github.com/features/actions"><img src="https://img.shields.io/badge/GitHub%20Actions-2088FF?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions"></a>
  <a href="https://www.gnu.org/software/bash/"><img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash"></a>
  <a href="https://learn.microsoft.com/powershell/"><img src="https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="PowerShell"></a>
</p>

## How it flows

```mermaid
flowchart LR
    M[("MongoDB")] -->|"pg_staging.py<br/>incremental upsert"| S[("staging<br/>17 tables")]
    S -->|"run_models.py<br/>dims then facts"| C[("core<br/>5 dims · 5 facts")]
    C -->|"run_data_quality_loops.py --strict"| Q{{"DQ loops<br/>read only"}}
    Q -->|"all pass"| GX{{"gx_run.py --strict<br/>Great Expectations"}}
    GX -->|"all pass"| G["✓ green run"]
    GX -->|"any fail"| F["✗ exit 1"]
    Q -->|"any fail"| F
    C --> A["sql/analytics<br/>KPI queries"]

    subgraph OPSBOX ["ops — read only, never writes"]
        H["health_check.sh"]
        SC["security_check.sh"]
        L["monitor_logs.sh"]
    end

    S -.-> H
    C -.-> H
    C -.-> SC
    C -.-> L

    classDef source fill:#47A248,stroke:#2d6e2e,color:#fff
    classDef stage fill:#B7791F,stroke:#8a5a13,color:#fff
    classDef core fill:#336791,stroke:#24486b,color:#fff
    classDef dq fill:#D6336C,stroke:#a32653,color:#fff
    classDef ok fill:#22863A,stroke:#176f2c,color:#fff
    classDef bad fill:#CB2431,stroke:#9d1c26,color:#fff
    classDef ops fill:#6E7681,stroke:#586069,color:#fff

    class M source
    class S stage
    class C,A core
    class Q,GX dq
    class G ok
    class F bad
    class H,SC,L ops
```

`make pipeline` runs the staging → models → quality → GX chain in one command.
The ops scripts verify and maintain the result without ever writing to it.

```Bash
make setup-dev          # uv sync + .env scaffold + health check (one time)
make config             # confirm resolved variables
make pipeline           # staging load -> models -> data quality -> GX
make install            # install/sync all project dependencies via uv
make check-env          # Verify a .env file exists before running anything DB-related
make lint               # Run ruff checks over the codebase (no changes made)
make lint-fix           # Run ruff checks and auto-fix what it safely can
make format-check       # Check formatting with ruff without changing files
make staging            # Load every Mongo collection into staging
make models             # Run every model in sequence, in dependency order
make quality            # Run the read only data quality SQL loops
make gx                 # Run the Great Expectations suites (all, or one by name)
make analytics          # SQL analytics queries
make health-check       # Verify tools, env, DBs, logs, and venv.
make clean              # Remove Python cache artifacts (safe — no data or log deletion)
```
**Note** Explore the available make commands yourself. Run `make help` or inspect the Makefile to discover additional commands and understand what each one does.

## Repo structure

```
Data-Modelling/
├── models/                  # dimension + fact load SQL (run by run_models.py)
├── scripts/
│   ├── python/              # pipeline: pg_staging, run_models, quality, gx, main
│   ├── bash/                # ops: health, security, logs, setup, pipeline
│   └── powershell/          # Windows equivalents, kept in lockstep
├── sql/
│   ├── 00_create_database_and_schemas.sql   # bootstrap (manual, not CI)
│   ├── 09_fn_customer_function.sql          # helper functions
│   ├── 10_fn_products_function.sql
│   └── analytics/           # ad hoc KPI queries (read only, via make analytics)
├── tests/
│   ├── python/unit/         # pytest unit tests for utils/
│   └── sql/data_quality/    # the five read only DQ loops
├── gx/                      # Great Expectations suites (run by gx_run.py)
├── docs/                    # reference docs (catalog, ERD, runbook, decisions)
├── utils/                   # shared Python: engine, connection, logger
├── assets/                  # logo and diagrams
└── Makefile                 # thin wrappers, no logic
```

## Requirements

- [`uv`](https://github.com/astral-sh/uv)
- `bash`
- `psql` (for `make analytics` and `make health-check`)
- `mongosh` (for `make health-check`)
- A `.env` file at the project root (copy `.env.example` and fill it in)

> **Windows:** run everything from inside WSL — the Makefile shells out
> to `bash`, and all `scripts/*.sh` need a real POSIX shell, not
> PowerShell/cmd.exe. The `.ps1` equivalents work natively.

## Docs

| Doc | What's in it |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The pipeline end to end, with a diagram, stage by stage explanation, shared conventions, and directory layout. |
| [`scripts.md`](docs/scripts.md) | Per-script reference — usage, flags, where each one logs to. |
| [`data_catlog.md`](docs/data_catlog.md) | Data Catlog of dim and fact tables. |
| [`ERD.md`](docs/ERD.md) | A visual flowchart that maps out how data objects, or entities, relate to each other within a database system. |
| [`TESTS.md`](docs/TESTS.md) | SQL data-quality loop reference (runs from `tests/sql/data_quality/`). |
| [`OPERATIONS.md`](docs/OPERATIONS.md) | Runbook — running the pipeline, daily checks, logs, what to do when a run fails, cron. |
| [`TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom → cause → fix for setup, pipeline, and CI problems. |
| [`DECISIONS.md`](docs/DECISIONS.md) | Decision log — settled design decisions and open items awaiting a data owner. |
| [`GIT_WORKFLOW.md`](docs/GIT_WORKFLOW.md) | Git workflow guide — branching, Conventional Commits, production repo files, hooks, releases. |

