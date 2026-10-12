# Flaky test: dispatch-review 'deleted another run's lock' — plan

**Issue:** #9 · **Branch:** `feat/9-flaky-test-dispatch-review-deleted`
**Spec:** `docs/superpowers/specs/2026-10-11-flaky-test-dispatch-review-deleted-design.md`

One layer, `factory`. The fix lives almost entirely in the tests: QA rewrites the flaky case against a helper that does not exist yet, and the engineer writes the helper.

## Acceptance tests (QA, before any task)

| File | ACs | What it holds |
|---|---|---|
| `scripts/test/dispatch-review.test.sh` | AC-1, AC-2, AC-3, AC-5 | The fake agent in `setup` drops `CLAUDE_SLEEP` and waits for the file named by `CLAUDE_HOLD` (bounded by `TEST_WAIT_SECS`; unset, it returns at once). The case "a run removes only its own lock" follows the spec's six steps, every wait a `wait_for`; the counterpart case waits for the lock directory to be gone. The other cases stay as they are. |
| `scripts/test/lib-wait.test.sh` (new) | AC-4 | `wait_for` returns 0 as soon as its command succeeds; with `TEST_WAIT_SECS=1` in a subshell and a command that never succeeds it returns 1 within a bounded time and prints `FAIL timed out waiting for <what>`. |

Red before the implementation: both files fail because `wait_for` is missing from `scripts/test/lib.sh`.

## Tasks

### Task 1 — `wait_for` in the test helpers
- **Layer:** factory · **Owner:** engineer · **Depends on:** the acceptance tests
- **Files:** `scripts/test/lib.sh`
- **What:** add `wait_for <what> <command...>`: runs the command every 0.1 s until it succeeds (returns 0), or until `TEST_WAIT_SECS` seconds have passed (default 60, measured with `$SECONDS`, not a number of tries); on timeout calls `fail "timed out waiting for <what>"` and returns 1. The command's own output is discarded. Comment style as the helpers beside it (`name() {  # name <args>: what it does`).
- **Not touched:** `scripts/dispatch.sh`, `run_dispatch`, any other test's waits.

## Checks
- After the task: `scope factory`, `acceptance-intact`, `migration`, `build` (the full suite, `TEST_JOBS=4`).
- At the end: `green factory scripts/test/dispatch-review.test.sh` and `green factory scripts/test/lib-wait.test.sh`.
- AC-6 (20 full runs with `TEST_JOBS=16`) is checked by hand in review, as the spec decides.
