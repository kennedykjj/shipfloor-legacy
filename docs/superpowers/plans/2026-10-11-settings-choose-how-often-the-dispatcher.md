# Settings: choose how often the dispatcher looks for work — plan

**Issue:** #32 · **Spec:** `docs/superpowers/specs/2026-10-11-settings-choose-how-often-the-dispatcher-design.md`
**Layers:** `factory` (path `./`, agent `engineer`). No migration, no new dependency.

Acceptance tests (written by QA before any task): `scripts/test/dashboard-dispatcher.test.sh` (new; AC-1, 2, 3, 4, 6, 8), `scripts/test/machine.test.sh` (AC-5), `scripts/test/health.test.sh` (AC-7).

No test may touch the real `ShipfloorDispatcher` task: the scheduler is always the `SHIPFLOOR_SCHEDULER` stub, and the installer runs only with `-DryRun`, only where `powershell` exists.

## Task 1 — the setting, the installer and the missed-cycle alert

- **Layer:** factory · **Owner:** engineer · **Depends on:** nothing
- **Files:** `scripts/shipfloor_config.py`, `installer/install-dispatcher.ps1`, `scripts/shipfloor_health.py`
- **ACs:** AC-5, AC-7; the installer half of AC-1 and AC-3
- `shipfloor_config.py`: `DISPATCHER_EVERY = (1, 3, 5, 10)`; `MACHINE_DEFAULTS["dispatcher"] = {"every_min": 3}`; `machine_problems` reports `dispatcher must be a mapping {every_min}` and `dispatcher.every_min must be 1, 3, 5 or 10` (a bool or a string is refused too). `machine values dispatcher.every_min` prints it; `machine set` does not take it.
- `install-dispatcher.ps1`: parameter `-EveryMin` (1, 3, 5 or 10) feeds `RepetitionInterval` and the closing message; without it the value comes from the installed `shipfloor-config.sh machine values dispatcher.every_min`, 3 when there is no config. Switch `-DryRun` prints `ShipfloorDispatcher: every <n> minutes` and registers nothing. Still only `Register-ScheduledTask -Force`: no stop, no kill.
- `shipfloor_health.py`: `alerts(home)` adds `no dispatcher cycle for <n> min (it runs every <m>)` when the newest health line is older than 1.5 × `dispatcher.every_min` from `config.yml`; nothing when there is no health line.

## Task 2 — the dashboard server

- **Layer:** factory · **Owner:** engineer · **Depends on:** Task 1
- **Files:** `scripts/dashboard.py`
- **ACs:** the API half of AC-1, AC-2, AC-3, AC-4, AC-6, AC-8
- `scheduler()`: the command that sets the pace, or `None` with the reason. `SHIPFLOOR_SCHEDULER` set to a command → that command; `none` → no scheduler; unset on Windows → `powershell -NoProfile -ExecutionPolicy Bypass -File <source>/installer/install-dispatcher.ps1 -EveryMin` (`<source>` from the installed copy's `.source`, else the checkout the script runs from); unset elsewhere → no scheduler. The minutes go as the last argument, as an argv list, never through a shell.
- `settings()`: adds `dispatcher: {every_min, choices, can_set, why}` and `cycle.next_at` (last cycle's start, `at - took_s`, plus `every_min`; null with no cycle).
- `set_machine(changes)`: accepts `dispatcher: {every_min}`. Build the new config, `machine_problems`, then, only when `every_min` changed, run the scheduler (timeout 60 s). Exit 0 → write `config.yml`. Anything else → `409 {"error": "<the scheduler's last output line>"}` and nothing written, the other limits of the same request included. No scheduler → `409` with the `why`.
- `POST /api/settings/machine`: same route and token rule; `409` is new.

## Task 3 — the Settings view, the catalog and the README

- **Layer:** factory · **Owner:** engineer · **Depends on:** Task 2
- **Files:** `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `README.md`
- **ACs:** the page half of AC-1, AC-2, AC-4, AC-6, AC-8
- `renderSettings`: the "Looks for work every" `<label class="sfl">` with a native `<select>` (1, 3, 5, 10 minutes) between `.who` and the pause; the pick is the draft `every_min` (select text in `--sand`, counted by the save bar, cleared when the saved value is picked again), sent by the existing Save as `dispatcher: {every_min}` in the machine request.
- On `409` the page wraps the server's reason in the UX failure sentence and keeps the draft.
- "Next cycle" in `.who p` from `cycle.next_at`: `next cycle in N min` (rounded up, never below 1), `next cycle overdue`, and from one full minute late `next cycle overdue by N min` in `--warn`. None when paused, with no cycle, or with no scheduled task.
- Disabled (`can_set` false): `disabled` select on the configured value inside `.sknob`, the reason in its `<small>`; one added rule `select:disabled`. A disabled select makes no draft.
- A refresh while the select is focused updates only the status text; it does not rewrite the select.
- `dashboard.pt-BR.json`: the entries from the spec's copy list, the machine problem included.
- `README.md`: "every 3 minutes" becomes the default, with where to change it.
