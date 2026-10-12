# Dashboard started without SHIPFLOOR_BASH — plan

**Issue:** #13 · **Branch:** `feat/13-dashboard-started-without-shipfloor-bash`
**Spec:** `docs/superpowers/specs/2026-10-11-dashboard-started-without-shipfloor-bash-design.md`

**Goal:** Started directly, the dashboard server picks a usable bash from `PATH` (never the WSL launcher on Windows) or exits at start with one line that names both ways out.

## Constraints

- An explicit `SHIPFLOOR_BASH` is returned as is: no lookup, no check.
- `find_bash` is pure: it reads only its arguments and the file system, never `os.environ` or `os.name`.
- The refusal happens before the port is bound and before the URL line is printed.
- `scripts/shipfloor` and `scripts/shipfloor-dispatch.sh` are not touched; no README change.
- No dead code, no narrating comments, no option the spec does not ask for.

## Tasks

### Task 0 — acceptance tests
- **Layer:** factory · **Owner:** qa-engineer · **Depends on:** nothing
- **Files:** `scripts/test/dashboard-bash.test.sh` (new)
- One test per AC, as the spec's test plan describes how each is reached: `find_bash` called from Python with a fake environment and temporary directories (AC-1, AC-3, AC-6, AC-7), and the server started with `SHIPFLOOR_BASH` unset (AC-1, AC-2, AC-7 with the test's own `PATH` and the fake `gh`; AC-4, AC-5 with `PATH` set to one empty directory).

### Task 1 — the shell is looked up, not assumed
- **Layer:** factory · **Owner:** engineer · **Depends on:** Task 0
- **Files:** `scripts/dashboard.py` (change)
- Add `find_bash(environ, windows)` as the spec's contract says: `SHIPFLOOR_BASH` set and not empty wins; otherwise each directory of `environ["PATH"]`, in order, is asked through `shutil.which("bash", path=<directory>)`; when `windows` is true a hit inside `<SystemRoot>\System32` or `<LOCALAPPDATA>\Microsoft\WindowsApps` is skipped (case-insensitive, after `os.path.normpath`); nothing left returns `None`.
- `bash()` keeps its name and its eight callers: it returns `find_bash(os.environ, os.name == "nt")`, resolved on first use and kept, and on `None` raises `SystemExit("shipfloor dashboard: no usable bash found: set SHIPFLOOR_BASH or start it with shipfloor dashboard")`.
- `main()` calls `bash()` right after `parse_args()`, before `Server(...)` is bound.

## Review focus

- A `SystemRoot` or `LOCALAPPDATA` missing from the environment must not refuse or crash: with neither set, nothing is refused.
- An empty `PATH` entry must not make `shutil.which` search the current directory.
- `bash()` keeps its first answer: a later change of `SHIPFLOOR_BASH` in the same process is not read, which the existing tests must not depend on.
