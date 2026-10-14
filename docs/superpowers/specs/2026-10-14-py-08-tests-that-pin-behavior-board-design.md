# Tests that pin behavior: board, setup-board, reports, metrics, review page, config, CLI — spec

**Issue:** #161 · **Branch:** `feat/161-py-08-tests-that-pin-behavior-board` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The Python port (PY-10, PY-11, PY-17) will replace these scripts. Today nothing pins their observable behavior, so a regression could ship without anyone noticing.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine and maintains it.
**Acceptance criteria**
- **AC-1** — Given a fake gh, when `scripts/test/` tests for `board.sh` run, then they assert the exact `items`/`snapshot` output (`n\tstatus\titemId`, mark stripped), `label add`, `move` exit 1 for an off-board card or unknown status, `move` reading status from a stale `FACTORY_BOARD_SNAPSHOT`, and what happens to item 101 under the 100-item limit.
- **AC-2** — Given a fake gh set through `FACTORY_GH`, when the `setup-board.sh` test runs, then it asserts the 10 options with marks, colors and descriptions, every card restored by name, a card with no column reported on stderr, the three labels created, `board-ids` removed, the printed counts, and `SNAPSHOT` setting the snapshot path.
- **AC-3** — Given the `report.sh` test, when it runs, then it asserts the remote `factory-reports` branch with no local worktree (`-B`), a failed push, two reports in the same second as today, and the header comment (`:3-4`) still documenting the report.json schema.
- **AC-4** — Given the `metrics.sh` test, when a report JSON lacks `issue`, `pipeline` or `outcome`, or `FACTORY_HOME` is unset while `FACTORY_CONFIG` is set, then today's exit code or crash is asserted.
- **AC-5** — Given the `review-page.sh` test, when it runs, then it asserts exit 2 on a wrong argument count, the `__KEY__` and `__DATE__` substitutions, and the "open questions / dúvidas" ordering.
- **AC-6** — Given the `shipfloor-config.sh` test, when `step <k>` runs with a lock, with no lock, and with a non-numeric k, then `k\t<epoch>` is written to `$SHIPFLOOR_RUN_LOCK/step` when a lock exists and the exit code is always 0.
- **AC-7** — Given no inbox file, when the `inbox-hook.sh` test runs it, then it exits 0 and the test fails if `FACTORY_PYTHON` is invoked.
- **AC-8** — Given the `shipfloor` CLI test, when it runs, then it asserts `setup-board`, `metrics`, `dashboard` (first line `shipfloor dashboard: <url>  (Ctrl+C stops it)`), `pool stacks n`, `add --main <b>`, `doctor`'s gh-auth, branch-protection and models lines, and the usage text from the header lines; each test file above is named after its script so `run.sh --changed` selects it, and the whole suite passes on main.
**Out of scope:** Any behavior change other than `setup-board.sh` honoring `FACTORY_GH`; deciding whether the owner-only `move` check must read the board live (pinned as is); the Python port itself.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): the port is held by tests, not by the agent's word that behavior is preserved. No conflict with positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Contracts:** none change. The only code change is `scripts/setup-board.sh` calling `"${FACTORY_GH:-gh}"` (as `board.sh` does) in place of plain `gh`.
- **Layer:** `factory` only. Files: `scripts/setup-board.sh` (edit); tests `scripts/test/board.test.sh`, `report.test.sh`, `review-page.test.sh`, `shipfloor-cli.test.sh` (extended); `setup-board.test.sh`, `metrics.test.sh`, `shipfloor-config.test.sh`, `inbox-hook.test.sh` (new).
- **Tests use the existing helpers** in `scripts/test/lib.sh` and a fake `gh` script written per test, in a temp dir. Each file names its script in its text, so `run.sh --changed` selects it.
- **Pinning:** assertions record what the scripts do today, including odd results (item 101 dropped by `first: 100`, same-second reports, a crash on a missing JSON field). A test never fixes the script to match its own expectation.
- **Migration:** none. **Rollback:** revert the commit.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/board.test.sh` |
| AC-2 | factory | `scripts/test/setup-board.test.sh` |
| AC-3 | factory | `scripts/test/report.test.sh` |
| AC-4 | factory | `scripts/test/metrics.test.sh` |
| AC-5 | factory | `scripts/test/review-page.test.sh` |
| AC-6 | factory | `scripts/test/shipfloor-config.test.sh` |
| AC-7 | factory | `scripts/test/inbox-hook.test.sh` |
| AC-8 | factory | `scripts/test/shipfloor-cli.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: 8 acceptance criteria (more than 6), although one layer.
- The owner-only check in `move` stays pinned as it is (stale snapshot); a live read is a separate issue, which keeps this one tests-only.
- Extend the existing test files for board, report, review-page and the CLI; new files only for scripts with no test today.

## Open questions
- none
