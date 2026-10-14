# Plan — #171 [PY-18] Finish the migration: thin shims, one source of truth, docs

Spec: `docs/superpowers/specs/2026-10-14-finish-the-migration-design.md`, plus the owner's decision on the issue: Linux
only for now (#154 closed as not planned), so the suite must be green on Linux.

## Tasks

| # | Layer | Owner | Files | Depends on |
|---|---|---|---|---|
| 1 | factory | qa-engineer | `scripts/test/hygiene.test.sh` (AC-1 to AC-5, AC-9), `scripts/test/fixtures/wrapper-check.py`, `scripts/test/finish-migration.test.sh` (AC-6, AC-7, AC-8 hook, AC-10 to AC-12), `scripts/test/fixtures/callers-before-migration.txt` | — |
| 2 | factory | engineer | `scripts/shipfloor_core/defaults.py` (new); `deploy.py`, `report.py`, `dispatch.py`, `dashboard.py` and `shipfloor_health.py` import from it | 1 |
| 3 | factory | engineer | `scripts/shipfloor_core/text.py` (`grep`, `say_bytes`); `gate/run.py`, `gate/acceptance.py` and `stack.py` call `text.grep` | 1 |
| 4 | factory | engineer | `scripts/shipfloor_core/project.py` (`main`, `config_main`, `config_path`), `scripts/sf.py` (`project` and `config`), `scripts/shipfloor_config.py` (`run`) | 1 |
| 5 | factory | engineer | `scripts/lib/project.sh` (shim), `scripts/shipfloor-config.sh` (step fast path plus wrapper), `scripts/gate.sh` (no `usage()`), `scripts/lib/stack.sh`; `lib/portable.sh` moved to `scripts/test/fixtures/` | 4 |
| 6 | factory | engineer | `installer/install-dispatcher.sh` (no bash 4.4 check); `PRODUCT.md`, `README.md`, `docs/how-it-works.md`, `docs/install.md`, `docs/operation.md`, `docs/contracts.md` | 5 |

## Notes

- The hygiene check (`wrapper-check.py`) applies a grammar to every file:
  - a wrapper holds only the `HERE=` line, `set -- <command> "$@"`, an `export` that passes one variable through, and the `lib/py.sh` source line;
  - the fast paths (`shipfloor-config.sh`'s step block, `inbox-hook.sh`, `run-dispatcher.sh`) are pinned by exact code;
  - in a shim, every multi-line function is plumbing pinned by a hash (the Python lookup in `lib/project.sh`, `lib/stack.sh`'s marshalling and INT/TERM forwarding, and `lib/py.sh` whole);
  - one-line functions may hold no control flow.
  
  A legitimate change to a pinned block updates its hash in the check, in the same commit.
- `shipfloor_resolve`'s `eval` takes only what `sf.py project resolve|use` prints: `export NAME='value' …`, quoted with `shlex.quote`, or `return 1`.
- `sf.py config` and `sf.py project cfg|machine` run `shipfloor_config.run` in-process: it is still one Python start per query, as before.
- These existing tests had to be edited: `stack-py-lease`, `stack-py-up`, `stack-py-heartbeat` and `fixtures/deploy-bash.sh` (the path to `portable.sh` only), and `gate-py-delegate` (its #165 "suites unedited" list gains those two suites and itself).
- Owner, after merge: the layer's `stack:` line in `.shipfloor/factory.yml` (protected path); the text is in the spec's Rollback section.
