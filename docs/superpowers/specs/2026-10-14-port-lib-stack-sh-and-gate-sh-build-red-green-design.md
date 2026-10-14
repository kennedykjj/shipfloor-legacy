# [PY-13] Port lib/stack.sh and gate.sh build/red/green to Python — spec

**Issue:** #166 · **Branch:** `feat/166-port-lib-stack-sh-and-gate-sh-build-red-green` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** stack leasing and the `build`/`red`/`green` gates are still Bash (`lib/stack.sh`, `scripts/lib/gate-run.sh`), blocking the Python port (#153); they must move to `shipfloor_core` with no behavior change, and a pass recorded before an upgrade must not be reused after it.
**Audience:** the factory's owner, and the developers who install the plugin (their gates and stacks must behave the same after upgrading).

**Acceptance criteria**
- AC-1 (stack state, lease, queue): Given projects with and without `stack.up` competing for slots, When `sf.py stack` leases, reclaims, releases and reports status, Then the files under `$SHIPFLOOR_HOME/locks` (`stack-<k>.lock/{info,beat,beat.pid,solo,env,down,cwd,up.log}`, `stack-queue/`, `logs/stacks.log`), atomic-`mkdir` leases, zero-padded head-only tickets, solo-blocking, `slot_state` reasons, the `stack status` TSV, the exported `SHIPFLOOR_*` env, the messages and exit codes (incl. exit 3) and port freeing are identical to the Bash version.
- AC-2 (heartbeat): Given a leased slot, When the gate that started it exits, Then the heartbeat keeps touching `beat` every 15 s from `/`, ignores HUP, holds no inherited fd, and stops when the lock dir is gone.
- AC-3 (up, down, health): Given a slot being brought up, When `down` then `up` and the health probes run, Then `down` uses the new slot's env, `up` output goes to `up.log` with its tail printed on failure, probes use a `clamp(remaining,1,5)` timeout (`file://` included) with the `REJECT` precedence, and the `up failed:`/`not healthy after Ts at <url>` messages are unchanged.
- AC-4 (build, red, green): Given the existing gate-test repos, When a differential test runs `build`, `red` and `green` with the Python version and with the Bash version kept as a fixture, Then exit codes and output match (runner env, `{selector}` as an argument, one-time deps install with exit 3 on failure, layer selection, retry and `flaky:` messages, red's error matching and 20 assertion lines).
- AC-5 (pass cache): Given a recorded pass, When `green` runs again on the same clean tree, Then it prints `<gate>: reused the pass on <sha12> recorded <time>; nothing ran` before any install or stack, and no cache is used with `SHIPFLOOR_GATE_FRESH=1`, an empty `FACTORY_HOME`, a dirty worktree or a store inside the worktree; records older than 14 days are pruned.
- AC-6 (cache key on upgrade): Given a pass recorded before the upgrade, When any file under `shipfloor_core/` or `sf.py` changes, Then that pass is not reused and the gate runs.
- AC-7 (needs_stack, FIFO): Given 3 slots and 5 concurrent `gate.sh green` on `needs_stack` layers, When they run (and when one is interrupted with INT/TERM), Then the queue serves them in FIFO order, each keeps its verdict, and no slot is left leased afterwards.
- AC-8 (compatibility, cleanup): Given the port is in place, When the existing `gate-*.test.sh`, `stack-*.test.sh`, `dispatch-stack.test.sh` and the PY-03/PY-05 tests run unedited, Then they pass, `scripts/lib/gate-run.sh` no longer exists, and `lib/stack.sh` is a shim calling `sf.py stack …` that `dispatch.sh` still sources for `stack_settings`/`stack_release_run`.

**Out of scope:** any behavior change (including the fail-open `stack_settings`, unless the owner decided otherwise on #158); porting `dispatch.sh` (#168); other gates not named here.

**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim): the gates stay scripts with identical verdicts, and the widened cache key stops a stale pass from standing in for a real run after an upgrade. No conflict with the positioning.

**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts:** no CLI change. `gate.sh build|red|green|stack` keep arguments, exit codes, stdout/stderr and verdict. `sf.py stack <settings|lease|up|down|release-run|status|slot-state|...>` is the new entry the shim calls; its `status` TSV (`<k>\t<state>\t<owner>\t<held_s>\t<reason>` per slot, then `queue\t<n>`) is what `dashboard.py` and `shipfloor pool` parse. New Python API: `shipfloor_core.stack` (settings, slot_state, lease, up, down, release, release_run, status, heartbeat) and `shipfloor_core.gate.run` (`build`, `red`, `green`, `ensure_deps`, pass cache).

**Layer:** one, `factory`. Files:
- `shipfloor_core/stack.py`: everything in `lib/stack.sh`; the heartbeat is a detached child (`start_new_session`, HUP ignored, cwd `/`, `close_fds=True`, no inherited fd), pid in `beat.pid`.
- `shipfloor_core/gate/run.py`: `build`, `red`, `green`, `ensure_deps`, `stack_around` (lease, always release, INT/TERM handlers, verdict kept), the pass cache (`pass_key`/`pass_reused`/`pass_record`, key adds a hash of every file under `shipfloor_core/` and of `sf.py`).
- `shipfloor_core/gate/main.py` (from #165): route `build|red|green|stack` to `run.py` instead of `gate-run.sh`.
- `scripts/lib/gate-run.sh`: deleted.
- `scripts/lib/stack.sh`: shim of Bash functions (`stack_settings`, `stack_release_run`, `stack_status`, ...) calling `sf.py stack ...`; `stack_settings` keeps exporting the variables `dispatch.sh` reads.
- `scripts/test/fixtures/gate.bash.sh`, `scripts/test/fixtures/stack.bash.sh`: the pre-port Bash, kept as differential references.
- New tests (see Test plan).

**Migration plan:** no data migration; lock files, `accepted.tsv`-style records and the pass-record format are unchanged. Old passes simply stop matching (new key), which is intended. Order: copy the Bash fixtures, write the differential tests green against Bash, port stack then run, swap the shim, delete `gate-run.sh`. Rollback is reverting the PR plus `shipfloor install`.

**Dependencies:** needs #165 (PY-12: `shipfloor_core/gate/` dispatch, `gate-run.sh`) and, through it, the package, `ere_match` (#162) and the PY-03/PY-05 tests (#156, #158) on main. None is on main today.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/stack-py-lease.test.sh` |
| AC-2 | factory | `scripts/test/stack-py-heartbeat.test.sh` |
| AC-3 | factory | `scripts/test/stack-py-up.test.sh` |
| AC-4 | factory | `scripts/test/gate-py-run-diff.test.sh` |
| AC-5 | factory | `scripts/test/gate-py-pass-cache.test.sh` |
| AC-6 | factory | `scripts/test/gate-py-cache-key.test.sh` |
| AC-7 | factory | `scripts/test/gate-py-stack-fifo.test.sh` |
| AC-8 | factory | `scripts/test/gate-py-run-compat.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Weight heavy: more than 6 acceptance criteria and more than 8 files.
- Bash reference copies kept as test fixtures, as the issue asks, so differential tests need no git history.
- Fail-open `stack_settings` kept, as the issue says, since nothing on #158 changes it.
- The `shipfloor_core` hash in the cache key covers every file under it plus `sf.py`, so any upgrade invalidates old passes by design.

## Open questions
- **Order:** A (recommended) hold this card until #165 (and so #162, #156, #158) is merged, none is on main, or B approve now — develop would have no package, `gate-run.sh` or PY-03/05 tests to build on.
