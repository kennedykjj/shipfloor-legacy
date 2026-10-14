# shipfloor_config: notify_problems quebra (exit 2) quando notify.channels não é um mapa — spec

**Issue:** #243 · **Branch:** `feat/243-shipfloorconfig-notifyproblems-quebra-ex` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** light

## Product
_Product Owner_

**Problem:** When `notify.channels` in the config is not a mapping (a list, string or number) and `ntfy_topic` is empty or absent, config validation crashes with a traceback (exit 2) instead of naming the bad key, so the owner gets a stack trace instead of a fix to make.
**Audience:** The factory's owner (and developers who install the plugin) editing their Shipfloor config.
**Acceptance criteria**
- **AC-1** — Given a config whose `notify.channels` is a list or a string and no `ntfy_topic`, when the owner runs `shipfloor_config validate`, then it prints the line `notify.channels must be a mapping`, prints no traceback, and exits 1.
- **AC-2** — Given that same config, when the owner opens the dashboard Settings or runs `doctor`, then each shows the `notify.channels must be a mapping` line instead of failing.
- **AC-3** — Given a valid config (channels a mapping, with or without an ntfy topic) or a config with no `notify.channels`, when the owner runs `validate`, then the output and exit code are the same as before this change.

**Out of scope:** New validation rules for other `notify` keys; changing the wording of existing problem lines; auto-repairing the config.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): config validation is a deterministic check and must report, not crash. No conflict with the positioning or out-of-scope items.
**Touches UI:** no (the dashboard only shows an existing problem line; no layout or component change)

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Contract touched:** `shipfloor_config.notify_problems(raw) -> list` (no signature change). With `channels` not a mapping, it returns the existing `notify.channels must be a mapping` line and skips the ntfy-topic check. It does not raise.
- **Change:** `scripts/shipfloor_config.py:528`: run the `err.ntfy_topic` check only when `raw.get("channels")` is a dict. Callers stay as they are: `machine_problems` → `machine validate` (the CLI and the dispatcher), the dashboard Settings save (`dashboard.py:940`), the dashboard cost/notify reads and `doctor` all get the line through `machine_problems`.
- **Layers/modules:** `factory` only: `scripts/shipfloor_config.py` and the tests in `scripts/test/py/config_machine.py` and `scripts/test/py/cli_doctor.py`.
- **Migration:** none. No data or config format change.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/config_machine.py` |
| AC-2 | factory | `scripts/test/py/cli_doctor.py` |
| AC-3 | factory | `scripts/test/py/config_machine.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Guard the single `channels` read in the ntfy-topic check instead of restructuring `notify_problems`: the loop already reports the bad shape, and only this read crashes.
- `events` needs no guard: `notify_problems` reads it only inside the loop, after the dict check.
- AC-2 is tested through `doctor` in `cli_doctor.py`. The dashboard Settings save calls the same `machine_problems`, so a second end-to-end test would add nothing.
- Weight `light`: one layer, 3 ACs, 3 files, no UI, no security section.

## Open questions
- none
