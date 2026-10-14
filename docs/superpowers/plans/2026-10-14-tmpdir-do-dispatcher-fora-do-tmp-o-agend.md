# Plan — #218 TMPDIR do dispatcher fora do /tmp

Spec: `docs/superpowers/specs/2026-10-14-tmpdir-do-dispatcher-fora-do-tmp-o-agend-design.md`
Layers: `factory` only (owner agent: `engineer`). No migration.

## Tasks

### T1 — factory: dispatcher entry point forces `TMPDIR` (AC-1, AC-2, AC-3, AC-7)
- Owner: `engineer`, layer `factory`.
- Files: `scripts/run-dispatcher.sh`.
- After `H=...`: `mkdir -p "$H/tmp"` and `export TMPDIR="$H/tmp"`, before the cycle is exec'd; overrides any inherited `TMPDIR`.
- `installer/install-dispatcher.sh` / `.ps1` stay unchanged (they already start `run-dispatcher.sh` and set no `TMPDIR`); per-run `TMPDIR` in `dispatch.py` unchanged.
- Depends on: nothing.

### T2 — factory: sweep `<home>/tmp` in the cycle (AC-4, AC-5)
- Owner: `engineer`, layer `factory`.
- Files: `scripts/shipfloor_core/project.py` (`sweep_home_tmp(home, days=3)`), `scripts/shipfloor_core/cycle.py` (call it in `_cycle` after the overlap/PAUSE check, log `<iso> shipfloor: removed tmp/<name>` per entry).
- Only direct entries of `<home>/tmp`; reuse `_fresh`; symlinks unlinked, never followed; `OSError` skips the entry; missing dir → `[]`.
- Depends on: nothing (independent of T1).

### T3 — factory: doctor warns on tmpfs (AC-6)
- Owner: `engineer`, layer `factory`.
- Files: `scripts/shipfloor_core/cli.py` (`_fs_type(path, mounts="/proc/self/mounts")`, doctor check on `<home>/tmp`).
- `tmpfs` → `WARN dispatcher TMPDIR <path> is on tmpfs (inode cap); move SHIPFLOOR_HOME off tmpfs`; otherwise no line; unreadable mounts → silent.
- Depends on: nothing.

## Order
T1 → T2 → T3 (one at a time, shared worktree).

## Acceptance tests (QA)
Per the spec's test plan: `scripts/test/dispatch-cli.test.sh` (AC-1, AC-2), `scripts/test/install-dispatcher.test.sh` (AC-3), `scripts/test/py/dispatch_cycle.py` (AC-4, AC-5), `scripts/test/py/cli_doctor.py` (AC-6), `scripts/test/py/dispatch_launch.py` (AC-7).
