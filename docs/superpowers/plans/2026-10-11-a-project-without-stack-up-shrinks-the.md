# A project without stack.up shrinks the stack slots for every project — plan

**Issue:** #2 · **Spec:** `docs/superpowers/specs/2026-10-11-a-project-without-stack-up-shrinks-the-design.md`
**Branch:** `feat/2-a-project-without-stack-up-shrinks-the`

One layer (`factory`), one implementation task. The acceptance tests come first and are QA's.

## Acceptance tests (QA, before any implementation)

- `scripts/test/gate-stack-solo.test.sh` (new): AC-1 to AC-7. Two project configs (A without `stack.up`, B with one) on one `SHIPFLOOR_HOME`, machine `stacks: 3`. Follow the setup of `scripts/test/gate-stack.test.sh`; keep waits short with `FACTORY_STACK_WAIT`.
- `scripts/test/shipfloor-cli.test.sh` (change): AC-8, next to "pool shows the stack slots": with a project that has no `stack.up` registered first, `shipfloor pool` lists slots 0, 1 and 2.

## Tasks

### T1 — the slot count is the machine's, and a no-`up` project serializes only itself

- **Layer:** factory · **Owner:** engineer · **Depends on:** the acceptance tests
- **Files:** `scripts/lib/stack.sh` (only this file)
- **What**
  1. `stack_settings`: remove `[ -z "$UP" ] && STACKS=1`. Set `SOLO="$NAME"` when `UP` is empty, `SOLO=-` otherwise; add `SOLO` to the function's header comment.
  2. `stack_lease`:
     - the ticket is written as `<pid> <run> <solo>`; a ticket with two fields reads as solo `-`;
     - a project is *busy* when some slot `k < STACKS` has a `solo` file naming it and `slot_state k` is `busy` (a `stuck` slot does not make its project busy);
     - a ticket is *blocked* when its solo is not `-` and that project is busy;
     - the waiter takes a slot when every earlier ticket (sorted order) is blocked and its own is not; today's rule, "it is the first ticket", is the case with no blocked ticket;
     - on a lease, write `info` and then, when `SOLO` is not `-`, `solo` (the project name) into the slot lock, both before the ticket is removed;
     - the wait limit, exit 3, the "no free slot" message, the trap and the ticket cleanup stay as they are.
  3. `info` keeps its three fields; `stack_status`, `stack_down`, `stack_release_run`, `slot_state` and `slot_release` are not changed (`rm -rf` of the lock already drops `solo`).
- **Not changed:** `scripts/shipfloor`, `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/dispatch.sh`, the config keys, the CLI, exit codes and output formats.
- **Done when:** `scripts/test/gate-stack-solo.test.sh` and `scripts/test/shipfloor-cli.test.sh` pass, and the whole suite (`TEST_JOBS=4 bash scripts/test/run.sh`) stays green, `gate-stack.test.sh` and the dispatch tests included.

## Risks to watch

- Two runs of one no-`up` project racing for a lease: only the first unblocked ticket acts and `solo` is written before the ticket goes, so the second one sees the project busy.
- A ticket written by the previous version has two fields: it must read as not solo, never as an empty project name.
- An existing test that relied on a no-`up` project seeing one slot: if one fails for that reason it is an acceptance or regression question for QA, not something to patch in the test by the engineer.
