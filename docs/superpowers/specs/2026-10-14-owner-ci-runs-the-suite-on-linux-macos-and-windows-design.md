# Owner: CI runs the suite on Linux, macOS and Windows — spec

**Issue:** #154 · **Branch:** `feat/154-owner-ci-runs-the-suite-on-linux-macos-and-windows` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** light

## Product
_Product Owner_

**Problem:** CI runs the suite on `ubuntu-latest` only, so the Windows (Git Bash) and macOS (BSD tools, bash 3.2, launchd) code paths that the #153 migration rewrites are never exercised; a platform regression surfaces only on the owner's machine.
**Audience:** The factory's owner (who runs Shipfloor on Windows, macOS or Linux), and other developers who install the plugin on those platforms.
**Acceptance criteria**
- **AC-1** — Given a PR opened against main, When CI runs, Then the PR's checks list three `test` jobs: one on `ubuntu-latest`, one on `macos-latest`, one on `windows-latest`.
- **AC-2** — Given the macOS job, When it runs the suite, Then its log shows `bash --version` at 4.4 or later (Homebrew bash on PATH, not the system bash 3.2).
- **AC-3** — Given the Windows job, When it runs the suite, Then it runs under Git Bash with Python 3.11+ and PyYAML installed, and its log shows those versions.
- **AC-4** — Given `deploy.required_checks`, When the matrix is merged, Then the required `test` check is still satisfied by the Linux job alone, and a red macOS or Windows job does not block a merge.
- **AC-5** — Given the first macOS and Windows runs on main, When they finish, Then every failure they show is listed as one line on issue #154 with a link to its own issue under #153, labelled `priority: high`.
- **AC-6** — Given one week after merge, When the owner has reviewed Actions minutes and the green streak, Then issue #154 records the owner's decisions: whether macOS/Windows join `required_checks`, and whether they run on every PR or only on PRs touching `scripts/`.
**Out of scope:** Fixing the failures the new jobs find (each gets its own issue under #153); adding macOS/Windows to `required_checks` in this change; path filters on the workflow before the cost review; any change to factory scripts or tests.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): platform support is proven by a CI gate, not by the owner's machine or an agent's word; it also backs the Operating Context promise that the owner works on Windows, macOS or Linux. No conflict with positioning. It is an owner task because it changes `.github/`.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Owner task: the only file is `.github/workflows/ci.yml` (layer `factory`), which the factory may not touch. No contract, module or migration changes.

- `test` job becomes a matrix over `os: [ubuntu-latest, macos-latest, windows-latest]` with `fail-fast: false` and `continue-on-error` on the macOS and Windows entries, so only the Linux result gates a merge.
- Required-check name: keep the Linux job reporting as the bare `test` check (matrix entries named `test (macos-latest)` / `test (windows-latest)` do not collide); a separate job or a `name:` expression keeps `deploy.required_checks=['test']` satisfied by Linux alone.
- macOS: `brew install bash` and put `$(brew --prefix)/bin` first on `GITHUB_PATH`; log `bash --version`.
- Windows: `defaults.run.shell: bash` (Git Bash), `actions/setup-python` 3.11+, `pip install pyyaml`; log `python --version` and `bash --version`.
- Keep `TEST_JOBS: 4`, `timeout-minutes: 30`, the concurrency group and read-only permissions.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | manual | checked on a PR's checks list |
| AC-2 | manual | checked in the macOS job log |
| AC-3 | manual | checked in the Windows job log |
| AC-4 | manual | checked with a red non-Linux job on a PR |
| AC-5 | manual | checked on issue #154 |
| AC-6 | manual | checked on issue #154 after a week |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight light: one file, no UI, no security section (the AC count is above 3, but all are manual checks of one workflow file).
- All ACs are `manual`: they are observed on GitHub Actions and the issue, which a factory test cannot run.
- Non-Linux jobs are non-blocking (`continue-on-error`) until the owner promotes them, as the issue says.

## Open questions
- **Implementation:** A (recommended) the owner edits `.github/workflows/ci.yml` by hand — the factory may not touch `.github/` — or B close this card as owner-only and track it outside the pipeline.
