# Git Workflow

The short version of how changes get into this repo. For the full contributor
guide see `CONTRIBUTING.md`; for repo policies see `SECURITY.md`.

## Branches

| Branch | Purpose |
|---|---|
| `main` | Stable. Never commit to it directly — changes land through a pull request. |
| `feat/<name>` | New model, script, or doc. |
| `fix/<name>` | Bug fix. |
| `docs/<name>` | Documentation only. |

```bash
git switch -c feat/new-fact-table     # start
git push -u origin feat/new-fact-table # publish
```

## Everyday loop

```bash
git switch main && git pull            # start from fresh main
git switch -c feat/my-change           # branch
# ...edit...
git status                             # check what changed
git add <files>                        # stage only your files
git commit -m "fix(models): guard milestones in upsert"
git push                               # right after committing
```

Open a pull request into `main` when the work is ready. Reviewers are assigned
via `.github/CODEOWNERS`; the PR template lists what to fill in.

## Commit rules

- **One logical change per commit** — a SQL fix and a doc rewrite are two commits.
- **Short, imperative summary** — `fix(models): ...`, `docs: ...`, `feat: ...`.
- **Every change gets a `CHANGELOG.md` entry** in the same commit (see the
  Changelog Requirement in `CLAUDE.md`).
- **Never commit** `.env`, credentials, `logs/`, or anything
  `make security-check` flags.

## Hooks

- `pre-commit` (ruff + yaml): `uv tool install pre-commit && pre-commit install`
- `commit-msg` (Conventional Commits): `git config core.hooksPath .githooks` — mirrors CI `commitlint.yml`

## Before you push

```bash
make lint          # ruff, must be clean
make quality       # data quality loops, must pass
make security-check
```

CI mirrors this on every push and PR: `commitlint` → `ci` (lint + unit tests) → `CodeQL` + `dependency review` → `label` → `CD` smoke on `main`, `release` on tag `v*`.

## Merging

Pull requests are merged by the maintainer, not the branch author. Delete the
feature branch after merge:

```bash
git switch main && git pull
git branch -d feat/my-change
```
