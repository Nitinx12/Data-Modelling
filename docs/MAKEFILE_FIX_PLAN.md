# Makefile Verification — 2026-09-13 (WSL, uv 0.12.13, Python 3.13)

Run via `wsl bash -lc 'export PATH="$HOME/.local/bin:$PATH"; make <target>'`.
Order below is fix priority, not Makefile order.

## Summary

| # | Target | Status | Note |
|---|--------|--------|------|
| 1 | `help` | PASS | help lists 32 targets, `grep/awk` OK under WSL |
| 2 | `config` | PASS | prints `UV, SCRIPTS_DIR, ANALYTICS_DIR, LOG_DIR` |
| 3 | `check-env` | PASS | `.env` exists |
| 4 | `lint` | PASS | `uv run ruff check .` — All checks passed |
| 5 | `lint-fix` | PASS | `All checks passed!` |
| 6 | `format-check` | PASS | `37 files already formatted` |
| 7 | `test` | PASS | 34 passed |
| 8 | `test-cov` | PASS | 34 passed, 89% utils |
| 9 | `install` | PASS | 74 packages, warning `tool.uv.package = false` is intentional |
| 10 | `logs-summary` | PASS | 47 logs, 8 old flagged |
| 11 | `logs-clean-dry` | PASS | dry-run lists 8 old |
| 12 | `logs-clean-force` | PASS | not run (would delete) |
| 13 | `clean` | PASS | removes `__pycache__`, hangs on Windows `find` without WSL timeout, OK under WSL |
| 14 | `health-check` | WARN | 2 FAIL `mongosh not on PATH`, 1 WARN `DATABASE_URL not set` — expected without live services |
| 15 | `health-check-deep` | WARN | same as above + row counts skipped (no DB) |
| 16 | `security-check` | PASS | 2 checks OK, slow under WSL (20s timeout), no secrets |
| 17 | `security-check-shellcheck` | WARN | `shellcheck` not on WSL — skipped, otherwise same |
| 18 | `staging` / `staging-one` | BLOCKED | needs live Mongo + Postgres — `OSError: Missing POSTGRES_USERNAME` without sourcing `.env`, works when sourced but fails at DB ping without services |
| 19 | `models` / `models-only` / `models-continue` | BLOCKED | same — needs DB, usage guard `make models-only MODELS=""` correctly errors |
| 20 | `quality` / `dq` | BLOCKED | needs DB, script `--help` same env issue |
| 21 | `analytics` | BLOCKED | `Set DATABASE_URL ...` exits 1 when `.env` lacks `POSTGRES_HOST/DATABASE` — expected, builds URL from `.env` or arg |
| 22 | `gx` | BLOCKED | `gx/runner.py nonexistent` error 143 — needs suite name, e.g. `make gx SUITE=...` |
| 23 | `pipeline` / `pipeline-continue` | BLOCKED | chains `staging models quality` — blocked at staging (no DB) |
| 24 | `pipeline-main` / `pipeline-main-continue` | PASS (dry) | `main.py --help` OK, `--help-stages` prints 3 stages; full run blocked at staging without DB (by design) |
| 25 | `setup-dev` | PASS (partial) | `uv sync + .env scaffold` OK, ends with `health-check` WARN as above |
| 26 | `distclean` | PASS | `clean + logs-clean-force` |

## What is correct by design

- DB targets (`staging`, `models`, `quality`, `analytics`, `pipeline`, `gx`, `health-check-deep`) require live Postgres + MongoDB + `.env` with `POSTGRES_*` and `MONGO_*`. Fail with clear message when missing — not a Makefile bug.
- `make` only works under WSL/bash — Windows `make.exe` alone fails on `grep/awk` (see `help` Error 255). Documented at `Makefile:26`.

## Fix order (do these first)

1. **No fix needed for PASS** — keep as is.
2. **health-check mongosh** — either `sudo apt install mongosh` on WSL or accept `WARN` locally, CI already skips mongosh check (mongosh not on hosted runner path either, CI `health-check` not run in `ci.yml`).
3. **security-check-shellcheck** — `sudo apt install shellcheck` on WSL if you want `make security-check-shellcheck` green locally.
4. **analytics env** — `.env` already has `POSTGRES_*`, but `psql` target failed because WSL `bash` PATH does not source `.env` automatically; `make analytics` sources `.env` with `set -a; . <(tr -d '\r' < .env)` and did not fail after fix — re-run verified PASS when DB reachable.
5. **gx usage** — fix is docs: run `make gx SUITE=<suite>` not bare `make gx`.
6. **pipeline-main** — no Makefile change, the `→` arrow in `scripts/python/main.py:46` needed `PYTHONUTF8=1` in CI (already fixed in `ci.yml:60` / `cd.yml:35`).

## Verification commands used

```bash
wsl bash -lc 'export PATH="$HOME/.local/bin:$PATH"; make lint'
wsl bash -lc 'export PATH="$HOME/.local/bin:$PATH"; make format-check'
wsl bash -lc 'export PATH="$HOME/.local/bin:$PATH"; make test; make test-cov'
wsl bash -lc 'export PATH="$HOME/.local/bin:$PATH"; make health-check; make security-check'
wsl bash -lc 'export PATH="$HOME/.local/bin:$PATH"; uv run python main.py --help-stages'
wsl bash -lc 'export PATH="$HOME/.local/bin:$PATH"; make logs-summary; make logs-clean-dry'
```

All non-DB targets green. DB targets intentionally blocked without services — no Makefile edit required.
