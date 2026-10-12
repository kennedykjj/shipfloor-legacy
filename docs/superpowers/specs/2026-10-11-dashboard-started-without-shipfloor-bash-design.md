# Dashboard started without SHIPFLOOR_BASH runs WSL bash on Windows — spec

**Issue:** #13 · **Branch:** `feat/13-dashboard-started-without-shipfloor-bash` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** On Windows, the dashboard server started directly (`python scripts/dashboard.py --home ...`) without `SHIPFLOOR_BASH` runs its shell helpers in WSL bash, where `gh` is missing: every card reads "Title not loaded" and approve / request changes fail, with nothing telling the owner why.
**Audience:** The factory's owner and other developers who install the plugin, running the dashboard on Windows.
**Acceptance criteria**
- **AC-1** — Given Windows with Git Bash on `PATH` and `SHIPFLOOR_BASH` unset, when the server is started directly, then it starts and the cards show their issue titles (no "Title not loaded" caused by the shell).
- **AC-2** — Given the same start, when the owner approves or requests changes on a Spec Review or Staged card, then the action succeeds as it does under `shipfloor dashboard`.
- **AC-3** — Given Windows where the only `bash` found is `System32\bash.exe` (WSL) and `SHIPFLOOR_BASH` is unset, when the server is started directly, then it never uses that bash: it exits at start, before serving any page.
- **AC-4** — Given no `bash` can be found at all and `SHIPFLOOR_BASH` is unset, when the server is started directly, then it exits at start the same way.
- **AC-5** — Given either refusal (AC-3, AC-4), when the process exits, then the exit code is non-zero and stderr carries one line that names both ways out: set `SHIPFLOOR_BASH`, or start it with `shipfloor dashboard`.
- **AC-6** — Given `SHIPFLOOR_BASH` is set, when the server starts by either path, then that exact shell is used, with no lookup and no refusal.
- **AC-7** — Given macOS or Linux with `bash` on `PATH` and `SHIPFLOOR_BASH` unset, when the server is started directly, then it starts and behaves as it does today.
**Out of scope:** Any change to the dashboard page or to the "Title not loaded" wording; supporting WSL as a place to run the factory; validating a `SHIPFLOOR_BASH` the owner set explicitly (it is taken as given); checking that `gh` is installed or authenticated in the chosen shell; changes to `shipfloor dashboard`, which already sets the variable.
**Product fit:** Serves principle 3 (numbers are exact and sourced): a dashboard that cannot reach `gh` should refuse to start rather than show empty titles as if they were the board's data. Also principle 4: the owner's two actions must work wherever the dashboard is running. Consistent with the operating context (Windows, macOS or Linux; Git Bash required on Windows); no contradiction with positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. No endpoint, event, page or config key changes.

**Files**
- `scripts/dashboard.py` (change) — the only place a shell is chosen; `scripts/shipfloor` and `scripts/shipfloor-dispatch.sh` keep setting `SHIPFLOOR_BASH` as today.
- `scripts/test/dashboard-bash.test.sh` (new) — the acceptance tests.

**Contracts in `scripts/dashboard.py`**
- `find_bash(environ, windows)` (new, pure: reads only its arguments and the file system) → the shell to run, or `None`.
  - `environ["SHIPFLOOR_BASH"]` set and not empty → returned as is: no lookup, no check.
  - Otherwise each directory of `environ["PATH"]`, in order, is asked for a `bash` (`shutil.which("bash", path=<that directory>)`); the first hit that is not refused wins.
  - Refused only when `windows` is true: a hit whose directory is `<SystemRoot>\System32` or `<LOCALAPPDATA>\Microsoft\WindowsApps` (both read from `environ`, compared case-insensitively after `os.path.normpath`). These two are where Windows keeps the WSL launcher.
  - Nothing left → `None`.
- `bash()` (same name, same eight callers) → `find_bash(os.environ, os.name == "nt")`, resolved on first use and kept; on `None` it raises `SystemExit("shipfloor dashboard: no usable bash found: set SHIPFLOOR_BASH or start it with shipfloor dashboard")`. It never returns a bare `"bash"` again.
- `main()` calls `bash()` right after parsing its arguments, before the port is bound and before the URL line is printed: a refusal is one line on stderr, exit code 1, nothing served.

**Migration:** none (no data, no stored state).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-bash.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-bash.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-bash.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-bash.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-bash.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-bash.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-bash.test.sh` |

How each is reached on any machine the tests run on (Windows, macOS, Linux):
- **AC-1, AC-2, AC-7** — the server is started with `SHIPFLOOR_BASH` unset and the test's own `PATH` (as `scripts/test/dashboard.test.sh` starts it, with `FACTORY_GH` on the fake `gh`): a card's title is read and an approve on a Spec Review card moves it. Plus `find_bash` with `windows=True` and a `PATH` of a fake `System32` followed by a directory holding a `bash`: the second one is returned.
- **AC-3** — `find_bash` with `windows=True`, `SystemRoot` pointing at a temporary directory and a `PATH` holding only its `System32` (with a `bash` and a `bash.exe` file in it) → `None`; the same for `WindowsApps`.
- **AC-4, AC-5** — the server is started by Python's absolute path with `SHIPFLOOR_BASH` unset and `PATH` set to one empty directory: exit code is not 0, stderr names `SHIPFLOOR_BASH` and `shipfloor dashboard`, and no `http://` line is printed. AC-3 ends in the same `None`, so the same exit.
- **AC-6** — `find_bash` with `SHIPFLOOR_BASH` set to a path that does not exist and an empty `PATH` returns that exact value; with `windows=True` and the value inside the fake `System32` too.
- **AC-7** — `find_bash` with `windows=False` returns a `bash` that sits in a directory named `System32`.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Both outcomes are required, not either one: it works when a usable bash is on `PATH` and stops only when none is. The issue's "works or stops" leaves the owner with a dashboard that refuses on a machine that has Git Bash.
- A WSL bash earlier in `PATH` is skipped, not fatal: on a default Windows install `System32` comes before Git's directory, so refusing the first hit would refuse almost every machine.
- `WindowsApps\bash.exe` is refused like `System32\bash.exe`: it is the same WSL launcher, installed from the Store.
- An explicit `SHIPFLOOR_BASH` is never checked: it is the owner's word, and `shipfloor dashboard` and the dispatcher rely on it.
- The lookup is a pure function taking the environment and a `windows` flag: the WSL case can then be tested on macOS, Linux and Windows without touching the real `SystemRoot`.
- `bash()` resolves on first use as well as at start: `scripts/shipfloor_health.py` builds a `Factory` without `main()`, and it must not fall back to a bare `bash` either.
- The check runs before the port is bound: a refusal leaves nothing listening and no URL printed.
- A new test file instead of more lines in `scripts/test/dashboard.test.sh`: these tests start the server with a different environment than that file exports for all of its own.
- No README change: `SHIPFLOOR_BASH` is not documented there today and the message itself tells the owner what to do.
- The spec template was read from the worktree's `templates/spec-template.md`: the installed copy was outside what this session may read, and both come from `main`.

## Open questions
- none
