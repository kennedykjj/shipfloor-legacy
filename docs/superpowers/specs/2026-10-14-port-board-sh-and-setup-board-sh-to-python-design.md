# [PY-10] Port board.sh and setup-board.sh to Python — spec

**Issue:** #163 · **Branch:** `feat/163-port-board-sh-and-setup-board-sh-to-python` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** standard

## Product
_Product Owner_

**Problem:** `board.sh` and `setup-board.sh` hold the factory's board logic in Bash; part of the Python port (#153), they move to `shipfloor_core`. On 2026-10-14 the pipelines exhausted the GraphQL quota and every dispatcher cycle failed with "board read failed"; the board read also stops at 100 items. The port reads and moves cards through the REST Projects API first (core quota), keeps GraphQL only as fallback, and reads the whole board.
**Audience:** the factory's owner and developers who install the plugin (they run the dispatcher, the gates and the dashboard on top of `board.sh`).

**Acceptance criteria**
- AC-1: Given a stubbed `gh` whose REST Projects calls fail, when any `board.sh` subcommand (`items`, `status`, `count`, `eligible`, `first`, `move`, `snapshot`, `infra`, `label`, `issue`) or `setup-board.sh` runs, then the GraphQL query text and `--jq` match today's character for character (only the cursor paging of AC-8 added), and every other `gh` argv (per-card REST label reads, `project view`/`field-list`/`item-edit`, label POST/DELETE, the `blocked:infra` issues URL, setup's `--force` labels and `item-list --limit 500`) is unchanged; `board.sh` never calls `project item-list`.
- AC-2: Given bad input, when `board.sh` runs, then it exits 2 for a bad owner/number, fewer than 3 config values, an unknown column, a non-numeric issue or an unknown subcommand; 3 for an owner-only target (Ready for Refinement, Ready for Dev, Ready for Prod) or source (Spec Review, Staged); 1 for a card not on the board, an unknown status, a failed lookup, a failed `count` or an empty `api user`.
- AC-3: Given one failed label lookup, when `eligible` runs, then it prints nothing and exits 1; given any outcome, `label remove` exits 0; given a status with an owner mark, the mark is stripped by the C-locale rule `^[^A-Za-z]+ `; given a non-empty `FACTORY_BOARD_SNAPSHOT`, every subcommand except `snapshot` reads it.
- AC-4: Given an issue with comments, when `board.sh issue <n>` runs, then it prints `#N title`, the body, each trusted comment as `--- comment by L, createdAt`, and `(k comment[s] by other people not shown)`, where trusted is the factory's user plus `trusted_commenters` from the snapshot config (`*` = anyone).
- AC-5: Given a board, when `setup-board.sh` runs, then it takes the snapshot before rewriting the options, writes the 10 options with marks, colors and descriptions, restores cards by plain name, creates the three labels with `--force` and removes `board-ids`.
- AC-6: Given the port, when the suite runs, then the existing `board*.test.sh`, `dispatch-order.test.sh`, `dashboard*.test.sh` and the PY-08 board and setup-board tests pass unedited; a hygiene test shows `board.sh` only sources `lib/py.sh` and execs; and on Linux `board.sh status <n>` with a snapshot is at most 100 ms slower than the Bash version.
- AC-7: Given the REST Projects API answers, when `snapshot` or `move` runs, then it reads `GET /users/{owner}/projectsV2/{n}/items?fields=<Status field id>` and moves with `PATCH .../items/{item_id}` (numeric id), and makes no GraphQL call.
- AC-8: Given a REST call that fails, when `snapshot` or `move` runs, then it falls back to today's GraphQL path (node ids `PVTI_...`) with the same output and exit code, and the snapshot keeps the id the path that wrote it needs to move a card.
- AC-9: Given a board of more than 100 items, when `snapshot` runs on either path, then every item is read (REST through `Link` headers, GraphQL through the cursor) and the output stays in the board's position order.

**Out of scope:** new subcommands or flags; any change to exit codes, output text or column names; any gh call change other than REST-first snapshot/move and paging; porting other scripts (other PY-* issues); dashboard changes.

**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim) and principle 1 (the board stays the source of truth): the gates and the dispatcher keep the exact board contract they rely on, and keep reading the board when the GraphQL quota is gone. No conflict with the positioning.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts:** the CLI `board.sh items|status|count|first|eligible|move|snapshot|infra|label|issue` and `setup-board.sh` (env `SNAPSHOT`, `FACTORY_GH`, `FACTORY_BOARD_SNAPSHOT`, `FACTORY_HOME`) keep argv, stdout, stderr and exit codes. No new public contract. `shipfloor_core/board.py` exposes `main(argv)`; `shipfloor_core/setup.py` exposes `main(argv)`; both are reached through `sf.py board` and `sf.py setup-board` (PY-09).
**Layer:** only `factory`. Files:
- `scripts/shipfloor_core/board.py` (new): all ten subcommands, built on `proc.gh`, `project.py` (resolve, cfg values) and the C-locale mark rule as a Python regex `^[^A-Za-z]+ ` on ASCII letters. `board-ids` cache keeps its file format (`PROJECT_ID FIELD_ID`).
  - Board read (`snapshot`, `move`): REST first (`gh api --paginate -i`-style paging by `Link` header on `GET /users/{owner}/projectsV2/{n}/items?fields=<Status field id>`), move by `PATCH .../items/{item_id}` with the numeric id; on any REST failure, GraphQL fallback with today's query plus `after:`/`pageInfo` cursor paging. Both paths yield the same snapshot shape in board position order; each item records the id its own path needs for a move (numeric for REST, `PVTI_...` for GraphQL), and a move uses the id of the path that wrote the snapshot, falling back to GraphQL `item-edit` if the PATCH fails.
- `scripts/shipfloor_core/setup.py` (new): `setup-board`, honoring `FACTORY_GH`.
- `scripts/board.sh`, `scripts/setup-board.sh`: reduced to `source lib/py.sh` and `exec`.
- `scripts/test/board-port.test.sh` (new): hygiene (wrappers have no logic), argv/exit-code parity not already pinned, timing check.
- `scripts/test/py-board-unit.test.sh` (new): runs `unittest` for `board.py` and `setup.py` (issue output, trusted commenters, fail-closed `eligible`).
- Existing tests are not edited.

**Migration plan:** none (no data or schema). The Bash version is replaced in place; the parity is proven by the existing and PY-08 tests passing unedited.
**Dependencies:** needs #162 (package, `lib/py.sh`, `proc.gh`), #161 (pinning tests) and #157 (execute bit) merged first; develop starts only after them.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py-board-unit.test.sh` |
| AC-2 | factory | `scripts/test/py-board-unit.test.sh` |
| AC-3 | factory | `scripts/test/py-board-unit.test.sh` |
| AC-4 | factory | `scripts/test/py-board-unit.test.sh` |
| AC-5 | factory | `scripts/test/py-board-unit.test.sh` |
| AC-6 | factory | `scripts/test/board-port.test.sh` |
| AC-7 | factory | `scripts/test/py-board-unit.test.sh` |
| AC-8 | factory | `scripts/test/py-board-unit.test.sh` |
| AC-9 | factory | `scripts/test/py-board-unit.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight standard: one layer, 9 ACs (at most 6 files in Architecture), no security section.
- The owner's review overrides the issue's "gh argv identical" for the board read and move: REST first, GraphQL fallback, no 100-item cap; the fallback query is today's text plus cursor paging, as character identity is impossible once it pages.
- Existing pinning tests that record the snapshot-read argv run with the REST call failing (stub gh), so they pass unedited via the fallback; if one cannot, only its stub is adapted, never its expectations.
- Tests go in two new files and existing ones stay unedited, as the issue demands.
- The 100 ms timing check is measured in `board-port.test.sh` on Linux only.

## Open questions
- none
