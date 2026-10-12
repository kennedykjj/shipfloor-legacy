# shipfloor install refuses a clone that is not a clean, up-to-date main — spec

**Issue:** #80 · **Branch:** `feat/80-shipfloor-install-refuses-a-clone-that-i` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** `shipfloor install` copies whatever the plugin clone holds into `~/.shipfloor/factory`; a work branch, a half-written file or a stale main becomes the running factory and nothing says so.
**Audience:** the factory's owner and other developers who install the plugin, at the terminal.
**Acceptance criteria**
- **AC-1** — Given the clone is on a branch other than main, when `shipfloor install` runs, then nothing under `~/.shipfloor/factory` changes, it exits non-zero, names the branch and says what to do (switch to main, or force).
- **AC-2** — Given a tracked file has an uncommitted change, when it runs, then nothing is copied, it exits non-zero and names the changed files; given only untracked files, the install is not blocked.
- **AC-3** — Given main is behind or ahead of its remote after a fetch, when it runs, then nothing is copied, it exits non-zero and names the direction and the number of commits.
- **AC-4** — Given the remote cannot be fetched (no network), when it runs, then nothing is copied, it exits non-zero and says it could not check the remote.
- **AC-5** — Given any of AC-1 to AC-4 and `shipfloor install --force`, when it runs, then it installs, exits zero and prints one line saying the installed copy is not a verified main, with the branch and the short commit.
- **AC-6** — Given a clean main level with its remote, when it runs, then it installs with today's output and exit code, and the commit it came from is recorded.
- **AC-7** — Given the source folder is not a git clone, when it runs, then it installs as today with no check and no refusal.
- **AC-8** — Given an installed copy, when `shipfloor doctor` runs, then it prints the commit the copy came from and, if the install was forced, a WARN line with the branch and commit; a copy with no recorded commit (non-git source, or installed before this change) says so without failing.
**Out of scope:** replacing the files in one step (#78); installing by itself after a merge; pulling, switching branch or stashing on the owner's behalf; any dashboard indication of a forced install; checking the clone again at dispatch time.
**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim): the factory's own scripts are held to what was merged by a check, not by the assumption that the clone is main; and principle 3 (exact and sourced): doctor names the commit rather than "matches the source". No conflict with the positioning or the constraints.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts touched**
- `shipfloor install [--force]` (CLI, `cmd_install` in `scripts/shipfloor`): one new optional flag; any other argument exits 2 with the usage, as `shipfloor add` does. The dispatch line passes the arguments (`install) cmd_install "$@" ;;`).
  - Refusal: exit 1, nothing created or changed under `$SHIPFLOOR_HOME` (the check runs before the first `mkdir`). On stderr, one `shipfloor: not installing from <src>:` line, then one line per reason, then `install anyway: shipfloor install --force`.
  - Reasons, all that apply are listed, each with what to do:
    - `on branch <name>, not <main>` (or `on a detached HEAD at <short>, not <main>`) — `git -C <src> checkout <main>`.
    - `<n> tracked file(s) with uncommitted changes: <path>, <path>…` (the first 10, then `and <k> more`) — commit or stash them.
    - `<n> commit(s) behind origin/<main>` — `git -C <src> pull`.
    - `<n> commit(s) ahead of origin/<main>` — they are not merged; push and merge them first.
    - `could not check the remote (git fetch origin <main> failed)` — replaces the behind/ahead lines.
  - Forced with at least one reason: installs, exits 0, and after the usual output prints `WARN installed copy is not a verified <main>: branch <name>, commit <short> (<reasons, short form>)`. Forced with no reason is a plain install.
- `$SHIPFLOOR_HOME/factory/.origin` (new file, written last, beside `.source`): one line, tab-separated: `<full commit>`, `<branch, or "detached">`, `verified` or `forced`. Absent when the source is not a git clone (an older one is removed).
- `shipfloor doctor` (`cmd_doctor`): one more line after the "installed copy matches / differs" line, never changing the exit code:
  - `ok   installed from <main> at <short>` when `.origin` says `verified`;
  - `WARN installed copy was forced from branch <name> at <short>, not a verified <main> (shipfloor install from a clean <main>)` when it says `forced`;
  - `WARN installed copy has no recorded commit (not a git clone, or installed before this check)` when there is no `.origin`.
  - Its `diff -rq` between source and installed copy also excludes `.origin`.

**Layers and modules** — layer `factory` only.
- `scripts/shipfloor` (changed):
  - `source_state <src>` (new helper beside `source_dir`): prints the reasons, one per line, and sets the branch, commit and main it read. The source is a git clone when `<src>/.git` exists; otherwise it prints nothing and the install goes on unchecked.
    - main: `git symbolic-ref -q --short refs/remotes/origin/HEAD` without `origin/`, else `main` (as `cmd_add`).
    - branch: `git symbolic-ref -q --short HEAD`; changed files: `git -c core.quotePath=false status --porcelain --untracked-files=no`.
    - remote: `GIT_TERMINAL_PROMPT=0 git fetch -q origin <main>`, then `git rev-list --left-right --count HEAD...origin/<main>` (ahead, behind).
  - `cmd_install`: parses `--force`, calls `source_state` before anything is written, refuses or goes on; after `.source`, writes or removes `.origin`. The "drop what the plugin no longer ships" pass skips `.origin` as it skips `.source`.
  - `cmd_doctor`: the line above. Header comment line 3 gains `[--force]`.
- `README.md` (changed): the install line says it refuses a clone that is not a clean, up-to-date main, and names `--force`.
- `scripts/test/install-source.test.sh` (new): each case builds its own source: a `new_repo` holding a copy of `scripts/` and `templates/`, committed and pushed to a bare remote in a temp dir, with `origin/HEAD` set; it runs that copy's `scripts/shipfloor` against a temp `SHIPFLOOR_HOME`. No network: "cannot fetch" is the remote's URL pointed at a path that does not exist.
- `scripts/test/lib.sh` (changed): `plugin_copy`, a plain (non-git) copy of `scripts/` and `templates/` in a temp dir.
- `scripts/test/shipfloor-cli.test.sh`, `scripts/test/transition.test.sh` (changed): their `install` runs from `plugin_copy`; today they install from the checkout under test, which is a feature branch in a worktree and a detached merge commit in CI, and the new check would refuse both.

**Migration plan** — none: no data, no schema. A copy installed before this change has no `.origin`; doctor says so until the next install.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/install-source.test.sh` |
| AC-2 | factory | `scripts/test/install-source.test.sh` |
| AC-3 | factory | `scripts/test/install-source.test.sh` |
| AC-4 | factory | `scripts/test/install-source.test.sh` |
| AC-5 | factory | `scripts/test/install-source.test.sh` |
| AC-6 | factory | `scripts/test/install-source.test.sh` |
| AC-7 | factory | `scripts/test/install-source.test.sh` |
| AC-8 | factory | `scripts/test/install-source.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a — nothing destructive. Reverting the commit restores the unchecked install; a leftover `.origin` is then one more file the old `doctor` reports as a difference until the next install removes it.

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The flag is `--force`: the issue asks for "an explicit flag" and this is the name every CLI uses for it.
- Ahead of the remote refuses like behind: the issue lists it under what is needed; unmerged commits are exactly "not what was merged".
- Behind and ahead are counted against `origin/<main>`, not the current branch's upstream: the question is whether the copy is what was merged, and a work branch is refused by name anyway.
- Every reason that applies is listed, not only the first: the owner fixes the clone in one pass.
- A failed fetch refuses with its own message and no behind/ahead count: a count against a stale `origin/<main>` would be the false "up to date" the issue describes.
- `--force` still runs the checks: the WARN line needs the reasons, and a forced install of a clean main is recorded as `verified`, not as forced.
- The fetch has no timeout: `timeout` is not on macOS by default; `GIT_TERMINAL_PROMPT=0` keeps it from waiting on a credential prompt.
- The source is a git clone when `<src>/.git` exists, not when git finds a repository above it: a marketplace cache that sits inside some other repository is still not a clone of the plugin.
- The commit goes in a new `.origin` file, `.source` keeps its one-line path: `source_dir` reads `.source` whole, and #78 writes it as the last step with that exact content.
- Untracked files never block, and they are still copied as today: the issue says so, and ignoring them is how a new, not yet added script is tried with `--force`.
- Doctor's new line is `ok` or `WARN`, never `FAIL`: a forced install is the owner's choice and must not make `doctor` exit non-zero.
- The existing tests install from a plain copy instead of passing `--force`: they stay independent of the branch and network of the checkout that runs them, and no test-only switch enters `cmd_install`.
- #78 rewrites the same `cmd_install`; whichever merges second keeps `.origin` out of the "no longer shipped" removal and writes it after `.source`. The AC-6 and AC-8 tests fail if that is lost.
- `.shipfloor/factory.yml` has a comment about `shipfloor install` from main; it stays as it is (the path is off-limits to the pipeline and the comment remains true).

## Open questions
- none
