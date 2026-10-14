# [PY-18] Finish the migration: thin shims, one source of truth, docs — spec

**Issue:** #171 · **Branch:** `feat/171-finish-the-migration` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** the ports of #162 to #170 moved the factory's logic into `scripts/shipfloor_core/`, but the migration (#153) is not finished. `lib/project.sh` is still 166 lines of Bash logic (resolve, snapshot, tmp sweep, spec weight, the catalog), `shipfloor-config.sh` and `gate.sh` still hold Bash of their own, and `lib/portable.sh` is Bash only the old Bash fixtures use. The same facts are written in more than one place: the deploy defaults (`dashboard.py` and `deploy.py`), the stage/column table (`shipfloor_health.py` and `dispatch.py`) and the commit trailer (`deploy.py` and `report.py`). Python code outside the catalog and ERE helpers still starts `grep` on its own. The docs still describe Bash scripts and a bash 4.4 requirement. Nothing stops new logic from creeping back into a wrapper.

**Audience:** the owner, who maintains the factory and closes #153, and the developers who install the plugin and read its docs.

**Acceptance criteria**
- **AC-1** — Given every `scripts/*.sh` and `scripts/shipfloor`, when the hygiene test reads them, then each one is a wrapper: besides the shebang and comments it holds only the `HERE=` line, `set -- <command> "$@"`, an `export` that passes one variable through, and `source "$HERE/lib/py.sh"`. The exceptions are the named fast paths, each pinned to its exact text: the `step <k>` block of `shipfloor-config.sh`, `inbox-hook.sh` and `run-dispatcher.sh`.
- **AC-2** — Given every `scripts/lib/*.sh`, when the hygiene test reads it, then it is a shim. It holds only `source` lines, plain assignments and one-line functions with no control flow (`if`, `case`, `for`, `while`, `until`). Its plumbing is pinned by a hash of its exact text: the Python lookup, the signal forwarding of `lib/stack.sh` and the reading of results back into the shell. `lib/portable.sh` is no longer under `scripts/lib/`.
- **AC-3** — Given a copy of `scripts/`, when one line of logic is added to any wrapper, fast path or shim (a top-level `if`, a line inside a pinned block, an extra command in a fast path), then the hygiene check fails and names that file.
- **AC-4** — Given the git index, when the hygiene test lists `scripts/*.sh` and `scripts/lib/*.sh`, then every one is mode 100755.
- **AC-5** — Given every file under `scripts/` except `test/` and the `lang/` catalogs, when the hygiene test scans it, then nothing starts `awk` or `jq`, `sed` is started only by the catalog (`shipfloor_core/text.py`), and `grep` is started only by the ERE helpers (`shipfloor_core/text.py`).
- **AC-6** — Given `lib/project.sh` is sourced, when its functions run, then each one runs `sf.py project <command>` (the logic is `shipfloor_core/project.py`). `shipfloor_resolve` and `shipfloor_use` export `FACTORY_PROJECT`, `FACTORY_REPO`, `FACTORY_MAIN`, `FACTORY_HOME`, `FACTORY_WT_ROOT` and `FACTORY_CONFIG` into the caller's shell with the same values as before, through an `eval` of output that `sf.py` quotes for the shell, so a path with a space, a quote or a `$` stays intact. An unknown directory still prints `shipfloor: <pwd> is not in a registered project (shipfloor add <repo>)` and returns 1.
- **AC-7** — Given `shipfloor-config.sh`, when it is run with `step <k>`, then it records the step without starting Python, as before. When it is run with `machine …`, `validate` or any other query, then it runs `sf.py config`, with the same output, exit codes and "no project" exit 2 as before.
- **AC-8** — Given `inbox-hook.sh`, when the run has no inbox or an empty one, then it exits 0 without starting Python, and `hooks/hooks.json` is unchanged.
- **AC-9** — Given the package, when the hygiene test searches `scripts/` (tests aside), then the commit trailer, the deploy defaults (`timeout_min 30`, `conflict_max_files 5`) and the stage/column table are each defined once, in `shipfloor_core/defaults.py`. `deploy.py`, `report.py`, `dispatch.py`, `dashboard.py` and `shipfloor_health.py` take them from there.
- **AC-10** — Given the docs, when the owner reads them, then they describe the factory as it now is:
  - `PRODUCT.md` (Stack) names the Python package with thin Bash wrappers;
  - `README.md` and `docs/install.md` list the requirements: Python 3.11+ with PyYAML, Git, gh and Claude Code, plus Git Bash on Windows for the wrappers and the scheduler;
  - `docs/how-it-works.md` and `docs/operation.md` say where the logic lives;
  - `docs/contracts.md` names, in each script's section, the Python module behind it.
- **AC-11** — Given the dispatcher installer, when it registers the scheduled entry, then it no longer refuses a bash older than 4.4 and says why in a comment: no Bash beyond the wrappers is left. No doc still asks for bash 4.4.
- **AC-12** — Given the callers, when `grep -rn 'deploy.sh\|gate.sh\|board.sh' skills agents docs` runs, then it shows the same commands as before the migration. The set of `deploy.sh`, `gate.sh` and `board.sh` invocations in `skills/`, `agents/` and `docs/*.md` equals the set taken at the commit before #162, kept as a fixture.
- **AC-13** — Given the whole suite, when `bash scripts/test/run.sh` runs on Linux, then it ends with 0 FAIL. Existing tests are unedited, except those the move of `lib/portable.sh` forces (see Decisions).

**Out of scope:**
- Rewriting the dashboard, `shipfloor_config.py` or the other existing Python modules, beyond moving the shared values into the package.
- Replacing the `sed` catalogs or `grep -E` with Python `re`.
- CI on macOS and Windows: #154 was closed as not planned, and the owner decided on Linux only for now.
- The `stack:` line of `.shipfloor/factory.yml`: it is a protected path, so the owner updates it (see Rollback and owner steps).
- New behavior of any kind.

**Product fit:** this closes the migration that principle 2 (deterministic gates outrank any agent's claim) depends on. The gates and the deploy keep one implementation in one language, and the hygiene test keeps new logic out of the wrappers. The callers are unchanged: the skills, the agents, the allow rules and the schedulers.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. There is no endpoint, event or file-format change. The contract is `docs/contracts.md`.

**New files**
- `scripts/shipfloor_core/defaults.py`: `TRAILER`, `DEPLOY_DEFAULTS` (`timeout_min` 30, `conflict_max_files` 5, `conflict_max_hunks` 20) and `STAGES` (stage → queue column, the column whose orphans it resumes, its WIP columns). This is the one copy.
- `scripts/test/fixtures/portable.sh`: `lib/portable.sh` moved here verbatim. Only the Bash reference fixtures (`stack.bash.sh`, `deploy-bash.sh`) and `stack-py-heartbeat.test.sh` use it; no production code does.
- `scripts/test/fixtures/callers-before-migration.txt`: the sorted `deploy.sh`/`gate.sh`/`board.sh` invocations in `skills/`, `agents/` and `docs/*.md` at `e9669e2^` (the commit before #162).
- `scripts/test/finish-migration.test.sh`: AC-6, AC-7, AC-9 (behavior), AC-10, AC-11 and AC-12.

**Changed files**
- `scripts/shipfloor_core/project.py`: `main(args)` for `sf.py project <command>`. The commands are `resolve [dir]`, `use <slug> <repo> [wt] [main]` (both print `export NAME='value' …` quoted with `shlex.quote`; a failed resolve prints `return 1` for the caller's `eval`), `cfg <query…>` (`shipfloor_config` in-process, so it is still one Python start), `machine <…>`, `validate`, `ere-ok`, `native`, `git-common`, `config-path`, `snapshot`, `clean-tmp`, `stale-tmp`, `sweep-tmp`, `card-spec`, `spec-weight`, `card-weight` and `say`. Also new: `config_path(d, rev)`, and `config_main(args)` for `sf.py config`.
- `scripts/sf.py`: the `project` and `config` commands.
- `scripts/lib/project.sh`: a shim with the same function names. `_shipfloor_sf` runs `sf.py` with the shell's `SHIPFLOOR_HOME`, `FACTORY_CONFIG`, `FACTORY_HOME`, `FACTORY_WT_ROOT` and `FACTORY_REPO` (set or exported). `shipfloor_resolve` keeps its fast path: with `FACTORY_CONFIG` set it starts nothing. `shipfloor_py` and `shipfloor_python` stay: they are the launcher for sourced code.
- `scripts/shipfloor-config.sh`: keeps the `step <k>` block; anything else goes through `set -- config "$@"` and `lib/py.sh`.
- `scripts/gate.sh`: the `usage()` heredoc and `case` go. `shipfloor_core.gate.main` already prints the same usage for `-h`/`--help`/`help` (exit 0) and for no argument (stderr, exit 2). The usage stays as comment lines, which `contracts-doc.test.sh` reads.
- `scripts/lib/stack.sh`: no longer sources `portable.sh`, which it never used.
- `scripts/shipfloor_core/text.py`: `grep(flags, pattern, data, …)` is the one place that starts `grep`. `gate/run.py`, `gate/acceptance.py` and `stack.py` call it, with the same arguments, bytes and exit codes. `say_bytes` is the catalog on bytes, for `shipfloor_say`.
- `scripts/shipfloor_config.py`: `run(argv)` wraps `main` with the same exit-2 handling as `__main__`, so `sf.py config` and `sf.py project cfg` print the same errors.
- `deploy.py`, `report.py`, `dispatch.py`, `dashboard.py` and `shipfloor_health.py` import from `defaults.py`.
- `installer/install-dispatcher.sh`: the bash 4.4 check goes; a comment says why.
- `scripts/test/hygiene.test.sh`: AC-1 to AC-5 and AC-9 (single definition), added at its end in its own style.
- Docs: `PRODUCT.md`, `README.md`, `docs/how-it-works.md`, `docs/install.md`, `docs/operation.md` and `docs/contracts.md`.

**Migration:** none; the files and formats under `~/.shipfloor` stay the same. The pass records of `gate build`/`green` are keyed by `gate.sh`'s hash and the package's code, so one recheck after the upgrade is expected. Rollback is reverting the commits and running `shipfloor install` again.

## Test plan
_Tech Lead_

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/hygiene.test.sh` |
| AC-2 | factory | `scripts/test/hygiene.test.sh` |
| AC-3 | factory | `scripts/test/hygiene.test.sh` |
| AC-4 | factory | `scripts/test/hygiene.test.sh` |
| AC-5 | factory | `scripts/test/hygiene.test.sh` |
| AC-6 | factory | `scripts/test/finish-migration.test.sh` |
| AC-7 | factory | `scripts/test/finish-migration.test.sh` |
| AC-8 | factory | `scripts/test/inbox-hook.test.sh` |
| AC-9 | factory | `scripts/test/hygiene.test.sh` |
| AC-10 | factory | `scripts/test/finish-migration.test.sh` |
| AC-11 | factory | `scripts/test/finish-migration.test.sh` |
| AC-12 | factory | `scripts/test/finish-migration.test.sh` |
| AC-13 | manual | the full suite, `bash scripts/test/run.sh`, ends with 0 FAIL |

## Security
_Cybersec_ — n/a. The one new surface is the `eval` in `shipfloor_resolve` and `shipfloor_use`. `sf.py` quotes every value with `shlex.quote` and prints only `export NAME=…` or `return 1`. AC-6 covers a repository path with a space, a single quote, a `$` and a backtick.

## Rollback
Revert the commits, then run `shipfloor install`.

Owner steps after merge (protected path, never edited by the factory): in `.shipfloor/factory.yml`, change the layer's `stack:` line to:
`stack: Python 3.11+ (stdlib + PyYAML) package scripts/shipfloor_core behind thin Bash wrappers; the dashboard is one HTML file, no build; tests print "ok" / "FAIL" lines`

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: 13 acceptance criteria.
- Linux only: the owner closed #154 as not planned, so AC-13 reads "green on Linux" in place of "Linux, macOS and Windows".
- `lib/portable.sh` moves to `scripts/test/fixtures/portable.sh`, because no production code uses it and `scripts/lib/` must hold no logic. This forces edits that change only the path in `stack-py-lease.test.sh`, `stack-py-up.test.sh`, `stack-py-heartbeat.test.sh` and `fixtures/deploy-bash.sh`. `gate-py-delegate.test.sh` (#165) fails any edit to the existing gate, stack and py suites since `origin/main`, so its exclusion list gains those two suites and itself. This follows the precedent it already sets for #166's files.
- `lib/py.sh` is the wrapper's own body (`templates/py-wrapper.sh`), so it is pinned plumbing, not a fast path.
- `shipfloor_py` stays in `lib/project.sh` as pinned plumbing: sourced code cannot `exec` `lib/py.sh`, and its order (`SHIPFLOOR_PY` before `FACTORY_PYTHON`) is the contract the tests and the fixtures rely on.
- `lib/stack.sh` keeps its marshalling and its INT/TERM forwarding (from #166), pinned by hash. These move bytes and signals and make no decision, and rewriting them would put the stack parity tests at risk for no behavior gain.
- `inbox-hook.sh` keeps its text: it is a named fast path, and `inbox-hook.test.sh` expects `inbox_hook.py` on Python's command line.
- `shipfloor-config.sh` now picks Python as every wrapper does (`FACTORY_PYTHON` first). A different `SHIPFLOOR_PY` handed down no longer answers its queries; nothing sets the two apart.
- The dashboard's inline acceptance-diff snippet (`mapfile -t`, bash 4.0) stays: rewriting the dashboard is out of scope, and every Linux bash runs it.
- AC-12 compares against a fixture rather than `git show e9669e2^`, because a shallow CI checkout would not have that commit.

## Open questions
- none
