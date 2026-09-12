# Security Policy

## Reporting a Vulnerability

Please do not open a public issue for security concerns. Email
nitin321x@gmail.com with details and reproduction steps. Reports are
acknowledged within 5 business days where possible.

Do not include real credentials, connection strings, or `.env` contents in a
report; placeholder values are enough to reproduce most issues.

## Supported Versions

Only the latest release on `main` receives security fixes.

## Scope Notes

- Secrets belong in `.env`, which is gitignored; `.env.example` carries only
  variable names and blank values. Run `./scripts/bash/security_check.sh`
  (or `scripts/powershell/security_check.ps1`) before pushing if unsure.
- The data quality suite under `tests/sql/data_quality/` is read only by
  design and holds no credentials.
