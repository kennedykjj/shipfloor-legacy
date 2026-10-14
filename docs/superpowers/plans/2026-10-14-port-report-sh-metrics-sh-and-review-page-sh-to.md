# Plan — #164 Port report.sh, metrics.sh and review-page.sh to Python

Spec: `docs/superpowers/specs/2026-10-14-port-report-sh-metrics-sh-and-review-page-sh-to-design.md`
Layers: `factory` only (path `./`, agent `engineer`). Tasks run one at a time in the same worktree.

Foundation on the branch (from #162): `scripts/sf.py` (a `COMMANDS` table), `scripts/lib/py.sh` (finds Python, `exec`s `sf.py "$@"` under `-I`; the wrapper sets `HERE` first), `templates/py-wrapper.sh`, `scripts/shipfloor_core/{proc,project,fs,text}.py` (`proc.git`, `proc.native_path`, `project.resolve`, `ProjectError`).

## Task 0 — Acceptance tests (qa-engineer)
- `scripts/test/port-reports.test.sh` (new): AC-1, AC-2, AC-5, plus the unit-style cases the spec lists (orphan vs `-B`, `pull --rebase` failure, metrics null/rounding, review-page exit 2 and LF).
- `scripts/test/hygiene.test.sh` (changed): AC-8, the three wrappers hold no logic.
- `scripts/test/report.test.sh`, `scripts/test/review-page.test.sh`, `scripts/test/metrics.test.sh`: no edits (AC-8). They cover AC-3, AC-4, AC-6, AC-7 today and must keep passing after the port.

## Task 1 — report (factory, engineer)
Depends on: Task 0.
- `scripts/shipfloor_core/report.py` (new): `main(argv)`; `-h|--help|help` → usage, exit 0, before resolve; argument count ≠ 5 → usage on stderr, exit 2; `project.resolve` failure → exit 2; the `factory-reports` worktree under `FACTORY_HOME/reports-wt` (`worktree add -B` from `origin/factory-reports`, else detached + orphan + `README.md` "# Factory reports" + `chore(factory): start reports branch`); `pull --rebase` ignoring failure; local `%Y-%m-%dT%H%M%S` stamp; copy both files; commit `chore(factory): report #N pipeline stamp` with the Co-Authored-By trailer; push. Git through `proc.git`.
- `scripts/report.sh` (rewritten): the wrapper from `templates/py-wrapper.sh`, passing `report` before the arguments; keeps the header comment with the report.json schema.
- `scripts/sf.py`: register `report`.

## Task 2 — metrics (factory, engineer)
Depends on: Task 1 (shares `sf.py`).
- `scripts/shipfloor_core/metrics.py` (new): `main(argv)`; resolve (exit 2); `pull --rebase` that never fails; TSV header and rows exactly as `metrics.sh` prints today, malformed reports as PY-08 pinned (`scripts/test/metrics.test.sh`).
- `scripts/metrics.sh` (rewritten): wrapper, `metrics` command; `scripts/sf.py`: register `metrics`.

## Task 3 — review-page (factory, engineer)
Depends on: Task 2.
- `scripts/shipfloor_core/review_page.py` (new): `build(spec, issue, branch, out, template, label, project)` and `main(argv)` with the logic of `scripts/review_page.py`; argument count ≠ 4 or spec not a file → exit 2; creates the output folder; LF output.
- `scripts/review_page.py` (deleted).
- `scripts/review-page.sh` (rewritten): wrapper, `review-page` command; `scripts/sf.py`: register `review-page`.
- `docs/contracts.md`: the review-page entry names `shipfloor_core/review_page.py` instead of `review_page.py` (no contract change).

## Gates after each task
`scope factory <start>`, `acceptance-intact <qa>`, `migration <base> <spec>` (no migration), `build <base>`; at the end `green factory <selector>` for every acceptance test file in the QA commit, plus `report.test.sh`, `review-page.test.sh`, `metrics.test.sh`.
