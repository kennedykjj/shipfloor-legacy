# Stack queue order is not FIFO on macOS — plan

**Issue:** #3 · **Branch:** `feat/3-stack-queue-order-is-not-fifo-on-macos`
**Spec:** `docs/superpowers/specs/2026-10-11-stack-queue-order-is-not-fifo-on-macos-design.md`

## Tasks

| # | Layer | Owner | Task | Files | Depends on |
|---|---|---|---|---|---|
| 0 | factory | qa-engineer | Acceptance tests for AC-1 to AC-7 | `scripts/test/stack-queue.test.sh` (new) | — |
| 1 | factory | engineer | Name queue tickets by a sequence taken under a `mkdir` lock | `scripts/lib/stack.sh` | 0 |

## Task 0 — acceptance tests (QA)

- One new file, `scripts/test/stack-queue.test.sh`, in the style of `scripts/test/gate-stack.test.sh` (same fixtures and `ok` / `FAIL` lines).
- "A `date` without `%N`": a `date` stub first in `PATH` that prints the seconds followed by a literal `N` for `+%s%N` and passes every other call to the real `date`.
- Same-second arrival: start the next waiter as soon as the previous ticket is in the queue directory (poll the directory, no `sleep 1` between waiters); owner names chosen so the later arrival sorts first.
- AC-1, AC-2, AC-4 and AC-7 must fail before the fix; AC-3, AC-5 and AC-6 are regression criteria and already pass.

## Task 1 — sequence ticket (engineer)

In `scripts/lib/stack.sh`:

- New helper `queue_ticket <owner>`: creates the ticket in `$STACK_LOCKS/stack-queue` and prints its path.
  - Takes a `mkdir` lock at `<queue>/.lock`; retries every 0.1 s; after 50 tries removes the lock as left behind by a dead process and tries again.
  - Under the lock: the highest leading number among the tickets in the queue (read base 10, `10#`), plus 1; an empty queue starts at 1.
  - Ticket name `<seq>-<owner>`, `<seq>` zero-padded to 19 digits; content unchanged (`<pid> <run lock>`). The pid written is the waiter's, not a subshell's.
  - `rmdir` the lock before returning.
- `stack_lease` calls `queue_ticket` in place of the `date +%s%N` line. Arguments, `SLOT`, exit codes and the `stack: waiting, position X of Y` line do not change.
- The lock is a dot-directory: `ls "$q"` and the `"$q"/*` loop must keep not seeing it (queue length and dead-ticket sweep stay as they are).
- `date` is no longer read to name a ticket.

## Done when

- `scripts/test/stack-queue.test.sh` passes; `scripts/test/gate-stack.test.sh` stays green without edits.
- `TEST_JOBS=4 bash scripts/test/run.sh` passes.
