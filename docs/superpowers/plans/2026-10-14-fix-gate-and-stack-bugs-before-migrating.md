# Plan — #156 fix gate and stack bugs before migrating

Spec: `docs/superpowers/specs/2026-10-14-fix-gate-and-stack-bugs-before-migrating-design.md`

Layer: `factory` only (agent: engineer). Tasks run one at a time in the shared worktree.

## Task 1 — `scripts/lib/stack.sh` (AC-1, AC-5)
Depends on: acceptance tests.
- `stack_up`: the heartbeat subshell closes inherited fds (`3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-`) and reads `</dev/null`, in both modes, so it never holds the caller's `$(...)` open.
- `stack_lease`: drop `trap ... EXIT INT TERM` and `trap -`. Save the caller's INT/TERM traps (`trap -p INT TERM`), install `rm -f "$t"; exit 3` for INT/TERM only, restore the saved traps on every return path (success, deadline).

## Task 2 — `scripts/gate.sh` (AC-2, AC-3, AC-4)
Depends on: task 1.
- `stack_around`: run the runner in the background and `wait` it so INT/TERM is handled while it runs; the handler calls `stack_down "$owner"` and exits 3, so the slot is released and the EXIT `verdict` trap still fires with `last-gate` written.
- Same behavior in English and pt-BR (no text matching on localized output).

## Tests (QA, before implementation)
- `scripts/test/gate-stack-lang.test.sh` (AC-1)
- `scripts/test/gate-stack-verdict.test.sh` (AC-2, AC-3)
- `scripts/test/stack-signal.test.sh` (AC-4, AC-5)
Reuse the fixture/`machine`/`project` helpers of `gate-stack-deadline.test.sh`.
