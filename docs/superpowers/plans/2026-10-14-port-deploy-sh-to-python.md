# Plan — #167 Port deploy.sh to Python

Spec: `docs/superpowers/specs/2026-10-14-port-deploy-sh-to-python-design.md`
Layers: `factory` only (path `./`, agent `engineer`). Tasks run one at a time in the same worktree.

Foundation on main (from #162, #164): `scripts/sf.py` (a `COMMANDS` table), `scripts/lib/py.sh`, `templates/py-wrapper.sh`,
`scripts/shipfloor_core/{proc,project,fs,text}.py`. #163 (`board` in Python) is not merged: `deploy.py` keeps calling
`board.sh` (or `$FACTORY_BOARD`) as an external process with the same argv, so it does not depend on it.

## Task 0 — Acceptance tests (qa-engineer)
- `scripts/test/fixtures/deploy-bash.sh` (new): today's `scripts/deploy.sh`, verbatim except `HERE`, which points two
  folders up (the fixture lives in `scripts/test/fixtures/`).
- `scripts/test/deploy-differential.test.sh` (new): AC-1..AC-8. Static checks that `deploy.sh` is the wrapper and
  `sf.py deploy` is registered (red until Task 2), then every `deploy-*.test.sh` is run, unedited, in two copies of
  `scripts/` whose `deploy.sh` is a recorder in front of the fixture (one copy) or today's `deploy.sh` (the other).
  Each run's record (exit code, stdout, stderr, the fake gh's full call log, comments, labels, status, the remote's
  refs, hand-over files, lock, worktree) must match between the copies once temp paths and shas are normalized.
- Existing `deploy-*.test.sh`, `dispatch-review.test.sh`, `hygiene.test.sh`: no edits (AC-8).

## Task 1 — deploy.py (factory, engineer)
Depends on: Task 0.
- `scripts/shipfloor_core/deploy.py` (new): `main(argv)`; one function per Bash function (`say`, `comment`,
  `reset_worktree`, `block`, `back_to_coding`, `retry_later`, `resume_merged`, `approved_chain`, `merge_main`,
  `check_resolution`, `renumber_migrations`, `qa_commit`, `hand_fix`, `check_fix`, `ci_findings`, `fast_gates`,
  `local_ci`, `wait_checks`, `push_recorded`, production, revert). Exits through `DeployExit(code)`; the lock is removed
  in one `finally`, except on the exit-3 paths, which remove it first. Same processes and argv (`git`, `gh`, `curl`,
  `timeout`, `bash gate.sh`, `board.sh`), same streams (what Bash let through to stderr still goes there), the same
  env (`FACTORY_GH`, `FACTORY_BOARD`, `FACTORY_CURL`, `FACTORY_POLL`, `FACTORY_POLLS`); `grep -E` through `text`.
- `scripts/shipfloor_core/proc.py`: `git`/`gh` take the streams as keywords; `script_argv` runs a script directly
  (or through bash on Windows), and `gh` uses it.
- `scripts/shipfloor_core/text.py`: `ere_match(..., invert=)` (`grep -Ev`) and `ere_lines` (the lines `grep -E` prints).
- `scripts/shipfloor_core/project.py`: `cfg(..., input=)` for `migration-renumber`, which reads stdin.
- `scripts/sf.py`: register `deploy`.

## Task 2 — the wrapper (factory, engineer)
Depends on: Task 1.
- `scripts/deploy.sh` (rewritten): the wrapper from `templates/py-wrapper.sh` with `set -- deploy "$@"`; keeps the
  header comment (usage and exit codes).
- `docs/contracts.md`: the deploy.sh entry names `shipfloor_core/deploy.py`; `lib/portable.sh` is no longer sourced
  by deploy.sh (no contract change).

## Gates
`bash scripts/test/run.sh` with 0 FAIL (the differential test included), `hygiene.test.sh`, `py-unit.test.sh`.
