#!/usr/bin/env bash

# ============================================================================
# setup_dev.sh — one-shot local environment setup for new contributors
# ============================================================================
# Steps (in order, idempotent):
#   1. Verify uv is installed
#   2. Sync project dependencies (uv sync)
#   3. Copy .env.example -> .env if .env missing
#   4. Verify .env has no placeholder values
#   5. Run health_check.sh if present
#
# Usage:
#   ./setup_dev.sh                    # full setup
#   ./setup_dev.sh --skip-health      # skip health_check.sh
#   ./setup_dev.sh --no-sync          # don't run uv sync
#   ./setup_dev.sh -h | --help        # this help
#
# Exit codes:
#   0  setup completed
#   1  setup failed (missing tool, uv sync error, etc.)
#   2  usage error
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_HEALTH=0
DO_SYNC=1

usage() {
  sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-health)  SKIP_HEALTH=1; shift ;;
    --no-sync)      DO_SYNC=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

C_OK="\033[32m"; C_FAIL="\033[31m"; C_WARN="\033[33m"; C_RESET="\033[0m"
ok()    { printf "  ${C_OK}[ OK ]${C_RESET}  %s\n" "$*"; }
fail()  { printf "  ${C_FAIL}[FAIL]${C_RESET}  %s\n" "$*" >&2; exit 1; }
warn()  { printf "  ${C_WARN}[WARN]${C_RESET}  %s\n" "$*"; }
header() { printf "\n\033[1m%s\033[0m\n" "$*"; }

cd "${PROJECT_ROOT}" || fail "Cannot cd to ${PROJECT_ROOT}"

# ------------------------------------------------------------------
# 1. uv
# ------------------------------------------------------------------
header "1. Verifying uv"

if ! command -v uv >/dev/null 2>&1; then
  fail "uv not found. Install from https://github.com/astral-sh/uv"
fi
ok "uv found: $(command -v uv)"

# ------------------------------------------------------------------
# 2. Sync dependencies
# ------------------------------------------------------------------
if [[ "${DO_SYNC}" -eq 1 ]]; then
  header "2. Syncing dependencies (uv sync)"
  uv sync
  ok "uv sync complete"
else
  warn "Skipped uv sync (--no-sync)"
fi

# ------------------------------------------------------------------
# 3. .env
# ------------------------------------------------------------------
header "3. .env file"

if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    ok "Created .env from .env.example (fill in real values before running the pipeline)"
  else
    fail ".env.example missing — cannot scaffold .env"
  fi
else
  ok ".env already present"
fi

# ------------------------------------------------------------------
# 4. .env placeholder check
# ------------------------------------------------------------------
header "4. .env placeholder check"

PLACEHOLDER_HITS="$(grep -E '^(POSTGRES_(PASSWORD|HOST|username|database))|MONGO_URI' .env 2>/dev/null | \
  grep -E '(<|TODO|CHANGE_ME|REPLACE_ME|xxxxxxxx)' || true)"

if [[ -n "${PLACEHOLDER_HITS}" ]]; then
  warn "Placeholder values detected in .env — update them before running the pipeline:"
  printf '      %s\n' "${PLACEHOLDER_HITS}" | sed 's/^/  /'
else
  ok "No obvious placeholders in .env"
fi

# ------------------------------------------------------------------
# 5. Health check
# ------------------------------------------------------------------
if [[ "${SKIP_HEALTH}" -eq 0 ]]; then
  header "5. Health check"
  if [[ -x scripts/health_check.sh ]]; then
    scripts/health_check.sh || warn "health_check.sh reported issues (see above)"
  else
    warn "scripts/health_check.sh not found or not executable"
  fi
else
  warn "Skipped health check (--skip-health)"
fi

header "Done"
printf "  ${C_OK}Setup complete.${C_RESET}\n"
printf "  Next steps:\n"
printf "    1. Edit .env with your real credentials\n"
printf "    2. Run 'make pipeline' to test end-to-end\n"
printf "    3. Run 'make test' for unit tests\n"
