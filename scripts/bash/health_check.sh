#!/usr/bin/env bash

# ============================================================================
# health_check.sh — verify project dependencies and external services
# ============================================================================
# Checks (in order):
#   1. Required CLIs on PATH: uv, psql, mongosh
#   2. Python 3.13+ via uv
#   3. .env file presence (warning if missing)
#   4. Postgres reachability + version
#   5. MongoDB reachability + server version
#   6. Project disk space in logs/ + .venv/
#   7. Optional: warehouse table counts (when --deep)
#
# Usage:
#   ./health_check.sh                # quick checks
#   ./health_check.sh --deep         # also count rows in core.* / staging.*
#   ./health_check.sh -h | --help    # this help
#
# Exit codes:
#   0  all required checks passed
#   1  one or more required checks failed
#   2  usage error
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ------------------------------------------------------------------
# Defaults / flags
# ------------------------------------------------------------------
DEEP=0
DATABASE_URL=""
QUIET=0

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep)        DEEP=1; shift ;;
    --database-url) DATABASE_URL="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -q|--quiet)    QUIET=1; shift ;;
    *)             echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------
if [[ "${QUIET}" -eq 0 ]]; then
  C_OK="\033[32m"   # green
  C_FAIL="\033[31m" # red
  C_WARN="\033[33m" # yellow
  C_RESET="\033[0m"
else
  C_OK=""; C_FAIL=""; C_WARN=""; C_RESET=""
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

ok()    { printf "  ${C_OK}[ OK ]${C_RESET}  %s\n" "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { printf "  ${C_FAIL}[FAIL]${C_RESET}  %s\n" "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()  { printf "  ${C_WARN}[WARN]${C_RESET}  %s\n" "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
header() { printf "\n\033[1m%s\033[0m\n" "$*"; }

# ------------------------------------------------------------------
# 1. Required CLIs
# ------------------------------------------------------------------
header "1. Required command-line tools"

for tool in uv psql mongosh; do
  if command -v "${tool}" >/dev/null 2>&1; then
    ok "${tool} found: $(command -v "${tool}")"
  else
    fail "${tool} not found on PATH"
  fi
done

# ------------------------------------------------------------------
# 2. Python via uv
# ------------------------------------------------------------------
header "2. Python environment (uv)"

if command -v uv >/dev/null 2>&1; then
  PY_VERSION="$(uv python find 3.13 2>/dev/null || true)"
  if [[ -n "${PY_VERSION}" ]] && [[ -x "${PY_VERSION}" ]]; then
    VER="$("${PY_VERSION}" --version 2>&1 | awk '{print $2}')"
    ok "uv-managed Python 3.13+ found: ${VER}"
  else
    fail "uv cannot resolve a Python 3.13+ interpreter"
  fi
else
  fail "uv not on PATH — install from https://github.com/astral-sh/uv"
fi

# ------------------------------------------------------------------
# 3. .env
# ------------------------------------------------------------------
header "3. Environment file"

if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  ok ".env present at project root"
else
  if [[ -f "${PROJECT_ROOT}/.env.example" ]]; then
    warn ".env not found (copy .env.example and fill in credentials)"
  else
    fail ".env and .env.example both missing"
  fi
fi

# ------------------------------------------------------------------
# 4. Postgres
# ------------------------------------------------------------------
header "4. Postgres"

if ! command -v psql >/dev/null 2>&1; then
  fail "psql not on PATH — cannot check Postgres"
else
  # Build DATABASE_URL from .env if not passed on CLI
  if [[ -z "${DATABASE_URL}" ]] && [[ -f "${PROJECT_ROOT}/.env" ]]; then
    set -a; . <(tr -d '\r' < "${PROJECT_ROOT}/.env"); set +a
    if [[ -n "${POSTGRES_HOST:-}" ]] && [[ -n "${POSTGRES_DATABASE:-}" ]] && [[ -n "${POSTGRES_USERNAME:-}" ]]; then
      DATABASE_URL="postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT:-5432}/${POSTGRES_DATABASE}"
    fi
  fi
  if [[ -z "${DATABASE_URL}" ]]; then
    warn "DATABASE_URL not set — skipping Postgres ping"
  else
    PG_VERSION="$(psql "${DATABASE_URL}" -tAc 'SELECT version();' 2>&1 || true)"
    if [[ "${PG_VERSION}" == PostgreSQL* ]]; then
      ok "Postgres reachable: ${PG_VERSION%%,*}"
    else
      fail "Postgres unreachable: ${PG_VERSION}"
    fi
  fi
fi

# ------------------------------------------------------------------
# 5. MongoDB
# ------------------------------------------------------------------
header "5. MongoDB"

if ! command -v mongosh >/dev/null 2>&1; then
  fail "mongosh not on PATH — cannot check MongoDB"
else
  MONGO_URI_VAL="${MONGO_URI:-mongodb://localhost:27017}"
  MONGO_PING="$(MONGO_URI="${MONGO_URI_VAL}" mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>&1 || true)"
  if [[ "${MONGO_PING}" == "1" ]]; then
    ok "MongoDB ping ok at ${MONGO_URI_VAL}"
  else
    fail "MongoDB ping failed: ${MONGO_PING}"
  fi
fi

# ------------------------------------------------------------------
# 6. Disk
# ------------------------------------------------------------------
header "6. Disk usage"

if [[ -d "${PROJECT_ROOT}/logs" ]]; then
  LOG_BYTES="$(du -sb "${PROJECT_ROOT}/logs" 2>/dev/null | awk '{print $1}')"
  LOG_MB="$(awk -v b="${LOG_BYTES:-0}" 'BEGIN{printf "%.1f", b/1024/1024}')"
  ok "logs/ size: ${LOG_MB} MB"
else
  warn "logs/ directory does not exist"
fi

if [[ -d "${PROJECT_ROOT}/.venv" ]]; then
  VENV_BYTES="$(du -sb "${PROJECT_ROOT}/.venv" 2>/dev/null | awk '{print $1}')"
  VENV_MB="$(awk -v b="${VENV_BYTES:-0}" 'BEGIN{printf "%.1f", b/1024/1024}')"
  ok ".venv/ size: ${VENV_MB} MB"
else
  warn ".venv/ does not exist (run 'uv sync')"
fi

# ------------------------------------------------------------------
# 7. Deep: warehouse table counts
# ------------------------------------------------------------------
if [[ "${DEEP}" -eq 1 ]] && command -v psql >/dev/null 2>&1 && [[ -n "${DATABASE_URL}" ]]; then
  header "7. Warehouse table counts (deep)"
  psql "${DATABASE_URL}" -tAc "
    SELECT table_schema, table_name, n_live_tup
    FROM information_schema.tables t
    JOIN pg_stat_user_tables s USING (table_schema, table_name)
    WHERE table_schema IN ('staging','core')
    ORDER BY table_schema, table_name;
  " 2>/dev/null | while IFS='|' read -r schema name rows; do
    [[ -z "${schema}" ]] && continue
    printf "  ${C_OK}[ OK ]${C_RESET}  %s.%s — %s rows\n" "${schema}" "${name}" "${rows:-?}"
  done
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
header "Summary"
printf "  %s%d passed%s, %s%d warned%s, %s%d failed%s\n" \
  "${C_OK}"  "${PASS_COUNT}" "${C_RESET}" \
  "${C_WARN}" "${WARN_COUNT}" "${C_RESET}" \
  "${C_FAIL}" "${FAIL_COUNT}" "${C_RESET}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
exit 0
