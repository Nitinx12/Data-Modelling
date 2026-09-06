#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# db_reset.sh — drops and recreates core and staging schemas
# ============================================================================

# Build DATABASE_URL from .env
if [[ -f .env ]]; then
  set -a; . <(tr -d '\r' < .env); set +a
  if [[ -n "${POSTGRES_HOST:-}" ]] && [[ -n "${POSTGRES_DATABASE:-}" ]] && [[ -n "${POSTGRES_USERNAME:-}" ]]; then
    DATABASE_URL="postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT:-5432}/${POSTGRES_DATABASE}"
  fi
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "Error: DATABASE_URL not set. Please check your .env file."
  exit 1
fi

echo "Resetting database schemas... (this will delete all data in core and staging)"
read -p "Are you sure you want to proceed? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Reset aborted."
  exit 0
fi

psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 <<EOF
DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA staging;
CREATE SCHEMA core;
EOF

echo "Schemas reset successfully. You can now run 'make pipeline' to reload everything."
