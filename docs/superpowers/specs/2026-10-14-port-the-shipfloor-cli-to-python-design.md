# Port the shipfloor CLI to Python — spec

**Issue:** #170 · **Branch:** `feat/170-port-the-shipfloor-cli-to-python` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The `shipfloor` CLI is Bash, which blocks the Python port (#153) and behaves unevenly across Windows, macOS and Linux; it must move to `shipfloor_core/cli.py` without any user seeing a change.
**Audience:** Other developers who install the plugin (first command they run is `bash <plugin>/scripts/shipfloor install`), and the factory's owner who runs the CLI daily.
**Acceptance criteria**
- **AC-1** — Given no argument, `help` or an unknown command, when `shipfloor` runs, then it prints today's usage text (with `weight`, without `migrate-home`) to stderr and exits 2.
- **AC-2** — Given a checkout and no `~/.shipfloor` yet, when `bash <checkout>/scripts/shipfloor install` runs, then it installs the factory and prints `installed S → I: X replaced, Y added, Z removed` then `next:` (the `.ps1` hint on MINGW/MSYS/CYGWIN).
- **AC-3** — Given a detached HEAD, a non-main branch, dirty tracked files, a checkout behind/ahead of origin or a failed fetch, when `install` runs without `--force`, then it refuses with the reason and exits non-zero; with `--force` it installs, records `forced` in `.origin` and ends with the `WARN` line.
- **AC-4** — Given an install that crashes at any step, when the installed copy is inspected, then it is entirely the old copy or entirely the new one, and `.source` exists only for a complete install.
- **AC-5** — Given a previous install, when `install` runs again, then unchanged files keep their mtime, files no longer shipped and directories left empty are removed, and no `.<name>.install-tmp` file remains.
- **AC-6** — Given a fresh install, when `shipfloor doctor` runs, then it prints the same `ok   `/`FAIL `/`WARN ` checks as today plus the Python ≥ 3.11 check, reports the installed copy as matching (ignoring `__pycache__`), and exits 1 only on a FAIL.
- **AC-7** — Given the commands `add`, `remove`, `list`, `pause`, `resume`, `pool`, `clean`, `accept`, `weight`, `setup-board`, `metrics`, `dashboard`, when each runs, then its output, exit codes (`weight` exits 3 outside Spec Review or with a live run), `accepted.tsv` lines and `registry.tsv` contents match today, and `dashboard` prints its first line unchanged.
- **AC-8** — Given the existing suites `shipfloor-cli.test.sh`, `install-*.test.sh`, `config-machine.test.sh` and the #161 CLI tests, when they run against the port, then they pass, with only `install-atomic.test.sh` amended to keep its intent.
**Out of scope:** New commands, flags or output wording; restoring `migrate-home`; porting the dispatcher, gates or dashboard server (other PY-* issues); removing the `scripts/shipfloor` Bash entry point.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): the existing CLI tests stay the unedited gate on behavior, and `install` keeps refusing unverified sources. No conflict with positioning; it is an internal port with no user-visible change.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Contracts:** no new public contract. The CLI surface (commands, flags, output, exit codes, `registry.tsv`, `accepted.tsv`, `.source`, `.origin`) stays byte-identical. `shipfloor_core/cli.py` exposes `main(argv) -> int`, called through the `sf.py` entry point from #162.
- **Layer:** `factory` only. Files: `scripts/shipfloor_core/cli.py` (new; uses `proc.py`, `project.py`, file helpers from #162 and the `board`, `gate` and `metrics` ports from #163/#165), `scripts/shipfloor` (becomes a wrapper), `scripts/test/install-atomic.test.sh` (amended), `scripts/test/shipfloor-cli.test.sh` and `scripts/test/install-source.test.sh` (new cases only if QA needs them).
- **Wrapper:** `scripts/shipfloor` stays Bash. It finds Python as `lib/py.sh` does, then runs `-I <package dir>/sf.py cli "$@"`. The package dir is the wrapper's own folder, so a first install from a checkout (no `~/.shipfloor`) works. It must not source `lib/project.sh`.
- **install:** each file is copied to `.<name>.install-tmp` and renamed with `os.replace`; unchanged files (byte compare) are skipped so mtime stays; stale files and empty directories are removed; `.source` is written last, by rename, only when nothing failed; `.origin` is `commit\tbranch\tverified|forced`. `__pycache__` and `test/` are never copied or counted. Git state is read with `proc.git`.
- **install-atomic.test.sh:** it stubs external `mv`/`cp`/`rm`; the Python install no longer calls them. QA replaces the stub with a crash injected at each step (an env var or a monkeypatched `os.replace`) and keeps the same checks: old or new copy, never a mix, `.source` last.
- **doctor:** same lines in the same order, plus the Python ≥ 3.11 check from #162. The copy comparison ignores `__pycache__`, `test`, `.source`, `.origin`.
- **Other commands:** `registry.tsv` written to a temp file and renamed; `weight` keeps exit 3 for the not-in-Spec-Review and live-run cases; `accept` keeps the `accepted.tsv` line format; `dashboard`, `setup-board` and `metrics` hand over to the ported or still-Bash scripts with the same arguments.
- **Migration:** none; the wrapper keeps the same path and name, so docs and installed copies keep working.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/shipfloor-cli.test.sh` |
| AC-2 | factory | `scripts/test/install-source.test.sh` |
| AC-3 | factory | `scripts/test/install-source.test.sh` |
| AC-4 | factory | `scripts/test/install-atomic.test.sh` |
| AC-5 | factory | `scripts/test/install-atomic.test.sh` |
| AC-6 | factory | `scripts/test/shipfloor-cli.test.sh` |
| AC-7 | factory | `scripts/test/shipfloor-cli.test.sh` |
| AC-8 | factory | `scripts/test/config-machine.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight is heavy: the card has 8 acceptance criteria.
- The spec assumes the package, wrapper and process helpers from #162 and the ports of #161, #163 and #165 exist; the card cannot be developed before they merge (its stated dependencies).
- The wrapper finds the package next to itself, so the first install needs no `~/.shipfloor`.
- Crash tests for install-atomic inject failures in Python rather than stubbing `mv`/`cp`/`rm`, since the port no longer calls them; the intent is unchanged.

## Open questions
- none
