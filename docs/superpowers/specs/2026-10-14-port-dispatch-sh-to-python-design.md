# Port dispatch.sh to Python — spec

**Issue:** #168 · **Branch:** `feat/168-port-dispatch-sh-to-python` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The dispatcher cycle is Bash, and the Python migration (#153) needs it in `shipfloor_core/dispatch.py`. The port must not change anything the board, dashboard, health, notify or the owner can observe.
**Audience:** The factory's owner, plus the developers who install the plugin and run the factory on Windows, macOS or Linux.
**Acceptance criteria**
- **AC-1**: Given a cycle that starts a run, when the cycle exits, then the run's process is still alive and was never waited on or killed by the cycle (SIGHUP ignored). It ends with `== end`, releases its stack slot, sweeps tmp while keeping the infra marker, and removes `locks/<stage>-<n>.lock` only if `info` holds its own pid.
- **AC-2**: Given a lock dir created by the cycle before the fork, with `info` = `pid epoch n`, when the next count runs, then the lock is live under `FACTORY_LOCK_TTL` even with a dead pid. Over the TTL it is live only if `kill -0` succeeds, and otherwise it is removed. The epoch comes from `info`, else the dir mtime.
- **AC-3**: Given a run launch, when `claude` starts, then its flags (same order), its stdin prompt `/sf:<p> <n>` with no newline, its cwd `<home>/control`, its environment (set, removed and unset variables as today) and the `== start`/`== end`/`== step-up` lines in `logs/<date>-<n>-<stage>.log` match today's byte for byte.
- **AC-4**: Given a board snapshot, when the cycle schedules, then orphans go first, WIP counts include in-flight runs (`limit 0` = no limit), the stage slots and machine pool hold (`SHIPFLOOR_MAX_PARALLEL` overrides), at most one deploy runs per project, board order is followed and blocked cards are skipped.
- **AC-5**: Given the policies, when the cycle hits them, then they act as today: model and weight per stage, the develop-only step-up, the usage-limit stop, the infra retry with a second block going to the owner, cost `card_block`/`day_stop`, working hours that skip only new runs, `refresh_staged` only when enabled, the tmp sweep and the atomic `board.tsv` write.
- **AC-6**: Given each failure and stop case, when the cycle exits, then the exit code is 2 for invalid config, 0 for PAUSE, usage limit and `day_stop`, and 1 for board, cost or step failures. Every stdout/stderr line is the same text, served through the catalog (`MLANG`).
- **AC-7**: Given the existing `dispatch*.test.sh`, `tmp-sweep.test.sh`, `health.test.sh` and #160 tests, when they run against the port, then they all pass with no edits. The #154 macOS and Windows jobs show a cycle-started run alive after the cycle returns and ending with `== end`.
- **AC-8**: Given `dispatch.sh`, when it runs, then it is a thin wrapper over `dispatch.py` that does not source `lib/stack.sh` and calls `stack.py` directly.
**Out of scope:** Any behavior, flag, log line or message change. Other runtimes (#146, which comes after this). Removing the Bash dispatcher (#169). The owner's full day of real cards is a manual owner step tracked in #153, not a pipeline criterion.
**Product fit:** This serves principle 2 (deterministic gates outrank any agent's claim). It keeps the dispatcher and its gates scripted and exactly reproducible. It also serves principle 3, because `dashboard_cost.py` keeps finding transcripts by cwd and first message. It does not conflict with the positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Prerequisites (not on main yet):** #162 (`shipfloor_core/` package, `sf.py`, `lib/py.sh`, `proc.py`, `project.py` with `snapshot`/`clean_tmp`/`sweep_tmp`/`card_weight`, `say`, lock helpers), #157 (the Bash fixes and the deploy-pool decision), #160 (the pinning tests), #166 (`stack.py`), #167 (`deploy.py`). Develop must start only when these are merged; this spec names them by role, not by final function name.

**Contracts touched** (no public contract changes):
- `scripts/dispatch.sh` becomes a wrapper (`lib/py.sh`, `exec python -I sf.py dispatch "$@"`); it no longer sources `lib/stack.sh` or `lib/project.sh`.
- `shipfloor_core/dispatch.py`: `main(argv) -> int` (the cycle) and `supervise(...)` (the per-run supervisor); `sf.py dispatch` is its entry. Env knobs read as today: `FACTORY_HOME`, `FACTORY_REPO`, `FACTORY_WT_ROOT`, `FACTORY_CLAUDE`, `FACTORY_BOARD`, `FACTORY_DEPLOY`, `FACTORY_LOCK_TTL`, `FACTORY_CLEANUP`, `FACTORY_CONTROL_REFRESH`, `FACTORY_MAIN`, `SHIPFLOOR_MAX_PARALLEL`, `SHIPFLOOR_GITHUB_LIMIT_MIN`.
- Files unchanged in format: `locks/<stage>-<n>.lock/{info,last-gate}`, `stepup/<n>`, `infra/<n>`, `cost/<n>.json(.prev)`, `board.tsv`, `logs/*.log` lines.

**Layers and modules:** only the `factory` layer: `scripts/shipfloor_core/dispatch.py` (new), `scripts/shipfloor_core/locks.py` additions only if #162 lacks a needed helper, `scripts/dispatch.sh` (wrapper), `scripts/shipfloor-dispatch.sh` untouched (#169), `scripts/dashboard_cost.py` untouched (called as a subprocess, as today).

**Process model:** the cycle creates `locks/<stage>-<n>.lock` and `tmp/<n>`, then starts ONE supervisor per run as a detached process (`python -I sf.py dispatch --supervise ...` via `subprocess.Popen` with `start_new_session=True` on POSIX, `DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP` on Windows, stdin/stdout/stderr closed), SIGHUP ignored, never waited on or killed, no `atexit` child cleanup. The supervisor writes `info` (`pid epoch n`), the `== start` line, runs `claude` (prompt on stdin, no newline) or `deploy.sh` with the exit-3 loop (max 3 rounds), step-up, then `stack_release_run`, `clean_tmp` (infra marker kept), `cleanup_processes` (Windows), and removes the lock only if `info` holds its pid. A missing control dir is handled inside the supervisor's cleanup (fixes #157 item 6, so the lock is not leaked).

**Port shape:** functions mirror the Bash ones one to one (`lock_live`, `running_issues`, `card_busy`, `live_runs`, `launch`, `step_up`, `run_pipeline`, `usage_limited`, `github_limited`, `block_card`, `refresh_staged`, `retry_infra`); output goes through `say(lang, ...)`; `board.sh` and `deploy.sh` are called with `bash <path>`; `dashboard_cost.py` is called with `python -I`; the board snapshot is written to `board.tsv.<pid>.tmp` then renamed.

**Migration plan:** none (no data format change). The Bash `dispatch.sh` body is replaced in the same change; `shipfloor-dispatch.sh` keeps calling `dispatch.sh`, so the dispatcher entry is unchanged.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dispatch-process.test.sh` |
| AC-2 | factory | `scripts/test/dispatch-lock.test.sh` |
| AC-3 | factory | `scripts/test/dispatch-launch.test.sh` |
| AC-4 | factory | `scripts/test/dispatch-pool.test.sh` |
| AC-5 | factory | `scripts/test/dispatch-policies.test.sh` |
| AC-6 | factory | `scripts/test/dispatch-exit.test.sh` |
| AC-7 | factory | `scripts/test/tmp-sweep.test.sh` |
| AC-8 | factory | `scripts/test/dispatch-wrapper.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Existing `dispatch*.test.sh` stay unedited and are the parity check; the new tests only add what they do not pin (real detached process, lock TTL cases, wrapper not sourcing `lib/stack.sh`, exit codes).
- The supervisor is a re-invocation of the same entry (`sf.py dispatch --supervise`), not a `multiprocessing` child: it must outlive the cycle on every OS.
- The pool count of a deploy follows the owner's decision on #157 (recommended: one unit); the port copies whatever #157 merged.
- Develop waits for #162, #157, #160, #166 and #167 to be merged: the package they create does not exist on main yet.
- Weight heavy: 8 acceptance criteria.

## Open questions
- none
