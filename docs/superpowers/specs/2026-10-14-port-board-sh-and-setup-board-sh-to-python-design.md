# [PY-10] Port board.sh and setup-board.sh to Python — spec

**Issue:** #163 · **Branch:** `feat/163-port-board-sh-and-setup-board-sh-to-python` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** standard

## Product
_Product Owner_

**Problem:** `board.sh` and `setup-board.sh` hold the factory's board logic in Bash; part of the Python port (#153), they must move to `shipfloor_core` without any change a user or a gate can see.
**Audience:** the factory's owner and developers who install the plugin (they run the dispatcher, the gates and the dashboard on top of `board.sh`).

**Acceptance criteria**
- AC-1: Given a stubbed `gh`, when any `board.sh` subcommand (`items`, `status`, `count`, `eligible`, `first`, `move`, `snapshot`, `infra`, `label`, `issue`) or `setup-board.sh` runs, then the recorded `gh` argv (GraphQL query text and `--jq`, per-card REST label reads, `project view`/`field-list`/`item-edit`, label POST/DELETE, the `blocked:infra` issues URL, setup's `--force` labels and `item-list --limit 500`) matches today's character for character, and `board.sh` never calls `project item-list`.
- AC-2: Given bad input, when `board.sh` runs, then it exits 2 for a bad owner/number, fewer than 3 config values, an unknown column, a non-numeric issue or an unknown subcommand; 3 for an owner-only target (Ready for Refinement, Ready for Dev, Ready for Prod) or source (Spec Review, Staged); 1 for a card not on the board, an unknown status, a failed lookup, a failed `count` or an empty `api user`.
- AC-3: Given one failed label lookup, when `eligible` runs, then it prints nothing and exits 1; given any outcome, `label remove` exits 0; given a status with an owner mark, the mark is stripped by the C-locale rule `^[^A-Za-z]+ `; given a non-empty `FACTORY_BOARD_SNAPSHOT`, every subcommand except `snapshot` reads it.
- AC-4: Given an issue with comments, when `board.sh issue <n>` runs, then it prints `#N title`, the body, each trusted comment as `--- comment by L, createdAt`, and `(k comment[s] by other people not shown)`, where trusted is the factory's user plus `trusted_commenters` from the snapshot config (`*` = anyone).
- AC-5: Given a board, when `setup-board.sh` runs, then it takes the snapshot before rewriting the options, writes the 10 options with marks, colors and descriptions, restores cards by plain name, creates the three labels with `--force` and removes `board-ids`.
- AC-6: Given the port, when the suite runs, then the existing `board*.test.sh`, `dispatch-order.test.sh`, `dashboard*.test.sh` and the PY-08 board and setup-board tests pass unedited; a hygiene test shows `board.sh` only sources `lib/py.sh` and execs; and on Linux `board.sh status <n>` with a snapshot is at most 100 ms slower than the Bash version.

**Out of scope:** new subcommands or flags; any change to gh calls, exit codes, output text or column names; porting other scripts (other PY-* issues); dashboard changes.

**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim) and principle 1 (the board stays the source of truth): the gates and the dispatcher keep the exact board contract they rely on. No conflict with the positioning.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts:** the CLI `board.sh items|status|count|first|eligible|move|snapshot|infra|label|issue` and `setup-board.sh` (env `SNAPSHOT`, `FACTORY_GH`, `FACTORY_BOARD_SNAPSHOT`, `FACTORY_HOME`) keep argv, stdout, stderr and exit codes. No new public contract. `shipfloor_core/board.py` exposes `main(argv)`; `shipfloor_core/setup.py` exposes `main(argv)`; both are reached through `sf.py board` and `sf.py setup-board` (PY-09).
**Layer:** only `factory`. Files:
- `scripts/shipfloor_core/board.py` (new): all ten subcommands, built on `proc.gh`, `project.py` (resolve, cfg values) and the C-locale mark rule as a Python regex `^[^A-Za-z]+ ` on ASCII letters. `board-ids` cache keeps its file format (`PROJECT_ID FIELD_ID`).
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

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight standard: one layer, 6 ACs, 6 files.
- Tests go in two new files and existing ones stay unedited, as the issue demands.
- The 100 ms timing check is measured in `board-port.test.sh` on Linux only.

## Open questions
- none
