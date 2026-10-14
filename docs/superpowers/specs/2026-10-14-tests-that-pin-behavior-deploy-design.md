# Tests that pin behavior: deploy — spec

**Issue:** #159 · **Branch:** `feat/159-tests-that-pin-behavior-deploy` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** `deploy.sh` merges to main and opens reverts, but only its happy paths, conflicts, fix rounds and local CI are under test. PY-14 cannot port it safely until every path it can take is pinned by a test against today's behavior.
**Audience:** The factory's owner, and developers who install the plugin and rely on the deploy stage not to break main.
**Acceptance criteria**
- **AC-1** — Given a run starts with a busy or stale `deploysh-<n>.lock`, a card in the wrong column, `--refresh` on a non-Staged card / unapproved head / back_to_coding mid-refresh, a fork PR, several open PRs (incl. `revert/<n>` beside `feat/<n>-*`), or a merged PR missing from `origin/main`, when `deploy.sh` runs, then it exits 2, takes over, exits 0 with nothing moved, blocks, or reports `RESUMED` as each case does today.
- **AC-2** — Given an approval chain over 10 steps, a second parent not on main, CRLF in comments, or a login that would break the jq splice of `ME`, when approval is checked, then the outcome matches today's `deploy.sh`.
- **AC-3** — Given a merge that fails without conflicts, or conflicts above `conflict_max_files` or `conflict_max_hunks`, when the merge step runs, then the exit code and recorded moves/comments match today's.
- **AC-4** — Given `--continue` with `MERGE_HEAD` left, unresolved files, missing or wrong `resolve.parents`, a moved head, a dirty worktree, a merge commit in the fix range, a large fix with failing fast gates, or a fix round started from a gate failure, when it runs, then `check_resolution`/`check_fix` reject or accept as today.
- **AC-5** — Given a failed push, a card moved during the run, a failed record comment, gates failing with nothing merged, each `wait_checks` case (10 empty polls with `allow_no_checks`, each failure keyword, green needing two polls, only right-head polls counting, timeout, red checks on the approved head) or main moving three times, when the push and CI wait run, then the run blocks, retries later, pushes nothing, or goes to Coding as today.
- **AC-6** — Given `pr merge` failing with state `MERGED`, an unknown merge commit, production CI with no run / unfinished / failing rerun, each `deploy.environment` outcome (success with URL, inactive, failure, timeout), several healthcheck URLs, a failed revert prep or `pr create`, or a `revert/<n>` PR being deployed, when merge and production run, then the outcome, the failed log in the comment, "revert by hand", the forbidden-path-only gate, worktree removal on Done and the `Deployed:` comment with URL and minutes match today's.
- **AC-7** — Given a `local_ci` timeout (124) or no `timeout` binary, `ci_findings` with GitHub failed logs, or `language` pt-BR, when `deploy.sh` runs, then it goes to Coding / falls back, includes the logs, and posts pt-BR text with markers and `CONFLICT` lines in English.
- **AC-8** — Given every bullet of the issue, when its test runs, then at least one assertion checks the exit code and one checks the comments/labels/moves recorded by the fake gh.
- **AC-9** — Given main with the new tests, when the test suite runs, then it passes without any change to `deploy.sh`.
- **AC-10** — Given `TEST_JOBS=4` and `FACTORY_POLL=0`, when the deploy tests run, then they finish within today's time budget.
**Out of scope:** Changing `deploy.sh`; a test that exposes a bug opens a new issue under #153 instead of fixing it here. The Python port itself (PY-14).
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): the deploy gate's behavior is pinned by scripts before it is rewritten. No conflict with positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Contracts:** none changed. `deploy.sh` (exit codes 0/2/3/4/5/6, comment markers, labels, board moves) is only observed.
- **Layer:** `factory` only. New files, one per issue heading, each sourcing `scripts/test/deploy-lib.sh`:
  - `scripts/test/deploy-start.test.sh` (AC-1)
  - `scripts/test/deploy-approval-limits.test.sh` (AC-2)
  - `scripts/test/deploy-merge-fail.test.sh` (AC-3)
  - `scripts/test/deploy-continue-checks.test.sh` (AC-4)
  - `scripts/test/deploy-push-ci.test.sh` (AC-5)
  - `scripts/test/deploy-production.test.sh` (AC-6)
  - `scripts/test/deploy-other.test.sh` (AC-7)
- **Helpers:** `scripts/test/deploy-lib.sh` and `scripts/test/fake-gh-deploy` gain only additive switches (state files in `$FG`, e.g. failing `pr merge`/`pr create`/push, failed-run logs, environment deployments, empty/changing check rollups, a login with odd characters). Existing cases must keep their output unchanged.
- **Budget:** cases reuse `scene` snapshots and `FACTORY_POLL=0`; no sleeps. Run with `TEST_JOBS=4` and compare against the current deploy-* total before and after.
- **Bugs found:** a test that exposes a bug in `deploy.sh` pins today's behavior and a follow-up issue is opened under #153; `deploy.sh` is not edited.
- **Migration:** none (tests only).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/deploy-start.test.sh` |
| AC-2 | factory | `scripts/test/deploy-approval-limits.test.sh` |
| AC-3 | factory | `scripts/test/deploy-merge-fail.test.sh` |
| AC-4 | factory | `scripts/test/deploy-continue-checks.test.sh` |
| AC-5 | factory | `scripts/test/deploy-push-ci.test.sh` |
| AC-6 | factory | `scripts/test/deploy-production.test.sh` |
| AC-7 | factory | `scripts/test/deploy-other.test.sh` |
| AC-8 | factory | `scripts/test/deploy-start.test.sh` |
| AC-9 | factory | `scripts/test/deploy-production.test.sh` |
| AC-10 | factory | `scripts/test/deploy-push-ci.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: 10 acceptance criteria and more than 8 files.
- Seven test files, one per issue heading: keeps each file small and lets `TEST_JOBS=4` run them in parallel.
- AC-8/9/10 are suite-wide; each is mapped to one representative file, and every file asserts exit code plus fake-gh records.

## Open questions
- none
