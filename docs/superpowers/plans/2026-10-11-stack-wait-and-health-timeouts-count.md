# Stack wait and health timeouts count seconds — plan for #1

**Goal:** `stack_wait` (and `FACTORY_STACK_WAIT`) and `stack.timeout` are wall-clock limits in `gate.sh stack up`, measured with `$SECONDS` deadlines instead of loop passes.

**Spec:** `docs/superpowers/specs/2026-10-11-stack-wait-and-health-timeouts-count-design.md`

**Layers:** `factory` only (path `./`, agent `engineer`, Bash and Python 3).

## Constraints

- No contract changes shape: the URL on stdout, exit codes 0 and 3, both give-up messages (`stack: no free slot after <WAIT>s`, `stack: not healthy after <TIMEOUT>s at <url>`), the config keys and their defaults stay as they are.
- `$SECONDS` only: no `date` call and no new process per pass for the deadline.
- `scripts/test/gate-stack.test.sh`, `scripts/test/stack-lock.test.sh` and `scripts/test/dispatch-stack.test.sh` keep passing unchanged.
- Minimal change: no new config key, no dead code, no narrating comments; the two function header comments stay accurate.

## Tasks

### Task 0 — Acceptance tests (QA, before any implementation)

- **Owner:** `qa-engineer`
- **Files:** creates `scripts/test/gate-stack-deadline.test.sh`
- AC-1 to AC-7 from the spec, following its test notes: same setup as `scripts/test/gate-stack.test.sh`, elapsed time measured with `date +%s` around the call, the `date` shim for AC-2, a `$FACTORY_PYTHON` socket server that accepts and never answers for AC-3 and AC-4.
- Must fail on the current code for the timing ACs (AC-2, AC-3, AC-4 at least) with a message that names the limit that was overrun.

### Task 1 — Wall-clock deadlines in `scripts/lib/stack.sh`

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 0
- **Files:** changes `scripts/lib/stack.sh` only

`stack_lease`:
- Replace the `waited` counter with `deadline=$(( SECONDS + WAIT ))`, set on entry.
- A pass stays as it is (drop dead tickets, try the slots when first in the queue). After a failed pass, give up when `SECONDS >= deadline`: same message, same ticket and trap cleanup, `return 3`.
- The slots are tried once before any give-up, so a free slot is taken with `stack_wait: 0`.
- The "waiting, position X of Y" line is timed by the clock: print when `SECONDS >= note`, then `note=$(( SECONDS + 60 ))`; the first pass still prints it.
- `sleep 1` between passes stays.

Health wait in `stack_up`:
- After `stack.up` succeeds: `deadline=$(( SECONDS + TIMEOUT ))`; a `healthy` flag replaces the `i >= TIMEOUT` test and the `i` local goes away.
- Each probe is capped at the time left: `curl -fsS -m <min(5, deadline - SECONDS), at least 1>`.
- Healthy (empty health URL, or a 2xx body that does not match `stack.reject`) stops the wait. Otherwise give up when `SECONDS >= deadline`: same message, `up.log` tail, `slot_down`, `slot_release`, `return 3`. Else `sleep 1` and probe again.
- At least one probe always runs.

**Done when:** every acceptance test in `scripts/test/gate-stack-deadline.test.sh` passes and the whole suite (`TEST_JOBS=4 bash scripts/test/run.sh`) is green.

## Review focus

- `stack_wait: 0` and `stack.timeout: 0` still try the slots and probe once.
- The curl cap never goes below 1 (`-m 0` means no limit).
- The trap and ticket cleanup on the give-up path of `stack_lease` are unchanged.
