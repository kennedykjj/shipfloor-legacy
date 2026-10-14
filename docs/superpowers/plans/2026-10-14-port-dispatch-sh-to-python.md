# Plan — #168 Port dispatch.sh to Python

Spec: `docs/superpowers/specs/2026-10-14-port-dispatch-sh-to-python-design.md`, plus the owner's note on the issue
(each run gets its own `TMPDIR` under `tmp/<n>/`; the #191 GitHub-limit wait stays).

## Tasks

| # | Layer | Owner | Files | Depends on |
|---|---|---|---|---|
| 1 | factory | qa-engineer | `scripts/test/dispatch-wrapper.test.sh` (AC-8), `dispatch-lock.test.sh` (AC-2, AC-1 detach), `dispatch-launch-argv.test.sh` (AC-3), `dispatch-policies.test.sh` (AC-5), `dispatch-exit.test.sh` (AC-6), `dispatch-tmpdir.test.sh` (owner's note) | — |
| 2 | factory | engineer | `scripts/shipfloor_core/dispatch.py` (new): `main` (the cycle) and `supervise` (one run, detached) | 1 |
| 3 | factory | engineer | `scripts/dispatch.sh` (wrapper over `lib/py.sh`), `scripts/sf.py` (`dispatch` command), `docs/contracts.md` | 2 |

## Notes

- One method per Bash function (`lock_live`, `running_issues`, `card_busy`, `live_runs`, `launch`, `step_up`,
  `run_pipeline`, `usage_limited`, `github_limited`, `block_card`, `refresh_staged`, `retry_infra`), the same processes
  with the same argv (board, claude, `bash deploy.sh`, `dashboard_cost.py` under `SHIPFLOOR_PY`, gh, powershell.exe),
  the same streams, every line through `text.say`.
- Reused: `project.resolve/cfg/machine/card_weight/clean_tmp/sweep_tmp`, `cli._validate`, `stack.read_settings` +
  `stack.release_run`, `proc.alive/script_argv/gh_argv/native_path`, `text.say/read_tab`.
- The supervisor (`sf.py dispatch --supervise <json>`) is started with `start_new_session` (POSIX) or
  `DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP` (Windows), stdin closed, HUP/INT/QUIT ignored before the exec; its
  stdout/stderr are the cycle's, as the Bash background run's were (the step-up lines reach the dispatcher's log).
- Existing `dispatch*.test.sh`, `tmp-sweep`, `health` and the #160 tests are the parity check and stay unedited.
  Exception: `gate-py-run-compat.test.sh` (#166) asserted that `dispatch.sh` sources `lib/stack.sh`, which AC-8 reverses.
