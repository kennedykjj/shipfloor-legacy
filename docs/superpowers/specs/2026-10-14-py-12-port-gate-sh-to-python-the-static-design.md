# [PY-12] Port gate.sh to Python: the static gates — spec

**Issue:** #165 · **Branch:** `feat/165-py-12-port-gate-sh-to-python-the-static` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The static gates (`scope`, `forbidden`, `acceptance-intact`, `acceptance-own`, `qa-commit`, `qa-amend`, `migration`, `fast`, `test-plan`, `weight`) and the `gate.sh` dispatch are in Bash. They have to move to Python under `shipfloor_core/gate/`. The port must not change a single verdict, because these gates decide what passes.
**Audience:** The factory's owner, plus the developers who install the plugin and depend on its gates holding the same way.
**Acceptance criteria**
- **AC-1** — Given each static gate on each scenario repo built by the existing gate tests, when it runs through the Bash `gate.sh` (kept as a fixture) and through the Python one, then exit code, stdout, stderr and `last-gate` match byte for byte, in English and in pt-BR.
- **AC-2** — Given any gate invocation, when it passes, blocks, gets bad usage, a bad revision, a failed config query or an invalid ERE, or hits an infrastructure error, then it exits 0, 1, 2 or 3 as today, and an `exit` inside a check ends the whole gate.
- **AC-3** — Given a gate that reaches a verdict, when it ends, then the last stderr line is the English `gate <raw name>: pass|FAIL` (exit 2 shows as `FAIL`), and it is written to `last-gate` only when `$SHIPFLOOR_RUN_LOCK` exists. There is no verdict for a resolve or `-C` failure, for usage with no argument, for `acceptance-own` or for `stack`.
- **AC-4** — Given `FACTORY_LANGUAGE`, `language:` in `overrides.yml`, or `language:` in `FACTORY_CONFIG`, when a gate prints, then stderr is translated in that order of precedence through the sed catalog, and stdout carries only data (`qa-commit` the sha, `acceptance-own` `own:<hash>`).
- **AC-5** — Given committed renames, uncommitted changes, untracked files that are not ignored, or a name with control characters, when `scope`/`forbidden` run, then the changed set and the ERE matching from `shipfloor_config.py` give the same result as today. Control characters block, and scope's check runs before forbidden's control-character check.
- **AC-6** — Given a card's QA commits and an `accepted.tsv` written before the port, when `acceptance-intact` runs and `shipfloor accept` is used, then the allow paths apply in today's order, `own:` keys are byte-identical, and the old records still match.
- **AC-7** — Given an amended QA commit, or a migration plan with existing and new migrations, when `qa-amend` or `migration` runs, then the keep regex, the max+1 count, `SKIP_MARKS`, the `## Rollback` rules, the destructive keywords and the non-blocking warnings for main's bad names behave as today.
- **AC-8** — Given a spec, when `test-plan` or `weight` runs (`weight` without a config query, stripping `\r`), then every message is exactly as today. `gate.sh --help` prints the same usage text, including `green <layer> <selector>` and `weight <spec>`.
- **AC-9** — Given the unchanged test suites (`gate-*.test.sh`, `stack-lock.test.sh`, `dispatch-stepup.test.sh`, `deploy-*`, PY-05), when they run in English and pt-BR, then all pass with no edits, and `build`/`red`/`green`/`stack` are still handed to `scripts/lib/gate-run.sh` unchanged.
**Out of scope:** Porting `build`, `red`, `green` and `stack` (#164, PY-13). Any change to gate behavior, messages, exit codes or translations. New gates.
**Product fit:** Serves principle 2 ("Deterministic gates outrank any agent's claim") and the positioning ("the gates are scripts, not the agents' word"). A behavior-preserving port proven by a differential test keeps the gates deterministic. It contradicts neither.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts:** the CLI of `gate.sh` (arguments, exit codes, stderr verdict, `last-gate`, stdout data) does not change. New public Python entry: `shipfloor_core.gate.main(argv) -> int`. `scripts/gate.sh` keeps its name and becomes a wrapper that runs it; `build|red|green|stack` are handed to `scripts/lib/gate-run.sh` (the current Bash code of those four gates, moved unchanged, with the shared helpers it needs).

**Layer:** one, `factory`. Files:
- `shipfloor_core/gate/__init__.py` and `main.py`: dispatch, `-C`, help/usage, language lookup, verdict and `last-gate`, stderr translation through `scripts/lang/<code>.sed`.
- `shipfloor_core/gate/changes.py`: changed files (`git diff -z --name-only --no-renames`, uncommitted, untracked, `core.quotePath=false`) and the control-character check.
- `shipfloor_core/gate/scope.py`: `scope`, `forbidden` (patterns from `shipfloor_config.py`, matched with PY-09 `ere_match`).
- `shipfloor_core/gate/acceptance.py`: `acceptance-intact`, `acceptance-own`, `qa-commit`, `qa-amend`; `own:` key = `git hash-object` of the own-edit lines plus a trailing newline.
- `shipfloor_core/gate/migration.py`: `migration`, `fast`.
- `shipfloor_core/gate/spec.py`: `test-plan`, `weight`.
- `scripts/gate.sh` (wrapper), `scripts/lib/gate-run.sh` (new, Bash code of build/red/green/stack).
- `scripts/test/fixtures/gate.bash.sh`: the pre-port `gate.sh`, kept as the differential test's reference.
- New tests (see Test plan).

**Migration plan:** no data migration. `accepted.tsv` format and `own:` keys unchanged. Port in this order: fixture copy of the Bash gate, differential test (green against Bash), then the Python gates one by one until the differential stays green, then swap the wrapper. Rollback is reverting the PR plus `shipfloor install`.

**Dependencies:** needs the `shipfloor_core` package, the process helpers and `ere_match` (#162), the gate fixes (#156) and the pinned tests (#158) on main first.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-py-diff.test.sh` |
| AC-2 | factory | `scripts/test/gate-py-exit.test.sh` |
| AC-3 | factory | `scripts/test/gate-py-verdict.test.sh` |
| AC-4 | factory | `scripts/test/gate-py-language.test.sh` |
| AC-5 | factory | `scripts/test/gate-py-changes.test.sh` |
| AC-6 | factory | `scripts/test/gate-py-accept.test.sh` |
| AC-7 | factory | `scripts/test/gate-py-qa-migration.test.sh` |
| AC-8 | factory | `scripts/test/gate-py-plan-weight.test.sh` |
| AC-9 | factory | `scripts/test/gate-py-delegate.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: one layer but more than 6 ACs and more than 8 files.
- Reference Bash gate kept as a test fixture, as the issue asks, so the differential test needs no git history.
- `build|red|green|stack` stay in Bash via `scripts/lib/gate-run.sh` until #166, as the issue says.

## Open questions
- **Order:** A (recommended) hold this card until #162, #156 and #158 are merged (none is on main; `shipfloor_core` does not exist yet) or B approve now — develop would fail with no package or `ere_match` to build on.
