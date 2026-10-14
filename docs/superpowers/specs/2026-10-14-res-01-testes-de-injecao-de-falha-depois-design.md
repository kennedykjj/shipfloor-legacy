# [RES-01] Fault-injection tests: after any failure, the next cycle repairs or blocks for the owner — spec

**Issue:** #173 · **Branch:** `feat/173-res-01-testes-de-injecao-de-falha-depois` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The suite proves only the happy path and known errors. Nothing proves that a violent failure (killed subprocess, `gh` failing mid-sequence, full disk, overlapping dispatchers, orphan lock) leaves no state that nobody sees.
**Audience:** The factory's owner, who runs Shipfloor on their own machine.
**Acceptance criteria**
- **AC-1**: Given `FAKE_GH_FAIL_AT=<n>` or `FAKE_GH_FAIL_CMD=<ERE>`, when the code under test calls `fake-gh`, then the n-th call (or every call matching the ERE) exits non-zero and every other call behaves as before.
- **AC-2**: Given a board mutation sequence (label change, column move), when `gh` fails at each point of it in turn, then the next cycle either finishes the transition or leaves the card blocked for the owner with a reason, never half-moved with no block.
- **AC-3**: Given a launch, gate or deploy subprocess killed with SIGKILL, when the next dispatcher cycle runs, then no lock is held without a live process and no card sits in a WIP column without a live run or a block.
- **AC-4**: Given an orphan lock (dead or reused PID) or an orphan `index.lock`, when the next cycle runs, then the stale lock is cleared and the cycle proceeds.
- **AC-5**: Given two dispatcher cycles started at the same time, when both finish, then each card was launched at most once and no lock or temp file remains.
- **AC-6**: Given a write that fails as if the disk were full during install or a report, when it fails, then the previous installed files or report stay intact, no temp file remains, and `~/.shipfloor` still loads in the dashboard reader.
- **AC-7**: Given the normal test run on Linux, macOS and Windows CI, when it runs, then `scripts/test/chaos-*.test.sh` pass using only stubs (no network, no LLM), cover dispatcher, board, deploy, install and gate against the Python package where ported, and no existing test file changes.
- **AC-8**: Given `docs/contracts.md`, when read, then it states the invariant: after any failure, the next cycle repairs the state or blocks the card for the owner with a reason; no live lock without a process, no WIP card without a run or block, no leftover temp file, `~/.shipfloor` readable by the dashboard.
**Out of scope:** Fixing bugs the invariant exposes beyond small fixes that fit this card (each becomes its own bug issue); chaos tests for areas not yet ported to the Python package (they land with their port); tests against the Bash code being replaced; real disk exhaustion or real network faults.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim) by turning convergence into something a script proves, and principle 1 (the board is the source of truth) by guaranteeing the board never shows a state nobody acts on. No conflict with positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts touched**
- `scripts/test/fake-gh` and `scripts/test/fake-gh-deploy` (test seam): new env `FAKE_GH_FAIL_AT=<n>` (the n-th call, counted in `$FAKE_GH_DIR/fail-count`, exits 1 with `gh: injected failure` on stderr) and `FAKE_GH_FAIL_CMD=<ERE>` (every call whose argv line matches `grep -E` exits 1). Checked first, before any other branch; unset = today's behavior byte for byte.
- `docs/contracts.md`: new `## Failure invariant` section (after `## Security invariants`): after any failure, the next cycle repairs the state or the card is labelled `blocked`/`blocked:infra` with a comment saying why. Checkable form: no `locks/*.lock` whose `info` pid is dead and older than the TTL survives a cycle; no card in a 🤖 WIP column (`Technical Refinement`, `Coding`, `Validation`) without a live lock or a `blocked*` label; no `*.tmp` / `.*.install-tmp` / `tmp/<n>` left for a card with no run; `dashboard.py`'s readers load `~/.shipfloor` without an exception. The env table gains the two `FAKE_GH_*` seams.
- No product API, CLI flag, exit code or file format changes. Small fixes the tests expose stay inside the module they hit and keep its contract; a larger break becomes its own bug issue.

**Modules exercised (Python package, all ported since #171)**
- dispatcher: `shipfloor_core/dispatch.py` (`lock_live`, `launch`, `block_card`, `retry_infra`), `shipfloor_core/cycle.py` (`Claim` / `dispatch.pid` overlap, `clear_stale_lock`).
- board: `shipfloor_core/board.py` (`move`, label edits) through `board.sh` with `FACTORY_GH=fake-gh`.
- deploy: `shipfloor_core/deploy.py` (`take_lock`, `block`, `revert`) through `deploy.sh` with `fake-gh-deploy` and `deploy-lib.sh`'s shared base repo.
- install: `shipfloor_core/cli.py` `cmd_install` (`_put`, `.install-tmp` sweep, `.source` last).
- gate: `shipfloor_core/gate/run.py` killed mid-run: `last-gate` and the gate-passes record stay consistent.
- report: `shipfloor_core/report.py` (`shutil.copyfile` into `reports-wt`; today a failed copy can leave half a report: expected small fix, write through `fs.write_atomic`).

**Files**
- New: `scripts/test/chaos-lib.sh` (shared: `chaos_invariant <home>` asserting the four checkable conditions, `kill_after <pattern> <cmd>` that SIGKILLs a stub-held subprocess), `scripts/test/chaos-board.test.sh`, `scripts/test/chaos-dispatch.test.sh` (launch, gate and deploy kills; orphan locks; overlapping cycles), `scripts/test/chaos-fs.test.sh` driving `scripts/test/py/chaos_fs.py` (in-process: `ENOSPC` injected by patching `os.replace`/`open` writes in `cli.cmd_install` and `report._run`).
- Changed: `scripts/test/fake-gh`, `scripts/test/fake-gh-deploy`, `docs/contracts.md`; small fixes, if any, in `scripts/shipfloor_core/{report,dispatch,deploy,board,cli}.py`.
- Kills use a stub (`FACTORY_CLAUDE`, a slow fake gh or runner) that writes its pid and sleeps; the test kills that pid with `kill -9`, never a real process; deadlines via `wait_for`, no fixed sleeps. Portable tools only (no GNU-only flags): the files run on every OS the CI suite runs on.

**Migration:** none.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/chaos-board.test.sh` |
| AC-2 | factory | `scripts/test/chaos-board.test.sh` |
| AC-3 | factory | `scripts/test/chaos-dispatch.test.sh` |
| AC-4 | factory | `scripts/test/chaos-dispatch.test.sh` |
| AC-5 | factory | `scripts/test/chaos-dispatch.test.sh` |
| AC-6 | factory | `scripts/test/chaos-fs.test.sh` |
| AC-7 | manual | CI green on the PR; `git diff --name-only origin/main` lists no existing `scripts/test/*.test.sh` or `scripts/test/py/*.py` |
| AC-8 | manual | `docs/contracts.md` `## Failure invariant` read in review |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- New `chaos-*` test files instead of the existing suites: the issue forbids editing existing tests (#153 principle 3), and the issue names the `chaos-*.test.sh` layer.
- `FAKE_GH_*` failure mode goes in both `fake-gh` and `fake-gh-deploy`: the deploy tests use the second; editing a fake (a helper, not a test) is allowed, and unset it behaves as today, so no existing test changes.
- Disk full is simulated in-process (`ENOSPC` raised by a patched write) in `scripts/test/py/chaos_fs.py`, driven by `chaos-fs.test.sh` so `run.sh` picks it up: filling a real disk is out of scope and not portable.
- Gate and deploy kill scenarios live in `chaos-dispatch.test.sh`: the invariant is judged by the next dispatcher cycle, so one file owns the kill-then-cycle harness.
- AC-7 and AC-8 are `manual`: AC-7 is CI and a diff check, AC-8 is prose; a test grepping the doc would be a source-text check.
- No CI change: #154 is closed, and the chaos files join `run.sh`'s default glob, so CI runs them wherever it runs the suite; `.github/` is off-limits to the pipeline anyway.
- Bugs the invariant exposes beyond a small fix in the module hit are filed as separate bug issues and the failing scenario is left out of this PR, not skipped in code.
- Weight `heavy`: 8 acceptance criteria and more than 8 files in the architecture.

## Open questions
- none
