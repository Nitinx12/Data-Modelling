# Contributing

Thanks for contributing to the Data Modelling warehouse.

## Getting started

1. Clone the repo and install dependencies with uv (the only supported
   package manager here):

   ```bash
   uv sync
   ```

2. Copy `.env.example` to `.env` and fill in the required values (PostgreSQL
   and MongoDB connection details). Never commit `.env` — run
   `./scripts/bash/security_check.sh` if you want to verify.

3. Verify your setup:

   ```bash
   make health          # POSIX shell or WSL
   # or on Windows, without make:
   ./scripts/powershell/health_check.ps1
   ```

4. Optional but recommended: install the pre-commit hooks so lint and secret
   detection run before every commit:

   ```bash
   uv tool install pre-commit
   pre-commit install
   ```

## Workflow

1. Branch from `main` using `feature/`, `fix/`, `docs/`, or `chore/` prefixes
   (see `docs/GIT_WORKFLOW.md` §1).
2. Make your change. Read the relevant reference doc before editing the
   matching part of the codebase — `Schema.md`, `ERD.md`, `data_catlog.md`,
   `scripts.md`, `SQL.md`, `TESTS.md` each document constraints that are not
   obvious from the code.
3. Run the checks that apply:
   - `make test` — unit tests (no database needed)
   - `make quality` — data quality loops (needs a loaded warehouse)
   - `make lint` — ruff
4. Add an entry under `[Unreleased]` in `docs/CHANGELOG.md`. Every change
   gets a line, however small.
5. Commit with a Conventional Commits message, e.g.
   `fix(models): handle NULL customer_name in fact_orders`.
6. Push and open a pull request against `main`. Fill in the PR template.
7. Delete your branch after merge.

## Conventions

The full list lives in `CLAUDE.md`; the ones that matter most day to day:

- **uv only** — no bare `pip install`, no hand edited `requirements.txt`.
- **Data quality scripts are read only** — anything under
  `tests/sql/data_quality/` must never contain `INSERT`, `UPDATE`, `DELETE`,
  or DDL.
- **Catalog driven, not hardcoded** — the five PL/pgSQL loops discover
  tables and columns from `information_schema`; keep them that way.
- **Known issues are intentional** — the list in `CLAUDE.md` documents
  inconsistencies that look like bugs but are tracked as open items. Do not
  fix them as a side effect of an unrelated change; flag them instead.
- **No hyphens in prose** in markdown files — write "read only", not
  "read-only". Code identifiers are unaffected.

## Windows contributors

The Makefile targets wrap bash scripts and expect a POSIX shell (WSL works).
Without `make`, use the PowerShell equivalents under `scripts/powershell/`
and run Python entry points directly, e.g.
`uv run scripts/python/run_models.py`.
