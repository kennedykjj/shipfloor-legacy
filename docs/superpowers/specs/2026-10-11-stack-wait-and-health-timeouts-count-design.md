# Stack wait and health timeouts count loop iterations, not seconds — spec

**Issue:** #1 · **Branch:** `feat/1-stack-wait-and-health-timeouts-count` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** `stack_wait` and `stack.timeout` are written in seconds but `gate.sh stack up` counts loop passes, so a slow pass (a hanging health probe, slow process starts on Windows) stretches the limit many times over: `stack.timeout: 900` can hold a slot and a run for about 90 minutes.
**Audience:** The factory's owner and other developers who install the plugin, who set these two numbers and wait on the runs they bound.
**Acceptance criteria**
- **AC-1** — Given `stack_wait: 3` and every slot busy, when `gate.sh stack up <owner>` runs, then it exits 3 with `stack: no free slot after 3s` on stderr, no earlier than 3 s and no later than 8 s after it started.
- **AC-2** — Given the same setup with each wait pass slowed to at least 2 s, when `gate.sh stack up <owner>` runs, then it still exits 3 no later than 8 s after it started.
- **AC-3** — Given `stack.timeout: 2` and a health URL that accepts the connection and never answers, when `gate.sh stack up <owner>` runs with a free slot, then it exits 3 with `stack: not healthy after 2s at <url>` on stderr, no earlier than 2 s and no later than 7 s after it started.
- **AC-4** — Given the health failure of AC-3, when `stack up` has exited, then `stack.down` ran for that slot and the slot is free.
- **AC-5** — Given a health URL that starts answering healthy before `stack.timeout` elapses, when `gate.sh stack up <owner>` runs, then it exits 0 and prints the stack URL without waiting for the rest of the limit.
- **AC-6** — Given every slot busy and one released before `stack_wait` elapses, when a waiting `gate.sh stack up <owner>` is running, then it takes the released slot and exits 0, and waiters still get slots in ticket order.
- **AC-7** — Given `FACTORY_STACK_WAIT=3` set over a larger `stack_wait` and every slot busy, when `gate.sh stack up <owner>` runs, then it exits 3 no later than 8 s after it started.
**Out of scope:** new config keys or changed defaults (`stack_wait` 1800, `stack.timeout` 300); the wording of the two give-up messages; `stack_stale`, `stack_hold_max` and the heartbeat; making the wait loop itself faster on Windows; the dashboard field that edits `stack_wait`.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim: a gate's limit must hold whatever the machine's speed) and principle 3 (numbers are exact and sourced: a limit labeled in seconds is seconds). No conflict with the positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer and files:** `factory` only. Changes `scripts/lib/stack.sh`; creates `scripts/test/gate-stack-deadline.test.sh`. No other file changes.

**Contracts touched:** none change shape. `gate.sh stack up <owner>` keeps its output (the URL), exit codes (0, 3) and both give-up messages; `stack_wait`, `FACTORY_STACK_WAIT` and `stack.timeout` keep their names, defaults and unit. Only what they measure changes: elapsed seconds instead of loop passes.

**`stack_lease <owner>`** (wait for a slot)
- On entry: `deadline=$(( SECONDS + WAIT ))`. The `waited` counter goes away.
- Each pass is as today (drop dead tickets, try the slots when first in the queue). After a failed pass, give up when `SECONDS >= deadline`: same message, same ticket and trap cleanup, return 3.
- The slots are always tried once before giving up, so a free slot is taken even with `stack_wait: 0`.
- The "waiting, position X of Y" line is timed by the clock too: print when `SECONDS >= note`, then `note=$(( SECONDS + 60 ))`; the first pass still prints it.
- `sleep 1` between passes stays.

**Health wait in `stack_up`**
- After `stack.up` succeeds: `deadline=$(( SECONDS + TIMEOUT ))`, and a `healthy` flag replaces the `i >= TIMEOUT` test.
- Each probe is capped at the time left: `curl -fsS -m <min(5, deadline - SECONDS), at least 1>`. Without the cap a hanging probe overruns the limit by up to 5 s.
- Healthy (empty health URL, or a 2xx body that does not match `stack.reject`) → stop waiting. Otherwise give up when `SECONDS >= deadline`: same message, `up.log` tail, `slot_down`, `slot_release`, return 3. Else `sleep 1` and probe again.
- At least one probe always runs, so an already healthy stack passes whatever the limit.

**Precision:** `$SECONDS` counts whole seconds, so a limit can fire up to 1 s early or late in real time, and one pass (or one probe, at most 5 s and never past the limit by more than 1 s) can overrun it. That is inside the tolerances of AC-1 to AC-3.

**Migration:** none (no data, no config change).

**Test notes** (`scripts/test/gate-stack-deadline.test.sh`, same setup as `scripts/test/gate-stack.test.sh`: private `SHIPFLOOR_HOME`, `stack_wait: 3`, config copied from the fixture)
- Elapsed time is measured by the test with `date +%s` around the call (whole seconds, same clock as `$SECONDS`, so "no earlier than" holds).
- AC-2: a `date` shim first on `PATH`, only for the measured call, that sleeps before answering `+%s` so one wait pass takes 3 s or more (`slot_state` calls it once per slot). The old loop needs four such passes (16 s or more); the new one gives up after the first.
- AC-3 and AC-4: a `$FACTORY_PYTHON` socket server on a free local port that accepts and never answers, as `stack.health`, with `stack.timeout: 2`; then assert the `down` call was recorded and `stack-0.lock` is gone.
- AC-5: `stack.timeout: 30` and a `file://` health body that a background job writes after about 1 s; `stack up` exits 0 well under 30 s.
- AC-6: two busy slots, two waiters a second apart, release one slot; the first waiter gets it and the second gets none.
- AC-7: `stack_wait: 60` in the machine config and `FACTORY_STACK_WAIT=3` in the environment.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-stack-deadline.test.sh` |
| AC-2 | factory | `scripts/test/gate-stack-deadline.test.sh` |
| AC-3 | factory | `scripts/test/gate-stack-deadline.test.sh` |
| AC-4 | factory | `scripts/test/gate-stack-deadline.test.sh` |
| AC-5 | factory | `scripts/test/gate-stack-deadline.test.sh` |
| AC-6 | factory | `scripts/test/gate-stack-deadline.test.sh` |
| AC-7 | factory | `scripts/test/gate-stack-deadline.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- `$SECONDS` deadlines, not `date +%s` or `EPOCHREALTIME`: the issue asks for it, it costs no process per pass, and 1 s precision is enough for limits of minutes.
- Each health probe is capped at the time left (minimum 1 s): otherwise a hanging URL overruns `stack.timeout` by up to 5 s and AC-3 cannot hold.
- The slots are tried once and the health URL is probed once before any give-up: a limit of 0 or a slow start must not fail a run that could have succeeded.
- The "waiting, position" line moves to a clock-based 60 s interval: it was tied to the counter being removed, and slow passes would otherwise make it rarer.
- Tolerance is +5 s over the limit in the tests: a correct run ends within about 1 s of the limit plus gate start (about 0.6 s measured here), and the old loop takes 12 s or more in the same cases.
- AC-2's slow pass is 3 s (the AC asks for at least 2 s): with a pass as long as the limit the new code gives up after one pass, which keeps the 8 s bound safe on a slow machine.
- All seven ACs go in one new test file, `scripts/test/gate-stack-deadline.test.sh`: the timing cases need their own config and shims, and `scripts/test/gate-stack.test.sh` stays as it is.
- Defaults, config keys, both give-up messages and the dashboard field do not change: the bug is only in what the numbers measure.
- No UX and no Cybersec section: no screen changes and the issue has neither the `ui` nor the `cybersec` label.

## Open questions
- none
