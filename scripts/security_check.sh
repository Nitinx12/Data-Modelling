#!/usr/bin/env bash

# ============================================================================
# security_check.sh — surface common security mistakes before they leak
# ============================================================================
# Checks (in order):
#   1. .env / .env.* are not tracked by git and not staged
#   2. No hard-coded credentials in models/, scripts/, sql/, utils/
#   3. No private keys (*.pem, id_rsa, *.key) in the repo
#   4. No committed .coverage / htmlcov directories
#   5. Make sure .gitignore covers secret patterns
#   6. Optional: shellcheck on all .sh scripts (when --shellcheck)
#
# Usage:
#   ./security_check.sh                    # all checks except shellcheck
#   ./security_check.sh --shellcheck       # also run shellcheck if present
#   ./security_check.sh -h | --help        # this help
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed (secrets or unsafe patterns found)
#   2  usage error
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_SHELLCHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shellcheck)  RUN_SHELLCHECK=1; shift ;;
    -h|--help)     sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *)             echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

C_OK="\033[32m"; C_FAIL="\033[31m"; C_WARN="\033[33m"; C_RESET="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0

ok()    { printf "  ${C_OK}[ OK ]${C_RESET}  %s\n" "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { printf "  ${C_FAIL}[FAIL]${C_RESET}  %s\n" "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()  { printf "  ${C_WARN}[WARN]${C_RESET}  %s\n" "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
header() { printf "\n\033[1m%s\033[0m\n" "$*"; }

cd "${PROJECT_ROOT}" || { echo "Cannot cd to ${PROJECT_ROOT}" >&2; exit 1; }

# ------------------------------------------------------------------
# 1. .env not tracked or staged
# ------------------------------------------------------------------
header "1. .env file handling"

if [[ -f .env ]]; then
  # Is .env tracked?  Use git ls-files.
  if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    fail ".env is tracked by git — remove it with 'git rm --cached .env'"
  else
    ok ".env is not tracked by git"
  fi
  # Is .env staged?
  if git diff --cached --name-only | grep -qx '.env'; then
    fail ".env is staged in the current index"
  else
    ok ".env is not staged"
  fi
else
  warn ".env not present (skipped)"
fi

# .env.* (except .env.example)
if git ls-files | grep -E '^\.env\.[^e]' >/dev/null 2>&1; then
  fail "A non-example .env.* file is tracked: $(git ls-files | grep -E '^\.env\.[^e]')"
else
  ok "No non-example .env.* file is tracked"
fi

# ------------------------------------------------------------------
# 2. Hard-coded credentials in source
# ------------------------------------------------------------------
header "2. Hard-coded credentials in source"

# Search for common patterns: assignment to *PASSWORD*, *SECRET*, *TOKEN* with a quoted value.
SECRET_HITS="$(grep -RInE --include='*.py' --include='*.sql' --include='*.sh' \
  -E '(password|secret|api[_-]?key|access[_-]?key|token)\s*=\s*['\''"][^'\''"$]{6,}' \
  models scripts sql utils 2>/dev/null || true)"

if [[ -n "${SECRET_HITS}" ]]; then
  fail "Possible hard-coded credentials found:"
  printf '      %s\n' "${SECRET_HITS}" | sed 's/^/  /'
else
  ok "No obvious hard-coded credentials in models/, scripts/, sql/, utils/"
fi

# PostgreSQL DSN with embedded password
PG_DSN_HITS="$(grep -RInE --include='*.py' --include='*.sql' --include='*.sh' --include='*.md' \
  -E 'postgresql://[^:]+:[^@]+@' \
  . 2>/dev/null | grep -v -E '(\.env|\.env\.example|README|docs/|\.git/)' || true)"

if [[ -n "${PG_DSN_HITS}" ]]; then
  fail "PostgreSQL DSN with embedded password found:"
  printf '      %s\n' "${PG_DSN_HITS}" | sed 's/^/  /'
else
  ok "No PostgreSQL DSN with embedded password in source"
fi

# ------------------------------------------------------------------
# 3. Private keys
# ------------------------------------------------------------------
header "3. Private keys"

PRIVATE_KEYS="$(find . -path ./.git -prune -o -type f \
  \( -name '*.pem' -o -name '*.key' -o -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ed25519' \) \
  -print 2>/dev/null || true)"

if [[ -n "${PRIVATE_KEYS}" ]]; then
  fail "Private key files found in repo:"
  printf '      %s\n' "${PRIVATE_KEYS}" | sed 's/^/  /'
else
  ok "No private key files in repo"
fi

# ------------------------------------------------------------------
# 4. Coverage artifacts
# ------------------------------------------------------------------
header "4. Coverage artifacts"

if [[ -d htmlcov ]]; then
  fail "htmlcov/ directory present — should be in .gitignore"
else
  ok "No htmlcov/ directory in working tree"
fi

if find . -path ./.git -prune -o -name '.coverage' -o -name '.coverage.*' -print 2>/dev/null | grep -q .; then
  fail ".coverage files present in working tree"
else
  ok "No .coverage files in working tree"
fi

# ------------------------------------------------------------------
# 5. .gitignore coverage
# ------------------------------------------------------------------
header "5. .gitignore coverage"

REQUIRED_PATTERNS=(
  '^\.env$'
  '^\.coverage'
  'htmlcov/'
  '__pycache__/'
  '\.venv/'
  'logs/'
)

MISSING=()
for pat in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Eq "${pat}" .gitignore 2>/dev/null; then
    MISSING+=("${pat}")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  fail ".gitignore is missing patterns: ${MISSING[*]}"
else
  ok ".gitignore covers .env, .coverage, htmlcov/, __pycache__/, .venv/, logs/"
fi

# ------------------------------------------------------------------
# 6. Optional shellcheck
# ------------------------------------------------------------------
if [[ "${RUN_SHELLCHECK}" -eq 1 ]]; then
  header "6. shellcheck"
  if ! command -v shellcheck >/dev/null 2>&1; then
    warn "shellcheck not on PATH — install with 'brew install shellcheck' or 'apt install shellcheck'"
  else
    SC_FAIL=0
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      if ! shellcheck "${f}" >/dev/null 2>&1; then
        fail "shellcheck ${f}"
        SC_FAIL=1
      fi
    done < <(find scripts -name '*.sh' -type f 2>/dev/null)
    if [[ "${SC_FAIL}" -eq 0 ]]; then
      ok "shellcheck clean on all scripts/*.sh"
    fi
  fi
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
