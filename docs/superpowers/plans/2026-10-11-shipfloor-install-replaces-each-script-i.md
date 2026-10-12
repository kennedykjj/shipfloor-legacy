# shipfloor install replaces each script in one step, so it is safe while runs are in progress — plan

**Issue:** #78 · **Spec:** `docs/superpowers/specs/2026-10-11-shipfloor-install-replaces-each-script-i-design.md`
**Branch:** `feat/78-shipfloor-install-replaces-each-script-i`

One layer (`factory`), one implementation task. The acceptance tests come first and are QA's.

## Acceptance tests (QA, before any implementation)

- `scripts/test/install-atomic.test.sh` (new): AC-1 to AC-8. Each case has its own temporary `SHIPFLOOR_HOME` and its own copy of the source tree (`scripts/` without `test/`, plus `templates/`), and runs `bash <copy>/scripts/shipfloor install`. Follow the setup and the `ok` / `FAIL` output of `scripts/test/shipfloor-cli.test.sh`.
  - AC-1: a long-running script started from the installed copy, replaced while it runs: it ends as the old version with exit 0, and the next start is the new version.
  - AC-2: a second install of an unchanged source: no modification time changes, and the summary says `0 replaced, 0 added, 0 removed`.
  - AC-3: a background reader that opens one installed template in a loop while installs with changed templates run: never missing, never partial.
  - AC-4: a script and a template the source no longer ships are gone, every shipped file is present.
  - AC-5 and AC-7 (killed): a fake `mv` first on `PATH`, written by the test into a temp dir, kills its parent on the Nth call. Every installed file is byte-equal to its old or its new version, no `.*.install-tmp` is taken for a script, `.source` is as before, `shipfloor doctor` does not say the copy matches, and a second install ends equal to the source with exit 0.
  - AC-6: a source with changed, new and no-longer-shipped files: the three numbers of the summary equal the real counts.
  - AC-8 and AC-7 (not replaced): a fake `mv` that fails for one named target: stderr has `shipfloor: could not replace <relative path>`, the other files are installed, exit is non-zero, `.source` is unchanged, and a later install with the real `mv` exits 0. On Git Bash only, also hold one installed file open from Python (no delete sharing) and expect the same outcome whether or not that rename is refused.
- `scripts/test/shipfloor-cli.test.sh` is not changed: it keeps the plain install checks.

## Tasks

### T1 — every installed file is put in place by rename, and the install counts what it did

- **Layer:** factory · **Owner:** engineer · **Depends on:** the acceptance tests
- **Files:** `scripts/shipfloor` (`cmd_install` and one new helper beside it), `README.md` (the install line)
- **What**
  1. `put_file <src> <dst>`: `cmp -s` equal → nothing. Otherwise copy to `<dir>/.<name>.install-tmp` in the destination's own directory and `mv -f` it over `<dst>`. A failed copy or `mv` deletes the temporary file, prints `shipfloor: could not replace <path relative to the installed copy>` on stderr and returns non-zero; the caller goes on. It tells the caller whether the file was replaced, added or left alone.
  2. `cmd_install`, in this order:
     1. delete leftover `.*.install-tmp` files under the installed copy (not counted);
     2. scripts (everything under `scripts/` except `test/`), each through `put_file`;
     3. `templates/`, each file through `put_file`; the folder is never removed;
     4. remove installed files no longer shipped, scripts then templates, then the directories left empty; a file that cannot be removed is named the same way and counts as a failure;
     5. `.source` through `put_file`, only when steps 2–4 had no failure;
     6. `installed <src> → <dst>: <r> replaced, <a> added, <d> removed`, then the existing `next: …` line.
  3. The loops read from process substitution (`done < <(...)`), not from a pipeline, so the counts and the failure flag survive the loop.
  4. Exit 0 when every file is in place, 1 when at least one could not be replaced or removed.
  5. `README.md`: the install line says it is safe with runs in progress.
- **Not changed:** `cmd_doctor`, `source_dir`, the arguments and the destination of `install`, `.source`'s content, `scripts/test/shipfloor-cli.test.sh`.
- **Done when:** `scripts/test/install-atomic.test.sh` and `scripts/test/shipfloor-cli.test.sh` pass.

## Risks to watch

- `mv` must be found through `PATH` (no absolute path, no `command -p`), or the tests' fake `mv` is skipped.
- The mode of a script must survive the copy to the temporary file: an installed script that lost its execute bit breaks callers that run it directly.
- A leftover `.*.install-tmp` must never be listed as "no longer shipped" and counted as removed: step 1 runs before any count.
- `.source` is in none of the three counts, and is not rewritten when its content is the same (AC-2: no modification time changes).
- On Git Bash `mv -f` over a file another process holds may fail or succeed depending on how it was opened: both are valid, the install must name the file when it fails and go on.
- Card #80 (`shipfloor install` refuses a clone that is not on a clean `main`) also edits `cmd_install`: whichever lands second resolves the overlap in the deploy.
