# Tests that pin behavior: gate and stack — spec

**Issue:** #158 · **Branch:** `feat/158-tests-that-pin-behavior-gate-and-stack` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The Python port of `gate.sh` and `lib/stack.sh` (PY-12, PY-13) has no tests pinning today's verdicts, exit codes, cache and stack behavior, so the port could silently change what the gates hold.
**Audience:** The factory's owner (a developer who runs Shipfloor on their own machine) and the developers who install the plugin, who rely on the gates behaving the same after the port.
**Acceptance criteria**
- **AC-1** — Given today's `gate.sh`, when a gate hits an infra failure, resolve or `-C` fails, `help`/no argument/an unknown command is run, then the tests pin each verdict line, exit code (0/2/3), `last-gate` record (or its absence) and that stdout carries only data.
- **AC-2** — Given the static gates (`fast`, `scope`, `test-plan`, `## Rollback`), when run with the qa argument, a wrong `gate-fast` count, `FACTORY_QA_AMEND_MAX`, the extra `SKIP_MARKS`, a tests-only role, `|` in a cell, a multi-line HTML comment or a destructive keyword in a string, then the tests pin today's verdict for each.
- **AC-3** — Given `migration`, `owner_accepted` and `merged_with_main`, when an applied file is deleted, `FACTORY_MAIN` differs from `main` or `project.main`, `FACTORY_HOME` is unset, or only a local `main` exists, then the tests pin today's result for each.
- **AC-4** — Given the pass cache, when records age past 14 days, a record is written, `FACTORY_HOME` is unset, or `gate.sh` changes, then the tests show pruning, the `.tmp`-then-rename write, a usable `pass_key`, and a new key.
- **AC-5** — Given `lib/stack.sh` slots, when `stack_lease` meets `stuck hold-max`/`no-info`/`run-ended`, `slot_release` runs with reason `heartbeat`, or `free_range` runs with `lsof` or the Windows tools stubbed, then the tests show the reclaim, the kept beat pid, and docker/vpnkit/wslrelay spared.
- **AC-6** — Given a stack, when `up` fails, the queue is waiting or its `.lock` is stuck for 50 tries, the slot `env` has special characters or a non-identifier port name, `stack_down` gets a slot ≥ STACKS, or the project config is broken, then the tests pin the `up.log` tail in the message, `stack: waiting, position i of n`, the forced lock break, the env contents, the `stack_down` result, and the defaults/solo fallback.
- **AC-7** — Given the new tests live in files whose names contain `gate` or `stack`, when `run.sh --changed` and the whole suite run on main, then they are selected and pass with no change to `gate.sh` or `lib/stack.sh`.
- **AC-8** — Given `docs/contracts.md`, when a behavior pinned above is not yet listed there, then it is added.
**Out of scope:** Changing `gate.sh` or `lib/stack.sh`; fixing bugs the tests expose (they go to PY-03 or a new issue under #153); deciding whether `stack_settings` should fail closed (pinned as today's behavior); extending the cache key to the Python sources (PY-13).
**Product fit:** Serves principle 2, "Deterministic gates outrank any agent's claim": the gates stay deterministic across the port only if their behavior is pinned by tests. No conflict with the positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Contracts touched:** none. `gate.sh` and `lib/stack.sh` are read-only; the tests call them as black boxes (stubbed `lsof`, `netstat.exe`, `tasklist.exe`, `taskkill.exe` on PATH, temp `FACTORY_HOME`, temp git repos), following the style of the existing `gate-*.test.sh` and `stack-*.test.sh` files and `scripts/test/lib.sh`.
- **Layers:** only `factory`. New files, all under `scripts/test/`:
  - `gate-pin-verdict.test.sh` — AC-1
  - `gate-pin-static.test.sh` — AC-2 and AC-3
  - `gate-pin-cache.test.sh` — AC-4
  - `stack-pin-slots.test.sh` — AC-5
  - `stack-pin-queue.test.sh` — AC-6
- **Docs:** `docs/contracts.md` (PY-02, branch `feat/155-*`) is not on main yet. If it exists when develop runs, add the pinned behaviors it lacks; if not, list them in a `## Pinned behavior` section of the PR description and leave `docs/` alone, so PY-02 does not conflict.
- **A test that exposes a bug:** pin nothing wrong; leave that case out and note it for PY-03 or a new issue under #153 in the PR.
- **Migration:** none.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-pin-verdict.test.sh` |
| AC-2 | factory | `scripts/test/gate-pin-static.test.sh` |
| AC-3 | factory | `scripts/test/gate-pin-static.test.sh` |
| AC-4 | factory | `scripts/test/gate-pin-cache.test.sh` |
| AC-5 | factory | `scripts/test/stack-pin-slots.test.sh` |
| AC-6 | factory | `scripts/test/stack-pin-queue.test.sh` |
| AC-7 | manual | checked in review: file names contain `gate`/`stack`, `run.sh --changed` selects them, the suite passes, `gate.sh` and `lib/stack.sh` are unchanged |
| AC-8 | manual | checked in review: `docs/contracts.md` diff lists the pinned behaviors |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- `stack_settings` keeps falling back to defaults/solo on a broken config, pinned as today's behavior: the issue asks for exactly that; fail-closed is a separate issue under #153.
- `docs/contracts.md` is not on main, so AC-8 applies only if it has landed by develop time; otherwise the list goes in the PR, to avoid a conflict with PY-02.
- Five test files grouped by subject (not one per bullet) to keep each readable and let `run.sh --changed` pick them by name.
- Weight heavy: 8 acceptance criteria (more than 6).

## Open questions
- none
