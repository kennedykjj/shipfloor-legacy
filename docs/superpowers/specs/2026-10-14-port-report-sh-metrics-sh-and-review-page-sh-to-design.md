# Port report.sh, metrics.sh and review-page.sh to Python — spec

**Issue:** #164 · **Branch:** `feat/164-port-report-sh-metrics-sh-and-review-page-sh-to` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** `report.sh`, `metrics.sh` and `review-page.sh` carry their logic in Bash. Under the Python port (#153) they must move to `shipfloor_core` without any change that agents, skills, the dashboard or the owner can see.
**Audience:** The factory's owner and the developers who install the plugin. They run these scripts through the pipeline and read their reports, metrics and review pages.
**Acceptance criteria**
- **AC-1** — Given `report.sh` is called with `-h`, `--help` or `help`, When it runs, Then it exits 0 before resolving the project and prints the report.json schema from the wrapper's header comment; a wrong argument count or a resolve failure exits 2.
- **AC-2** — Given no remote `factory-reports` branch, When a report is written, Then an orphan `factory-reports` branch is created with `README.md` "# Factory reports" as its first commit. Given the remote branch exists, Then it is checked out with `worktree add -B` and `pull --rebase` runs before writing. In both cases `main` is never touched.
- **AC-3** — Given a report for issue N, When it is written, Then it lands at `reports/<issue>-<slug>/<pipeline>-<local %Y-%m-%dT%H%M%S>.{json,md}`, is committed as `chore(factory): report #N pipeline stamp` with the same trailer, and is pushed.
- **AC-4** — Given the existing report fixture, When `metrics.sh` runs, Then its TSV header and rows match today's: tokens summed over `agents[].tokens`, minutes rounded, rounds summed, gates_failed comma-joined, null printed as empty, and the fixture row is `26\trefine\tok\t1000\t12`. Malformed reports are handled as PY-08 pinned.
- **AC-5** — Given `pull --rebase` fails, When `metrics.sh` runs, Then the command still succeeds and prints the metrics.
- **AC-6** — Given `review-page.sh` is called with a wrong argument count or a spec that does not exist, When it runs, Then it exits 2.
- **AC-7** — Given a valid spec, When `review-page.sh` builds the page, Then it fills the same template placeholders (`__DATA__ __ISSUE__ __TITLE__ __BRANCH__ __SPEC__ __DATE__ __KEY__`) and shows the same sections in the same order. "Open questions" / "dúvidas" comes first and stays editable, and the output uses LF line endings.
- **AC-8** — Given the ported code, When the test suite runs, Then `report.test.sh`, `review-page.test.sh` and the PY-08 cases pass with no edits, and the hygiene test confirms the three `.sh` wrappers hold no logic.

**Out of scope:** Changes to the report.json schema, the TSV columns, the review page template or its wording. New metrics. Porting other scripts (those belong to other children of #153).
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): the report and metrics scripts stay deterministic, and the port moves them to tested Python. It also serves principle 3, since the metrics numbers stay exact and sourced from the reports. It contradicts no part of the positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Prerequisite:** #162 (PY-09, `scripts/shipfloor_core/`, `scripts/sf.py`, `scripts/lib/py.sh`, `proc.py`, `project.py`) and #161 (PY-08, the pinning tests) are not on main yet. `develop` starts only after both merge; names below follow the #162 text and are adjusted to what actually lands.

**Contracts (no change):** the CLI of the three scripts (arguments, exit codes, stdout/stderr), `report.json` schema, the metrics TSV, the page template placeholders, the `factory-reports` layout. New public functions only inside the package: `report.main(argv)`, `metrics.main(argv)`, `review_page.build(spec, issue, branch, out, template, label, project)` and `review_page.main(argv)`.

**Layer touched:** `factory` only (Bash wrappers and Python under `scripts/`).

**Files:**
- `scripts/shipfloor_core/report.py` (new): argument check, resolve (exit 2), `factory-reports` worktree (`worktree add -B` or orphan + README commit), `pull --rebase`, stamp, copy, commit with trailer, push; git through `proc.git`.
- `scripts/shipfloor_core/metrics.py` (new): `pull --rebase` that never fails, TSV from `reports/*/*.json`, malformed-report behavior exactly as #161 pinned.
- `scripts/shipfloor_core/review_page.py` (new): the logic of `scripts/review_page.py` moved as a function; LF output.
- `scripts/review_page.py` (deleted): absorbed; nothing else imports it (checked: only `review-page.sh`).
- `scripts/report.sh`, `scripts/metrics.sh`, `scripts/review-page.sh` (rewritten): wrappers sourcing `lib/py.sh` and `exec`-ing `sf.py <command>`. `report.sh` keeps the header comment (report.json schema) and its `--help` text; the `-h|--help|help` exit 0 and the argument-count exit 2 are kept in the Python side before resolve.
- `scripts/sf.py` (changed): registers `report`, `metrics`, `review-page`.
- `scripts/test/hygiene.test.sh` (changed): asserts the three wrappers hold no logic (a few lines, no control flow beyond sourcing `lib/py.sh` and `exec`).
- `scripts/test/port-reports.test.sh` (new): unit-style cases for the paths the existing tests do not reach (orphan vs `-B`, `pull --rebase` failure, metrics null/rounding, review-page exit 2 and LF).

**Migration:** none. Rollback is reverting the PR and `shipfloor install` again.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/port-reports.test.sh` |
| AC-2 | factory | `scripts/test/port-reports.test.sh` |
| AC-3 | factory | `scripts/test/report.test.sh` |
| AC-4 | factory | `scripts/test/report.test.sh` |
| AC-5 | factory | `scripts/test/port-reports.test.sh` |
| AC-6 | factory | `scripts/test/review-page.test.sh` |
| AC-7 | factory | `scripts/test/review-page.test.sh` |
| AC-8 | factory | `scripts/test/hygiene.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight `heavy`: one layer and no security section, but 8 acceptance criteria (over 6) and 10 files (over 8).
- Package location `scripts/shipfloor_core/` and entry `sf.py`: fixed by #162, so the three ports follow it rather than invent a layout.
- Dependencies #161 and #162 are open: the spec is written against the issues' text and `develop` must wait for both to merge; not a question for the owner, it is the order already set in #153.
- A new `port-reports.test.sh` holds the cases the existing tests do not cover, so `report.test.sh` and `review-page.test.sh` stay unedited as the issue demands.
- `scripts/review_page.py` is removed once absorbed, to keep one source of truth.

## Open questions
- none
