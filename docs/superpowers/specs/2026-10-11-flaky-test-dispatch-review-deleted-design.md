# Flaky test: dispatch-review 'deleted another run's lock' — spec

**Issue:** #9 · **Branch:** `feat/9-flaky-test-dispatch-review-deleted` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** The case "a run removes only its own lock" in `scripts/test/dispatch-review.test.sh` fails now and then under a loaded parallel suite (`locks/refine-25.lock/info: No such file or directory`, reported as "deleted another run's lock"). The test simulates the takeover inside a fixed 4-second window; when the machine stalls past it, the run has already ended and removed its own lock. The dispatcher is correct; the red is false, and a suite that goes red without a defect stops being believed.
**Audience:** The factory's owner, who runs the suite on their own machine and whose pipeline gates run it.
**Acceptance criteria**
- **AC-1** — Given a live run holds `refine-25.lock` and its `info` is rewritten to name another owner, when the run ends, then the lock directory still exists and `info` still names the other owner.
- **AC-2** — Given the same case, when the test writes the takeover, then the run is verifiably still live at that moment (its log has no `== end` yet) because the test, not a fixed duration, decides when the run ends.
- **AC-3** — Given a live run holds `refine-25.lock` and nobody rewrites `info`, when the run ends, then the lock directory is gone (the case cannot pass by the dispatcher never removing locks).
- **AC-4** — Given the run never starts or never ends, when the case waits for it, then it fails within a bounded time with a message naming what it waited for, instead of hanging the suite.
- **AC-5** — Given the fix is in place, when `bash scripts/test/run.sh dispatch-review.test.sh` runs, then every other case in the file still passes.
- **AC-6** — (by hand, in review) Given the fix is in place, when the full suite runs 20 times with `TEST_JOBS=16 bash scripts/test/run.sh`, then `dispatch-review.test.sh` passes 20 out of 20.
**Out of scope:** Changing how `scripts/dispatch.sh` takes, reclaims or removes locks (no production defect was found; if one turns up while fixing the test, it gets its own issue). Hunting other timing-dependent tests in the suite. Making the suite faster or changing the default `TEST_JOBS`.
**Product fit:** Serves principle 2, "Deterministic gates outrank any agent's claim": the gates are only as deterministic as the tests they run, and a test that depends on machine load is not. No conflict with the positioning or the out-of-scope list.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Cause.** `scripts/test/dispatch-review.test.sh:31-35` starts a run whose fake agent sleeps 4 s, then writes the takeover into `locks/refine-25.lock/info`. When the test stalls past 4 s, the run has ended and removed its own lock (`scripts/dispatch.sh:123-124`), the write fails and the case reports a deletion that never happened. The case also has a second, silent weakness: it asserts right after `== end` appears in the log, but the run decides about its lock later (after `stack_release_run` and `shipfloor_clean_tmp`), so a dispatcher that did delete the lock could still pass.

**Contracts touched** (test helpers only; no endpoint, event or factory script changes)
- `scripts/test/lib.sh` — new `wait_for <what> <command...>`: runs the command every 0.1 s until it succeeds (returns 0), or until `TEST_WAIT_SECS` seconds have passed (default 60, measured with `$SECONDS`); on timeout calls `fail "timed out waiting for <what>"` and returns 1.
- `scripts/test/dispatch-review.test.sh` — the fake agent in `setup` drops `CLAUDE_SLEEP`: when `CLAUDE_HOLD` names a file, it waits until that file exists (bounded by `TEST_WAIT_SECS`, so a failed case leaves no process behind); unset, it returns at once as today.

**The case, in order** (every wait is a `wait_for`)
1. `setup`; `export CLAUDE_HOLD="$tmp/release"`; `bash "$D"`.
2. Wait for `$tmp/launched` to be non-empty; read the run's pid from the first field of `locks/refine-25.lock/info`.
3. Takeover (AC-1, AC-2): assert the log has no `== end`, write `99999 <now> 30` into `info`, assert again that the log has no `== end`.
4. `touch "$tmp/release"`; wait for the run's pid to be gone (`kill -0` fails), not for the `== end` line: only then has the run made its decision about the lock.
5. Assert the lock directory exists and `info` still starts with `99999`.
6. Counterpart (AC-3): same steps 1, 2 and 4 without the takeover; wait for the lock directory to be gone.

**Layers and modules:** `factory` only — `scripts/test/lib.sh` (engineer), `scripts/test/dispatch-review.test.sh` and the new `scripts/test/lib-wait.test.sh` (QA). `scripts/dispatch.sh` is not changed.

**Migration plan:** none; no data, no installed file changes behaviour (the test folder is not part of a run).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dispatch-review.test.sh` |
| AC-2 | factory | `scripts/test/dispatch-review.test.sh` |
| AC-3 | factory | `scripts/test/dispatch-review.test.sh` |
| AC-4 | factory | `scripts/test/lib-wait.test.sh` |
| AC-5 | factory | `scripts/test/dispatch-review.test.sh` |
| AC-6 | manual | `scripts/test/dispatch-review.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Fix the test, not the dispatcher: a run removes a lock only while `info` names its own pid, and `lock_live` never reclaims a lock whose process is alive, so no production race was found.
- The test decides when the run ends (a release file), instead of a longer sleep: a longer window only makes the flake rarer.
- The case waits for the run's process to exit, not for `== end`: the lock decision comes after that log line, so the old assertion could pass against a dispatcher that deletes.
- AC-3 added as counterpart: without it the case would pass if the dispatcher never removed any lock.
- AC-4 kept (bounded waits): the case's two `until` loops hang the whole suite today when the run never starts; the bound lives in one helper, `wait_for`, in `scripts/test/lib.sh`.
- `wait_for` is bounded by elapsed seconds, not by a number of tries: under load a `sleep 0.1` takes far longer than 0.1 s, which is the same mistake as the fixed window.
- AC-4 is tested in its own file, `scripts/test/lib-wait.test.sh`, with `TEST_WAIT_SECS=1` in a subshell, so the expected `FAIL` line does not count against the file.
- `run_dispatch` and the other tests' own waits are left alone: out of scope, and none of them is reported flaky.
- AC-6 (20 full runs with `TEST_JOBS=16`) is checked by hand in review: about 20 × 5 min, too long for a gate.

## Open questions
- none
