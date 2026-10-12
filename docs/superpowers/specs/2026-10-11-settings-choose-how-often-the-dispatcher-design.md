# Settings: choose how often the dispatcher looks for work — spec

**Issue:** #32 · **Branch:** `feat/32-settings-choose-how-often-the-dispatcher` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The dispatcher's pace (every 3 minutes) is fixed by the installer; changing it means editing the `ShipfloorDispatcher` task by hand in Windows Task Scheduler, and the Settings view shows the last cycle but neither the pace nor when the next one comes.
**Audience:** The factory's owner, running Shipfloor on their own Windows machine.
**Acceptance criteria**
- **AC-1** — Given the interval is 3 minutes, when the owner picks 5 in "Looks for work every" on the Settings dispatcher bar and saves, then the `ShipfloorDispatcher` task repeats every 5 minutes, `~/.shipfloor/config.yml` holds `dispatcher.every_min: 5` and the bar shows 5 after a reload.
- **AC-2** — Given `config.yml` has no `dispatcher.every_min`, when the owner opens Settings, then the control shows 3 minutes and offers exactly 1, 3, 5 and 10.
- **AC-3** — Given a cycle is running, when the owner saves a new interval, then that cycle finishes untouched and the following cycles start on the new interval.
- **AC-4** — Given re-registering the task fails (for example, no permission), when the owner saves, then Settings shows the reason, `config.yml` keeps the old value and the task keeps its old interval.
- **AC-5** — Given a hand-edited `config.yml` with `dispatcher.every_min` other than 1, 3, 5 or 10, when the config is validated, then it is reported as a machine problem like the others, naming the key and the allowed values.
- **AC-6** — Given a last cycle and an interval, when the owner views the dispatcher bar, then it shows "next cycle in N min" computed from both, and says the cycle is overdue instead of a zero or negative number once that time has passed.
- **AC-7** — Given the interval is 10 minutes, when cycles arrive on time every 10 minutes, then the health history raises no missed-cycle alert; given one is skipped, then it does.
- **AC-8** — Given a machine without the Windows scheduled task (macOS or Linux), when the owner opens Settings, then the control is shown disabled with the reason and saving changes neither `config.yml` nor any schedule.
**Out of scope:** Scheduling on Linux and macOS (cron, launchd); triggering a cycle on demand from the dashboard; free-form intervals beyond the four values; a per-project interval; pausing the dispatcher.
**Product fit:** Serves principle 3 (numbers are exact and sourced): the pace and the "next cycle" time come from the registered task's setting and the last recorded cycle, and a failed save never leaves the screen showing a pace the machine does not run. Stays inside the positioning: it is a machine setting, not card state (principle 1), and the dashboard remains local only. Mild tension with principle 4 (the owner acts only where the factory waits for the owner): this is an optional tuning control, so it lives in Settings and never asks for attention on the board.
**Touches UI:** yes

## UX
_UX/UI Designer_

Screen: the dispatcher bar (`#disp`, `renderSettings` in `scripts/dashboard.html`). Languages: English in the page, pt-BR in `scripts/lang/dashboard.pt-BR.json`. No new component.

- **Control.** A second `<label class="sfl">` in `.disp`, between `.who` and "Pause the factory": the text "Looks for work every" and a native `<select>` (the global `select` rule) with exactly `1 minute`, `3 minutes`, `5 minutes`, `10 minutes`; no stored value shows `3 minutes`. The label names the select; no extra `aria-label`.
- **Saving.** A pick is a draft like a stepper's (`SET.draft.every_min`): the select's text turns `--sand` (as `.stp.dirty output`), the existing save bar counts it ("1 change not saved.") and Save / Discard apply or drop it. Picking the saved value again clears the draft. It is not instant like the pause: re-registering a task is not urgent and can fail. The bar's hint stays as is.
- **Success.** The bar closes, the select shows the new value in normal text, and "next cycle" is recomputed from the new interval. No toast.
- **Failure (AC-4).** The save bar stays with the existing `.bad` line; the draft is kept (select still `--sand` on the picked value) so Save retries and Discard returns to the running pace. "Next cycle" keeps using the saved interval. The reason is the system's own text, never translated.
- **Next cycle (AC-6).** Appended to the existing status line in `.who p`, same muted text: `Running · last cycle 2m ago, it took 4s · next cycle in 2 min`. N is the minutes left until last cycle + saved interval, rounded up, never below 1. Recomputed on every refresh; the tick must not close the select while it is open or focused.
- **Overdue.** Once that time has passed the same slot reads `next cycle overdue`, still muted; from one full minute late it reads `next cycle overdue by N min` in `--warn` (only that phrase, not the line). No azure: nothing waits for the owner here; the health history carries the alert (AC-7).
- **No "next cycle"** when the factory is paused, when no cycle is recorded yet ("No cycle recorded yet." unchanged), or when the machine has no scheduled task: a pace the machine does not run is never shown as a forecast.
- **Disabled (AC-8).** Without the `ShipfloorDispatcher` task the select is `disabled` on the configured value (3 by default) and wrapped in the existing `.sknob`, whose `<small>` carries the reason, always visible (not only a `title`), `max-width: 34ch`. One added rule, `select:disabled`, mirrors `.btn:disabled`: `--faint` text, `--edge` border, `cursor: not-allowed`. A disabled select makes no draft, so the save bar never opens for it.
- **Loading / empty.** None of its own: the bar renders once `/api/settings` answers, as today.
- **Small screens.** `.disp` already wraps (`flex-wrap`, gap `12px 26px`): the new label drops under the status line, before the pause; in a wrapped row the `.sknob` reason aligns left. No new breakpoint.
- **Copy, en → pt-BR** (catalog entries; `exact` unless a number or reason varies, then `rx`):
  - `Looks for work every` → `Procura trabalho a cada`
  - `1 minute` / `3 minutes` / `5 minutes` / `10 minutes` → `1 minuto` / `3 minutos` / `5 minutos` / `10 minutos`
  - `· next cycle in N min` → `· próximo ciclo em N min`
  - `· next cycle overdue` → `· próximo ciclo atrasado`; `· next cycle overdue by N min` → `· próximo ciclo atrasado há N min`
  - `The pace was not changed: <reason>. The dispatcher still looks for work every N min.` → `O ritmo não mudou: <reason>. O dispatcher continua procurando trabalho a cada N min.`
  - `Windows only: this machine has no ShipfloorDispatcher scheduled task. Its pace is set by whatever schedules the dispatcher here.` → `Só no Windows: esta máquina não tem a tarefa agendada ShipfloorDispatcher. O ritmo é definido por quem agenda o dispatcher aqui.`
- **Machine problem (AC-5)**, in the validator's existing sentence shape (`pool must be an integer >= 1`): `dispatcher.every_min must be 1, 3, 5 or 10` → `dispatcher.every_min deve ser 1, 3, 5 ou 10`.

## Architecture
_Tech Lead_

One layer, `factory`. No migration, no new dependency.

**Contracts**
- `~/.shipfloor/config.yml`: new key `dispatcher.every_min`, one of 1, 3, 5, 10; missing means 3.
- `scripts/shipfloor_config.py`: `DISPATCHER_EVERY = (1, 3, 5, 10)`; `MACHINE_DEFAULTS["dispatcher"] = {"every_min": 3}`; `machine_problems` reports `dispatcher must be a mapping {every_min}` and `dispatcher.every_min must be 1, 3, 5 or 10` (a bool or a string is refused too). `machine values dispatcher.every_min` prints it like any other key; `machine set` does not take it (a value written without the task would lie).
- `installer/install-dispatcher.ps1`: new parameter `-EveryMin <1|3|5|10>`, used for the trigger's `RepetitionInterval` and the closing message. Without it the installer reads `dispatcher.every_min` from `config.yml` through the installed `shipfloor-config.sh machine values`, so running it again by hand keeps the owner's pace; 3 when there is no config. New switch `-DryRun`: prints `ShipfloorDispatcher: every <n> minutes` and registers nothing. It still only registers the task (`Register-ScheduledTask -Force`): it stops no running task and kills no process.
- `scripts/dashboard.py`
  - `scheduler()`: the command that sets the pace, or `None` with the reason. `SHIPFLOOR_SCHEDULER` set to a command: that command (tests); set to `none`: no scheduler; unset on Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File <source>/installer/install-dispatcher.ps1 -EveryMin`, where `<source>` is the installed copy's `.source` (as `shipfloor install` prints) or the checkout the script runs from; unset elsewhere: no scheduler. The minutes are appended as the last argument; never through a shell.
  - `settings()` adds `dispatcher: {every_min, choices: [1, 3, 5, 10], can_set, why}` (`why` is the reason when `can_set` is false, else null) and `cycle.next_at` (ISO time: the last cycle's start, `at - took_s`, plus `every_min`; null with no cycle).
  - `set_machine(changes)` accepts `dispatcher: {every_min}`. Order: build the new config, `machine_problems`, then, only when `every_min` differs from the current one, run the scheduler (timeout 60 s); exit 0 → write `config.yml`; anything else → `409 {"error": "<the scheduler's last output line>"}` and nothing written. No scheduler → `409` with the `why`. The other limits in the same request are not saved either: one save, one outcome.
  - `POST /api/settings/machine`: same route, same token rule; `409` is new.
- `scripts/shipfloor_health.py`: `alerts(home)` gains one line, `no dispatcher cycle for <n> min (it runs every <m>)`, when the newest health line is older than 1.5 × `dispatcher.every_min` (read from `config.yml`). Not raised when there is no health line yet. Paused cycles still write their line, so a pause raises nothing.
- `scripts/dashboard.html` (`renderSettings`, the save path): the control and the "next cycle" text from the UX section, fed by `dispatcher` and `cycle.next_at`; the choice is the draft `every_min`, sent by the existing Save bar as `dispatcher: {every_min}` in the same machine request. On `409` the page wraps the server's reason in the UX failure sentence. A refresh while the select is focused updates only the status text in `.who p`; it does not rewrite the select.
- `scripts/lang/dashboard.pt-BR.json`: the catalog entries from the UX copy list.
- `README.md`: "every 3 minutes" becomes the default, with where to change it.

**Files:** `scripts/shipfloor_config.py`, `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `scripts/shipfloor_health.py`, `installer/install-dispatcher.ps1`, `README.md`, and the tests below. All owned by `factory`.

**Tests never touch the real task:** every test sets `SHIPFLOOR_SCHEDULER` to a stub that records its arguments (or fails on purpose); the installer is run only with `-DryRun`, and only where `powershell` exists.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-dispatcher.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-dispatcher.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-dispatcher.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-dispatcher.test.sh` |
| AC-5 | factory | `scripts/test/machine.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-dispatcher.test.sh` |
| AC-7 | factory | `scripts/test/health.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-dispatcher.test.sh` |

What each proves: AC-1 the stub receives `5`, `config.yml` holds 5, `/api/settings` answers 5, and `-DryRun -EveryMin 5` prints 5 minutes; AC-3 a live `dispatch.pid` and its process survive the save and the installer has no stop or kill; AC-4 a failing stub gives `409` with its reason and `config.yml` is byte-identical; AC-6 `cycle.next_at` from a written health line, and the page carries both the "next cycle in" and the overdue wording; AC-8 with `SHIPFLOOR_SCHEDULER=none`, `can_set` is false with a reason and a save answers `409`.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The four values 1, 3, 5 and 10 are the whole set, in the file and on screen: the issue names them, and one list (`DISPATCHER_EVERY`) feeds the validator, the API and the select.
- The task is registered before `config.yml` is written: a failed registration then leaves both on the old pace (AC-4) with nothing to undo.
- A failed pace change saves none of the other limits in the same request: one Save has one outcome, and the draft stays for a retry.
- The dashboard finds the installer through the installed copy's `.source`: `shipfloor install` does not copy `installer/`, and the issue wants one place to know the task.
- The installer run by hand without `-EveryMin` uses the value in `config.yml`: otherwise a reinstall would silently go back to 3 while Settings shows the owner's choice.
- `machine set` does not take `dispatcher.every_min`: the CLI would write the value without touching the task.
- The health history has no missed-cycle alert today (only idle slots, over the limit and overlap), so AC-7 adds one instead of changing a threshold; it reads the pace from `config.yml`.
- The alert looks only at the time since the newest cycle, at 1.5 × the pace: gaps between older lines would raise it after every sleep or logoff, when the task rightly does not run.
- "Next cycle" counts from the last cycle's start (`at - took_s`), since the health line is written when a cycle ends.
- A new pace starts about one minute after the save: re-registering replaces the trigger, which starts at now + 1 minute. The running cycle is a detached process the task no longer owns, so it finishes (AC-3).
- At 1 minute a cycle longer than the pace overlaps the next one; the existing "two dispatcher cycles ran at once" alert already says so. No new guard.
- The task's 5-minute execution limit stays: it bounds one launch, not the pace.
- Tests replace the scheduler with a stub (`SHIPFLOOR_SCHEDULER`) and run the installer only with `-DryRun`: a test run must never change the owner's real scheduled task.
- A machine without the task gets `409` on save, not a silent success (AC-8): the page disables the control, and the API must not disagree with it.
- macOS, Linux, on-demand cycles, free intervals, per-project pace and pausing stay out, as the Product section says.

## Open questions
- none
