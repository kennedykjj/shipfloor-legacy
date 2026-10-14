# Port shipfloor-dispatch.sh to Python; run-dispatcher.sh stays the scheduler's entry — spec

**Issue:** #169 · **Branch:** `feat/169-port-shipfloor-dispatch-sh-to-python-run-dis` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** the machine-wide dispatch cycle lives in `shipfloor-dispatch.sh`, Bash that is hard to keep correct across Windows, macOS and Linux; it moves to `shipfloor_core/cycle.py` (part of #153, after #168) with no change the owner can see. `shipfloor-dispatch.sh` becomes a thin wrapper; `run-dispatcher.sh` stays Bash as the scheduler's entry.

**Audience:** the factory's owner and developers who install the plugin and leave the dispatcher on a schedule (systemd, cron, launchd, Windows task).

**Acceptance criteria**
- AC-1: Given the scheduler calls `bash -l run-dispatcher.sh` by name, When it runs, Then all output is appended to `logs/dispatcher.log`, `PAUSE` exits 0, `PATH` comes from the first line of `dispatcher.path`, and the cycle is `exec`'d; installers are unchanged.
- AC-2: Given no registry or an empty one, When a cycle runs, Then it exits 0 and writes no health line.
- AC-3: Given `dispatch.pid` holds a live pid and is younger than `SHIPFLOOR_CYCLE_STALE_MIN` (default 30), When a cycle starts, Then it is an overlap and leaves the file; otherwise the file is written atomically and removed at the end.
- AC-4: Given any exit after the registry check (PAUSE, usage limit, overlap, success, failure), When the cycle ends, Then `shipfloor_health.py record --seconds S --exit rc [--overlap]` is recorded (its errors ignored), then `shipfloor_notify.py cycle` runs with stdout dropped and stderr kept, both with `SHIPFLOOR_BASH`.
- AC-5: Given a global `PAUSE`, or a Claude usage limit hit recently in any project, When a cycle runs, Then it exits 0, the latter printing `<ISO> shipfloor: Claude usage limit hit recently; waiting`.
- AC-6: Given several projects, When one fails `use`, `refresh_control` (fetch, add missing detached `control`, no-op when clean, else up to 3 tries of stale `index.lock` clear + `reset --hard` + `clean -qfdx` with `SHIPFLOOR_LOCK_RETRY_S` between), `snapshot` or `validate`, Then it gets `SKIPPED` (`since\twhy`, `since` kept from the first failure, `why` the first `fatal|error` line), stderr shows `<ISO> shipfloor: <slug>: <why>; skipped`, and the other projects still run.
- AC-7: Given a project that passes those steps, When the cycle runs, Then its `SKIPPED` is cleared and its dispatch runs with `FACTORY_CONTROL_REFRESH=0`; the cycle exits 1 if any project failed or was skipped, else 0.
- AC-8: Given the existing `shipfloor-dispatch.test.sh`, `health.test.sh`, `notify*.test.sh`, `install-dispatcher.test.sh` and #160 tests unedited, When run, Then they pass, and on #154's three platforms the scheduled entry with an `env -i`-like environment and `dispatcher.path` runs a cycle that launches a stub run.

**Out of scope:** porting `run-dispatcher.sh` or the installers; any change to cycle behavior, messages, file formats or exit codes; the `shipfloor_core` package itself (#162/#168).

**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim): the dispatcher that runs the gates stays deterministic and is kept identical by unedited tests; it also keeps the cross-platform operating context (Windows, macOS, Linux). No conflict with positioning.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. No endpoint or event contract changes; the contract is the cycle's observable behavior listed in the issue.

**Prerequisite:** `scripts/shipfloor_core/` and `scripts/lib/py.sh` (#162) and the `board`/`gate`/`stack` ports up to #168 must be on main before develop starts; this port uses their `proc`, `text`, `project` and `fs` helpers (`git`, `say`, `use`, `snapshot`, `write_atomic`, `file_age`) and does not duplicate them.

**New files**
- `scripts/shipfloor_core/cycle.py`: `run_cycle(home) -> int` and `main()`. Steps: registry check (missing or empty → 0, no health); `dispatch.pid` overlap test (pid alive and `file_age` below `SHIPFLOOR_CYCLE_STALE_MIN`) and atomic write via `fs.write_atomic`; a `finally` that removes the pid file unless overlap, then records health (`shipfloor_health` record, errors ignored) and runs notify `cycle` (stdout dropped, stderr kept), both with `SHIPFLOOR_BASH`; global `PAUSE`; `usage_limited` (logs under `projects/*/logs/*.log` newer than 30 min, last `== start` block contains `hit your session limit`); the GitHub-limit hold (#190), kept as is; per-project loop.
- Per project: `refresh_control` (fetch, add detached `control` worktree, no-op when HEAD equals `origin/<main>` and clean, else 3 tries of stale `index.lock` clear then `-c core.longpaths=true reset --hard` and `clean -qfdx`, sleeping `SHIPFLOOR_LOCK_RETRY_S` between), `snapshot`, `validate`, `skip()` (SKIPPED `since\twhy`, `since` kept, `why` the first `fatal|error` line), then the dispatch with `FACTORY_CONTROL_REFRESH=0`. Each project runs in its own child process (`subprocess` of `sf.py cycle-project <slug> <repo> <wt> <main>`), so a crash or `exit` in one never stops the others; the parent ORs the exit codes.

**Changed files**
- `scripts/sf.py`: commands `cycle` and `cycle-project`.
- `scripts/shipfloor-dispatch.sh`: becomes a wrapper (template `templates/py-wrapper.sh`: `source lib/py.sh`, `exec` `sf.py cycle`); keeps honoring `SHIPFLOOR_DISPATCH` (the stub the tests point at) by passing it through the environment.
- `scripts/run-dispatcher.sh`: stays Bash, behavior unchanged (log append, `PAUSE`, `dispatcher.path`, `exec`). No edit unless the wrapper name changes.
- Installers and `lib/project.sh` are not touched.

**Migration:** none; same files, same formats. Rollback is reverting the commit.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-2 | factory | `scripts/test/shipfloor-dispatch.test.sh` |
| AC-3 | factory | `scripts/test/shipfloor-dispatch.test.sh` |
| AC-4 | factory | `scripts/test/health.test.sh` |
| AC-5 | factory | `scripts/test/shipfloor-dispatch.test.sh` |
| AC-6 | factory | `scripts/test/dispatch-project.test.sh` |
| AC-7 | factory | `scripts/test/dispatch-project.test.sh` |
| AC-8 | factory | `scripts/test/dispatch-resilience.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: more than 6 acceptance criteria.
- Test plan reuses the existing tests, unedited, as the issue requires: they are the parity proof; no new test file.
- Per-project isolation uses a child process (`cycle-project`), the closest equivalent to today's subshell.
- Develop waits on #162 and #168 being on main; the spec names no helper that #162 does not list.

## Open questions
- none
