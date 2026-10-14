# shipfloor init: guided end-to-end install — plan

**Issue:** #174 · **Spec:** `docs/superpowers/specs/2026-10-14-shipfloor-init-guided-end-to-end-install-design.md`
**Branch:** `feat/174-shipfloor-init-guided-end-to-end-install`

One layer (`factory`). Every external tool init calls (`git`, `gh`, `claude`, `board.sh`/`setup-board`,
`install-dispatcher.sh`) runs as a process, so the tests stub them on `PATH` / `SHIPFLOOR_HOME` like
`shipfloor-cli.test.sh` does.

## Acceptance tests (QA, before task 1)

| AC | File | What is new |
|---|---|---|
| AC-1 | `scripts/test/init.test.sh` | full run on stubs: install, `factory.yml` written + committed, `add`, `setup-board`, dispatcher registered, doctor, exit 0, no `FAIL` |
| AC-2 | `scripts/test/init.test.sh` | second run: no new commit, registry unchanged, "already" per step, exit 0 |
| AC-3 | `scripts/test/init.test.sh` | existing `factory.yml` kept and not committed; overwritten only with confirmation |
| AC-4 | `scripts/test/init.test.sh` | each missing prerequisite (gh auth, git, claude, Python, PyYAML): named with its fix, nothing changed, exit ≠ 0 |
| AC-5 | `scripts/test/init.test.sh` | no `<repo>`: machine part only, registry and repos untouched |
| AC-6 | `scripts/test/init.test.sh` | `$ <command>` per step; no TTY and no `--yes`: no commit / overwrite / dispatcher replace, exact command printed, exit 1 |
| AC-7 | `scripts/test/init.test.sh` | README quick start names `shipfloor init`; `docs/install.md` keeps the manual steps |

## Tasks

### Task 1 — factory: `init` command
- **Layer:** factory · **Agent:** engineer · **Depends on:** acceptance tests
- **Files:** `scripts/shipfloor_core/init.py` (new), `scripts/shipfloor_core/cli.py` (`cmd_init`, `COMMANDS`, usage),
  `scripts/shipfloor` (usage header if it carries one)
- Steps as in the spec's Architecture: prerequisites (fatal, before any change), install unless `_same_tree`,
  `factory.yml` from `examples/factory.yml` (commit + push to main only on confirmation, only on `<main>` with no
  unrelated staged changes), `add` unless registered, `setup-board`, dispatcher via `install-dispatcher.sh --status`,
  `doctor`, next steps. `_step(title, cmd)` prints `$ <cmd>`; `_confirm(q)` = TTY prompt, `--yes`, else no → print the
  command and exit 1. Reuse `cmd_install`, `cmd_add`, `cmd_setup_board`, `cmd_doctor`, `_have`, `source_dir`.

### Task 2 — factory: docs
- **Layer:** factory · **Agent:** engineer · **Depends on:** task 1
- **Files:** `README.md` (quick start = `shipfloor init` + what remains), `docs/install.md` (the manual steps, and
  `init` as the short path)
