# Working hours: outside them the dispatcher starts nothing — plan for #33

**Goal:** a machine setting `hours` in `~/.shipfloor/config.yml`; outside its windows the dispatcher does everything except start a run, the health history raises no "nothing moved" alert for that stretch, and the dashboard says when runs start again and edits the windows in Settings.

**Spec:** `docs/superpowers/specs/2026-10-11-working-hours-outside-them-the-dispatche-design.md`

**Layers:** `factory` only (path `./`, agent `engineer`, Bash and Python 3).

## Constraints

- One reader of the clock: `shipfloor_config.now()` (local time, or `SHIPFLOOR_NOW=HH:MM`). The dispatcher, the health record and the dashboard never call `date` or `datetime.now()` themselves for this.
- One judge of the windows: `hours_problems` and `hours_state` in `scripts/shipfloor_config.py`. The dispatcher asks through `machine hours`; the page sends what was typed and the server decides.
- A malformed `hours` never stops the dispatcher: it stays out of `machine_problems`, `machine validate` exits 0 when it is the only problem, and `machine values` keeps working.
- `hours` unset behaves exactly as today (AC-8): no log line, no message, no new field that changes an alert.
- The manual pause is untouched and wins over the working-hours message on both surfaces.
- `scripts/shipfloor-dispatch.sh` does not change.
- The existing tests keep passing unchanged, apart from the acceptance tests Task 0 adds to them.
- Minimal change: no new config key besides `hours`, no CLI subcommand on `shipfloor`, no dead code, no narrating comments.

## Tasks

### Task 0 — Acceptance tests (QA, before any implementation)

- **Owner:** `qa-engineer`
- **Files:** adds cases to `scripts/test/dispatch.test.sh` (AC-1, AC-2, AC-3, AC-8, and the AC-5 case that a run still starts with a malformed `hours`), `scripts/test/machine.test.sh` (AC-5), `scripts/test/health.test.sh` (AC-6) and `scripts/test/dashboard.test.sh` (AC-4, AC-7).
- Every case sets the clock with `SHIPFLOOR_NOW`; none depends on the real time.
- AC-1 also checks that the board snapshot is refreshed, a finished run is reaped and a running session is left alone while nothing starts.
- AC-4 and AC-7 are tested at the API (`hours` in `GET /api/overview` and `GET /api/settings`, `POST /api/settings/machine` setting, clearing and refusing it, the other keys of `config.yml` kept) and on the strings in `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json`.
- Must fail on the current code with a message that names the missing behavior.

### Task 1 — The setting and its clock in `scripts/shipfloor_config.py`

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 0
- **Files:** changes `scripts/shipfloor_config.py`, `README.md`
- `now()`: local `HH:MM`, or `SHIPFLOOR_NOW` when set.
- `hours_problems(raw) -> [str]`: every line starts with `hours`. A list of strings `HH:MM-HH:MM`, 24-hour, `00:00` to `23:59`; start equal to end is malformed; missing or `[]` is fine.
- `hours_state(raw, now) -> {"windows", "open", "next", "error"}`: a window includes its start and excludes its end; an end before its start crosses midnight. Unset or malformed gives `open: true, next: None`; outside every window `next` is the nearest coming start. When malformed, `windows` holds the value as written, as text.
- CLI `machine hours`: prints `open` or `closed HH:MM`, always exit 0.
- CLI `machine validate`: also prints `<path>: hours ...; ignored, runs start at all hours` on stderr; exit 0 when `hours` is the only problem.
- `README.md`: `hours` beside the other `config.yml` keys.
- **Done when:** the AC-5 cases in `scripts/test/machine.test.sh` pass.

### Task 2 — The dispatcher holds the pipelines, the health line records it

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 1
- **Files:** changes `scripts/dispatch.sh`, `scripts/shipfloor_health.py`, `scripts/lang/pt-BR.sed`
- `scripts/dispatch.sh`: after the board snapshot is written, read `shipfloor_machine hours`. When closed, log `dispatch: outside working hours; runs start again at HH:MM` through `shipfloor_say` and skip the four `run_pipeline` calls. `retry_infra`, lock reaping, `refresh_staged` and the tmp sweep run as on any cycle. Not beside `PAUSE`, which exits before the board is read.
- `scripts/shipfloor_health.py`: `snapshot` adds `"outside_hours": bool` and counts it in `stopped`, so no `idle` key is recorded outside the windows. Older lines without the field read as `false`.
- `scripts/lang/pt-BR.sed`: the new dispatcher line.
- **Done when:** the AC-1, AC-2, AC-3, AC-5 and AC-8 cases in `scripts/test/dispatch.test.sh` and the AC-6 cases in `scripts/test/health.test.sh` pass.

### Task 3 — The dashboard says it and edits it

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 1
- **Files:** changes `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`
- `scripts/dashboard.py`: `GET /api/overview` and `GET /api/settings` gain `hours` (the `hours_state` object). `POST /api/settings/machine` accepts `hours`: a list of strings sets it, `null` or `[]` removes the key; `hours_problems` on the new config returns 400 `{"error": ...}` and writes nothing; the other keys keep their values.
- `scripts/dashboard.html`: the alerts line and the Settings dispatcher bar exactly as in the spec's `## UX` (the warn alert after "Usage limit hit", the status sentence and warn dot, pause wins, the `Working hours` field with draft, Save/Discard, Enter to save, the invalid state, the malformed-in-file sentence, value, focus and caret kept across the 10 s rewrite, the small-screen row).
- `scripts/lang/dashboard.pt-BR.json`: the seven strings of the spec's copy list, the `starts again at` one as `rx`.
- **Done when:** the AC-4 and AC-7 cases in `scripts/test/dashboard.test.sh` pass and the whole build (`TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main`) is green.

## Review focus

- `hours` unset: no log line from the dispatcher, no `hours` message on the page, `outside_hours` false.
- The half-open bounds: 08:00 opens `08:00-23:00`, 23:00 closes it; `20:00-04:00` is open at 02:00 and at 20:00, closed at 04:00.
- `next` with several windows is the nearest coming start, not the first in the list.
- A malformed `hours` never reaches exit 1 or 2 in `machine validate`, `machine values` or the dispatcher.
- The save writes nothing on refusal and removes the key on `null` or `[]`.
- Outside the windows nothing running is touched: only the four `run_pipeline` calls are skipped.
