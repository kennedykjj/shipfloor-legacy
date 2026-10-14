# Port deploy.sh to Python — spec

**Issue:** #167 · **Branch:** `feat/167-port-deploy-sh-to-python` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** `deploy.sh` merges to main and opens reverts, so a mistake reaches production. This issue ports it to `shipfloor_core/deploy.py` and keeps `deploy.sh <n> [--refresh|--continue]` as a thin wrapper. Its behavior must not change at all.

**Audience:** the factory's owner, whose Staged cards are merged and deployed by this stage; other developers who install the plugin rely on the same behavior.

**Acceptance criteria**
- AC-1 Given any deploy scenario, when `deploy.sh <n>` runs (fresh, `--refresh` or `--continue`), then exit codes 0/2/3/4/5/6 mean what they mean today, the 15 config values keep their order and defaults (anything else exits 2), and the `deploy #n: …` lines, `CONFLICT <file>` lines and markers are unchanged, with only usage and config errors on stderr.
- AC-2 Given any outcome, when the stage comments on the issue, then every comment text (`Factory deploy stopped:`, `Back to Coding:`, `Back to Staged: … staged-head:`, `Production deploy failed: … Revert PR:`, `Deployed: merge …`) is unchanged, and the `deploy-merge:` and `deploy-fix:` records are posted before the push.
- AC-3 Given a Staged card, when approval is checked, then the newest `staged-head:` by the factory's own user wins (CR stripped) and the approved chain is walked over at most 10 first-parent steps: every commit is recorded and any second parent is on `origin/main`.
- AC-4 Given the lock and `tmp/<n>/fix.*`, when deploy runs, then a live pid exits 2, a dead pid is taken over, the lock goes on exit (exit-3 paths remove it explicitly), a fresh run clears `fix.*`, rounds stop at 2, and exit 3 leaves the worktree mid-merge for `--continue` to verify with `merge-tree --write-tree` against the recorded parents.
- AC-5 Given main moves or conflicts, when the merge loop runs, then it makes up to 3 attempts, renumbers migrations per layer into one `chore(migration): renumber above <main>'s newest` commit, sends migration conflicts and too many files or hunks back to Coding, runs the same fast gates (`forbidden` only on `revert/*`), applies the same fix-size rules, and pushes with `--force-with-lease` after re-checking the board status.
- AC-6 Given CI, when local and GitHub checks run, then `local_ci` keeps its timeout (124) and fallback, `wait_checks` keeps its fixed 30 minutes, head-count filter, two-poll green, 10-empty-poll rule under `allow_no_checks`, exact-name required checks and failure keywords, and CI findings keep their 150-line tails.
- AC-7 Given a green PR, when it merges and production is judged, then merge uses `--squash --match-head-commit` (a failure counts if the PR is `MERGED`), `RESUMED` judges the current `origin/main` head, production CI gets one `rerun --failed`, the `deploy.environment` statuses and 5-try health checks behave as today; on failure a `revert/<n>` PR is opened from a fresh worktree without force, its `staged-head` is in the comment, the issue is reopened and labelled `blocked`, and the card is not moved.
- AC-8 Given the existing suite, when it runs with `FACTORY_POLL=0`, then every `deploy-*.test.sh`, the #159 tests and `dispatch-review.test.sh` (driving the new `deploy.sh` through the exit-3 loop) pass with no edits, and a differential test replaying every deploy scenario against the Bash `deploy.sh` (kept as a fixture) and the new one finds identical exit codes, fake-gh call logs (including comment-versus-push order) and remote git state.

**Out of scope:** any behavior change, new option, message or config value; porting `dispatch.sh` or other scripts; changes to the dashboard or board columns; removing the Bash `deploy.sh` fixture.

**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim): the deploy gate keeps every rule pinned by tests, and the differential test proves the port rather than asserting it. No conflict with the positioning or scope.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. No endpoint or event changes; the contracts are `deploy.sh <n> [--refresh|--continue]` (exit codes, markers, comments, as in the issue) and `deploy.run(argv) -> int`.

**Depends on** #162 (package `shipfloor_core`: `proc.git/gh`, `text.say`, `text.ere_match`, `project.*`, `fs.lock_dir/write_atomic`, `scripts/lib/py.sh`, `templates/py-wrapper.sh`), #163 (`board` in Python) and #159 (the deploy scenario tests). None is on main yet: develop must wait for all three to merge, and must reuse their helpers, not duplicate them.

**New files**
- `scripts/shipfloor_core/deploy.py`: one function per Bash function (`say`, `comment`, `reset_worktree`, `block`, `back_to_coding`, `merge_main`, `check_resolution`, `renumber_migrations`, `hand_fix`, `check_fix`, `ci_findings`, `fast_gates`, `local_ci`, `wait_checks`, `push_recorded`, production, revert); exits through a `DeployExit(code)` exception so the lock is removed in one `finally`, except on the exit-3 paths, which remove it explicitly first.
- `scripts/test/fixtures/deploy-bash.sh`: a verbatim copy of today's `scripts/deploy.sh`, kept as the differential baseline.
- `scripts/test/deploy-differential.test.sh`: replays every scenario of the `deploy-*.test.sh` suite against the fixture and the new `deploy.sh`; compares exit code, the fake gh's full call log (comment-before-push order) and the remote's git state.

**Changed files**
- `scripts/deploy.sh`: becomes the wrapper from `templates/py-wrapper.sh` (`exec` into `sf.py deploy "$@"`).
- `scripts/sf.py`: registers the `deploy` command.

**Behavior notes for the port:** the external commands stay the same processes with the same argv (`git`, `gh`, `curl`, `timeout`, `bash gate.sh`, `board.sh`) so the fake gh's call log matches byte for byte; `FACTORY_GH`, `FACTORY_BOARD`, `FACTORY_CURL`, `FACTORY_POLL`, `FACTORY_POLLS` keep their meaning; `wait_checks` keeps the fixed 1800 s; the `grep -E` patterns go through `text.ere_match`.

**Migration:** none; the wrapper keeps the same CLI. Rollback is reverting the commit (the Bash script is the fixture and in git history).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/deploy-differential.test.sh` |
| AC-2 | factory | `scripts/test/deploy-differential.test.sh` |
| AC-3 | factory | `scripts/test/deploy-differential.test.sh` |
| AC-4 | factory | `scripts/test/deploy-differential.test.sh` |
| AC-5 | factory | `scripts/test/deploy-differential.test.sh` |
| AC-6 | factory | `scripts/test/deploy-differential.test.sh` |
| AC-7 | factory | `scripts/test/deploy-differential.test.sh` |
| AC-8 | factory | `scripts/test/deploy-differential.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: 8 criteria on a path that merges to main, more than 6 acceptance criteria.
- One differential test file for all ACs: it replays the whole suite's scenarios, so each AC is covered by the same replay; the pinned per-AC cases already live in the `deploy-*.test.sh` files from #159.
- The Bash script is kept as `scripts/test/fixtures/deploy-bash.sh` so the baseline cannot drift with the port.
- Dependencies #159, #162, #163 are not merged yet; develop starts only after they are (their specs define the helpers this port uses).

## Open questions
- none
