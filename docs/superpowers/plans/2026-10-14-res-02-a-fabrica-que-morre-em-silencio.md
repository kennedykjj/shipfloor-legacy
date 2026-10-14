# [RES-02] The factory that dies silently — plan for #176

**Spec:** `docs/superpowers/specs/2026-10-14-res-02-a-fabrica-que-morre-em-silencio-design.md`
**Layers:** factory (only layer; agent `engineer`)

## Tasks

### Task 1 — factory: health silence check, dashboard banner, i18n
**Owner:** engineer (layer `factory`, path `./`)
**Depends on:** the QA commit (acceptance tests in `scripts/test/health.test.sh` and `scripts/test/dashboard-silent.test.sh`)
**Files:**
- `scripts/shipfloor_health.py` — new public `silence(home) -> dict | None` (`{"min", "every"}` when the newest health line is older than 3× `shipfloor_config.dispatcher_every`, else `None`; no log, no line or unparsable timestamp → `None`). `alerts(home, skip_silence=False)` uses it for the existing "no dispatcher cycle for N min (it runs every E)" line (format unchanged; threshold 1.5× → 3×) and omits that line when `skip_silence=True`.
- `scripts/dashboard.py` — overview (near the `"alerts": shipfloor_health.alerts(self.home)` line): build `alerts` with `skip_silence=True`; new field `"silent": {"min", "every", "check", "reinstall"} | None`, with the platform commands from the spec (Linux/macOS `install-dispatcher.sh --status` / `install-dispatcher.sh`; Windows `Get-ScheduledTask -TaskName ShipfloorDispatcher` / `powershell -File .../install-dispatcher.ps1`).
- `scripts/dashboard.html` — `renderFlags`: when `o.silent`, a `bad` alert with keys `alert.silent` / `alert.silent.text` (params `m`, `every`, `check`, `reinstall`), first among the alerts.
- `scripts/lang/dashboard.*.json` (12 files) — `alert.silent` and `alert.silent.text` in every language.
- `scripts/test/health.test.sh` — existing missed-cycle cases that assume 1.5× move to 3× (only where QA did not already).

Single task: the four parts share one contract (`silence`) and are small; splitting them would only add rounds.

## Order
1. QA writes failing acceptance tests (AC-1..AC-5).
2. Task 1.
3. `green factory scripts/test/health.test.sh`, `green factory scripts/test/dashboard-silent.test.sh`.
