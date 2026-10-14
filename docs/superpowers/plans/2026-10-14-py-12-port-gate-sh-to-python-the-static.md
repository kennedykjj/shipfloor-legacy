# Plan — #165 [PY-12] Port gate.sh to Python: the static gates

**Spec:** `docs/superpowers/specs/2026-10-14-py-12-port-gate-sh-to-python-the-static-design.md`
**Layer:** `factory` (single layer; agent `engineer`). Tasks run one at a time in the shared worktree.
The package lives at `scripts/shipfloor_core/` (the spec's `shipfloor_core/gate/` means `scripts/shipfloor_core/gate/`).

## Acceptance tests (qa-engineer, before any task)
- `scripts/test/fixtures/gate.bash.sh` — the pre-port `scripts/gate.sh`, copied byte for byte (it sources `lib/project.sh` and `lib/stack.sh` from beside the real `scripts/`: the test runs it with `HERE` pointing at `scripts/`, e.g. by copying it into a temp copy of `scripts/`)
- `scripts/test/gate-py-diff.test.sh` — AC-1 (Bash fixture vs the new `scripts/gate.sh`, every static gate, en and pt-BR)
- `scripts/test/gate-py-exit.test.sh` — AC-2
- `scripts/test/gate-py-verdict.test.sh` — AC-3
- `scripts/test/gate-py-language.test.sh` — AC-4
- `scripts/test/gate-py-changes.test.sh` — AC-5
- `scripts/test/gate-py-accept.test.sh` — AC-6
- `scripts/test/gate-py-qa-migration.test.sh` — AC-7
- `scripts/test/gate-py-plan-weight.test.sh` — AC-8
- `scripts/test/gate-py-delegate.test.sh` — AC-9 (the static gates run in Python; `build|red|green|stack` go to `scripts/lib/gate-run.sh`)

## Tasks

### T1 — dispatch, verdict, language, changed files (factory, engineer)
Depends on: acceptance tests.
Files:
- `scripts/shipfloor_core/gate/__init__.py`, `scripts/shipfloor_core/gate/main.py`: `main(argv) -> int`; `-C`, help/usage (same text), unknown command; project resolve (exit 2, no verdict); language lookup (`FACTORY_LANGUAGE`, `overrides.yml` beside `FACTORY_CONFIG`, then `FACTORY_CONFIG`, same regex); stderr through `text.say`; verdict with the raw command name, `last-gate` only when `$SHIPFLOOR_RUN_LOCK` is a dir; none for `acceptance-own`/`stack`; a check's `exit` ends the gate (an exception carrying the code).
- `scripts/shipfloor_core/gate/changes.py`: `raw_changes`, `odd_names`, `changed_files` (`core.quotePath=false`, `diff -z --name-only --no-renames`, uncommitted, untracked not ignored), `require_rev`, config query helper (`shipfloor_config.py`, failure = exit 2 `gate: config query failed: ...`).
- `scripts/sf.py`: a `gate` command calling `shipfloor_core.gate.main`.
- `scripts/gate.sh`: becomes the wrapper; `build|red|green|stack` exec `scripts/lib/gate-run.sh` with the original arguments (including `-C`).
- `scripts/lib/gate-run.sh`: the Bash code of `build`, `red`, `green`, `stack` and the helpers they need, moved unchanged (same verdict trap, translation, pass records). The pass-record key must keep hashing a file that changes when the gate code changes.
Covers: AC-2, AC-3, AC-4, AC-9 (dispatch part).

### T2 — scope, forbidden, test-plan, weight (factory, engineer)
Depends on: T1.
Files: `scripts/shipfloor_core/gate/scope.py`, `scripts/shipfloor_core/gate/spec.py`. Patterns from `shipfloor_config.py`, matched with `text.ere_match` / `grep -E` (invalid ERE = exit 2). Scope's check before forbidden's control-character check.
Covers: AC-5, AC-8.

### T3 — acceptance-intact, acceptance-own, qa-commit, qa-amend (factory, engineer)
Depends on: T1.
Files: `scripts/shipfloor_core/gate/acceptance.py`. Allow paths in order (unchanged, `only_main_changed` via `git merge-file`, `both_sides_kept`, `owner_accepted`, `acceptance_assertions`); `origin/<main>` else `<main>`; `own:` = `git hash-object --stdin` of the own-edit lines plus a trailing newline; qa-amend keep regex default `assert|expect\(|verify\(|should`, max+1, `SKIP_MARKS`.
Covers: AC-6, AC-7 (qa-amend).

### T4 — migration, fast (factory, engineer)
Depends on: T1, T2, T3.
Files: `scripts/shipfloor_core/gate/migration.py`. `project.main` (first plan line) vs `FACTORY_MAIN`; E/N versions through `shipfloor_cfg migration-check`; `## Rollback` rules; destructive keywords; `fast` = one `gate-fast` query, forbidden + migration + acceptance-intact.
Covers: AC-7 (migration), AC-1 and AC-9 end to end (the whole differential and the unchanged suites green).

## Not changed
`scripts/lang/*.sed`, `scripts/lib/project.sh`, `scripts/lib/stack.sh`, `scripts/shipfloor_config.py` (unless a query is missing), the existing `gate-*.test.sh`, `stack-*.test.sh`, `dispatch-*.test.sh`, `deploy-*.test.sh`.
