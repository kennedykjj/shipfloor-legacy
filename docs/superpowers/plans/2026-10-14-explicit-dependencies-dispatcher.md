# Plan — explicit dependencies in the dispatcher (#202)

**Spec:** `docs/superpowers/specs/2026-10-14-explicit-dependencies-dispatcher-design.md`
**Layer:** `factory` (path `./`), the only layer. Owner agent: `engineer`.
**Open question resolved:** option B. The refine agent writing "Blocked by" relations is a follow-up issue, not part of this card (it is already listed under the spec's Out of scope).

## Acceptance tests (QA, before any task)
- `scripts/test/dispatch-deps.test.sh`: AC-1, AC-2, AC-3, AC-6, AC-7, AC-8.
- `scripts/test/health-deps.test.sh`: AC-5 (`idle` and the waiting card).
- `scripts/test/dashboard-deps.test.sh`: AC-4, plus the AC-5 tile line and the AC-6 `dep.unread` line.
- `scripts/test/fake-gh` (test helper): answers `api repos/acme/shop/issues/<n>/dependencies/blocked_by` from `$d/blocked-by-<n>` (JSON array, default `[]`), exits 1 when `$d/fail-deps` exists, and logs each call to `$d/dep-calls`. The case goes before the generic `issues/<n>` case in both case blocks. QA adds it with the tests, since the tests cannot run without it.

## Task 1 — the dependency read and the dispatcher check (engineer, factory)
Depends on: the acceptance tests.
Files:
- `scripts/shipfloor_core/deps.py` (new): `blocked_by(repo, n)`, which makes one `gh api repos/<repo>/issues/<n>/dependencies/blocked_by?per_page=100` call and returns `[{"n", "title", "state"}]`, or `None` on a non-zero exit or a body that is not a JSON array. Also `open_numbers(deps)`, and `load(home)` / `save(home, record)` for `<home>/deps.json` (atomic: temp file + `os.replace`).
- `scripts/shipfloor_core/dispatch.py`: in `run_pipeline.start_run`, for stages develop, validate and deploy only (never refine), call `deps.blocked_by` once per candidate per cycle, before `block_card` and the launch. On an open dependency or `None`: record the entry (`read` false on `None`), set `self.started = 0` and return `True`, with no label, no slot taken and no failed cycle. Otherwise record the entry and go on. `run()` saves `deps.json` at the end of the cycle. Entries of cards not examined this cycle are carried over while the card is still on the board snapshot and not Done.
- The repo slug comes from `project.repo` (`self.cfg("get", "project.repo")`), as `block_card` does, never `FACTORY_REPO`.

## Task 2 — health does not count a waiting card as idle (engineer, factory)
Depends on: Task 1 (the `deps.json` format).
Files:
- `scripts/shipfloor_health.py`: `waiting(col)` skips a card whose `deps.json` entry has an open dependency or `read: false`, so `idle` does not count it.

## Task 3 — the dashboard shows the dependencies (engineer, factory)
Depends on: Task 1 (the `deps.json` format).
Files:
- `scripts/dashboard.py`: load `deps.json` per project. The card payload gets `deps` (each dependency's state resolved to the board column from the snapshot, `closed` when closed, `open` when open but off the board) and `deps_unread`. The `whyWaits` data gets the open numbers.
- `scripts/dashboard.html`: the drawer "Depends on" block in `tipHead`, the `why.deps` line in `whyWaits()` and the `dep.unread` line, exactly as in the spec's `## UX`.
- `scripts/lang/dashboard.*.json` (all 12 catalogs): `dep.h`, `dep.closed`, `dep.open`, `why.deps`, `dep.unread`, with the spec's copy (`dep.open` translated in each catalog).

## Task 4 — docs (engineer, factory)
Depends on: Tasks 1–3.
Files:
- `docs/operation.md`, `docs/contracts.md`: the dependency check, `deps.json`, and how to declare a dependency (GitHub's "Blocked by").

## Order
Acceptance tests → Task 1 → Task 2 → Task 3 → Task 4. They run one at a time, since they share the worktree.
