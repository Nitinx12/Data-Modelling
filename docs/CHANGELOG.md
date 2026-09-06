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

### Changed
- Removed hyphens from prose in all project markdown files to match project conventions.
- Updated `dim_customers` and `dim_products` load scripts to no longer silently exclude rows with missing timestamps or zero prices.
- Standardized dimension joins in `fact_orders` and `fact_inventory` to use business IDs (natural keys) instead of names.
- Extended `fact_inventory` unpivot logic to cover 2026 monthly columns.
- Updated documentation in `Schema.md` and `data_catlog.md` to reflect these changes.

### Fixed
- Fixed surrogate key inconsistency in `fact_order_process` by switching from `customer_id` (natural) to `customer_key` (surrogate).
- Fixed duplicate risk on NULL foreign keys in `fact_less_fact` by replacing `ON CONFLICT` with a `WHERE NOT EXISTS` check.

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