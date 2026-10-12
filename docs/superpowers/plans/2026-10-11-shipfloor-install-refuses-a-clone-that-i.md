# shipfloor install refuses a clone that is not a clean, up-to-date main — plan

**Issue:** #80 · **Branch:** `feat/80-shipfloor-install-refuses-a-clone-that-i`
**Spec:** `docs/superpowers/specs/2026-10-11-shipfloor-install-refuses-a-clone-that-i-design.md`

**Goal:** `shipfloor install` checks the clone it is about to copy and refuses when it is not a clean main level with its remote; `--force` installs anyway and says so; `shipfloor doctor` names the commit the installed copy came from.

## Constraints

- The check runs before the first `mkdir`: a refusal creates and changes nothing under `$SHIPFLOOR_HOME`.
- The messages, the exit codes and the `.origin` format are the ones in the spec's `## Architecture`, word for word.
- A source without `<src>/.git` installs as today: no check, no refusal, no `.origin` (an older one is removed).
- `.source` keeps its one-line content and its place; `.origin` is written after it.
- Doctor's new line never changes the exit code.
- No test-only switch in `cmd_install`: the existing tests install from a plain copy, not with `--force`.
- No network in any test. No dead code, no narrating comments, no option the spec does not ask for.

## Tasks

### Task 0 — acceptance tests
- **Layer:** factory · **Owner:** qa-engineer · **Depends on:** nothing
- **Files:** `scripts/test/install-source.test.sh` (new)
- One test per AC (AC-1 to AC-8), as the spec's test plan and `## Architecture` say each is reached: every case builds its own source, a `new_repo` holding a copy of `scripts/` and `templates/`, committed and pushed to a bare remote in a temp dir with `origin/HEAD` set, and runs that copy's `scripts/shipfloor` against a temp `SHIPFLOOR_HOME`. "Cannot fetch" is the remote's URL pointed at a path that does not exist. "Nothing is copied" is read from the file system (`$SHIPFLOOR_HOME/factory` absent, or unchanged when it existed).
- The file is self-contained: it does not depend on `plugin_copy`, which Task 1 adds.

### Task 1 — the install checks its source, doctor names it
- **Layer:** factory · **Owner:** engineer · **Depends on:** Task 0
- **Files:** `scripts/shipfloor` (change), `scripts/test/lib.sh` (change), `scripts/test/shipfloor-cli.test.sh` (change), `scripts/test/transition.test.sh` (change), `README.md` (change)
- `scripts/shipfloor`:
  - `source_state <src>` beside `source_dir`: the reasons, one per line, and the branch, commit and main it read (main from `origin/HEAD` as `cmd_add` reads it, else `main`; branch from `git symbolic-ref -q --short HEAD`; changed files from `git -c core.quotePath=false status --porcelain --untracked-files=no`; remote from `GIT_TERMINAL_PROMPT=0 git fetch -q origin <main>` then `git rev-list --left-right --count HEAD...origin/<main>`).
  - `cmd_install`: parses `--force` (any other argument exits 2 with the usage), calls `source_state` before anything is written, refuses on stderr with exit 1 or goes on; the "no longer shipped" pass skips `.origin` as it skips `.source`; after `.source` it writes `.origin` (`<full commit>\t<branch or "detached">\t<verified|forced>`) or removes it for a non-git source; a forced install with at least one reason prints the `WARN installed copy is not a verified <main>: ...` line after the usual output.
  - The dispatch line passes the arguments: `install) cmd_install "$@" ;;`. Header comment line 3 gains `[--force]`.
  - `cmd_doctor`: one line after the "matches / differs" line (`ok   installed from ...`, `WARN installed copy was forced ...`, `WARN installed copy has no recorded commit ...`); its `diff -rq` also excludes `.origin`.
- `scripts/test/lib.sh`: `plugin_copy`, a plain (non-git) copy of `scripts/` and `templates/` in a temp dir.
- `scripts/test/shipfloor-cli.test.sh`, `scripts/test/transition.test.sh`: their `install` runs from `plugin_copy`; nothing else in them changes.
- `README.md`: the install line says it refuses a clone that is not a clean, up-to-date main, and names `--force`.

## Review focus

- `source_state` both prints and sets: called inside `$(...)` its variables are lost. The branch, commit and main must reach `cmd_install` without a second round of git calls.
- In a git worktree `.git` is a file, not a directory: "exists" is `-e`.
- A detached HEAD has no branch name: the reason, the `WARN` line and `.origin` say `detached`, and the refusal names the short commit.
- A failed fetch replaces the behind/ahead lines; it must not also print a count read from a stale `origin/<main>`.
- The installed copy runs `install` too (`source_dir` reads `.source`): the check is on the source it points to, not on `~/.shipfloor/factory`.
- File names with spaces or non-ASCII characters in the "uncommitted changes" line; the cut at 10 with `and <k> more`.
- #78 rewrites the same `cmd_install`: whichever merges second keeps `.origin` out of the removal pass and writes it after `.source`.
