# =====================================================================
# Makefile — warehouse pipeline orchestration
# =====================================================================
# Thin wrapper around this project's scripts so the full pipeline, or
# any single stage of it, can be run with one command:
#
#   make pipeline            staging load -> models -> data quality
#   make staging             Mongo -> Postgres staging load (pg_staging.py)
#   make models               run warehouse model SQL in sequence (run_models.py)
#   make quality              run read-only data quality loops (run_data_quality_loops.py)
#   make analytics             apply analytics-schema SQL (functions/marts) via psql
#   make lint                  run ruff checks over the codebase
#   make logs-summary          read-only report of logs/ (monitor_logs.sh)
#
# Run `make help` (or just `make`) to list every target with a description.
#
# Requires: uv (https://github.com/astral-sh/uv), bash, psql (analytics target only).
# On Windows, run this from inside WSL — the Makefile shells out to bash
# and monitor_logs.sh needs a real POSIX shell, not PowerShell/cmd.exe.
# =====================================================================

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

# ---------------------------------------------------------------------
# Config — override on the command line, e.g.:
#   make staging-one COLLECTION=Address
#   make logs-clean MAX_AGE_DAYS=14 MAX_SIZE_MB=10
#   make analytics DATABASE_URL=postgresql://user:pass@host:5432/db
# ---------------------------------------------------------------------
UV              ?= uv
PY              := $(UV) run
SCRIPTS_DIR     := scripts
MODELS_DIR      := models
SQL_DIR         := sql
ANALYTICS_DIR   := $(SQL_DIR)/analytics
LOG_DIR         := logs
LINT_PATHS      ?= .

COLLECTION      ?=
MODELS          ?=
MAX_AGE_DAYS    ?= 7
MAX_SIZE_MB     ?= 5
DATABASE_URL    ?=

.PHONY: help install check-env \
        staging staging-one \
        models models-only models-continue \
        quality dq \
        analytics \
        lint lint-fix format-check \
        logs-summary logs-clean-dry logs-clean logs-clean-force \
        health-check health-check-deep \
        security-check security-check-shellcheck \
        setup-dev \
        pipeline pipeline-continue pipeline-main pipeline-main-continue \
        clean distclean config

# =====================================================================
# help — self-documenting target list (default target)
# =====================================================================
help: ## Show this help message
	@echo "Warehouse pipeline — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    sort | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

config: ## Print resolved variables (useful before running with overrides)
	@echo "UV              = $(UV)"
	@echo "SCRIPTS_DIR     = $(SCRIPTS_DIR)"
	@echo "MODELS_DIR      = $(MODELS_DIR)"
	@echo "ANALYTICS_DIR   = $(ANALYTICS_DIR)"
	@echo "LOG_DIR         = $(LOG_DIR)"
	@echo "LINT_PATHS      = $(LINT_PATHS)"
	@echo "MAX_AGE_DAYS    = $(MAX_AGE_DAYS)"
	@echo "MAX_SIZE_MB     = $(MAX_SIZE_MB)"
	@echo "DATABASE_URL    = $(if $(DATABASE_URL),(set),(not set))"

# =====================================================================
# Setup
# =====================================================================
install: ## Install/sync all project dependencies via uv
	$(UV) sync

check-env: ## Verify a .env file exists before running anything DB-related
	@test -f .env || (echo "Missing .env at project root — copy .env.example and fill it in." && exit 1)

# =====================================================================
# Code quality — ruff (lint only; this project has no test suite target,
# see `quality`/`dq` for the SQL data quality loops instead)
# =====================================================================
lint: ## Run ruff checks over the codebase (no changes made)
	$(PY) ruff check $(LINT_PATHS)

lint-fix: ## Run ruff checks and auto-fix what it safely can
	$(PY) ruff check --fix $(LINT_PATHS)

format-check: ## Check formatting with ruff without changing files
	$(PY) ruff format --check $(LINT_PATHS)

# =====================================================================
# Staging load (Mongo -> Postgres), pg_staging.py
# =====================================================================
staging: check-env ## Load every Mongo collection into staging
	$(PY) $(SCRIPTS_DIR)/pg_staging.py

staging-one: check-env ## Load a single collection — make staging-one COLLECTION=Address
	@test -n "$(COLLECTION)" || (echo 'Usage: make staging-one COLLECTION=<name>' && exit 1)
	$(PY) $(SCRIPTS_DIR)/pg_staging.py --collection $(COLLECTION)

# =====================================================================
# Warehouse models (core schema dims/facts), run_models.py
# =====================================================================
models: check-env ## Run every model in MODEL_SEQUENCE, in dependency order
	$(PY) $(SCRIPTS_DIR)/run_models.py

models-only: check-env ## Run specific models — make models-only MODELS="fact_orders.sql fact_less_fact.sql"
	@test -n "$(MODELS)" || (echo 'Usage: make models-only MODELS="model1.sql model2.sql"' && exit 1)
	$(PY) $(SCRIPTS_DIR)/run_models.py --only $(MODELS)

models-continue: check-env ## Run every model, continuing past failures instead of stopping
	$(PY) $(SCRIPTS_DIR)/run_models.py --continue-on-error

# =====================================================================
# Data quality — run_data_quality_loops.py (reads tests/data_quality/*_lp_*.sql)
# =====================================================================
quality: check-env ## Run the read-only data quality SQL loops
	$(PY) $(SCRIPTS_DIR)/run_data_quality_loops.py

dq: quality ## Alias for `quality`

# =====================================================================
# Analytics schema — dynamic functions / marts (applied via psql, not
# part of MODEL_SEQUENCE). Put those .sql files under sql/analytics/.
# =====================================================================
analytics: check-env ## Apply/run every .sql file in sql/analytics/ and print any KPI results; builds DATABASE_URL from .env if not passed explicitly
	@if [ -z "$(DATABASE_URL)" ]; then \
		if [ -f .env ]; then set -a; . <(tr -d '\r' < .env); set +a; fi; \
		if [ -n "$$POSTGRES_HOST" ] && [ -n "$$POSTGRES_DATABASE" ] && [ -n "$$POSTGRES_USERNAME" ]; then \
			url="postgresql://$$POSTGRES_USERNAME:$$POSTGRES_PASSWORD@$$POSTGRES_HOST:$${POSTGRES_PORT:-5432}/$$POSTGRES_DATABASE"; \
		else \
			echo 'Set DATABASE_URL, e.g. make analytics DATABASE_URL=postgresql://user:pass@host:5432/db'; \
			exit 1; \
		fi; \
	else \
		url="$(DATABASE_URL)"; \
	fi; \
	if [ ! -d "$(ANALYTICS_DIR)" ]; then \
		echo "No such directory: $(ANALYTICS_DIR)"; \
		exit 1; \
	fi; \
	for f in $(ANALYTICS_DIR)/*.sql; do \
		echo ""; \
		echo "==================== $$f ===================="; \
		PAGER=cat psql "$$url" -v ON_ERROR_STOP=1 --pset border=2 --pset pager=off -f "$$f" || exit 1; \
	done

# =====================================================================
# Log maintenance — monitor_logs.sh
# =====================================================================
logs-summary: ## Read-only summary report of logs/
	$(SCRIPTS_DIR)/monitor_logs.sh summary

logs-clean-dry: ## Preview what a log cleanup would delete (deletes nothing)
	MAX_AGE_DAYS=$(MAX_AGE_DAYS) MAX_SIZE_MB=$(MAX_SIZE_MB) $(SCRIPTS_DIR)/monitor_logs.sh clean --dry-run

logs-clean: ## Delete flagged logs (interactive confirmation)
	MAX_AGE_DAYS=$(MAX_AGE_DAYS) MAX_SIZE_MB=$(MAX_SIZE_MB) $(SCRIPTS_DIR)/monitor_logs.sh clean

logs-clean-force: ## Delete flagged logs without confirmation (CI/cron use)
	MAX_AGE_DAYS=$(MAX_AGE_DAYS) MAX_SIZE_MB=$(MAX_SIZE_MB) $(SCRIPTS_DIR)/monitor_logs.sh clean -y

# =====================================================================
# Health & security checks (scripts/health_check.sh, security_check.sh)
# =====================================================================
health-check: ## Run scripts/health_check.sh — verify CLIs, Python, Postgres, MongoDB
	$(SCRIPTS_DIR)/health_check.sh

health-check-deep: ## health_check.sh + warehouse table row counts
	$(SCRIPTS_DIR)/health_check.sh --deep

security-check: ## Run scripts/security_check.sh — surface secrets, key files, .env mistakes
	$(SCRIPTS_DIR)/security_check.sh

security-check-shellcheck: ## security_check.sh + shellcheck on all scripts/*.sh
	$(SCRIPTS_DIR)/security_check.sh --shellcheck

setup-dev: ## Run scripts/setup_dev.sh — uv sync, .env scaffold, health check
	$(SCRIPTS_DIR)/setup_dev.sh

# =====================================================================
# Full pipeline
# =====================================================================
pipeline: staging models quality ## Run staging load -> models -> data quality, in order
	@echo "Pipeline complete."

pipeline-continue: staging models-continue quality ## Same as `pipeline`, but models keep running past failures
	@echo "Pipeline complete (continue-on-error)."

pipeline-main: ## Run the full pipeline via main.py (stops on first failure)
	$(PY) main.py

pipeline-main-continue: ## Run main.py with --continue-on-error
	$(PY) main.py --continue-on-error

# =====================================================================
# Housekeeping
# =====================================================================
clean: ## Remove Python cache artifacts (safe — no data or log deletion)
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -type d -name ".pytest_cache" -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete

distclean: clean logs-clean-force ## clean + force-delete flagged logs (destructive)
	@echo "Deep clean complete."
