# CI/CD and Production Readiness Roadmap

An audit of where the pipeline stands against what "production grade" actually
means, plus a concrete plan to close the gap. Every claim in this document was
verified against the repository on 2026-09-12; §2 records where the original
draft of this roadmap turned out to be wrong about the code and was corrected.

---

## 1. Where this already earns the label

Worth stating plainly before listing gaps, because most of the hard part is
already done:

- The five PL/pgSQL data quality loops in `tests/sql/data_quality/` are catalog
  driven (`information_schema` / `pg_catalog`), not a hardcoded list of tables.
  New tables get covered automatically; nothing rots.
- Every load is a real upsert with a defined grain and a documented business
  key, not a naive full refresh.
- The design notes in `data_catlog.md` name real correctness risks in the model.
  Documenting your own known issues is a stronger signal than pretending they
  do not exist, provided they get resolved rather than tracked forever (§6 has
  the current status).
- Ops tooling (`health_check.sh`, `security_check.sh`, `setup_dev.sh`,
  `monitor_logs.sh`) plus PowerShell equivalents means a new contributor has a
  real onboarding path.
- Unit tests for `utils/` exist with a `make test-cov` target.
- **CI already exists.** `.github/workflows/ci.yml` runs ruff lint, ruff format
  check, pytest, and a coverage artifact on every push and pull request to
  `main`, and `codeql.yml` runs CodeQL analysis on a schedule. The gap is not
  "no CI" — it is that CI only covers the half of the checks that need no
  database.

None of that needs to be rebuilt. What is missing is the thing that turns a
well built pipeline into a *production* one: nothing that touches the database
runs unattended, and nothing currently blocks a broken change from merging.

---

## 2. Verification notes — corrections applied to the draft

The draft this document started from made several claims that do not match the
repository. They are recorded here so future readers know this roadmap reflects
the code, not assumptions about it:

| Draft claim | Reality (verified 2026-09-12) |
|---|---|
| "No CI at all" | `.github/workflows/ci.yml` and `codeql.yml` already exist. Lint, format, unit tests, coverage, and CodeQL run on every push and pull request. |
| CI runs `pytest tests/unit` | Live bug: the tests live at `tests/python/unit` (see the reorganization in commit `53b88b5`). The `Pytest` steps in `ci.yml` point at a path that no longer exists, and `pyproject.toml` `testpaths = ["tests/unit"]` is equally stale. Fixed alongside this document. |
| CI can lint with `uv run sqlfluff` | `sqlfluff` is not a dependency — only `ruff` is in the `dev` group. The lint step must either be dropped or `sqlfluff` added to `dev` first. |
| CI sets `DATABASE_URL`, `POSTGRES_SCHEMA_BRONZE` | The connection layer (`utils/engine.py`, `utils/connection.py`) reads `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DATABASE`, `POSTGRES_USERNAME`, `POSTGRES_PASSWORD`, `MONGO_URI`, and `MONGO_DB` via dotenv. The Makefile's `check-env` target also requires a `.env` file to exist, so CI must write one before any DB touching target runs. |
| Bootstrap `sql/*.sql` in the integration job | The draft's placeholder opened a psycopg2 cursor and executed nothing. Reality: `sql/00_create_database_and_schemas.sql` cannot run as-is in CI (it starts with `CREATE DATABASE` and a `\c` meta-command), and it does not need to — the service container already provides the database, and `pg_staging.py` creates every staging table itself (`CREATE TABLE ... PRIMARY KEY` on first load). CI only needs the three schemas. |
| Add checks to `sql/08_data_quality_checks.sql` | Correction to an earlier correction: that file does exist, at `sql/analytics/08_data_quality_checks.sql` — analyst ad hoc queries, not the pipeline's DQ suite. The actionable part stands: new *pipeline* checks belong in `tests/sql/data_quality/` as a sixth loop. |
| `make gx` in CI | The target requires a suite argument (`make gx SUITE=required_text_suite`); a bare `make gx` prints usage and fails. Five suites exist in `gx/expectations/`. |
| "Four unresolved design inconsistencies" | Two of the four were resolved in commits `53c39f0` and `efb1bdd`; one is structurally forced and needs documenting, not fixing; one is genuinely still open. See §6. The newer problem is docs drift: `data_catlog.md` §4 and the CLAUDE.md known issues list still describe the pre-fix behavior. |
| No `.env.example` | Confirmed — it does not exist, despite CLAUDE.md requiring it be kept in sync. Worth adding before CI needs to generate a `.env`. |

Claims that checked out as written at audit time: `security_check.sh
--shellcheck` exists and exits 1 on failure, and `make test-cov` works.
One has since been fixed: `run_data_quality_loops.py` no longer exits 0
unconditionally — it gained a `--strict` flag, and `main.py` passes it,
so a red DQ run now fails the pipeline.

---

## 3. The gaps that actually matter

Ranked by how much they change the "is this production grade" answer:

| # | Gap | Why it matters |
|---|---|---|
| 1 | **CI stops at the database boundary.** Lint and unit tests run unattended; the integration pipeline, the five DQ loops, the security scan, and the GX suites are all things a human has to remember to run locally. | A check nobody is forced to run is a check that will eventually get skipped under deadline pressure. |
| 2 | **The data quality suite cannot fail a build.** `run_data_quality_loops.py` prints a PASS/FAIL summary and exits 0 regardless. | A quality gate that cannot gate anything is a report, not a gate. This has to change before CI can mean anything. |
| 3 | **Docs and code have drifted.** Two of the four documented design caveats were fixed in recent commits, but `data_catlog.md` §4 and the CLAUDE.md known issues list still describe them as live. | In an interview, "did you fix these, or are they still live" needs a good answer — and right now the docs give the wrong one. |
| 4 | **No failure signal outside a terminal someone is watching.** If `main.py` fails at 3am on a schedule, nothing tells anyone. | Production means something notices when it breaks without a human staring at the screen. |

---

## 4. GitHub Actions: overall design

### 4.1 Trigger strategy

| Trigger | Jobs that run | Why |
|---|---|---|
| `pull_request` targeting `main` | lint + unit tests, integration run (seeded), DQ gate, security scan | Every change is proven before merge, not after. |
| `push` to `main` | same as above, plus GX suites with Data Docs as an artifact | Confirms `main` is always green. |
| `schedule` (nightly, `cron: "0 3 * * *"`) | integration + DQ gate + GX | Catches drift that only shows up over time (a source schema change, a stale watermark). |
| `workflow_dispatch` | any job, manually | Re-run the DQ gate or GX on demand without pushing a commit. |

### 4.2 Job breakdown

| Job | Runs | Needs services | Gates merge |
|---|---|---|---|
| `lint-and-test` | `ruff check`, `ruff format --check`, `pytest tests/python/unit` | No | Yes (already exists in `ci.yml`) |
| `integration` | write `.env` → create schemas → seed fixtures → `main.py` → `run_data_quality_loops.py --strict` | Postgres, MongoDB | Yes |
| `security` | `security_check.sh --shellcheck` | No | Yes |
| `gx` | all five suites via `gx/runner.py`, upload Data Docs artifact | Postgres (seeded) | Optional at first; promote to required once thresholds are trusted |

### 4.3 Workflow additions

These jobs extend the existing `ci.yml` rather than replacing it. Only the new
jobs are shown; the existing `lint-and-test` job stays as-is once the pytest
path is corrected:

```yaml
  integration:
    runs-on: ubuntu-latest
    needs: [lint-and-test]
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: warehouse_ci
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
      mongo:
        image: mongo:7
        ports: ["27017:27017"]
    env:
      POSTGRES_HOST: localhost
      POSTGRES_PORT: "5432"
      POSTGRES_DATABASE: warehouse_ci
      POSTGRES_USERNAME: postgres
      POSTGRES_PASSWORD: postgres
      MONGO_URI: mongodb://localhost:27017
      MONGO_DB: warehouse_ci
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v3
        with:
          enable-cache: true
          cache-dependency-glob: "uv.lock"
      - run: uv python install 3.13
      - run: uv sync --group dev --frozen

      - name: Write .env
        run: |
          cat > .env <<'EOF'
          POSTGRES_HOST=localhost
          POSTGRES_PORT=5432
          POSTGRES_DATABASE=warehouse_ci
          POSTGRES_USERNAME=postgres
          POSTGRES_PASSWORD=postgres
          MONGO_URI=mongodb://localhost:27017
          MONGO_DB=warehouse_ci
          EOF

      - name: Create schemas
        run: |
          uv run python - <<'PY'
          import os
          import psycopg2

          conn = psycopg2.connect(
              host=os.environ["POSTGRES_HOST"],
              port=os.environ["POSTGRES_PORT"],
              dbname=os.environ["POSTGRES_DATABASE"],
              user=os.environ["POSTGRES_USERNAME"],
              password=os.environ["POSTGRES_PASSWORD"],
          )
          conn.autocommit = True
          with conn.cursor() as cur:
              for schema in ("staging", "core", "analytics"):
                  cur.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
          conn.close()
          PY

      - name: Seed source fixtures
        run: uv run scripts/python/ci_seed_source.py

      - name: Run pipeline end to end
        run: uv run scripts/python/main.py

      - name: Data quality gate
        run: uv run scripts/python/run_data_quality_loops.py --strict

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: ./scripts/bash/security_check.sh --shellcheck

  gx:
    runs-on: ubuntu-latest
    needs: [integration]
    if: github.ref == 'refs/heads/main' || github.event_name == 'schedule'
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: warehouse_ci
        ports: ["5432:5432"]
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v3
        with:
          enable-cache: true
          cache-dependency-glob: "uv.lock"
      - run: uv python install 3.13
      - run: uv sync --group dev --frozen
      - name: Run all GX suites
        run: |
          for suite in required_text_suite future_date_suite negative_numeric_suite duplicate_key_suite orphan_fk_suite; do
            uv run gx/runner.py "$suite"
          done
      - uses: actions/upload-artifact@v4
        with:
          name: gx-data-docs
          path: gx/uncommitted/data_docs/
          if-no-files-found: ignore
```

Notes on choices the draft got wrong or left implicit:

- **Env vars match `utils/engine.py`**, not a generic `DATABASE_URL`. The
  `.env` file is written explicitly because `make check-env` and dotenv both
  expect it, and because it keeps the CI job honest about what the scripts
  actually read.
- **No staging DDL step.** `pg_staging.py` creates staging tables on first
  load; CI only creates the three schemas. CI must start from an empty
  database every run, the same way a fresh clone does — the seeding step is
  what makes that possible (§7).
- **The `gx` job runs each suite explicitly** because `make gx` requires
  `SUITE=` and there is no "run everything" target. If that gets tedious, add
  a `gx-all` Makefile target that loops over `gx/expectations/*.yaml` and call
  that from CI instead.
- **No sqlfluff step yet.** Add `sqlfluff` to the `dev` dependency group first
  (CLAUDE.md already assumes SQLFluff conventions like the `::VARCHAR` cast
  preference), then add `uv run sqlfluff lint models/ sql/` to `lint-and-test`.

### 4.4 Branch protection

Once the workflow is green a few times, require `lint-and-test`,
`integration`, and `security` as required status checks on `main`, and turn
off force push. `gx` can stay optional until its suites have run enough
times to trust the thresholds.

---

## 5. Fixing the data quality suite so it can actually gate something

This is not a GitHub Actions problem; it has to happen before CI can mean
anything. `run_data_quality_loops.py` currently has no argument parsing at
all — `main()` takes nothing and returns `None` — so the fix is to add
`argparse` plus a strict mode:

```python
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 if any data quality check failed (for CI).",
    )
    args = parser.parse_args()
    ...
    results = run_data_quality_loops(loop_files)
    print_summary_table(results)

    total_failed_checks = sum(r["checks_failed"] for r in results)
    if args.strict and total_failed_checks > 0:
        log.error(
            "%d data quality check(s) failed; failing the run (--strict).",
            total_failed_checks,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Keep the current non failing behavior as the local default, since being able
to run the loops during development without the process dying is genuinely
useful. `--strict` is what CI passes; a human at a terminal does not have to.

---

## 6. The documented design caveats: current status

The draft treated all four as unresolved. Verification against the current
`models/*.sql` shows two are already fixed. Status as of 2026-09-12:

| Caveat | Status | Remaining action |
|---|---|---|
| `fact_order_process.customer_id` used the natural key while `fact_orders.customer_key` used the surrogate key | **Fixed** (`efb1bdd`): `fact_order_process` now carries `customer_key` joined to `dim_customers(customer_key)`. | Update `data_catlog.md` and the CLAUDE.md known issues list, which still describe the old behavior. |
| `dim_products` / `dim_customers` silently dropped rows (NULL or zero `unit_price`; NULL `update_at`) | **Fixed** (`53c39f0`): invalid prices now land as NULL rather than the row being excluded. | Promote the commented out unmatched key verification queries in the model scripts into an active check — a sixth DQ loop counting rows with NULL `customer_key` / `product_key` by reason. |
| Facts join `dim_customers` / `dim_products` by **name** | **Still live, and structurally forced:** `staging.orders_2025` / `staging.orders_2026` carry `CustomerName` but no `CustomerID`, so the name join is the only option against the current extract (`models/fact_orders.sql` joins `ON C.customer_name = O."CustomerName"`). | Document it as an explicit decision in `data_catlog.md` rather than an open question. Longer term: if the Mongo source has a customer ID, extend `pg_staging.py` to extract it and switch the join. |
| `dim_products.category` sourced from `staging.subcategory.category` on a subcategory name match | **Still open.** | Confirm intent once, in writing, in `data_catlog.md`: either "confirmed correct, subcategory owns category" or "bug, fixed to source from products". |

The meta finding: the docs are now the problem, not the code. `data_catlog.md`
§4 and the CLAUDE.md known issues list predate the fixes in `53c39f0` and
`efb1bdd`, so anyone reading them (including a hiring manager, or Claude in a
future session) will believe bugs exist that were fixed. Reconciling those two
files with the current models is the highest signal, lowest effort item on
this whole roadmap.

---

## 7. Seeding data for CI

The integration job needs deterministic MongoDB source data to run against,
since CI starts from nothing every time. Port the pattern used elsewhere (a
`ci_seed_bronze.py` style seeder that loads a fixed set of fixtures and fails
hard if one is missing or malformed) rather than designing a new one:

- `scripts/python/ci_seed_source.py` inserts a small, fixed fixture per MongoDB
  collection covering the cases the DQ loops actually check for: at least one
  blank required value, one future dated value, one duplicate key, one
  orphaned foreign key, one zero price product. That way the integration job
  is also a regression test for the checks themselves, not just a happy path
  run.
- Fail hard if a fixture is missing. A silently incomplete seed produces a
  green integration job that proves nothing.
- Seed into the `MONGO_DB` named in the `.env` written by CI (§4.3) so
  `pg_staging.py` reads exactly what the seeder wrote.

---

## 8. Filling in the rest

### 8.1 Failure alerting

Minimal version, no new infrastructure — append to any job that should page:

```yaml
      - name: Notify on failure
        if: failure()
        uses: slackapi/slack-github-action@v2
        with:
          payload: |
            {"text": "CI failed on ${{ github.repository }}@${{ github.ref_name }}: ${{ github.event.head_commit.message }}"}
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

A Discord or email webhook works the same way. The point is not the channel;
it is that a scheduled run failing at 3am produces a signal somewhere other
than a GitHub Actions tab nobody is looking at.

### 8.2 README badges

Once the new jobs are green:

```markdown
![CI](https://github.com/<user>/<repo>/actions/workflows/ci.yml/badge.svg)
```

### 8.3 Repository hygiene

- `.github/pull_request_template.md`: a short checklist (ran `make test`, ran
  the DQ loops locally, updated `CHANGELOG.md`).
- `CODEOWNERS`: even solo, this documents intent for anyone who forks it.
- `.env.example`: does not exist yet; CLAUDE.md requires it, and §4.3's CI
  config is the natural content to extract into one.
- Dependabot for `uv.lock`:

  ```yaml
  # .github/dependabot.yml
  version: 2
  updates:
    - package-ecosystem: "uv"
      directory: "/"
      schedule:
        interval: "weekly"
  ```

  Verify the `uv` ecosystem is supported for your lockfile at setup time; if
  Dependabot rejects it, fall back to the `pip` ecosystem against
  `pyproject.toml`.

### 8.4 Linting SQL and Python locally, not just in CI

If `ruff` (and eventually `sqlfluff`) are not wired into a `pre-commit` hook,
add one so CI failures are rare rather than routine:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.8.0
    hooks:
      - id: ruff
  - repo: https://github.com/sqlfluff/sqlfluff
    rev: 3.2.0
    hooks:
      - id: sqlfluff-lint
```

---

## 9. Priority order

Sequenced by leverage, not by section number:

1. **Fix the pytest path bug** (`ci.yml` and `pyproject.toml` point at
   `tests/unit`, which no longer exists). Done alongside this document — CI
   cannot even run the unit tests correctly until it is.
2. **Add `--strict` to `run_data_quality_loops.py`** (§5). Fifteen minutes,
   and nothing after this step means anything without it.
3. **Reconcile the docs drift** (§6): update `data_catlog.md` §4 and the
   CLAUDE.md known issues list to match the fixed models, and turn the two
   remaining caveats into explicit written decisions. Highest signal, lowest
   effort item on the list.
4. **Build `ci_seed_source.py`** by porting the fixture seeder pattern (§7).
5. **Ship the `integration` and `security` jobs** in `ci.yml` and require them
   as status checks (§4.3, §4.4).
6. **Add the `gx` job and Slack failure notification** once the above has run
   green for a week (§4.3, §8.1).
7. **Badges, PR template, CODEOWNERS, `.env.example`, Dependabot,
   `pre-commit`** (§8.2 to §8.4) as ongoing polish, not blockers.

Steps 1 to 3 cost almost nothing and change how the project reads to someone
reviewing it. Steps 4 and 5 are the actual engineering work. Step 6 and 7 are
what take it from "has CI" to "production grade".
