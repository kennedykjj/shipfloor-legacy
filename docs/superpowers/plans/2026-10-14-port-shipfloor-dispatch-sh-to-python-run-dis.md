# Plan — #169 Port shipfloor-dispatch.sh to Python; run-dispatcher.sh stays the scheduler's entry

Spec: `docs/superpowers/specs/2026-10-14-port-shipfloor-dispatch-sh-to-python-run-dis-design.md`

The cycle moves to `scripts/shipfloor_core/cycle.py` with no behavior change. Every process the Bash cycle started
is started with the same argv (`git`, `bash <dispatch.sh>`, `shipfloor_health.py record`, `shipfloor_notify.py cycle`,
`shipfloor_config.py validate|patterns|machine`), so the port does not wait on #168: `dispatch.sh` stays an external
process. The parity proof is the existing tests, unedited.

## Tasks

| # | Layer | Owner | Files | Depends on |
|---|---|---|---|---|
| 1 | factory | qa-engineer | `scripts/test/cycle-port.test.sh`: the port's shape (wrapper, `sf.py cycle`/`cycle-project`), per-project process isolation, the `env -i` scheduled entry (AC-8) | — |
| 2 | factory | engineer | `scripts/shipfloor_core/cycle.py`: `run_cycle(home)`, `main`, `main_project`; `proc.pid_alive` (moved from `deploy.py`) | 1 |
| 3 | factory | engineer | `scripts/sf.py`: `cycle`, `cycle-project`; `scripts/shipfloor-dispatch.sh` becomes a wrapper (`set -- cycle`, `source lib/py.sh`) | 2 |
| 4 | factory | engineer | full suite: `shipfloor-dispatch*.test.sh`, `health`, `notify*`, `run-dispatcher`, `install-dispatcher` unedited and green | 3 |

## Notes

- `dispatch.pid` keeps its exclusive create (`O_CREAT|O_EXCL`, the Bash `set -C`), not a rename: a rename would let two
  cycles that start at once both take it (the race in `shipfloor-dispatch.test.sh`).
- The wrapper exports `SHIPFLOOR_CYCLE_BASH="$BASH"`: health and notify get `SHIPFLOOR_BASH` = the cycle's own bash,
  as before; on Windows the dispatch also runs under it (a bare `bash` from Windows Python could be the WSL launcher).
- Each project runs in `sf.py cycle-project <slug> <repo> <wt> <main> --lang <lang>`, the subshell's equivalent; the
  machine language is read once by the parent and handed down.
- `run-dispatcher.sh` and the installers are not touched.
