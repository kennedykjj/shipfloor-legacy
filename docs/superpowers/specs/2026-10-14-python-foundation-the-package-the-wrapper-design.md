# Python foundation: the package, the wrapper, the process helpers — spec

**Issue:** #162 · **Branch:** `feat/162-python-foundation-the-package-the-wrapper` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** the Bash-to-Python ports (#163 to #170) each need to find Python, load the package under `python -I`, call git/gh the same way on Windows, translate output, match config patterns and leave the installed copy untouched; answered port by port, they will disagree and break the gates' behavior per platform.

**Audience:** the developers who install the plugin and run the factory on Windows, macOS or Linux (and the factory's owner, who maintains the ports).

**Acceptance criteria**
- AC-1: Given an installed factory on Linux, macOS or Windows (Git Bash), When a wrapper built from the template sourcing `scripts/lib/py.sh` runs `sf.py version`, Then it prints the package version and exits 0.
- AC-2: Given `PYTHONPATH` pointing at a folder with a fake `shipfloor_core`, When any `sf.py` command runs through the wrapper, Then the real installed `shipfloor_core` is loaded.
- AC-3: Given an installed copy under `~/.shipfloor/factory`, When any `sf.py` command has run, Then no `__pycache__` exists there, and `install`/`doctor` neither copy a `__pycache__` nor report one as a difference.
- AC-4: Given the shared fixtures, When the parity test runs `project.py` and `lib/project.sh`, Then they agree on resolve from a worktree, the resolve failure message, snapshot, the three tmp helpers and weight (none, two lines, unknown value, CRLF).
- AC-5: Given `fake-gh` on PATH, When `gh()` issues the calls `board.sh` makes today, Then `fake-gh`'s call log shows byte-identical argv, `--jq` included.
- AC-6: Given every line of the current tests' pt-BR fixtures, When `say('pt-BR', line)` runs, Then its output equals `shipfloor_say pt-BR` on the same line; with no catalog for the language, the text passes through unchanged.
- AC-7: Given patterns using `\b`, `[[:space:]]` and an invalid pattern, When `ere_match` runs, Then it agrees with `grep -E` on the valid ones and raises an error (never "no match") on the invalid one.
- AC-8: Given Python 3.10 as the factory's Python, When `shipfloor doctor` runs, Then it fails with one clear line naming the 3.11 minimum; on 3.11 or later that check passes.

**Out of scope:** porting any script (#163 onward); changing `lib/project.sh`, the `lang/*.sed` catalogs or `.shipfloor/factory.yml`; any dashboard change.

**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim): one shared, parity-tested foundation keeps the gates' behavior identical across Bash and Python and across the three platforms the operating context names. No conflict with the positioning; the stack already names Python 3 stdlib.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. No endpoint or event contract changes; the contracts are the Python function signatures below.

**New files**
- `scripts/sf.py`: entry point; `sys.dont_write_bytecode = True` before any import, inserts its own folder into `sys.path`, forces UTF-8/LF on stdout and stderr, dispatches `<command>`; `version` is the first command.
- `scripts/shipfloor_core/__init__.py`: `__version__`.
- `scripts/shipfloor_core/proc.py`: `git(*args, cwd=None)`, `gh(*args)` (Windows: through `bash -c 'exec "${FACTORY_GH:-gh}" "$@"'`), `native_path(path, mode)` (`cygpath -m`/`-w` rules), `uname_s()` (subprocess).
- `scripts/shipfloor_core/text.py`: `say(lang, text)` (via `sed -E -f scripts/lang/<code>.sed`, passthrough without catalog), `ere_match(pattern, text, ignore_case=False)` (via `grep -E`/`-Ei`; exit 2 raises).
- `scripts/shipfloor_core/project.py`: `resolve`, `use`, `snapshot`, `clean_tmp`, `stale_tmp`, `sweep_tmp`, `card_spec`, `spec_weight`, `card_weight`, cfg/machine calls (imports `shipfloor_config`).
- `scripts/shipfloor_core/fs.py`: `lock_dir(path, info)` (mkdir-atomic), `write_atomic(path, data)` (temp then rename), `file_age(path)` (no GNU `stat`).
- `scripts/lib/py.sh`: finds Python (`FACTORY_PYTHON`, `python3`, `python`) into `SHIPFLOOR_PY`, `cygpath -m` under Git Bash, `exec "$SHIPFLOOR_PY" -I "$HERE/sf.py" "$@"`; does not source `lib/project.sh`.
- `templates/py-wrapper.sh`: wrapper template using the `HERE` idiom (`${0%[/\\]*}`).
- Tests: `scripts/test/py-unit.test.sh` (runs `unittest` over `scripts/test/py/`), `scripts/test/py-wrapper.test.sh`, `scripts/test/py-parity.test.sh`, `scripts/test/py-install.test.sh`.

**Changed files**
- `scripts/shipfloor`: `cmd_install` skips `__pycache__` (find prune, never copies it); `cmd_doctor` ignores `__pycache__` in the diff (`-x __pycache__`) and adds a Python ≥ 3.11 check.
- `lib/project.sh` is not changed.

**Migration:** none; additive, nothing existing changes behavior. Rollback is reverting the commit.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py-wrapper.test.sh` |
| AC-2 | factory | `scripts/test/py-wrapper.test.sh` |
| AC-3 | factory | `scripts/test/py-install.test.sh` |
| AC-4 | factory | `scripts/test/py-parity.test.sh` |
| AC-5 | factory | `scripts/test/py-unit.test.sh` |
| AC-6 | factory | `scripts/test/py-parity.test.sh` |
| AC-7 | factory | `scripts/test/py-unit.test.sh` |
| AC-8 | factory | `scripts/test/py-install.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: more than 6 acceptance criteria and more than 8 files.
- The unittest modules live in `scripts/test/py/`, which install already prunes (`scripts/test`), so tests are never installed.
- AC-5 and AC-7 run in `py-unit.test.sh` (fake-gh call log and grep comparison live in the unittest modules).
- The Python ≥ 3.11 check runs the interpreter named by `FACTORY_PYTHON`, so the test can point it at a stub reporting 3.10.

## Open questions
- none
