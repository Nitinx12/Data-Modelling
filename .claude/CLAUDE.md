# CLAUDE.md

Instructions and context for Claude (or Claude Code) when working in this repository.

## Project Summary

A Kimball-style analytics warehouse built in PostgreSQL. Raw documents land in MongoDB,
get extracted into a `staging` schema, and are transformed into a `core` schema fact
constellation (five conformed dimensions shared across five fact tables of different
types: transaction, periodic snapshot, accumulating snapshot, and factless). A
catalog-driven PL/pgSQL test suite audits both schemas for data quality issues without
ever writing to the database.

Full reference docs live at the repo root:

| File | Contents |
|---|---|
| `Schema.md` | Architecture overview, fact/dimension patterns, ERD, known issues |
| `ERD.md` | Mermaid ER diagram, fact table types, topological load order |
| `data_catlog.md` | Column-level catalog for every table — types, business keys, source lineage, caveats |
| `scripts.md` | Every pipeline/ops script, its flags, exit codes, and log locations |
| `SQL.md` | Ad hoc analyst queries in `sql/` (read-only, not part of the pipeline) |
| `TESTS.md` | The five catalog-driven PL/pgSQL data quality loops |

Read the relevant doc above before editing the corresponding part of the codebase —
each one documents constraints and caveats that aren't obvious from the code alone.

## Architecture at a Glance

- **Dimensions (SCD Type 1):** `dim_campaign`, `dim_customers`, `dim_geo`, `dim_products`
  — overwritten in place, driven by a `source_updated_at` comparison.
- **Junk dimension:** `dim_orders_flag` — bundles `channel`, `status`, `priority`;
  insert-only (`ON CONFLICT DO NOTHING`), rows are never updated.
- **Facts:** `fact_orders` (transaction), `fact_campaign_spend` (transaction),
  `fact_inventory` (periodic snapshot), `fact_less_fact` (factless, no measures),
  `fact_order_process` (accumulating snapshot — the only fact mutated in place as an
  order moves through order → ship → deliver → invoice → pay).
- **Role-playing dimension:** `dim_geo` joins to `fact_orders` twice (`ship_geo_key`,
  `bill_geo_key`).
- **Fact constellation, not a single star:** `fact_campaign_spend` and `fact_less_fact`
  both reference `dim_campaign`/`dim_products` but are never joined to each other.
- **Load order:** all five dimensions, then all five facts (any order among each group).
  See `ERD.md` for the exact topological sequence.

## Commands

```bash
uv run scripts/python/pg_staging.py                          # Mongo -> staging, incremental via update_at
uv run scripts/python/run_models.py                  # runs models/*.sql in dependency order
uv run scripts/python/run_data_quality_loops.py      # runs tests/sql/data_quality/*_lp_*.sql, read-only
uv run scripts/python/main.py                                # staging -> models -> quality, in sequence
./scripts/bash/health_check.sh --deep                      # verify deps + row counts, read-only
./scripts/bash/security_check.sh                           # scan for leaked creds/secrets, read-only
./scripts/bash/monitor_logs.sh clean --dry-run             # preview log cleanup, deletes nothing
```

Always use `uv run` for Python scripts in this repo, not a bare `python`/`python3` call.

On a POSIX shell or WSL, the `Makefile` wraps all of the above as short targets
(`make staging`, `make models`, `make quality`, `make pipeline`, `make health`,
`make security`, `make setup`, `make logs`, `make test`) — run `make help` for the full list.
Windows contributors without `make` should keep using the commands or `.ps1`
equivalents directly.

## Conventions

- **Package manager:** `uv` exclusively — `uv sync`, `uv run <script>`.
- **Console output:** scripts use `Rich` for live status and summary tables; keep new
  scripts consistent with that style rather than plain `print`.
- **Logging:** via `utils.logger`, written under `logs/<subdir>/`; don't hand-roll a
  separate logging setup in a new script.
- **Data quality scripts are read-only by design** — they audit via `RAISE NOTICE`
  and never `CREATE`/`ALTER`/`DROP`/`UPDATE`. Preserve that invariant in any change.
- **Catalog-driven, not hardcoded:** the five PL/pgSQL loops in `tests/sql/data_quality/`
  discover tables/columns/constraints from `information_schema`/`pg_catalog` at
  runtime. Don't refactor them toward a hardcoded table list — the whole point is that
  new tables are covered automatically.

## Coding Style

**Python**
- `uv` managed environment only — no bare `pip install`, no hand edited
  `requirements.txt`.
- Console output goes through `Rich` (live status lines, summary tables at the end);
  match the existing scripts' style instead of plain `print`.
- Secrets live in `.env`, with `.env.example` kept in sync as new variables are added.
  Never hardcode a credential or a connection string.

**SQL**
- The five PL/pgSQL data quality loops stay catalog driven — read tables, columns,
  and constraints from `information_schema`/`pg_catalog`, never a hardcoded list (see
  Conventions above).
- Prefer the `::VARCHAR` style cast over `CAST(value AS VARCHAR)` in SQLFluff linted
  files.
- Anything under `tests/sql/data_quality/` stays read only. No `INSERT`, `UPDATE`,
  `DELETE`, or DDL of any kind in those files.

**Bash**
- Ops scripts (`health_check.sh`, `security_check.sh`, `monitor_logs.sh`,
  `setup_dev.sh`) share one shape, follow it for any new script: `#!/usr/bin/env bash`
  shebang, `set -euo pipefail` near the top, a `-h`/`--help` flag, and the exit code
  convention already documented in `scripts.md`: `0` all checks passed, `1` at least
  one failed, `2` usage error.
- Match the existing colour coded status output (`[ OK ]` / `[WARN]` / `[FAIL]`) for
  anything that reports pass/fail per item, instead of inventing a new format.
- Anything destructive (deleting logs, dropping data) needs a confirm prompt plus a
  `--dry-run` and a `-y`/force flag, mirroring `monitor_logs.sh clean`.

**PowerShell**
- Every Bash ops script that exists today has, or should get, a PowerShell
  equivalent for Windows, per the project's cross platform requirement noted in
  `Schema.md`/`scripts.md`. Keep the two in lockstep: same flags, same exit codes,
  same behavior, just idiomatic syntax on each side.
- Start scripts with `$ErrorActionPreference = 'Stop'` and use `try`/`catch` so
  failures surface the same way `set -euo pipefail` does in Bash, rather than
  continuing silently past an error.
- Use approved PowerShell verbs for any function (`Get`, `Test`, `Remove`, `Invoke`,
  and so on) rather than ad hoc names — `Test-DatabaseConnection`, not
  `CheckDbConn`.
- Parameters go through a `param()` block with typed values, not positional
  `$args` parsing.

**Makefile**
- A root level `Makefile` wraps the commands from the Commands section as short
  targets (`make staging`, `make models`, `make quality`, `make pipeline`,
  `make health`, `make security`, `make setup`) for anyone on a POSIX shell or WSL.
- Keep every target a thin wrapper around the existing `uv run ...` / `./*.sh`
  command — no logic lives in the Makefile itself, so the Python/Bash/PowerShell
  scripts stay the single source of truth.
- Update the Makefile in the same change whenever a wrapped script's flags or name
  change, so the two never drift apart.
- Windows contributors without `make` installed should keep using the `.ps1`
  scripts directly; the Makefile is a convenience layer, not a requirement.

**Documentation**
- No hyphens in prose in any markdown file in this repo. Code identifiers such as
  `dim_orders_flag` are unaffected — this is about prose word joins only. Write
  "read only" rather than "read-only", "catalog driven" rather than "catalog-driven",
  and so on. Note that some of this repo's existing docs predate this rule; new or
  edited prose should follow it going forward.

## Known Issues — Do Not "Fix" Without Being Asked

These are documented, intentional-for-now inconsistencies. Several look like bugs but
are tracked as open items — don't silently correct them as a side effect of an
unrelated change:

- **Mixed key strategy:** `fact_order_process.customer_id` joins to `dim_customers` on
  the **natural key**, while every other fact uses the **surrogate key**
  (`customer_key`). Both work; it's an open standardization item, not a defect to patch
  in passing.
- **Staging table/column typos** (`campaing_logs`, `campaing_sku`, `customer_contach`,
  `addres`, `cust_master`) are inherited from the source system. See the glossary in
  `data_catlog.md` §5 — do not "correct" the spelling; that would break every script
  referencing them.
- **Silent row exclusion:** `dim_products` drops rows with NULL/`<= 0` `unit_price`;
  `dim_customers` drops joined rows with a NULL `update_at` from the address table.
  Both are load-time filters, not bugs — flag them if asked to investigate unmatched
  keys, don't remove the filter unprompted.
- **`fact_inventory` is hard-coded to 2025 monthly columns** (`staging.inventory` has
  no 2026 columns yet). The `LATERAL (VALUES ...)` unpivot list needs extending when
  2026 data lands — don't assume this is stale code to delete.
- **`fact_less_fact` dedup gap:** `ON CONFLICT (campaign_key, product_key) DO NOTHING`
  doesn't catch duplicate NULL/NULL pairs (unmatched campaign or product), since SQL
  nulls are never equal to each other.

## Changelog Requirement

**Every change made to this repository — by Claude, in any session — must be recorded
in `CHANGELOG.md`.** Before ending a turn that created, edited, or deleted a file:

1. Add an entry under an `## [Unreleased]` heading at the top of `CHANGELOG.md`
   (create that heading if it isn't already there).
2. Group entries under `### Added`, `### Changed`, `### Fixed`, or `### Removed` as
   appropriate.
3. One line per change: what changed and why, not a diff. E.g.
   `- Extended fact_inventory unpivot to include 2026-01..2026-12 columns.`
4. Don't rewrite or reorder past entries — append only, oldest `[Unreleased]` entries
   move under a dated version heading only when the user explicitly cuts a release.

This applies regardless of how small the change is — a one-line SQL fix still gets a
changelog line.

## Git Workflow

Once a change and its `CHANGELOG.md` entry are both done, commit and push using this
sequence:

1. `git status` — see exactly what changed before touching the index. Confirm nothing
   unexpected (a stray log file, a `.env`, a venv artifact) shows up as modified or
   untracked.
2. `git add <files>` — stage only what's actually part of this change. Avoid a blanket
   `git add .` if the status output shows anything unrelated.
3. `git status` again — confirm the staged set matches intent before committing.
4. `git commit -m "<short, imperative summary>"` — one focused commit per logical
   change, message describing what changed and why, matching the `CHANGELOG.md` entry
   where it makes sense, e.g. `git commit -m "Extend fact_inventory unpivot for 2026
   months"`.
5. `git push` — push right after committing rather than leaving commits sitting local,
   unless told to hold off.

Never stage or commit `.env`, credentials, or anything `security_check.sh` flags. If
`git status` shows something unexpected, stop and ask rather than staging it anyway.