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