# Troubleshooting

Symptom → cause → fix. If your problem is not here, check the logs under
`logs/<subdir>/` and `docs/scripts.md`.

## Setup and environment

**`OSError: Missing required environment variables: ...`**
`.env` is missing or incomplete. Copy `.env.example`, fill in the listed
variables, then `make config` to confirm.

**`make health-check` fails on `psql not found`**
The Postgres client is not on the PATH of the shell you are using. Install it
or add it to PATH. Known on Windows where `psql` exists for PowerShell but not
inside the bash environment — the health check runs from bash.

**`uv` fails with `Access is denied ... .venv/lib64`**
The `.venv` was created from WSL and Windows `uv` cannot remove it. Delete the
`.venv` folder from a Windows shell, then `uv sync` to rebuild it.

**`mongosh` ping fails in the health check**
MongoDB is not running. Start it, then re-run `make health-check`.

**`make: *** No rule to make target '...'`**
Typo in the target name. Run `make help` for the real list.

## Pipeline failures

**A model fails on a missing column**
The staging table schema changed upstream. Compare the live columns against
`docs/data_catlog.md`, update the model and the catalog together.

**`make pipeline` exits 1 at the quality stage**
A data quality check found bad data. The exact table and predicate are printed
and logged. Fix the source or model, re-run `make models`, then `make quality`.
Do not hand edit `core` to make a check pass.

**Rows disappear after loading orders or payments**
Future dated source values are quarantined, not loaded. Check the reject
tables: `core.fact_order_process_rejects`, `..._payment_rejects`,
`..._milestone_rejects`. The rows return to the fact once the source dates
are corrected.

**A row deleted in MongoDB is still in the warehouse**
Known behavior: deletions do not propagate through the incremental load.
See decision O1 in `docs/DECISIONS.md` — not a bug you can fix in a model.

**`fact_inventory` has no 2026 months**
Expected: the unpivot list covers 2025 only because no 2026 columns exist in
staging or Mongo yet. Extend the list when 2026 data lands.

**`campaing_logs`, `addres` — "is this a typo?"**
Yes, and it is preserved on purpose. Renaming would break every script and
doc that references the source names. See the glossary in
`docs/data_catlog.md` §5.

## Git and CI

**CI fails on lint**
Run `make lint` locally; `make lint-fix` auto-fixes what it safely can.

**CI fails on tests**
Run `make test` locally — same suite, faster feedback.
