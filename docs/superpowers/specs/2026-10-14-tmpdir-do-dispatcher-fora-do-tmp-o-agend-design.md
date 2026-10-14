# TMPDIR do dispatcher fora do /tmp: o agendamento grava em ~/.shipfloor/tmp, com limpeza — spec

**Issue:** #218 · **Branch:** `feat/218-tmpdir-do-dispatcher-fora-do-tmp-o-agend` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The scheduled dispatcher uses the system `TMPDIR` (usually `/tmp`, often an inode-capped tmpfs). Temp files that the cycle and its tools leave behind can fill that cap, and then every write on the machine fails. Today the owner works around it with a hand-made systemd drop-in.
**Audience:** The factory's owner, and other developers who install the plugin and schedule the dispatcher with `install-dispatcher.sh`.
**Acceptance criteria**
- **AC-1** — Given a dispatcher installed with `install-dispatcher.sh` (systemd unit, launchd plist or Windows task), when a scheduled cycle runs, then its `TMPDIR` is `<SHIPFLOOR_HOME>/tmp` and that folder exists, even if it was missing before.
- **AC-2** — Given `run-dispatcher.sh` started by hand with any inherited `TMPDIR`, when the cycle runs, then it also uses `<SHIPFLOOR_HOME>/tmp`.
- **AC-3** — Given an install that already exists, when the owner runs `install-dispatcher.sh` again, then the regenerated entry point sets the new `TMPDIR` without any manual drop-in.
- **AC-4** — Given files and folders in `<SHIPFLOOR_HOME>/tmp` that have not changed for more than 3 days, when a cycle runs, then they are removed.
- **AC-5** — Given entries in `<SHIPFLOOR_HOME>/tmp` that changed in the last 3 days, or that the running cycle or a live run is using, when a cycle runs, then they are kept.
- **AC-6** — Given the dispatcher's effective `TMPDIR` is on a tmpfs, when the owner runs `shipfloor doctor`, then it prints a warning that names the path and says how to fix it; when it is not tmpfs, no warning appears.
- **AC-7** — Given a per-run `TMPDIR` (`tmp/<n>/tmp`, from #168), when a run starts, then it still gets its own folder, unchanged by this work.
**Out of scope:** CPU and memory limits (separate issue); removing the owner's local drop-in (a manual step after delivery); changing the `tmp/<n>/` sweep; cleaning the system `/tmp`.
**Product fit:** Serves the operating context, "runs, logs, locks and reports live under `~/.shipfloor`", on Windows, macOS and Linux alike: the factory keeps its scratch files under its own home and cleans them, so it cannot take down the owner's machine. The doctor warning is a script check, in the spirit of principle 2. No conflict with positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Layer: `factory` only. No endpoint, event or config key changes; no migration.

- `scripts/run-dispatcher.sh` (the one entry every scheduler starts: the systemd unit, cron line, launchd plist and the Windows task all run `~/.shipfloor/factory/run-dispatcher.sh`): after `H=...`, `mkdir -p "$H/tmp"` and `export TMPDIR="$H/tmp"`, before the cycle is exec'd. It overrides any inherited `TMPDIR` (AC-1, AC-2).
- `installer/install-dispatcher.sh` / `.ps1`: unchanged. The generated unit, plist, cron line and task already start `run-dispatcher.sh` and set no `TMPDIR`, so a reinstall (`shipfloor install`, then `install-dispatcher.sh`) gives the new behavior with no drop-in (AC-3).
- `scripts/shipfloor_core/project.py`: new `sweep_home_tmp(home, days=3)` → list of removed names. Walks only the direct entries of `<home>/tmp` (never the `TMPDIR` value, never `/tmp`), removes an entry when `_fresh(entry, days)` is false (nothing at or under it changed in the last 3 days, the `tmp/<n>/` sweep's criterion); symlinks are unlinked, never followed; an `OSError` skips the entry. A missing `<home>/tmp` returns `[]`.
- `scripts/shipfloor_core/cycle.py`: `_cycle(home, claim)` calls `project.sweep_home_tmp(home)` right after the overlap/PAUSE check (so only the cycle holding the claim sweeps, and it still sweeps while waiting on a usage or GitHub limit), and logs `<iso> shipfloor: removed tmp/<name>` per entry (AC-4, AC-5).
- `scripts/shipfloor_core/cli.py` (doctor): new check on `<home>/tmp`, the path `run-dispatcher.sh` sets. A helper `_fs_type(path, mounts="/proc/self/mounts")` returns the type of the longest mount point that contains the path (or its nearest existing parent); `None` when the mounts file is unreadable (macOS, Windows). `tmpfs` → `WARN dispatcher TMPDIR <path> is on tmpfs (inode cap); move SHIPFLOOR_HOME off tmpfs`; otherwise no line (AC-6).
- Per-run `TMPDIR` (`dispatch.py`, `tmp/<n>/tmp`): unchanged; a run still sets its own, which wins over the cycle's (AC-7).

Files: `scripts/run-dispatcher.sh`, `scripts/shipfloor_core/project.py`, `scripts/shipfloor_core/cycle.py`, `scripts/shipfloor_core/cli.py`, and the tests below.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dispatch-cli.test.sh` |
| AC-2 | factory | `scripts/test/dispatch-cli.test.sh` |
| AC-3 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-4 | factory | `scripts/test/py/dispatch_cycle.py` |
| AC-5 | factory | `scripts/test/py/dispatch_cycle.py` |
| AC-6 | factory | `scripts/test/py/cli_doctor.py` |
| AC-7 | factory | `scripts/test/py/dispatch_launch.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Set `TMPDIR` in `run-dispatcher.sh`, not in each unit/plist/cron/task: it is the single entry all four start, so one line covers every OS and a reinstall needs no unit change.
- `TMPDIR` is forced, not only defaulted: the bug is precisely an inherited `/tmp`.
- "In use" means changed in the last 3 days (`_fresh`), the existing `tmp/<n>/` criterion: no open-file scan, which is not portable; live runs write under `tmp/<n>/tmp`, not here.
- The sweep runs in the machine-wide cycle (`cycle.py`), not per project, because `<SHIPFLOOR_HOME>/tmp` is shared by every project; only the claim holder sweeps.
- The sweep never touches the `TMPDIR` env value, only `<home>/tmp`, so a wrong env can never point it at `/tmp`.
- The doctor reads the mount table (Linux) and stays silent where there is none (macOS, Windows): tmpfs inode caps are a Linux problem.
- AC-3 test: assert the generated entries start `run-dispatcher.sh` and set no `TMPDIR` of their own, which would override the entry's.
- Weight `heavy`: 7 acceptance criteria (rule: more than 6).

## Open questions
- none
