# [PY-04] Fix before migrating: dispatcher, board and install bugs — spec

**Issue:** #157 · **Branch:** `feat/157-fix-before-migrating-dispatcher-board-and` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** Ten latent bugs in the dispatcher, board and install scripts break the factory outside Git Bash/GNU Linux, leak locks, miscount the pool or dirty the installed copy. The Python ports (PY-10, PY-15..17) must copy deliberate behavior, not these bugs.
**Audience:** Other developers who install the plugin (macOS, Linux, paths with spaces), and the factory's owner.
**Acceptance criteria** (each backed by a test that fails on today's main and passes after)
- **AC-1** — Given `FACTORY_BOARD` is unset and the installed `board.sh` lacks the execute bit, when `dispatch.sh` or `deploy.sh` calls the board, then the call succeeds (no exit 126); and every `.sh` in `scripts/` is mode 100755, checked by a hygiene test.
- **AC-2** — Given a card reaches `costs.card_block`, when `block_card` comments on it, then gh is called with `-R owner/repo`, never the clone's local path.
- **AC-3** — Given one deploy is running, when `live_runs` counts the pool, then it counts the deploy as the number of units the owner decided (recommended: one), pinned by a test and recorded in `docs/contracts.md`.
- **AC-4** — Given `SHIPFLOOR_HOME` contains a space, when `usage_limited` scans its files, then it reads each file whole and reports the same result as with a space-free path.
- **AC-5** — Given two dispatch cycles start at once, when both try to take `dispatch.pid`, then exactly one owns it and the other exits without running.
- **AC-6** — Given the control checkout directory is missing, when a run starts and cannot `cd` into it, then it exits with an error and leaves no lock behind.
- **AC-7** — Given `FACTORY_MAIN` is set to a branch other than `main`, when `dispatch.sh` runs `refresh_control`, then it fetches and resets to that branch, not `origin main`.
- **AC-8** — Given a dispatch cycle that computes cost, when it ends, then no `__pycache__` exists under the installed `~/.shipfloor/factory` and `doctor` reports no difference.
- **AC-9** — Given `stat -c` is unavailable (GNU tools stubbed off PATH), when `lock_live` and `slot_state` read a live lease's age, then they get the true mtime and the lease is not reported as `stuck heartbeat` nor reclaimed.
- **AC-10** — Given `timeout` is unavailable (stubbed off PATH), when `deploy.sh local_ci` runs a command that hangs, then it is still stopped at its time limit.

**Out of scope:** The Python ports themselves (PY-10, PY-15..17); new dispatcher features; changing pool size or lock TTL values; any dashboard change.
**Product fit:** Principle 2 (deterministic gates outrank any agent's claim): the gates and dispatcher are only trustworthy if they behave the same on every OS the owner uses (Operating Context: Windows, macOS, Linux). AC-3 also serves principle 3 (numbers are exact): the pool count must be a deliberate, documented number. No conflict with positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

One layer (`factory`), no public contract changes (no endpoint, event or function signature; env vars unchanged). Files:
- `scripts/dispatch.sh`: callers use `bash "$HERE/board.sh"` (AC-1); `block_card` resolves `owner/repo` through `shipfloor-config.sh` instead of the clone path in `FACTORY_REPO` (AC-2); `live_runs` counts a deploy once (AC-3); `usage_limited` reads `find` output with `-print0`/`while read -d ''` (AC-4); the run subshell takes its lock after `cd "$CONTROL"` or releases it on failure (AC-6); `refresh_control` uses `FACTORY_MAIN` (AC-7); `lock_live` age uses a portable mtime helper (AC-9).
- `scripts/deploy.sh`: `bash "$HERE/board.sh"` (AC-1); `local_ci` bounded without GNU `timeout`, with a portable fallback (AC-10).
- `scripts/shipfloor-dispatch.sh`: `dispatch.pid` taken atomically (`set -o noclobber` or `mkdir`-style claim, stale takeover kept) (AC-5).
- `scripts/dashboard_cost.py`: `sys.dont_write_bytecode = True` before the imports (AC-8).
- `scripts/lib/stack.sh` and a shared portable `mtime` helper in `scripts/lib/` (`stat -c %Y`, then `stat -f %m`, then `date -r`, then Python) used by `lock_live`, `slot_state` and `lib/stack.sh` (AC-9).
- Mode 100755 on every `scripts/*.sh` including `board.sh` (git `update-index --chmod=+x`) (AC-1).
- `docs/how-it-works.md`: records the deploy pool-unit decision (AC-3); `docs/contracts.md` (PY-02) does not exist yet.
- Tests: the new `scripts/test/*.test.sh` listed in the Test plan, plus an addition to `hygiene.test.sh`.

Migration: none, no data or schema. Existing `__pycache__` in an installed copy is removed by the next install; no step needed.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/hygiene.test.sh` |
| AC-2 | factory | `scripts/test/dispatch-block-repo.test.sh` |
| AC-3 | factory | `scripts/test/dispatch-pool.test.sh` |
| AC-4 | factory | `scripts/test/dispatch-home-space.test.sh` |
| AC-5 | factory | `scripts/test/shipfloor-dispatch.test.sh` |
| AC-6 | factory | `scripts/test/dispatch-control-missing.test.sh` |
| AC-7 | factory | `scripts/test/dispatch-refresh-main.test.sh` |
| AC-8 | factory | `scripts/test/dispatch-pycache.test.sh` |
| AC-9 | factory | `scripts/test/portable-tools.test.sh` |
| AC-10 | factory | `scripts/test/deploy-local-ci.test.sh` |

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Every item is fixed; none is kept as intended, because each has a reproducible failure and a cheap fix.
- Weight is heavy: 10 acceptance criteria and more than 8 files.
- The pool-unit decision is recorded in `docs/how-it-works.md`, since `docs/contracts.md` (PY-02) does not exist yet.
- The portable mtime/timeout fallbacks go in one shared lib helper so the Python ports copy one behavior.

## Open questions
- **Deploy in the pool (item 3):** A (recommended) one unit per deploy, so `deploysh-<n>.lock` is not counted — a deploy is one card's work, and counting it twice wastes a slot; or B two units, documented — it reflects the two processes it runs.
