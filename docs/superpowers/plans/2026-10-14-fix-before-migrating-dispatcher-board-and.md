# Plan — #157 [PY-04] Fix before migrating: dispatcher, board and install bugs

Spec: `docs/superpowers/specs/2026-10-14-fix-before-migrating-dispatcher-board-and-design.md`
Layers: `factory` only (path `./`, agent `engineer`). Owner decision on item 3: **A**, a deploy is one pool unit (the card was approved into Ready for Dev with the recommendation).

## Tasks

### T1 — portable tools (AC-9, AC-10) · layer `factory` · agent `engineer`
- New shared helper in `scripts/lib/` (e.g. `scripts/lib/portable.sh`): `mtime <path>` (`stat -c %Y`, then `stat -f %m`, then `date -r`, then Python) and a bounded-run helper (`timeout` when present, else a portable fallback that kills the command at its limit).
- `scripts/dispatch.sh` `lock_live` and `scripts/lib/stack.sh` `slot_state` use `mtime`.
- `scripts/deploy.sh` `local_ci` uses the bounded-run helper, so it is stopped at its time limit without GNU `timeout`.
- Install: make sure the new lib file is shipped with the other `scripts/lib/*` files (check the install script's file list, if any).
- Depends on: nothing.

### T2 — dispatcher and deploy fixes (AC-1 callers, AC-2, AC-3, AC-4, AC-6, AC-7) · layer `factory` · agent `engineer`
- `scripts/dispatch.sh` and `scripts/deploy.sh`: call the board as `bash "$HERE/board.sh"` when `FACTORY_BOARD` is unset (no dependence on the mode bit).
- `block_card`: `gh issue comment -R <owner/repo>` resolved through `shipfloor-config.sh` (the `repo:` of the project), never the clone path in `FACTORY_REPO`.
- `live_runs`: a deploy counts once (`deploysh-<n>.lock` not counted); record the decision in `docs/how-it-works.md`.
- `usage_limited`: read `find` output with `-print0` / `while IFS= read -r -d ''`.
- The run subshell: no lock is left when `cd "$CONTROL"` fails (take the lock after the `cd`, or release it on failure).
- `refresh_control`: fetch and reset to `FACTORY_MAIN`, not `origin main`.
- Depends on: T1 (both edit `scripts/dispatch.sh`).

### T3 — dispatch.pid, bytecode, file modes (AC-5, AC-8, AC-1 modes) · layer `factory` · agent `engineer`
- `scripts/shipfloor-dispatch.sh`: take `dispatch.pid` atomically (`noclobber` or `mkdir` claim), keeping the stale-pid takeover.
- `scripts/dashboard_cost.py`: `sys.dont_write_bytecode = True` before importing `inbox_hook` / `shipfloor_config`.
- Mode 100755 on every `.sh` under `scripts/` (incl. `scripts/lib/*.sh`, `scripts/test/*.sh` as the hygiene test requires) via `git update-index --chmod=+x`.
- Depends on: T2.

## Acceptance tests (QA, before T1)
The files in the spec's test plan: `scripts/test/hygiene.test.sh` (addition), `dispatch-block-repo`, `dispatch-pool`, `dispatch-home-space`, `shipfloor-dispatch`, `dispatch-control-missing`, `dispatch-refresh-main`, `dispatch-pycache`, `portable-tools`, `deploy-local-ci` (`scripts/test/*.test.sh`).
