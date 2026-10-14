# shipfloor pool exits 1 when a project is registered and the stack queue is empty — spec

**Issue:** #244 · **Branch:** `feat/244-shipfloor-pool-sai-com-1-quando-ha` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** standard

## Product
_Product Owner_

**Problem:** `shipfloor pool` prints the pool correctly but exits 1 when a project is registered and the stack queue is empty, so scripts and callers that check the exit code see a failure that did not happen.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine (and developers who install the plugin and script around the CLI).
**Acceptance criteria**
- **AC-1** — Given a registered project and an empty stack queue, when the owner runs `shipfloor pool`, then it prints the pool and exits 0.
- **AC-2** — Given a registered project with cards queued in the stack, when the owner runs `shipfloor pool`, then it prints the pool and exits 0.
- **AC-3** — Given no project registered, when the owner runs `shipfloor pool`, then it prints the machine pool and exits 0.
- **AC-4** — Given an invalid config or an unreadable Shipfloor home, when the owner runs `shipfloor pool`, then it reports the error and exits non-zero.
**Out of scope:** Changing what `shipfloor pool` prints; exit codes of other `shipfloor` subcommands; the dashboard's pool view.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): gates and scripts rely on exit codes, so a false failure undermines them. No conflict with positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Contract:** `shipfloor pool` (no subcommand). Its output does not change. Its exit code becomes 0 whenever the pool is printed. Non-zero is kept for real errors: `project.machine("show")` fails (invalid `config.yml`, unreadable home), `gate.sh stack status` fails or the first project's home is missing, or the gate prints a queue count that is not an integer (2). `pool set|stage|stacks` and the usage exit 2 stay as they are.
- **Module:** `scripts/shipfloor_core/cli.py` `cmd_pool` (layer factory).
  - With no registered project, `return 1` becomes `return 0`.
  - The loop over `gate.sh stack status` lines no longer sets `right = 1` for `queue 0`. That line was a leftover from the Bash port, where the exit code was the last `[ n -gt 0 ]` test of a `while read` pipeline.
  - The result is `right or left`, where `right` is only the non-integer error (2) and `left` is the gate's own exit code.
  - Update the stale comment at the `use first` line.
- **Tests:** `scripts/test/py/cli_registry.py` `Pool.test_pool` and `Pool.test_pool_stacks`: every `self.ok("pool", want=1)` that prints the pool becomes `self.ok("pool")`, and the docstrings drop "(exit 1: no queue)". New assertions:
  - a queued count prints `queue: N waiting` and exits 0 (stub or real `gate.sh stack status`, as `test_pool_stacks` does today);
  - an invalid machine `config.yml` exits non-zero with its error on stderr;
  - a stack-status failure (first project's home removed) exits non-zero.
- **Migration:** none.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/cli_registry.py` |
| AC-2 | factory | `scripts/test/py/cli_registry.py` |
| AC-3 | factory | `scripts/test/py/cli_registry.py` |
| AC-4 | factory | `scripts/test/py/cli_registry.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- With no project registered, the command also exits 0. The issue asks for exit 0 "whenever the command prints the pool", and that case prints the machine pool too.
- A failure of `gate.sh stack status` and a non-integer queue count stay non-zero. These are real errors (the project home is missing, or the gate's output is broken), not an empty queue.
- No caller depends on the old exit 1. Nothing in the dispatcher, the dashboard or the scripts checks `shipfloor pool`'s exit code; only `cli_registry.py` does.
- The suite updating its `want=1` is part of AC-1..AC-3, not a separate criterion. It is the test of those ACs.
- Weight is standard: one layer, 2 files, no UI and no security, but 4 ACs is above light's limit of 3.

## Open questions
- none
