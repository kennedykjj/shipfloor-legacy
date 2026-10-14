# The scripts' contract, written down (docs/contracts.md) — spec

**Issue:** #155 · **Branch:** `feat/155-the-scripts-contract-written-down` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** standard

## Product
_Product Owner_

**Problem:** what the scripts promise their callers (verdict and log lines, GitHub markers, files under `~/.shipfloor`, env vars, the `claude -p` launch, security invariants) is scattered across comments, skills, dashboard regexes and tests. So a Python port (#153) can keep every test green and still break a consumer that no test covers.
**Audience:** the factory's owner, who maintains and ports the scripts, and the developers who install the plugin and extend it.

**Acceptance criteria**
- AC-1: Given the repo, when `docs/contracts.md` is opened, then it has a section for every `scripts/*.sh` file and for the `shipfloor` CLI.
- AC-2: Given `docs/contracts.md`, when its top is read, then it says the doc describes behavior and that when doc and code disagree, the code is the bug and the fix is a card.
- AC-3: Given every script's usage line lists subcommands that the doc also lists, when `scripts/test/contracts-doc.test.sh` runs, then it passes.
- AC-4: Given a script's usage line names a subcommand that `docs/contracts.md` does not list, when `scripts/test/contracts-doc.test.sh` runs, then it fails and names the script and the subcommand.
- AC-5: Given `docs/how-it-works.md`, when it is read, then it has a link to `docs/contracts.md`.

**Out of scope:** changing any script's behavior, output or exit codes; fixing a mismatch found while writing the doc (it gets its own card); automated checks of the doc beyond the usage-line subcommands; the port itself (#153, PY-10 to PY-17).

**Product fit:** serves principle 2 ("Deterministic gates outrank any agent's claim"): the contract becomes a written reference the port issues are checked against, and its subcommand coverage is enforced by a test, not by an agent saying so. It fits the positioning ("the gates are scripts") and does not conflict with anything out of scope.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts touched:** none. No script, endpoint, event or file format changes; the work is documentation plus one test.

**Layer:** `factory` only. Files:
- `docs/contracts.md` (new): top note (behavior, code is the bug, fix is a card), then one `##` section per script, headed by the file name (`board.sh`, `gate.sh`, `deploy.sh`, `dispatch.sh`, `shipfloor-dispatch.sh`, `run-dispatcher.sh`, `inbox-hook.sh`, `metrics.sh`, `report.sh`, `review-page.sh`, `setup-board.sh`, `shipfloor-config.sh`, `lib/project.sh`, `lib/stack.sh`) and `shipfloor` (the CLI). Each section lists its subcommands as backticked words under an "Interface" line. Cross-cutting sections follow: GitHub markers, files under `~/.shipfloor` (with readers), environment variables and test seams, the `claude -p` launch, security invariants, known quirks kept on purpose. Content is taken from the code as it is today, not from the issue's wording.
- `docs/how-it-works.md`: one link to `contracts.md`.
- `scripts/test/contracts-doc.test.sh` (new): for each `scripts/*.sh` (and `scripts/shipfloor`) it finds the script's `## <name>` section, reads the script's usage text (the `usage` heredoc or the `usage:` strings), extracts the subcommand words (alternatives split on `|`, ignoring `<arg>`, `[opt]`, flags and the script name) and fails with `<script>: <subcommand>` when a word is not in the section as a backticked token. It also checks that every script has a section (AC-1), the top note (AC-2) and the link (AC-5). AC-4 is proven inside the test by running the same check on a copy of the doc in `<tmp>` with one subcommand removed, expecting a failure that names script and subcommand. Output as `ok` / `FAIL` lines, via `scripts/test/lib.sh`, like `design-doc.test.sh`.

**Migration:** none. **Rollback:** n/a (docs and a test).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/contracts-doc.test.sh` |
| AC-2 | factory | `scripts/test/contracts-doc.test.sh` |
| AC-3 | factory | `scripts/test/contracts-doc.test.sh` |
| AC-4 | factory | `scripts/test/contracts-doc.test.sh` |
| AC-5 | factory | `scripts/test/contracts-doc.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- One test file for all five ACs: they check one document, and AC-4 needs the same extraction code as AC-3.
- Weight standard: one layer, 5 ACs, 3 files, no UI or security section.
- The doc lists subcommands as backticked words per script section, so the test can match them without parsing prose.
- Mismatches found between code and the issue's text are recorded in the doc as the code behaves and filed as cards, per the issue's "code is the bug".

## Open questions
- none
