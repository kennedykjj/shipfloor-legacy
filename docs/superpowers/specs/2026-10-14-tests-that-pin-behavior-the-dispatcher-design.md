# [PY-07] Tests that pin behavior: the dispatcher (dispatch, shipfloor-dispatch, run-dispatcher) — spec

**Issue:** #160 · **Branch:** `feat/160-tests-that-pin-behavior-the-dispatcher` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The dispatcher starts every run, and its process model (detach, signals, locks) is where a Python port (PY-15, PY-16) differs most from Bash; much of `dispatch.sh`, `shipfloor-dispatch.sh` and `run-dispatcher.sh` behavior is untested, so a port could break it silently.
**Audience:** The factory's owner, and developers who install the plugin and rely on the dispatcher to start, count and clean up runs correctly.
**Acceptance criteria**
- **AC-1** — Given a launched run, when the cycle returns, gets SIGHUP, or counts locks (with `FACTORY_LOCK_TTL`, `refresh-*` locks, 3 deploy rounds of exit 3, or `cleanup_processes` with `powershell.exe` stubbed), then the run stays alive, the lock exists before `info`, the run removes only its own lock and logs `== end`, stale locks and processes outside `$WT_ROOT/<n>/` are handled as today.
- **AC-2** — Given a launch, when `reports-wt` or `infra/<n>` exist or not, then the `Read(//…/reports-wt/**)` rule and `SHIPFLOOR_INFRA_RETRY=1` are passed only when they exist, and `--model`/`weight=` on `== start` match `dashboard.py`'s regex.
- **AC-3** — Given `day_stop`, a card leaving the board, an empty `board.tsv`, or `block_card` with python rc 2, when a dispatch runs, then it exits before the infra retry, removes `cost/*.json` and `stepup/*` only for departed cards (never on empty `board.tsv`), and restores from `.prev` with no start.
- **AC-4** — Given `language` pt-BR, or two dispatches at once for the same project, when the dispatcher runs, then its own lines come out through the `MLANG` translation and each PID writes its own `board.tsv` temp file without clobbering the other.
- **AC-5** — Given an empty or missing registry, `SHIPFLOOR_STALE_LOCK_MIN`, a git failure, PAUSE, the usage limit, or an overlap, when `shipfloor-dispatch.sh` runs, then it exits 0 with no health line, honors the override, writes the `SKIPPED` reason in today's format, and writes the health line where it does today.
- **AC-6** — Given `PAUSE`, or a normal run with `dispatcher.path`, when `run-dispatcher.sh` runs, then it exits 0 with no health line on PAUSE, appends stdout and stderr to `logs/dispatcher.log`, and uses `PATH` from `dispatcher.path`.
- **AC-7** — Given the process-model tests, when they run, then no stub replaces the launch itself and `FACTORY_CLAUDE` is a real script that sleeps and writes.
- **AC-8** — Given main with the new tests, when the test suite runs, then every issue bullet has an assertion and the suite passes with no change to the dispatcher scripts.
**Out of scope:** Changing `dispatch.sh`, `shipfloor-dispatch.sh` or `run-dispatcher.sh`; a bug a test finds goes to PY-04 or a new issue under #153. The Python port (PY-15, PY-16) and PY-01's macOS/Windows CI jobs.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): the dispatcher's behavior is pinned by scripts before it is rewritten. No conflict with positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Contracts:** none changed. The lock layout (`locks/<stage>-<n>.lock/info`), `== start` / `== end` log lines, `SKIPPED`, `logs/dispatcher.log` and the health line are only observed.
- **Layer:** `factory` only. New files, one per issue group, each sourcing `scripts/test/lib.sh`:
  - `scripts/test/dispatch-process.test.sh` (AC-1, AC-7): real `launch` with `FACTORY_CLAUDE` a script that sleeps and writes; no wait helper that joins the run (`run_dispatch` is not used), SIGHUP, lock before `info`, TTL, 3 deploy rounds, `refresh-*`, `cleanup_processes` with a stub `powershell.exe` on `PATH`.
  - `scripts/test/dispatch-launch-flags.test.sh` (AC-2): reports-wt rule, `infra/<n>`, `--model`/`weight=` checked against the regex read out of `scripts/dashboard.py`.
  - `scripts/test/dispatch-cost-cleanup.test.sh` (AC-3): `day_stop` vs infra retry order, `cost/*.json` and `stepup/*` cleanup, empty `board.tsv`, `block_card` rc 2.
  - `scripts/test/dispatch-lang-files.test.sh` (AC-4): `MLANG` pt-BR lines, per-PID `board.tsv` temp file, two dispatches at once.
  - `scripts/test/shipfloor-dispatch-cycle.test.sh` (AC-5): empty/missing registry, `SHIPFLOOR_STALE_LOCK_MIN`, `SKIPPED` format, health line on PAUSE / usage limit / overlap.
  - `scripts/test/run-dispatcher.test.sh` (AC-6): PAUSE, `dispatcher.log`, `dispatcher.path`.
- **Helpers:** reuse `lib.sh`; any shared setup (fake board, sleeping `FACTORY_CLAUDE`) is a function added to `lib.sh` without changing existing output.
- **Hygiene:** every test kills its own sleeping children in a trap and uses `mktemp -d` homes, so `TEST_JOBS=4` stays safe; waits use `wait_for`, no fixed sleeps.
- **Bugs found:** a test that exposes a bug pins today's behavior and a follow-up is opened under #153; the three scripts are not edited.
- **Migration:** none (tests only).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dispatch-process.test.sh` |
| AC-2 | factory | `scripts/test/dispatch-launch-flags.test.sh` |
| AC-3 | factory | `scripts/test/dispatch-cost-cleanup.test.sh` |
| AC-4 | factory | `scripts/test/dispatch-lang-files.test.sh` |
| AC-5 | factory | `scripts/test/shipfloor-dispatch-cycle.test.sh` |
| AC-6 | factory | `scripts/test/run-dispatcher.test.sh` |
| AC-7 | factory | `scripts/test/dispatch-process.test.sh` |
| AC-8 | factory | `scripts/test/dispatch-cost-cleanup.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: 8 acceptance criteria (more than 6).
- Six test files, one per issue group: small files that `TEST_JOBS=4` runs in parallel.
- AC-7/8 are suite-wide; each is mapped to one representative file.
- The issue's macOS/Windows job requirement is out of scope here (PY-01 owns those jobs); this card is checked on Linux main.

## Open questions
- none
