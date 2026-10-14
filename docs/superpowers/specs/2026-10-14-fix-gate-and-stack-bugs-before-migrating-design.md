# Fix before migrating: gate and stack bugs (stack up hangs in pt-BR, needs_stack gates lose their verdict) — spec

**Issue:** #156 · **Branch:** `feat/156-fix-gate-and-stack-bugs-before-migrating` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** standard

## Product
_Product Owner_

**Problem:** Three Bash bugs would be copied into the Python port (#153): `gate.sh stack up` hangs in non-English projects, `red`/`green` on `needs_stack` layers lose their verdict and `last-gate`, and a signal while queued for a slot is ignored until the deadline.
**Audience:** Factory owners running non-English projects or `needs_stack` layers; the dispatcher, which reads `last-gate`.
**Acceptance criteria**
- **AC-1** — Given `language: pt-BR` and a free slot, when `url=$(gate.sh stack up x)` runs, then it returns the URL in under 5 s.
- **AC-2** — Given a `needs_stack: true` layer, when `gate.sh green <layer> <sel>` finishes (pass or fail), then its last stderr line is `gate green: pass` or `gate green: FAIL (exit 1)` and `$SHIPFLOOR_RUN_LOCK/last-gate` holds `green<TAB>pass|FAIL`; the same for `red`.
- **AC-3** — Given AC-2 in English and in pt-BR, when each runs, then both behave the same.
- **AC-4** — Given a `needs_stack` green is running, when it receives SIGTERM, then `gate.sh stack status` shows its slot `free`.
- **AC-5** — Given a gate is queued for a slot, when it receives INT or TERM, then its ticket is removed and it exits 3.
**Out of scope:** The Python port itself; any change to queue ordering, deadlines or slot reclaim.
**Product fit:** Fixes correctness of the pipeline's gates before the port copies them.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Contracts: no public interface changes. `gate.sh stack up|down|status`, `red`, `green` keep their arguments, output and exit codes. Exit 3 on INT/TERM in the queue is the existing "infrastructure" code.

Layer: `factory` only.

Files:
- `scripts/lib/stack.sh` — `stack_up`: the heartbeat subshell also closes the inherited fds (`3>&- 4>&- … 9>&-`, plus `</dev/null`) so it never holds the caller's `$(...)` open, in both modes. `stack_lease`: stop using `trap ... EXIT INT TERM` and `trap -`. Save the caller's INT/TERM traps (`trap -p INT TERM`), install `rm -f "$t"; exit 3` for INT/TERM only, and restore the saved traps on every return path (success, deadline). No EXIT trap: a ticket whose pid is gone is already swept by the queue loop.
- `scripts/gate.sh` — `stack_around`: the INT/TERM handler does `stack_down "$owner"` and then exits 3, so the slot is released and the EXIT `verdict` trap (installed at line 545) still fires. The runner is waited on so a signal is handled while it runs (bash defers traps until the foreground command ends: run `"$@"` in the background and `wait` it, or equivalent).
- `scripts/test/gate-stack-lang.test.sh` (new), `scripts/test/gate-stack-verdict.test.sh` (new), `scripts/test/stack-signal.test.sh` (new): see Test plan; reuse the fixture/`machine`/`project` helpers of `gate-stack-deadline.test.sh`.

Migration: none. Rollback: revert the commit.

## Test plan
_Tech Lead_

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-stack-lang.test.sh` |
| AC-2 | factory | `scripts/test/gate-stack-verdict.test.sh` |
| AC-3 | factory | `scripts/test/gate-stack-verdict.test.sh` |
| AC-4 | factory | `scripts/test/stack-signal.test.sh` |
| AC-5 | factory | `scripts/test/stack-signal.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
- Signal in the queue exits 3 and the in-run handler exits 3 too: both are interruptions, and the dispatcher treats 3 as infrastructure and retries.
- No EXIT trap in `stack_lease`: stale tickets are already swept by the pid check, so there is nothing to clean on exit.
- Fds closed by explicit `N>&-` on the heartbeat (3 to 9): portable in Bash, and fd 3 is the only extra fd the gate opens.
- Weight standard: one layer, but 5 ACs and 5 files, with a trap/backgrounding change in a hot path.

## Open questions
- none
