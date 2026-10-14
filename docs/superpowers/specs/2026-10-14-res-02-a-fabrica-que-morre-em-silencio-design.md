# [RES-02] The factory that dies silently: the dashboard and the doctor shout when the dispatcher stops — spec

**Issue:** #176 · **Branch:** `feat/176-res-02-a-fabrica-que-morre-em-silencio` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** Every alert depends on a cycle running: the health JSONL is written by the cycle itself and the doctor speaks only when the owner runs it. If the scheduler dies (task disabled, reboot, WSL stopped, sleeping laptop) the factory goes quiet and looks healthy.
**Audience:** The owner, watching the dashboard or running `shipfloor doctor`.
**Acceptance criteria**
- **AC-1** — Given the newest health line is older than 3× the dispatcher pace, when the dashboard loads, then a banner on the first screen says the last cycle was N min ago and asks whether the dispatcher stopped, with the platform's status check command and the reinstall command.
- **AC-2** — Given that same stale state, when the owner runs `shipfloor doctor`, then it prints a `WARN health:` line with the age in minutes and the pace.
- **AC-3** — Given the newest health line is within 3× the pace, or there is no health line yet, when the dashboard loads or the doctor runs, then no such banner or WARN appears.
- **AC-4** — Given the banner text, when the dashboard language is any of the 12 shipped languages, then its message keys exist in every language file.
- **AC-5** — Given `dispatcher.every_min` in `config.yml`, when the threshold is computed, then it uses that pace, and falls back to the 3 min default when the key is missing or invalid.
**Out of scope:** An external watchdog (a second scheduler watching the first). If it proves necessary it becomes its own issue.
**Product fit:** Serves principle 3 (numbers are exact and sourced): the age shown comes from the newest health log line, not a guess, and a silent factory stops passing for a healthy one. It also serves principle 4: the owner is asked to act only when the dispatcher has stopped. It fits the positioning and the local-only constraint (no remote watchdog, nothing leaves the machine).
**Touches UI:** yes

## UX
_UX/UI Designer_ — n/a (reuses the existing alerts line at the top of the dashboard: a `bad` alert, no new component or style.)

## Architecture
_Tech Lead_

Already there: `shipfloor_health.alerts()` (`scripts/shipfloor_health.py`) raises "no dispatcher cycle for N min (it runs every E)" at 1.5× the pace, the doctor prints it as `WARN health:` (`scripts/shipfloor_core/cli.py`), and the dashboard shows it as a generic "Health" warn. This card tightens it to 3× and gives the dashboard a dedicated banner.

- **Contract `shipfloor_health.silence(home) -> dict | None`** (new, public): `{"min": <minutes since newest health line>, "every": <pace>}` when `min > 3 * every`, else `None` (no log, no line, or unparsable timestamp → `None`). `alerts(home, skip_silence=False)` uses it for the existing text, unchanged in format, and omits that line when `skip_silence=True`. Pace from `shipfloor_config.dispatcher_every` (already falls back to 3).
- **Contract dashboard overview** (`scripts/dashboard.py`, near line 1094): new field `"silent": {"min", "every", "check", "reinstall"} | None`. `alerts` is built with `skip_silence=True` so the line is not shown twice. `check` and `reinstall` are platform strings: `bash <plugin>/installer/install-dispatcher.sh --status` / `bash <plugin>/installer/install-dispatcher.sh` on Linux and macOS; on Windows `Get-ScheduledTask -TaskName ShipfloorDispatcher` / `powershell -File <plugin>/installer/install-dispatcher.ps1` (the `.ps1` has no status switch; the task name is the one `dashboard.py` already uses).
- **UI** (`scripts/dashboard.html`, `renderFlags`): when `o.silent`, a `bad` alert with keys `alert.silent` and `alert.silent.text` (params `m`, `every`, `check`, `reinstall`), placed first among the alerts so it is on the first screen.
- **i18n:** `alert.silent` and `alert.silent.text` added to all 12 `scripts/lang/dashboard.*.json` (en, pt-BR, de, es, fr, it, ja, ko, ru, tr, zh-CN, zh-TW).
- **Files changed:** `scripts/shipfloor_health.py`, `scripts/dashboard.py`, `scripts/dashboard.html`, 12 lang files, `scripts/test/health.test.sh` (threshold 1.5× → 3×: the missed-cycle cases move to 3× the pace), new `scripts/test/dashboard-silent.test.sh`. All belong to layer `factory`.
- **Migration:** none; read-only over existing logs. **Rollback:** n/a, revert the commit.
- The card says it comes after the PY migration block (#153 forbids new behavior during it); develop should not start before that block lands.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-silent.test.sh` |
| AC-2 | factory | `scripts/test/health.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-silent.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-silent.test.sh` |
| AC-5 | factory | `scripts/test/health.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
- Threshold is 3× the pace as the issue says, replacing the existing 1.5×: one missed or slow cycle (a long run) should not shout "stopped".
- No new `doctor` code: it already prints every alert as `WARN health:`, so only the health module changes.
- The dashboard banner is a dedicated alert (not the generic "Health" one) so it can carry the commands; the generic line is suppressed for it to avoid duplication.
- Windows check command is `Get-ScheduledTask`, because `install-dispatcher.ps1` has no `--status`; adding one is out of scope.
- The age comes from the newest health line, which the dashboard already reads via the alerts path; no new state is stored.

## Open questions
- none
