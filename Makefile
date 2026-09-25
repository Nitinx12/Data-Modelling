# =====================================================================
# Makefile — warehouse pipeline orchestration (production grade)
# =====================================================================
# One-command entry points for local dev, CI, and Docker:
#
#   make pipeline              staging → models → quality → GX (via deps, recommended)
#   make pipeline-main         same via scripts/python/main.py (explicit orchestrator)
#   make compose-up            one-command Docker demo (postgres:16 + mongo:7 + pipeline)
#   make dashboard             streamlit on core (requires POSTGRES_* / secrets.toml)
#   make dagster-dev           Dagster UI on :3000 (asset DAG, dims before facts)
#
# Run `make help` (or just `make`) to list every target.
#
# Requires: uv (https://github.com/astral-sh/uv), bash, psql (analytics/health),
#   mongosh (health), docker (compose demo), streamlit (dashboard/)
# On Windows, run from WSL — Makefile shells to bash, *.sh need POSIX shell.
# =====================================================================

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

# ---------------------------------------------------------------------
# Config — override on CLI, e.g. make staging-one COLLECTION=Address
# ---------------------------------------------------------------------
UV              ?= uv
PY              := $(UV) run
PIP             := $(UV) pip
SCRIPTS_DIR     := scripts
MODELS_DIR      := models
SQL_DIR         := sql
ANALYTICS_DIR   := $(SQL_DIR)/analytics
LOG_DIR         := logs
LINT_PATHS      ?= .
COMPOSE         ?= docker compose
DASHBOARD_DIR   := dashboard

COLLECTION      ?=
MODELS          ?=
SUITE           ?=
MAX_AGE_DAYS    ?= 7
MAX_SIZE_MB     ?= 5
DATABASE_URL    ?=

# Export for sub-processes (psql, mongosh, python)
export PYTHONUTF8 ?= 1
export UV

# ---------------------------------------------------------------------
# Phony — every target that is not a file
# ---------------------------------------------------------------------
.PHONY: help config install check-env \
        staging staging-one \
        models models-only models-continue \
        quality dq gx analytics \
        test test-cov \
        lint lint-fix format format-check \
        logs-summary logs-clean-dry logs-clean logs-clean-force \
        health-check health-check-deep \
        security-check security-check-shellcheck \
        setup-dev \
        pipeline pipeline-continue pipeline-main pipeline-main-continue \
        pipeline-dagster \
        compose-up compose-down compose-logs compose-ps compose-build compose-clean \
        dashboard dashboard-install dagster-dev \
        clean distclean

# =====================================================================
# help — self-documenting (default)
# =====================================================================
help: ## Show this help
	@echo "Warehouse pipeline — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z0-9._/-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    sort | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make pipeline                        # local: staging → models → quality → GX"
	@echo "  make compose-up                      # docker: one-command demo (seeded DBs)"
	@echo "  make dashboard                       # streamlit on core (needs DB creds)"

config: ## Print resolved variables
	@echo "UV              = $(UV)"
	@echo "PY              = $(PY)"
	@echo "COMPOSE         = $(COMPOSE)"
	@echo "SCRIPTS_DIR     = $(SCRIPTS_DIR)"
	@echo "MODELS_DIR      = $(MODELS_DIR)"
	@echo "SQL_DIR         = $(SQL_DIR)"
	@echo "ANALYTICS_DIR   = $(ANALYTICS_DIR)"
	@echo "DASHBOARD_DIR   = $(DASHBOARD_DIR)"
	@echo "LINT_PATHS      = $(LINT_PATHS)"
	@echo "MAX_AGE_DAYS    = $(MAX_AGE_DAYS)"
	@echo "MAX_SIZE_MB     = $(MAX_SIZE_MB)"
	@echo "DATABASE_URL    = $(if $(DATABASE_URL),(set),(not set))"
	@echo "PYTHONUTF8      = $(PYTHONUTF8)"

# =====================================================================
# Setup
# =====================================================================
install: ## Sync all deps via uv (frozen, dev group for pipeline+GX+dagster)
	$(UV) sync --group dev --frozen

install-all: ## Sync + install dashboard extra (if needed)
	$(UV) sync --group dev --frozen
	$(UV) pip install -r $(DASHBOARD_DIR)/requirements.txt || true

check-env: ## Verify .env exists before DB-related targets
	@test -f .env || (echo "Missing .env — copy .env.example and fill it in." && exit 1)

# =====================================================================
# Tests & quality (no DB)
# =====================================================================
test: ## Pytest unit tests (mocked, no DB)
	$(PY) -m pytest tests/python/unit -v

test-cov: ## Pytest with coverage
	$(PY) -m pytest --cov=utils --cov-report=term-missing --cov-report=html:htmlcov tests/python/unit

lint: ## Ruff lint (no fix)
	$(PY) ruff check $(LINT_PATHS)

lint-fix: ## Ruff lint + auto-fix
	$(PY) ruff check --fix $(LINT_PATHS)

format: ## Ruff format (write)
	$(PY) ruff format $(LINT_PATHS)

format-check: ## Ruff format --check (CI)
	$(PY) ruff format --check $(LINT_PATHS)

# =====================================================================
# Staging (Mongo → Postgres)
# =====================================================================
staging: check-env ## Load every Mongo collection into staging (incremental, validated)
	$(PY) $(SCRIPTS_DIR)/python/pg_staging.py

staging-one: check-env ## Load one collection — COLLECTION=Address
	@test -n "$(COLLECTION)" || (echo 'Usage: make staging-one COLLECTION=<name>' && exit 1)
	$(PY) $(SCRIPTS_DIR)/python/pg_staging.py --collection $(COLLECTION)

# =====================================================================
# Models (core dims/facts, SCD2 dim_customers)
# =====================================================================
models: check-env ## Run all models in MODEL_SEQUENCE (dims before facts)
	$(PY) $(SCRIPTS_DIR)/python/run_models.py

models-only: check-env ## Run specific models — MODELS="fact_orders.sql ..."
	@test -n "$(MODELS)" || (echo 'Usage: make models-only MODELS="..."' && exit 1)
	$(PY) $(SCRIPTS_DIR)/python/run_models.py --only $(MODELS)

models-continue: check-env ## Run all models, continue past failures
	$(PY) $(SCRIPTS_DIR)/python/run_models.py --continue-on-error

# =====================================================================
# Data quality (read-only, --strict fails pipeline)
# =====================================================================
quality: check-env ## SQL loops (5) — read-only, catalog-driven
	$(PY) $(SCRIPTS_DIR)/python/run_data_quality_loops.py

dq: quality ## Alias for quality

quality-strict: check-env ## SQL loops with --strict (CI)
	$(PY) $(SCRIPTS_DIR)/python/run_data_quality_loops.py --strict

gx: check-env ## Great Expectations suites (all or SUITE=name)
	$(PY) $(SCRIPTS_DIR)/python/gx_run.py $(if $(SUITE),--suite $(SUITE),)

gx-strict: check-env ## GX with --strict (CI)
	$(PY) $(SCRIPTS_DIR)/python/gx_run.py --strict $(if $(SUITE),--suite $(SUITE),)

# =====================================================================
# Analytics (psql, via DATABASE_URL or .env)
# =====================================================================
analytics: check-env ## Apply sql/analytics/*.sql via psql (skips the 00_ bootstrap)
	@if [ -z "$(DATABASE_URL)" ]; then \
		if [ -f .env ]; then set -a; . <(tr -d '\r' < .env); set +a; fi; \
		if [ -n "$$POSTGRES_HOST" ] && [ -n "$$POSTGRES_DATABASE" ] && [ -n "$$POSTGRES_USERNAME" ]; then \
			url="postgresql://$$POSTGRES_USERNAME:$$POSTGRES_PASSWORD@$$POSTGRES_HOST:$${POSTGRES_PORT:-5432}/$$POSTGRES_DATABASE"; \
		else echo 'Set DATABASE_URL or POSTGRES_* in .env' && exit 1; fi; \
	else url="$(DATABASE_URL)"; fi; \
	if [ ! -d "$(ANALYTICS_DIR)" ]; then echo "No such dir: $(ANALYTICS_DIR)" && exit 1; fi; \
	for f in $(ANALYTICS_DIR)/*.sql; do \
		[ -e "$$f" ] || continue; \
		if [[ "$$f" == */00_* ]]; then echo "  (bootstrap skipped) $$f"; continue; fi; \
		echo ""; echo "==================== $$f ===================="; \
		PAGER=cat psql "$$url" -v ON_ERROR_STOP=1 --pset border=2 --pset pager=off -f "$$f" || exit 1; \
	done

# =====================================================================
# Docker Compose — one-command demo + pipeline inside Docker
# =====================================================================
compose-up: ## Docker: postgres:16 + mongo:7 + pipeline (seeded, healthchecked)
	$(COMPOSE) up --build -d postgres mongo
	@echo "Waiting for DBs healthy (postgres 5433, mongo 27018 on host)..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
		$(COMPOSE) ps | grep -q "(healthy)" && break; sleep 3; done
	$(COMPOSE) ps

compose-build: ## Docker: build pipeline image (dagster+streamlit)
	$(COMPOSE) build pipeline

compose-logs: ## Docker: follow pipeline logs
	$(COMPOSE) logs -f pipeline

compose-ps: ## Docker: list services
	$(COMPOSE) ps

compose-down: ## Docker: stop (keep volumes)
	$(COMPOSE) down

compose-clean: ## Docker: stop and wipe volumes (fresh seed on next up)
	$(COMPOSE) down -v

compose-pipeline: ## Docker: run pipeline inside container (make pipeline)
	$(COMPOSE) run --rm pipeline

compose-sh: ## Docker: shell in pipeline container
	$(COMPOSE) run --rm pipeline bash

# =====================================================================
# Dashboard & Dagster
# =====================================================================
dashboard-install: ## Install dashboard deps (streamlit)
	$(PIP) install -r $(DASHBOARD_DIR)/requirements.txt

dashboard: ## Run Streamlit dashboard on core (needs DB creds/secrets.toml)
	$(PY) streamlit run $(DASHBOARD_DIR)/Home.py

dagster-dev: ## Run Dagster UI on :3000 (asset DAG)
	$(PY) dagster dev -m orchestration.definitions --host 0.0.0.0 --port 3000

dagster-job: ## Run Dagster full_pipeline job headless
	$(PY) dagster job execute -m orchestration.definitions --job full_pipeline

# =====================================================================
# Logs, health, security, setup
# =====================================================================
logs-summary: ## Read-only log summary
	$(SCRIPTS_DIR)/bash/monitor_logs.sh summary

logs-clean-dry: ## Preview log cleanup (dry-run)
	MAX_AGE_DAYS=$(MAX_AGE_DAYS) MAX_SIZE_MB=$(MAX_SIZE_MB) $(SCRIPTS_DIR)/bash/monitor_logs.sh clean --dry-run

logs-clean: ## Delete flagged logs (interactive)
	MAX_AGE_DAYS=$(MAX_AGE_DAYS) MAX_SIZE_MB=$(MAX_SIZE_MB) $(SCRIPTS_DIR)/bash/monitor_logs.sh clean

logs-clean-force: ## Delete flagged logs without confirmation (CI)
	MAX_AGE_DAYS=$(MAX_AGE_DAYS) MAX_SIZE_MB=$(MAX_SIZE_MB) $(SCRIPTS_DIR)/bash/monitor_logs.sh clean -y

health-check: ## Verify CLIs, Python, Postgres, Mongo
	$(SCRIPTS_DIR)/bash/health_check.sh

health-check-deep: ## health_check + row counts (core/staging)
	$(SCRIPTS_DIR)/bash/health_check.sh --deep

security-check: ## Surface secrets, .env mistakes
	$(SCRIPTS_DIR)/bash/security_check.sh

security-check-shellcheck: ## security_check + shellcheck
	$(SCRIPTS_DIR)/bash/security_check.sh --shellcheck

setup-dev: ## uv sync + .env scaffold + health check
	$(SCRIPTS_DIR)/bash/setup_dev.sh

# =====================================================================
# Full pipeline (local)
# =====================================================================
pipeline: staging models quality gx ## Local: staging → models → quality → GX (deps, recommended)
	@echo "Pipeline complete."

pipeline-continue: staging models-continue quality gx ## Local pipeline, continue past model failures
	@echo "Pipeline complete (continue-on-error)."

pipeline-main: ## Via main.py (explicit orchestrator, stops on first failure)
	$(PY) $(SCRIPTS_DIR)/python/main.py

pipeline-main-continue: ## Via main.py --continue-on-error
	$(PY) $(SCRIPTS_DIR)/python/main.py --continue-on-error

pipeline-dagster: ## Via Dagster headless job (asset DAG)
	$(PY) dagster job execute -m orchestration.definitions --job full_pipeline

# =====================================================================
# Housekeeping
# =====================================================================
clean: ## Remove Python cache (safe)
	find . -path ./.venv -prune -o -type d -name "__pycache__" -print -exec rm -rf {} + 2>/dev/null || true
	find . -path ./.venv -prune -o -type d -name ".pytest_cache" -print -exec rm -rf {} + 2>/dev/null || true
	find . -path ./.venv -prune -o -type f -name "*.pyc" -exec rm -f {} + 2>/dev/null || true

distclean: clean logs-clean-force compose-clean ## clean + logs + docker volumes
	@echo "Deep clean complete."
