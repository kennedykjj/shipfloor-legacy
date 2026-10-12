# shipfloor install replaces each script in one step, so it is safe while runs are in progress — spec

**Issue:** #78 · **Branch:** `feat/78-shipfloor-install-replaces-each-script-i` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** `shipfloor install` rewrites installed scripts in place and removes `templates/` before copying it again, so a run in progress can continue from the middle of other text or find a template missing. The owner pauses the factory and waits for every run to end (up to half an hour) before installing.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine (and other developers who install the plugin).
**Acceptance criteria**
- **AC-1** — Given a long-running script started from the installed copy, when `shipfloor install` replaces that script with different content, then the running one finishes as the old version and exits 0, and the next start of it runs the new version.
- **AC-2** — Given an installed copy equal to the source, when `shipfloor install` runs, then no installed file's modification time changes and the output reports 0 replaced, 0 added, 0 removed.
- **AC-3** — Given a reader that opens an installed template again and again, when `shipfloor install` runs with changed templates, then the reader never fails to find the file and never reads a partial one.
- **AC-4** — Given the installed copy holds a script or a template the plugin no longer ships, when `shipfloor install` runs, then that file is gone afterwards and every shipped file is present.
- **AC-5** — Given an install was killed halfway, when the installed copy is inspected, then every installed file is whole (byte-equal to its old or its new version) with no leftover temporary file taken for a script, and a second `shipfloor install` leaves the copy equal to the source and exits 0.
- **AC-6** — Given a source with changed, new and no-longer-shipped files, when `shipfloor install` runs, then its output states how many files it replaced, added and removed, and each number equals the real count.
- **AC-7** — Given an install that did not finish (killed, or a file could not be replaced), when the installed copy is inspected, then `.source` is unchanged from before the install (absent on a first install) and `shipfloor doctor` does not report that the copy matches; `.source` names the source only after every file is in place.
- **AC-8** — Given Git Bash on Windows and an installed file that cannot be renamed over because another process holds it, when `shipfloor install` runs, then the output names each such file, the other files are still installed, the command exits non-zero, and a later install once the file is free completes and exits 0.
**Out of scope:** Installing by itself after a merge. Checking that the clone is on a clean `main` before installing (its own issue). Pausing, draining or restarting runs on the owner's behalf. Changing what `shipfloor doctor` compares.
**Product fit:** Serves principle 2 and the positioning ("the gates are scripts"): a gate script torn mid-run is no longer deterministic, so the installed copy must always be whole. Serves principle 3 (the replaced/added/removed counts are exact) and principle 4 (the owner no longer stops the factory to do something the factory does not wait on). No conflict with positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts touched**
- `shipfloor install` (CLI, `cmd_install` in `scripts/shipfloor`): same arguments (none) and same destination (`$SHIPFLOOR_HOME/factory`).
  - stdout, last lines: `installed <src> → <dst>: <r> replaced, <a> added, <d> removed`, then the existing `next: …` line. The `installed <src> → <dst>` prefix is kept.
  - stderr, one line per file that could not be put in place: `shipfloor: could not replace <path relative to the installed copy>`.
  - exit: 0 when every file is in place; 1 when at least one could not be replaced or removed (today: always 0).
- `.source`: same content (the plugin path); now written only after every file is in place, and only when its content differs.
- No endpoint, event or config key changes. `shipfloor doctor` is untouched.

**Layers and modules** — layer `factory` only.
- `scripts/shipfloor` (changed): `cmd_install` and one new helper beside it.
  - `put_file <src> <dst>`: `cmp -s` equal → nothing; else copy to `<dir>/.<name>.install-tmp` in the destination's own directory and `mv -f` it over `<dst>`. A failed `mv` deletes the temporary file, records the path and returns non-zero; the caller goes on.
  - Order of one install: 1) delete leftover `.*.install-tmp` files (not counted); 2) scripts (everything under `scripts/` except `test/`), each through `put_file`; 3) `templates/`, each file through `put_file`, the folder never removed; 4) remove installed files no longer shipped, scripts then templates, then directories left empty; 5) `.source` through `put_file`; 6) the summary line.
  - Any failure in 2–4 skips step 5 and makes the exit 1; the remaining files are still processed.
  - The loops count in the calling shell (process substitution, not a pipeline), so the three counts survive the loop.
- `scripts/test/install-atomic.test.sh` (new): AC-1 to AC-8, each in its own temporary `SHIPFLOOR_HOME` and its own copy of the source tree.
  - AC-5 and AC-8 put a fake `mv` first on `PATH` (written by the test into a temp dir): it kills its parent on the Nth call, or fails for one named target. On Windows (Git Bash) AC-8 also holds one installed file open from Python, which does not share delete access, and expects the same outcome whether or not that rename is refused.
- `README.md` (changed): the install line says it is safe with runs in progress.

**Migration plan** — none: no data, no schema. The first install with the new code replaces the old files by rename like any other.

## Test plan
## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/install-atomic.test.sh` |
| AC-2 | factory | `scripts/test/install-atomic.test.sh` |
| AC-3 | factory | `scripts/test/install-atomic.test.sh` |
| AC-4 | factory | `scripts/test/install-atomic.test.sh` |
| AC-5 | factory | `scripts/test/install-atomic.test.sh` |
| AC-6 | factory | `scripts/test/install-atomic.test.sh` |
| AC-7 | factory | `scripts/test/install-atomic.test.sh` |
| AC-8 | factory | `scripts/test/install-atomic.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- A file that cannot be replaced does not stop the install: the others are installed, the file is named, the exit is 1 and `.source` is left alone. The issue asks for the name rather than a silent stop, and a re-run finishes the job.
- The temporary file is `.<name>.install-tmp` in the destination's own directory: same volume, so the rename is one step, and the leading dot keeps it out of `*.sh` and `*.md` globs.
- Leftover temporary files are deleted at the start of the next install and are not counted as removed: the counts are about shipped files.
- "Replaced" is a file whose content changed, "added" one that was not installed, "removed" one no longer shipped; `.source` is in none of the counts.
- Unchanged is decided by content (`cmp -s`), not by date: a fresh clone has new dates and equal content.
- Templates no longer shipped are removed like scripts, after the new ones are in place, so `templates/` is never empty or missing.
- The killed install is tested with a fake `mv` on `PATH` that kills its parent, not with a timer or a switch in `cmd_install`: deterministic, and no test-only code in the product.
- AC-8 is forced on every system with a fake `mv` that fails for one file; the real held-open file is exercised on Git Bash only, where CI's Linux runner cannot reproduce it.
- All eight criteria live in one new test file: they share the same fixture (a copy of the source tree and a temporary home), and `shipfloor-cli.test.sh` keeps the plain install checks.
- `shipfloor doctor` is not changed: it already compares content, so an unfinished install shows as a difference.
- Exit 1 on a file that could not be replaced is new behaviour for callers; nothing in the factory calls `install` by itself, so no caller changes.

## Open questions
- none
