# [PY-10] Port board.sh and setup-board.sh to Python — plan

**Issue:** #163 · **Spec:** `docs/superpowers/specs/2026-10-14-port-board-sh-and-setup-board-sh-to-python-design.md`

One layer (`factory`), one owner agent (`engineer`). Tasks run in order; they share the worktree.

## Tasks

1. **board.py** (layer `factory`, agent `engineer`)
   - Files: `scripts/shipfloor_core/board.py` (new), `scripts/sf.py` (register `board`).
   - All ten subcommands (`items`, `status`, `count`, `first`, `eligible`, `move`, `snapshot`, `infra`, `label`, `issue`) on `proc.gh` and `project.py`, with the exit codes, output and stderr of today's `board.sh`.
   - Board read for `snapshot`/`move`: REST first (`GET /users/{owner}/projectsV2/{n}/items?fields=<Status field id>`, `Link` header paging, `PATCH .../items/{item_id}`), GraphQL fallback with today's query text and `--jq` plus cursor paging. A snapshot line keeps the id its path needs to move a card; board position order on both paths.
   - Paging must terminate against a stub that ignores the cursor (stop on a short page, a page with no new item, or `hasNextPage` false).
   - `board-ids` cache format kept; C-locale owner-mark rule `^[^A-Za-z]+ `; `FACTORY_BOARD_SNAPSHOT` used by all but `snapshot`.
   - Depends on: nothing.

2. **setup.py** (layer `factory`, agent `engineer`)
   - Files: `scripts/shipfloor_core/setup.py` (new), `scripts/sf.py` (register `setup-board`).
   - `setup-board` as `setup-board.sh` does today: snapshot first, 10 options with marks, colors and descriptions, restore by plain name, three labels with `--force`, remove `board-ids`, `item-list --limit 500`; honors `FACTORY_GH`, `SNAPSHOT`, `FACTORY_HOME`.
   - Depends on: task 1 (shared helpers).

3. **Wrappers** (layer `factory`, agent `engineer`)
   - Files: `scripts/board.sh`, `scripts/setup-board.sh` (reduced to the `templates/py-wrapper.sh` form: set `HERE`, `source lib/py.sh`; `sf.py` gets the command name first).
   - Existing tests stay as they are; only a stub is adapted when a pinning test cannot pass through the GraphQL fallback. The cap pins in `board.test.sh` (101 cards read as 100) contradict AC-9; the engineer reports each such case.
   - Depends on: tasks 1 and 2.

## Tests (QA, before any implementation)

- `scripts/test/py-board-unit.test.sh` (new): AC-1 to AC-5, AC-7 to AC-9.
- `scripts/test/board-port.test.sh` (new): AC-6 (hygiene of both wrappers, the 100 ms timing check on Linux).
