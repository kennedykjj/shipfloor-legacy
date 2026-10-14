# Plan — #162 Python foundation: the package, the wrapper, the process helpers

**Spec:** `docs/superpowers/specs/2026-10-14-python-foundation-the-package-the-wrapper-design.md`
**Layer:** `factory` (single layer; agent `engineer`). Tasks run one at a time in the shared worktree.

## Acceptance tests (qa-engineer, before any task)
- `scripts/test/py-wrapper.test.sh` — AC-1, AC-2
- `scripts/test/py-install.test.sh` — AC-3, AC-8
- `scripts/test/py-parity.test.sh` — AC-4, AC-6
- `scripts/test/py-unit.test.sh` + `scripts/test/py/*.py` (unittest modules) — AC-5, AC-7

## Tasks

### T1 — package, entry point, wrapper, process/text/fs helpers (factory, engineer)
Depends on: acceptance tests.
Files:
- `scripts/sf.py` (`sys.dont_write_bytecode = True` before any import; own folder on `sys.path`; UTF-8/LF stdout+stderr; `version` command)
- `scripts/shipfloor_core/__init__.py` (`__version__`)
- `scripts/shipfloor_core/proc.py` (`git`, `gh` — Windows via `bash -c 'exec "${FACTORY_GH:-gh}" "$@"'` —, `native_path`, `uname_s`)
- `scripts/shipfloor_core/text.py` (`say` via `sed -E -f scripts/lang/<code>.sed`, passthrough with no catalog or `en`; `ere_match` via `grep -E`/`-Ei`, exit 2 raises)
- `scripts/shipfloor_core/fs.py` (`lock_dir`, `write_atomic`, `file_age`)
- `scripts/lib/py.sh` (finds Python: `FACTORY_PYTHON`, `python3`, `python`; `cygpath -m` under Git Bash; `exec "$SHIPFLOOR_PY" -I "$HERE/sf.py" "$@"`; does not source `lib/project.sh`)
- `templates/py-wrapper.sh` (`HERE` idiom `${0%[/\\]*}`)
Covers: AC-1, AC-2, AC-5, AC-6 (say), AC-7.

### T2 — project helpers (factory, engineer)
Depends on: T1.
Files: `scripts/shipfloor_core/project.py` (`resolve`, `use`, `snapshot`, `clean_tmp`, `stale_tmp`, `sweep_tmp`, `card_spec`, `spec_weight`, `card_weight`, cfg/machine calls through `shipfloor_config`), matching `scripts/lib/project.sh` behavior exactly (that file is not changed).
Covers: AC-4.

### T3 — install and doctor (factory, engineer)
Depends on: T1.
Files: `scripts/shipfloor` — `cmd_install` prunes `__pycache__` (never copies it); `cmd_doctor` ignores `__pycache__` in the diff (`-x __pycache__`) and checks the Python named by `FACTORY_PYTHON` (else the factory's Python) is ≥ 3.11, failing with one line naming the 3.11 minimum.
Covers: AC-3, AC-8.

## Not changed
`scripts/lib/project.sh`, `scripts/lang/*.sed`, `.shipfloor/factory.yml`, the dashboard.
