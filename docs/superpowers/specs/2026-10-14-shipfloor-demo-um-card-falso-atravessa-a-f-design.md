# shipfloor demo: a fake card crosses the factory, no real repo and no tokens — spec

**Issue:** #175 · **Branch:** `feat/175-shipfloor-demo-um-card-falso-atravessa-a-f` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** Seeing the factory work today takes a real repo, a real board and real tokens; the first impression costs an afternoon, and most people give up before it.
**Audience:** Other developers who install the plugin (evaluating Shipfloor before trusting it with a repo).
**Acceptance criteria**
- AC-1: Given a common machine with no network access, when the user runs `shipfloor demo`, then it finishes in about 2 minutes with exit code 0.
- AC-2: Given the CI matrix (#154), when the suite runs on each of its OSes, then `demo.test.sh` runs the demo there and passes.
- AC-3: Given a real `~/.shipfloor`, when `shipfloor demo` runs, then that directory is unchanged afterwards, and the test checks it.
- AC-4: Given the README, when a reader reaches the quick start, then a "Try it: `shipfloor demo`" line appears before it.
- AC-5: Given the demo is running, when the card moves, then the terminal narrates each column transition from refine through deploy, the red gate before code, the green gate after, one block going to the owner and the two owner approvals.
- AC-6: Given the demo is running, when it starts and when it shows a run, then the screen states in plain words that no LLM ran and the runs are recorded transcripts.
- AC-7: Given `shipfloor demo` without flags, when it ends, then the dashboard was opened on the temporary home and the temporary home is deleted.
- AC-8: Given `--no-dashboard` or `--keep`, when the demo runs, then `--no-dashboard` skips opening the dashboard and `--keep` leaves the temporary home in place and prints its path.
**Out of scope:** Calling any real LLM, GitHub or network service; depending on `shipfloor init` (#174, not built yet); the Floor v4 redesign (#180-#184) or any dashboard change; an interactive demo where the user approves cards themselves.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim) by showing the gates deciding, and honors Evidence on Hand: recorded transcripts are labeled as such, nothing simulated is presented as real. No conflict with the positioning.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Layer: `factory` only. Contracts touched: the `shipfloor` CLI gets one command, `demo [--no-dashboard] [--keep]`; nothing else public changes.
- `scripts/shipfloor_core/demo.py` (new): `main(args)`. Makes a temp dir; sets `SHIPFLOOR_HOME` and `FACTORY_GH` for the processes it starts; builds a local bare "origin" plus a clone of a tiny sample project (a one-file Python app with a `unittest` layer) with `.shipfloor/factory.yml`; registers it with `cli.cmd_add` (offline: origin is local); then plays one card through refine → develop → validate → deploy. Real parts: `board.sh` moves against the gh stand-in, `gate.sh` red (acceptance tests fail before the code) and green (they pass after), git commits, `report.sh`. Recorded parts: each stage's spec text, code change and run log are fixed files written as if an agent made them; the run logs and reports go in the formats `dashboard.py` reads. No `claude` process is ever started. One run ends in a block that goes to the owner (label `blocked` plus a comment), then the owner's approval moves the card, and a second approval releases the deploy. Narration: one line per transition, per gate verdict, per block and approval; the banner and the first run line say "no LLM ran: these runs are recorded transcripts". Without `--no-dashboard` it starts `dashboard.py --home <temp home>` on a free port, prints the URL, opens the browser and waits for Enter or Ctrl+C; the temp dir is removed at the end (also on error and Ctrl+C) unless `--keep`, which prints its path.
- `scripts/demo/gh` (new, shipped): the gh stand-in for the demo (board, issues, labels, comments, PR merge), state in a JSON file under the temp dir; no network. It lives in `scripts/demo/` because `install` ships everything under `scripts/` except `scripts/test/`, so the stubs in `scripts/test/` (`fake-gh`, `demo-gh`) are not on an installed machine. The test stubs stay as they are.
- `scripts/shipfloor_core/cli.py`: `COMMANDS["demo"]` delegating to `demo.main`; `usage()` and the header of `scripts/shipfloor` list the command.
- `README.md`: a "Try it: `shipfloor demo`" section before "Quick start"; `docs/install.md` gets one sentence.
- `scripts/test/demo.test.sh` (new): see the test plan.
No migration, nothing destructive.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/demo.test.sh` |
| AC-2 | factory | `scripts/test/demo.test.sh` |
| AC-3 | factory | `scripts/test/demo.test.sh` |
| AC-4 | factory | `scripts/test/demo.test.sh` |
| AC-5 | factory | `scripts/test/demo.test.sh` |
| AC-6 | factory | `scripts/test/demo.test.sh` |
| AC-7 | factory | `scripts/test/demo.test.sh` |
| AC-8 | factory | `scripts/test/demo.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: 8 acceptance criteria (more than 6).
- The demo does not call `shipfloor init` (#174 is not built) nor `cmd_install`: install refuses a dirty or behind checkout and fetches the network. It runs the scripts from its own checkout and registers the sample with `cmd_add`; it can switch to `init` once #174 lands.
- The gh stand-in is a new shipped copy under `scripts/demo/`, not the test stubs: `install` does not ship `scripts/test/`, so the demo would not run on an installed machine.
- No `claude` stand-in: no agent runs, so the recorded stage content is written by the demo itself; the test puts a `claude` that fails on PATH to prove nothing calls it.
- The test isolates by setting `HOME` and `SHIPFLOOR_HOME` to temp dirs and hashing a sentinel tree, and puts failing `gh` and `claude` on PATH; "no network" is that tripwire plus the local-only origin.
- The dashboard opening waits for Enter or Ctrl+C so the newcomer can look; the test uses `--no-dashboard` and starts the dashboard once on a free port with the browser opener disabled.
- "About 2 minutes" is a target, not a gate: the test asserts exit 0 within its own 5-minute timeout.

## Open questions
- **CI matrix:** A (recommended) — the owner adds macOS and Windows to `.github/workflows/ci.yml` by hand (#154 closed as not planned, so CI runs Linux only today); the demo test is written portable and passes on Linux now, or B — drop "three OSes" from AC-2 and accept Linux only.
