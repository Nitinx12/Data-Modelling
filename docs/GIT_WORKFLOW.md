# Git Workflow Guide

A production Git workflow reference for this repository: branching strategy,
commit conventions, the files a production repo needs, hooks, and release
management. Adapted from a generic workflow guide and verified against this
repo on 2026-09-12 — where the generic advice did not fit (dbt, Docker,
semantic-release, pip), it was dropped or replaced with this project's
equivalent, and §3 records each of those decisions.

Companion document: `docs/CI_CD.md` covers CI and production readiness in
depth, including the integration, security, and GX jobs planned for `ci.yml`.

---

## 1. Branching strategy

Trunk based development with short lived branches beats full Git Flow for a
project this size — less merge overhead, faster feedback. This is already how
the repo works in practice (`docs/ci-cd-roadmap` being the example closest to
hand).

```
main            → always green, protected, tagged for releases
feature/*       → short lived, branched from main
fix/*           → bug fixes
hotfix/*        → urgent production fixes, branched from main
chore/*         → tooling, deps, CI changes
docs/*          → documentation only changes
```

Skip a `develop` branch entirely: there is no staging environment with its own
deploy cadence, so an integration branch would just create merge debt.

### Branch naming convention

```
<type>/<short-description>          # solo work
<type>/<ticket-id>-<description>    # if you start using an issue tracker

docs/ci-cd-roadmap                  # real example from this repo
fix/fact-orders-null-customer-key
chore/bump-ruff
```

---

## 2. Commit message convention — Conventional Commits

This is already the de facto standard here — `git log` shows
`docs(architecture):`, `fix(models):`, `chore(claude):`. Keep it that way; it
makes `git log` readable and would enable automatic changelogs if ever wanted.

```
<type>(<scope>): <short summary>

[optional body]
```

**Types:**

| Type | Use for |
|---|---|
| `feat` | new feature |
| `fix` | bug fix |
| `docs` | documentation only |
| `style` | formatting, no logic change |
| `refactor` | code change that is neither a fix nor a feature |
| `perf` | performance improvement |
| `test` | adding or fixing tests |
| `build` | build system, dependencies |
| `ci` | CI/CD config changes |
| `chore` | maintenance, tooling |
| `revert` | reverts a previous commit |

**Real examples from this repo's history:**

```
fix(models): align fact joins with staging schema and rebuild fact_order_process
docs(architecture): sync ARCHITECTURE.md with current directory layout
chore(claude): add project configuration
```

Enforcement (commitlint) is deliberately not wired in — see §3.

---

## 3. Production repo file inventory

What a production repo needs, and where this one stands. Files marked **added**
were created alongside this document; their content lives in the repo, not
duplicated here.

| File | Status |
|---|---|
| `.github/workflows/ci.yml` | Exists: ruff lint + format check + unit tests + coverage artifact on every push and PR to `main`. Planned additions in `docs/CI_CD.md` §4. |
| `.github/workflows/codeql.yml` | Exists: CodeQL analysis on a weekly schedule. |
| `.gitignore` | Exists and is comprehensive (Python, env, logs, dbt, `gx/uncommitted/`). |
| `CHANGELOG.md` | Exists at `docs/CHANGELOG.md`, Keep a Changelog format, append only policy per CLAUDE.md. |
| `LICENSE`, `README.md`, `Makefile` | Exist. |
| `.env.example` | **Added.** Required by CLAUDE.md ("Secrets live in `.env`, with `.env.example` kept in sync") and by the `protect-env.sh` hook, which blocks direct `.env` edits in Claude Code. Lists every variable `utils/engine.py` reads, required ones first. |
| `.gitattributes` | **Added.** Normalizes line endings — git was warning "LF will be replaced by CRLF" on Windows checkouts, which this file fixes. |
| `.github/CODEOWNERS` | **Added.** Solo owner today; documents review intent for anyone who forks. |
| `.github/PULL_REQUEST_TEMPLATE.md` | **Added.** Checklist mirrors CLAUDE.md's changelog and quality requirements. |
| `.github/ISSUE_TEMPLATE/` | **Added.** Bug report and feature request templates. |
| `CONTRIBUTING.md` | **Added.** Onboarding path in this repo's terms (uv, make targets, PowerShell on Windows). |
| `SECURITY.md` | **Added.** Vulnerability reporting policy. |
| `.pre-commit-config.yaml` | **Added.** See §5. |
| `release.yml` + semantic-release | **Not adopted.** It contradicts the changelog policy in CLAUDE.md: entries are append only under `[Unreleased]`, and a dated version heading is cut manually by the owner, not automatically from commit types. Revisit only if the project moves to automated releases. |
| `VERSION` file | **Not adopted.** `pyproject.toml` already carries the version (`0.1.0`); a second source of truth would drift. |
| commitlint | **Not adopted for now.** It pulls a Node dependency into a Python project to enforce a convention that is already followed by habit. Add it if contributors other than the owner start committing. |
| sqlfluff hook | **Not adopted yet.** CLAUDE.md already documents SQLFluff conventions (the `::VARCHAR` cast preference), but the tool is neither a dependency nor configured; enabling the lint hook before a `.sqlfluff` config exists would fail on the current SQL. Add it together with the CI lint step planned in `docs/CI_CD.md` §4.3. |

---

## 4. Branch protection rules

Set these on `main` under **Settings → Branches → Branch protection rules**:

- [x] Require a pull request before merging
- [x] Require status checks to pass before merging → select `lint-and-test`
      (add `integration` and `security` once those jobs land per
      `docs/CI_CD.md` §4.3)
- [x] Require branches to be up to date before merging
- [x] Require conversation resolution before merging
- [x] Do not allow bypassing the above settings (even for admins)
- [ ] Allow force pushes → **off**
- [ ] Allow deletions → **off**

Note: on a free GitHub plan, "do not allow bypassing" requires a public repo or
an organization; for a personal private repo, requiring PRs and status checks
is still available and is the part that matters.

---

## 5. Git hooks

`.pre-commit-config.yaml` runs local checks before every commit so bad code
never reaches CI:

| Hook | Source | Purpose |
|---|---|---|
| `trailing-whitespace`, `end-of-file-fixer` | pre-commit-hooks | whitespace hygiene |
| `check-yaml`, `check-merge-conflict` | pre-commit-hooks | structural checks |
| `check-added-large-files` | pre-commit-hooks | keeps fixtures and exports out of git |
| `detect-private-key` | pre-commit-hooks | secret detection before it ever gets committed |
| `ruff` | ruff-pre-commit | lint, auto fixing what is safe |
| `ruff-format` | ruff-pre-commit | keeps local formatting aligned with the `ruff format --check` step in CI |

Install once (no project dependency needed — `uv tool` installs it isolated):

```bash
uv tool install pre-commit
pre-commit install
```

The first commit after installing will take a minute while the hook
environments build; after that they are cached.

Deliberately omitted, with reasons recorded in §3: commitlint (Node dependency
for a convention already followed) and sqlfluff (no config yet).

---

## 6. Versioning and releases

Semantic versioning, with the meanings adapted to a data warehouse:

- `MAJOR` — breaking schema or pipeline changes (a grain change, a renamed
  business key)
- `MINOR` — new models or features, backward compatible
- `PATCH` — bug fixes

Releases are cut manually, per the changelog policy in CLAUDE.md: when a
release is cut, `[Unreleased]` entries move under a dated version heading in
`docs/CHANGELOG.md`, then tag:

```bash
git tag -a v0.1.0 -m "release: v0.1.0"
git push origin v0.1.0
```

There is no automated release step, by design (§3).

---

## 7. Day to day workflow (cheat sheet)

```bash
# start new work
git checkout main && git pull
git checkout -b docs/my-change

# work, commit often with conventional messages
git add <files>
git commit -m "docs(models): clarify fact_orders grain"

# before opening a PR
uv run pytest tests/python/unit          # unit tests, no DB needed
make quality                             # DQ loops, needs a loaded warehouse

# push and open a PR
git push -u origin docs/my-change

# after merge, locally
git checkout main && git pull
git branch -d docs/my-change
```

Windows contributors without `make`: the same operations exist as PowerShell
scripts under `scripts/powershell/`, and Python entry points run directly via
`uv run scripts/python/<script>.py`. The Makefile is a convenience layer, not
a requirement.

Two rules from CLAUDE.md worth repeating because they bite:

1. **Every change gets a `docs/CHANGELOG.md` entry** under `[Unreleased]`,
   however small — before the commit, not after.
2. **Never stage or commit `.env`** — secrets live there, and
   `security_check.sh` exists precisely to catch it.

---

## 8. Quick setup checklist

Status of the standard production checklist for this repo:

- [x] `.gitignore`, `README.md`, `LICENSE` — already present
- [x] `.env.example` — added; `.env` is gitignored
- [x] `.gitattributes` — added
- [x] `.pre-commit-config.yaml` — added (`pre-commit install` still needs
      running once per clone)
- [x] CI workflow (`ci.yml`) — present; integration/security/GX jobs planned
      in `docs/CI_CD.md`
- [x] `CODEOWNERS`, PR template, issue templates — added
- [x] `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md` — present
- [x] Conventional Commits — followed by convention, not enforced
- [ ] Branch protection on `main` — a GitHub settings task, not a file; do it
      via §4
- [ ] First release tag `v0.1.0` — cut manually when ready (§6)

The pieces that scale this from a solo analytics project to a multi
contributor data platform — automated release tooling, commitlint, required
reviews — are recorded in §3 as deliberate omissions with the conditions under
which to revisit each.
