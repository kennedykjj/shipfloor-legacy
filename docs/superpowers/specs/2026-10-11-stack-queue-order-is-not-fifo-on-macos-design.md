# Stack queue order is not FIFO on macOS — spec

**Issue:** #3 · **Branch:** `feat/3-stack-queue-order-is-not-fifo-on-macos` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** Runs waiting for a stack slot are meant to be served in arrival order, but the queue ticket relies on `date +%s%N`. Where `date` has no `%N` (macOS), waiters that arrive in the same second are served by owner name, so a later run can take a slot ahead of an earlier one.
**Audience:** Developers who install the plugin and run the factory on macOS; the owner on any platform, who gets the same order everywhere.
**Acceptance criteria**
- **AC-1** — Given a `date` without `%N`, all slots taken, and two waiters arriving in the same second with the later one's owner name sorting first, when a slot frees, then the earlier arrival gets it.
- **AC-2** — Given a `date` without `%N` and three waiters arriving in the same second, when slots free one at a time, then they are taken in arrival order.
- **AC-3** — Given a `date` that supports `%N`, when the scenario of AC-1 runs, then the earlier arrival still gets the slot.
- **AC-4** — Given more than ten waiters queued in the same second, when slots free one at a time, then the tenth and later arrivals are served after the ninth, not before the second.
- **AC-5** — Given waiters that arrive in different seconds, when a slot frees, then the earlier arrival gets it on either kind of `date`.
- **AC-6** — Given the first waiter in the queue is gone (its process ended), when a slot frees, then the next waiter in arrival order gets it.
- **AC-7** — Given two waiters queued in the same second on a `date` without `%N`, when they report their wait, then the earlier one says position 1 and the later one position 2.
**Out of scope:** Priority or fairness between projects or stages; changes to slot count, wait time, heartbeat or reclaim rules; the order of tickets written by an older version still in the queue at upgrade time; any guarantee between arrivals that are truly simultaneous beyond a stable order with one position each; the dashboard.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): who gets the next slot must follow from arrival, not from a platform's `date` or an owner's name. Keeps the Operating Context promise that the factory behaves the same on Windows, macOS and Linux. No conflict with the positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts touched**
- `stack_lease <owner>` in `scripts/lib/stack.sh`: same arguments, same `SLOT`, same exit codes, same `stack: waiting, position X of Y` line. Only the ticket's name changes.
- Ticket name (internal, in `<home>/locks/stack-queue/`): from `<date +%s%N>-<owner>` to `<seq>-<owner>`, where `<seq>` is a sequence number zero-padded to 19 digits. The ticket's content (`<pid> <run lock>`) does not change.
- No endpoint, event, config key or CLI output changes. `stack status` still counts the tickets with `ls`.

**How the sequence is taken**
- A new helper in `scripts/lib/stack.sh`, `queue_ticket <owner>`, creates the ticket and prints its path. `stack_lease` calls it in place of the `date +%s%N` line.
- Under a `mkdir` lock at `<queue>/.lock`: read the highest leading number among the tickets in the queue (base 10, `10#`), add 1, write the ticket, `rmdir` the lock. An empty queue starts at 1.
- The lock is a dot-directory, so `ls "$q"` and the `"$q"/*` loop never see it: the queue length and the dead-ticket sweep stay as they are.
- A waiter that cannot take the lock retries every 0.1 s; after 50 tries (5 s) it removes the lock as left behind by a dead process and tries again.
- `date` is no longer read to name a ticket, so the order does not depend on the platform's `date`.

**Layers and modules**
- `factory`: `scripts/lib/stack.sh` (change), `scripts/test/stack-queue.test.sh` (new). `scripts/test/gate-stack.test.sh` stays green without edits.

**Migration plan:** none. No stored data changes shape; the queue holds only tickets of live waiters, and a ticket lives at most `stack_wait` seconds.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/stack-queue.test.sh` |
| AC-2 | factory | `scripts/test/stack-queue.test.sh` |
| AC-3 | factory | `scripts/test/stack-queue.test.sh` |
| AC-4 | factory | `scripts/test/stack-queue.test.sh` |
| AC-5 | factory | `scripts/test/stack-queue.test.sh` |
| AC-6 | factory | `scripts/test/stack-queue.test.sh` |
| AC-7 | factory | `scripts/test/stack-queue.test.sh` |

- "A `date` without `%N`" is a `date` stub first in `PATH` that prints the seconds followed by a literal `N` for `+%s%N` and passes every other call to the real `date`.
- Same-second arrival is made by starting the next waiter as soon as the previous ticket is in the queue directory (poll the directory, no `sleep 1` between them), with owner names chosen so the later arrival sorts first.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Sequence under `mkdir`, not a nanosecond time from python3 — a sequence gives a strict order; a clock can still tie (coarse timers on Windows) and costs a python start per waiter.
- The next number is the highest in the queue plus 1, with no counter file — nothing to lose or corrupt, and the queue restarts at 1 when it empties.
- 19 digits, zero-padded — the tenth waiter sorts after the ninth (AC-4), and a ticket written by the old version on Linux or Git Bash (19 digits) still sorts before a new one.
- Old tickets written on macOS (`<seconds>N`) are not reordered — out of scope: they are gone within one `stack_wait`.
- The lock is `<queue>/.lock`, not a `stack-*.lock` beside the slots — code that walks `stack-*.lock` must never take it for a slot.
- A lock held for 5 s is removed — the lock is held for milliseconds, so one that old belongs to a dead process; the worst case of a wrong removal is two tickets with the same number, ordered by owner name as today.
- Criteria phrased against "a `date` without `%N`", not a real Mac — a shell test can check them on any platform with a stubbed `date`.
- AC-3, AC-5 and AC-6 are regression criteria — they already pass before the fix; AC-1, AC-2, AC-4 and AC-7 are the ones that must fail first.
- All criteria in one new test file — `scripts/test/gate-stack.test.sh` waits a second between waiters by design and stays as the slot test.
- `stat -c %Y` in `slot_state` is also not portable to macOS — left out: another defect, to be filed as its own issue.

## Open questions
- none
