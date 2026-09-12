# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project does not currently follow a formal version-numbering scheme — entries are
grouped under `[Unreleased]` until a release is explicitly cut.

**Every change made by Claude to this repository must be logged here** — see the
"Changelog Requirement" section in `CLAUDE.md` for the exact rule. Add new lines under
`[Unreleased]`; don't edit past entries.

## [Unreleased]

### Added
- `docs/GIT_WORKFLOW.md`: git workflow guide adapted to this repo (branching, Conventional Commits, hooks, releases), with deliberate omissions recorded (semantic-release, VERSION file, commitlint, sqlfluff hook).
- Production repo files: `.env.example` (mirrors `utils/engine.py` variables), `.gitattributes` (LF normalization), `.github/CODEOWNERS`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/` (bug report, feature request), `CONTRIBUTING.md`, `SECURITY.md`, `.pre-commit-config.yaml` (ruff + pre-commit hooks).
- README docs table rows for `CI_CD.md` and `GIT_WORKFLOW.md`; fixed stale `tests/data_quality/` path in the `TESTS.md` row.
- `docs/CI_CD.md`: production readiness and CI/CD roadmap, verified against the repository on 2026-09-12, covering the data quality `--strict` gate, CI integration/security/GX jobs, CI source seeding, and a prioritized plan.
- PowerShell equivalents for all Bash ops scripts (`health_check.ps1`, `security_check.ps1`, `monitor_logs.ps1`, `setup_dev.ps1`) for cross-platform support.
- `scripts/bash/pipeline.sh` as a lightweight wrapper for the main pipeline.
- `scripts/bash/db_reset.sh` for rapid environment teardown and rebuild.
- `make gx` target in Makefile to execute Great Expectations suites.
- `make test` and `make test-cov` targets for Python unit tests.

### Changed
- Removed hyphens from prose in all project markdown files to match project conventions.
- Updated `dim_customers` and `dim_products` load scripts to no longer silently exclude rows with missing timestamps or zero prices.
- Standardized dimension joins in `fact_orders` and `fact_inventory` to use business IDs (natural keys) instead of names.
- Extended `fact_inventory` unpivot logic to cover 2026 monthly columns.
- Updated documentation in `Schema.md` and `data_catlog.md` to reflect these changes.
- Reorganized `scripts/` directory into `python/`, `bash/`, and `powershell/` subdirectories.
- Reorganized `tests/` directory into `sql/data_quality/` and `python/unit/`.
- Updated `Makefile`, `docs/scripts.md`, and `CLAUDE.md` to reflect new script and test paths.

### Fixed
- `docs/CI_CD.md` §2: corrected the row claiming `08_data_quality_checks.sql` does not exist (it lives at `sql/analytics/` as an analyst ad hoc query; the actionable point about new pipeline checks going to `tests/sql/data_quality/` stands), and updated the "claims that checked out" note since the DQ suite can now fail a build via `--strict`.
- Sorted/formatted the import block in `scripts/python/check_cols.py` (two `I001` ruff findings); `make lint` / `ruff check` is now clean on the whole repo.
- Colourised the summary line in `health_check.sh` and `security_check.sh`: the counts were printed through `%s`, which doesn't interpret backslash escapes, so the raw `\033[...m` codes appeared literally in the output; switched to `%b` (the PowerShell equivalents already colour correctly).
- `security_check.sh` / `security_check.ps1` DSN scan no longer false-positives: the regex now excludes `$` (and whitespace) from the user/password character classes so placeholder DSNs built from environment variables (`postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@...`) don't match, and the scanner scripts themselves are excluded since their own pattern lines contain the literal text being searched. Verified both directions: a real embedded DSN still fails the check (exit 1), a `${VAR}` template passes.
- Guarded the `fact_order_process` accumulating snapshot UPSERT so a NULL from the source can no longer overwrite a previously-loaded milestone: each of customer_key, ship_mode, invoice_id, ship/delivery/invoice/pay date is now `COALESCE(EXCLUDED.x, existing.x)`, lag columns are recomputed from the guarded dates (amount stays a plain overwrite — it's a measure, not a milestone), and the update WHERE now also covers customer_key/ship_mode/invoice_id, which were updated but never guarded, so changes to those alone were silently skipped. The quarantine self-heal for previously-loaded future dates had to become explicit UPDATE statements, since the guarded UPSERT no longer nulls those on its own. Verified: model rerun PASS, DQ gate green, no milestone lost (73 orders: 67 shipped, 59 delivered, 59 invoiced, 49 paid; every non-null milestone has its lag populated).
- Added `NULLS LAST` to the `update_at DESC` dedup rankings in `dim_customers`, `dim_campaign`, `dim_geo`, `fact_campaign_spend`, and `fact_inventory` — Postgres sorts NULLs first on DESC, so a row with a missing timestamp was winning the dedup, the opposite of what the docs claim (`dim_products` and `fact_orders` already had it; the fix was applied inconsistently). Verified: all five models re-run clean and the DQ gate stays green.
- `sql/analytics/08_data_quality_checks.sql` referenced `fact_order_process.customer_id`, a column removed when the table migrated to `customer_key`; the query errored out. Updated to `customer_key` (verified executing against the live warehouse) and fixed the stale `customer_id` verification comment in `fact_order_process.sql`.
- Ops scripts resolved the project root one directory short since the `scripts/` reorganization (`health_check.sh`, `security_check.sh`, `monitor_logs.sh`, `setup_dev.sh` plus PowerShell `health_check.ps1`, `setup_dev.ps1`), so health/security checks silently scanned `scripts/` instead of the repo root; now resolve two levels up from `scripts/bash|powershell/`.
- Data quality failures now fail the pipeline: `run_data_quality_loops.py` gains a `--strict` flag (exit 1 when any check fails; default stays report only) and `main.py` passes `--strict` to the quality stage, so cron/CI sees a non-zero exit on red data instead of a green run. Verified end to end with a deliberately failing check.
- Corrected stale test paths: `.github/workflows/ci.yml` pytest steps and `pyproject.toml` `testpaths` pointed at `tests/unit`, which no longer exists after the `tests/` reorganization; updated both to `tests/python/unit`.
- Fixed surrogate key inconsistency in `fact_order_process` by switching from `customer_id` (natural) to `customer_key` (surrogate).
- Fixed duplicate risk on NULL foreign keys in `fact_less_fact` by replacing `ON CONFLICT` with a `WHERE NOT EXISTS` check.
- Fixed `fact_order_process` `CREATE TABLE IF NOT EXISTS` not picking up the new `customer_key` column when the table already existed from a prior run; added a `DROP TABLE IF EXISTS core.fact_order_process CASCADE;` at the top of the DDL block so the table is rebuilt with the current schema.
- Fixed `fact_orders` staging SELECT lists that omitted `CustomerID`; switched the customer join to use `C.customer_name = O."CustomerName"` to match the actual columns in `staging.orders_2025` / `staging.orders_2026` (the staging tables only carry `CustomerName`, no `CustomerID`).
- Fixed `fact_orders` product join referencing `OI."ProductCode"` (column does not exist on `staging.order_line_items`); changed to `P.product_name = OI."ProductName"` so the join resolves against the real staging schema.
- Fixed `run_models.py` `BASE_DIR` path from `parents[1]` to `parents[2]` to account for the `scripts/` → `scripts/python/` reorganization; updated the inline comment accordingly.
- Updated `ARCHITECTURE.md` directory layout to reflect the current `scripts/python/`, `scripts/bash/`, `scripts/powershell/`, `tests/sql/data_quality/`, and `tests/python/unit/` structure.

---

<!--
Template for a new entry:

## [Unreleased]

### Added
- Short description of what was added and why.

### Changed
- Short description of what changed and why.

### Fixed
- Short description of the bug and the fix.

### Removed
- Short description of what was removed and why.
-->