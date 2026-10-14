# shipfloor_config notify_problems: channels not a mapping — plan for #243

**Spec:** `docs/superpowers/specs/2026-10-14-shipfloorconfig-notifyproblems-quebra-ex-design.md`
**Branch:** `feat/243-shipfloorconfig-notifyproblems-quebra-ex`

## Tasks

### Task 1 — factory: guard the ntfy-topic read (owner: engineer, layer `factory`)

**Files:**
- `scripts/shipfloor_config.py` (`notify_problems`, the `elif not topic` branch around line 528)

**Change:** run the `err.ntfy_topic` check only when `raw.get("channels")` is a dict. When `channels` is a list, string or number, the loop above already reports `notify.channels must be a mapping`, and the topic check is skipped instead of calling `.get` on a non-dict. Valid configs (channels a mapping, or absent) keep the same output.

**Depends on:** QA acceptance tests (step 3) for AC-1, AC-2 and AC-3.

**Done when:** the acceptance tests in `scripts/test/py/config_machine.py` and `scripts/test/py/cli_doctor.py` pass, and the factory build and test gates are green.
