#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# pipeline.sh — quick wrapper for the main pipeline orchestrator
# ============================================================================

echo "Starting the warehouse pipeline..."
uv run scripts/python/main.py "$@"
