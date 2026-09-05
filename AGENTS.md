# AGENTS.md

## Project purpose

This repository builds a PostgreSQL warehouse from MongoDB-backed staging
tables. The warehouse uses the `staging` schema for source-shaped data and the
`core` schema for SCD Type 1 dimensions and fact tables.

## Repository layout

- `models/`: executable PostgreSQL dimension and fact load scripts. Run all
  dimensions before their dependent facts.
- `tests/unit/`: pytest unit tests for `utils/` modules (engine, connection, logger).
- `tests/data_quality/`: executable PostgreSQL data-quality SQL. Five focused
  dynamic `DO` loops run after every warehouse load in numeric order.
- `gx/`: Great Expectations suite — YAML expectation suites and a runner script.
- `sql/`: database and schema bootstrap scripts.
- `scripts/`: ingestion and operational scripts.
- `docs/`: data catalog, schema, and ERD. Update these when the warehouse
  grain, keys, or business rules change.
- `utils/`: shared Python configuration, connections, and logging.
- `main.py`: one-shot pipeline orchestrator — runs `pg_staging.py` →
  `run_models.py` → `run_data_quality_loops.py` in sequence.

## SQL conventions

- Target PostgreSQL explicitly with schema-qualified object names
  (`staging.customer_contach`, `core.dim_customer`, never a bare table name).
- Preserve source names exactly, including existing staging typos such as
  `campaing_logs`, `campaing_sku`, `customer_contach`, and `addres`.
  (Do not "correct" these — downstream code depends on the exact spelling.)
- Keep each model idempotent: dimensions/facts use their declared business-key
  `ON CONFLICT` rules, and data-quality scripts can be rerun without changing
  warehouse data.
- Retain the documented grain of every fact table. Do not add joins that can
  multiply fact rows.
- Treat unresolved dimension keys, invalid measures, and impossible milestone
  dates as data-quality failures; do not silently hide them in tests.

### SQL formatting

- Keywords in UPPERCASE (`SELECT`, `FROM`, `WHERE`, `JOIN`, `ON`, `GROUP BY`,
  `ORDER BY`); identifiers in `snake_case`.
- One column per line once a `SELECT` list has more than 2-3 columns; align
  commas at the start of the line so a diff shows exactly what changed:
  ```sql
  SELECT
      c.customer_id
      , c.first_name
      , c.last_name
      , o.order_total
  FROM core.dim_customer AS c
  JOIN core.fct_orders AS o
      ON o.customer_id = c.customer_id
  WHERE o.order_total > 0
  ```
- 4-space indentation; indent `ON`, `AND`, `OR` conditions one level under
  their `JOIN`/`WHERE` so multi-line conditions stay scannable.
- Always alias joined tables with short, meaningful aliases (`c`, `o`, not
  `x`, `t1`) and qualify every column reference once more than one table is
  in scope.
- Never `SELECT *` in models or tests — list columns explicitly so schema
  drift is visible in the diff.
- Prefer a `WITH` CTE per logical step over deeply nested subqueries; name
  each CTE for what it produces (`WITH recent_orders AS (...)`).

## Data-quality checks

- Run the five SQL loops in `tests/data_quality/` in numeric order after
  loading the warehouse. Each uses a read-only `DO` loop over the `core` and
  `staging` schemas and reports aggregate counts with `RAISE NOTICE`.
- A non-zero reported count is a failed check; scripts should report counts,
  not sample business data.
- Keep checks read-only against `staging` and `core`. Do not create a test,
  audit, or results schema/table from test scripts.
- Do not create stored procedures, a master/orchestrator procedure, or a
  test/audit/results table for data-quality checks.

## Code style — Python, Bash, PowerShell

Assuming `ruff` as the Python formatter/linter since `uv` is already the
package manager here — swap this line if the repo standardizes on `black`
or something else instead.

**Python** (`utils/`, `scripts/`)
- Follow PEP 8; format and lint with `uv run ruff format` / `uv run ruff check`.
- 4-space indentation, `snake_case` for functions/variables, `PascalCase` for
  classes, `UPPER_SNAKE_CASE` for module-level constants.
- Type hints on all function signatures; docstrings on every public function
  in `utils/`.
- No bare `except:` — catch specific exceptions and log via the shared
  `utils` logger rather than `print`.

**Bash** (`scripts/`)
- `#!/usr/bin/env bash` shebang, and `set -euo pipefail` right after it.
- Quote every variable expansion (`"$var"`, `"${arr[@]}"`); prefer `[[ ]]`
  over `[ ]` for conditionals.
- `snake_case` for function names and local variables, `UPPER_SNAKE_CASE`
  for exported/env constants.
- Keep scripts `shellcheck`-clean before committing.

**PowerShell** (`scripts/`)
- Use approved verbs for functions (`Get-`, `New-`, `Set-`, `Invoke-`, ...);
  `PascalCase` for function and parameter names.
- `[CmdletBinding()]` plus a typed `param()` block for anything more than a
  one-liner.
- Prefer `Write-Output` / `Write-Error` / `Write-Verbose` over `Write-Host`
  so output stays pipeline- and log-friendly.
- Wrap operations that can fail in `try/catch` with `-ErrorAction Stop` on
  the risky cmdlet.

## Local verification

- Use `uv run` for Python entry points.
- Before changing model SQL, read the affected model and the corresponding
  sections of `docs/data_catlog.md` and `docs/ERD.md`.
  (Note: the file is named `data_catlog.md`, matching the existing typo —
  don't rename it.)
- Do not print or commit `.env` credentials. Database execution is optional
  only when the local PostgreSQL service and configured schemas are available.

## Commit & PR conventions

- Use [Conventional Commits](https://www.conventionalcommits.org/) style
  messages, e.g. `fix(models): correct fct_orders grain`,
  `feat(tests): add null-check for dim_customer`, `docs(erd): update fct_sales grain`.
- Keep commits scoped to one model, test, or doc change — don't mix schema
  changes with unrelated refactors.
- Run the affected model(s) and the relevant data-quality SQL in `tests/`
  locally before committing, whenever a local Postgres instance is available.
- Never commit `.env`, credentials, or sample rows of real business/PII data
  pulled from `staging` or `core`.
- If a change alters warehouse grain, keys, or business rules, update the
  relevant file(s) in `docs/` in the same commit/PR.

## Git workflow

### Branch naming

Prefix your branch with one scope matching the Conventional Commits types:

```
feat/models/     — new dimension or fact table
feat/tests/      — new pytest suite or SQL loop
feat/gx/         — new Great Expectations suite
fix/models/      — bug in a model SQL file
fix/tests/       — broken SQL loop or pytest test
fix/scripts/     — bug in a scripts/ entry point
refactor/        — restructuring models, tests, or scripts
chore/           — tooling, CI, Makefile, deps
docs/            — documentation only
```

### Pre-commit checklist

Before pushing any branch:

```bash
# 1. Lint & format (fails the build if ruff finds issues)
make lint
make format-check

# 2. Unit tests (pytest — no DB required)
make test

# 3. Data-quality loops (requires live Postgres with populated warehouse)
make quality

# 4. Run the full pipeline end-to-end (requires MongoDB + Postgres)
make pipeline
```

All four steps should pass before opening a PR.

### Handling push rejections

If `git push` is rejected with `fetch first`, another branch (usually `main`)
has new commits. **Always rebase** — never merge main into a feature branch:

```bash
git fetch origin
git rebase origin/main
# resolve any conflicts, then:
git rebase --continue
git push --force-with-lease origin <branch-name>
```

If you have local uncommitted changes during a rebase, stash them first:

```bash
git stash
git pull --rebase origin main
git stash pop
```

### Pull request guidelines

- Open a PR against `main` rather than pushing directly.
- Keep the PR focused: one logical change per PR.
- Fill in the PR description:
  - **What** changed and **why**.
  - Any grain, key, or business-rule changes — and which `docs/` files were updated.
  - Steps to verify (e.g. `make pipeline`, `make test`, `make quality`).
- Request a review before merging if others are working on the same area.

### Merging

Use **Squash and merge** on GitHub to keep `main`'s history linear and readable.
The squash title should be a valid Conventional Commits message; edit it if needed.

### Makefile name

The file is `Makefile` (lowercase). On Windows filesystems (case-insensitive by
default) renaming `MakeFile` → `Makefile` may not be detected by git. If git
shows `MakeFile` as modified after a rename, fix the index directly:

```bash
git rm --cached MakeFile
git add Makefile
git commit --amend  # or a new chore commit
```

Do not commit both `MakeFile` and `Makefile` — they are the same file on
case-insensitive filesystems.

### Common tasks

```bash
# Check what files changed vs origin/main
git diff origin/main --stat

# See the last 3 commits on the current branch
git log --oneline -3

# Undo the last commit (keep changes staged)
git reset --soft HEAD~1

# Discard all working-tree changes to one file
git checkout -- path/to/file

# Discard all working-tree changes (dangerous)
git checkout -- .

# View a stash without applying it
git stash show -p stash@{0}
```

### Commit examples

```bash
# stage only the files for this change (avoid `git add .` on mixed changes)
git add models/fct_orders.sql docs/ERD.md

# commit with a Conventional Commits message
git commit -m "fix(models): correct fct_orders grain to one row per order line"

# push a feature branch and open a PR rather than pushing to main directly
git push origin fix/fct-orders-grain
```

Other common cases:

```bash
# new data-quality check
git commit -m "feat(tests): add null-check for dim_customer.customer_id"

# docs-only update after a schema change
git commit -m "docs(erd): document new addres column in customer_contach"

# quick fix that only touches one script
git commit -m "fix(scripts): quote path variable in load_staging.sh"
```
