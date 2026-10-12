# A project without stack.up shrinks the stack slots for every project — spec

**Issue:** #2 · **Branch:** `feat/2-a-project-without-stack-up-shrinks-the` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** A project that starts no stack of its own (`stack.up` empty) caps the slot count at 1 for whoever is at the head of the machine-wide queue, so other projects' runs wait while slots sit free; `shipfloor pool` and the dashboard, which read slots through the first registered project, then report 1 slot on a machine that has 3.
**Audience:** The factory's owner and other developers who run Shipfloor with more than one project on one machine.
**Acceptance criteria** (machine `stacks: 3`; project A has no `stack.up`, project B has one)
- **AC-1** — Given a run of A holds its stack lease, when a run of B asks for a stack, then B gets a free slot without waiting for A.
- **AC-2** — Given a run of A holds its stack lease and other slots are free, when a second run of A asks for a stack, then it waits and holds no slot while it waits.
- **AC-3** — Given a second run of A waits at the head of the queue with a ticket of B behind it, when a slot is free, then B's run gets it without waiting for A's turn.
- **AC-4** — Given a second run of A waits, when A's first run releases its stack (`stack down`), then the waiting run gets its lease.
- **AC-5** — Given a run of A ended without releasing its stack, when A's next run asks for a stack, then it gets a lease instead of waiting for the dead one.
- **AC-6** — Given a second run of A is still waiting after `stack_wait` seconds, when the wait ends, then it exits 3 with the "no free slot" message and leaves no ticket in the queue.
- **AC-7** — Given `gate.sh stack status` is run from project A, when it prints, then it lists one line per machine slot (3), followed by the queue line.
- **AC-8** — Given A is the first registered project, when `shipfloor pool` runs, then it lists slots 0, 1 and 2, the same as when B is registered first.

**Out of scope:** changing the `stacks` default or how it is set (`shipfloor pool stacks <n>`); a per-project slot quota or priority between projects; fairness beyond the existing ticket order; any new or changed dashboard element (it shows the corrected count through the existing "Stacks n / m").
**Product fit:** Principle 3, numbers are exact and sourced: the slot count shown is the machine's, not one project's view of it. It also keeps principle 2: a slot lease stays a deterministic lock, and a project with one fixed environment still runs one stack-needing run at a time. No conflict with the positioning or its limits.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. No config key, CLI argument, exit code or output format changes.

**Files**
- `scripts/lib/stack.sh` (change): the whole fix.
- `scripts/test/gate-stack-solo.test.sh` (new): AC-1 to AC-7, two project configs on one `SHIPFLOOR_HOME`.
- `scripts/test/shipfloor-cli.test.sh` (change): AC-8.
- `scripts/shipfloor`, `scripts/dashboard.py`, `scripts/dashboard.html`: not changed; they keep asking `gate.sh stack status` through the first project, and the answer no longer depends on which one.

**Functions touched in `scripts/lib/stack.sh`**
- `stack_settings`: drops `[ -z "$UP" ] && STACKS=1`, so `STACKS` is always the machine's `stacks`. Sets `SOLO="$NAME"` when the project has no `stack.up`, `SOLO=-` otherwise.
- `stack_lease <owner>`: the ticket file becomes `<pid> <run> <solo>` (a ticket with two fields reads as `-`). A project is *busy* when some slot whose `solo` file names it is in state `busy`. A ticket is *blocked* when its `solo` is not `-` and that project is busy. The waiter takes a slot when every earlier ticket is blocked and its own is not (today: when it is the first ticket). On a lease it writes `info`, and `solo` (the project name) when `SOLO` is not `-`, both before it removes its ticket. Wait limit, exit 3, the "no free slot" message and ticket cleanup stay as they are.
- `slot_dir <k>/solo` (new file in the slot lock): the name of the no-`up` project that holds the slot; absent for a project with `up`. `info` keeps its three fields (`owner run epoch`), so `stack_status`, `stack_down`, `stack_release_run` and the dispatcher read it as before.
- `stack_status`, `stack_down`: no code change; they loop over `STACKS`, now the machine's count.

**How each rule falls out**
- A run of a no-`up` project still leases one machine slot (any free one), so it shows in `shipfloor pool` and counts against the machine's capacity; there is no separate project lock to go stale.
- A dead run's slot is `stuck`, not `busy`, so its project is not busy (AC-5); the existing reclaim in `stack_lease` frees the slot.
- Only the first unblocked ticket acts, and `solo` is written before the ticket goes, so two runs of one no-`up` project cannot both lease.

**Migration:** none. Slot locks and tickets are short-lived files; one written by the previous version has no `solo` (read as not solo) and is gone when its run ends.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-stack-solo.test.sh` |
| AC-2 | factory | `scripts/test/gate-stack-solo.test.sh` |
| AC-3 | factory | `scripts/test/gate-stack-solo.test.sh` |
| AC-4 | factory | `scripts/test/gate-stack-solo.test.sh` |
| AC-5 | factory | `scripts/test/gate-stack-solo.test.sh` |
| AC-6 | factory | `scripts/test/gate-stack-solo.test.sh` |
| AC-7 | factory | `scripts/test/gate-stack-solo.test.sh` |
| AC-8 | factory | `scripts/test/shipfloor-cli.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- A no-`up` project still runs one stack-needing run at a time: its runs share one environment that nothing isolates.
- A waiting run of a no-`up` project holds no slot and blocks no other project's ticket: otherwise the head-of-line blocking returns as soon as that project has two runs (one step past the issue's own acceptance).
- A run of a no-`up` project occupies one machine slot while it runs: `shipfloor pool` keeps showing who runs, and the stuck-slot reclaim covers a dead run with no new lock to maintain.
- "Project busy" is derived from the slots (`solo` file), not a separate per-project lock: one source of state, nothing extra to go stale.
- That run gets the ports and stack name of the slot it leased, not always slot 0's: slot 0 may belong to another project's stack at the same time.
- Projects are told apart by `project.name`: it is the registry slug, unique per machine.
- Another project's run may pass a waiting run of a no-`up` project more than once: fairness beyond ticket order is out of scope; `stack_wait` still bounds the wait.
- `info` keeps three fields and `solo` is a separate file: every current reader of `info`, and the tests that write it, stay valid.
- `shipfloor pool` and the dashboard still read slots through the first registered project: the count no longer depends on the project, so no change is needed there.
- No dashboard change and no UX section: the existing "Stacks n / m" shows the corrected count.

## Open questions
- none
