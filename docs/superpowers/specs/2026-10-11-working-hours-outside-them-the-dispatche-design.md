# Working hours: outside them the dispatcher starts nothing — spec

**Issue:** #33 · **Branch:** `feat/33-working-hours-outside-them-the-dispatche` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The factory starts runs around the clock; overnight it spends the owner's usage limit on cards nobody is there to approve, and the morning starts with the limit already hit.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine.
**Acceptance criteria** (times are the machine's local time; a window includes its start and excludes its end)
- **AC-1** — Given `hours: ["08:00-23:00"]` in `~/.shipfloor/config.yml` and the time is 23:30, when the dispatcher cycles, then no new run starts on any project, sessions already running are left alone, and the board refresh, the reaping of finished runs and the health line still happen.
- **AC-2** — Given the same hours and the time is 08:00, when the dispatcher cycles, then runs start as usual.
- **AC-3** — Given a window that crosses midnight (`20:00-04:00`) and the time is 02:00, when the dispatcher cycles, then runs start.
- **AC-4** — Given the factory is outside working hours, when the owner opens the dashboard, then the alerts line and the Settings view's dispatcher bar both say "Outside working hours: starts again at HH:MM", HH:MM being the start of the next window.
- **AC-5** — Given `hours` is malformed in `config.yml`, when the config is validated, then the error is reported naming `hours`, and the dispatcher keeps starting runs as "always" instead of stopping.
- **AC-6** — Given a stretch outside working hours in which no run started, when the health history is evaluated, then no "nothing moved" alert is raised for that stretch.
- **AC-7** — Given the Settings view, when the owner sets, changes or clears the window in the dispatcher bar and saves, then `hours` in `~/.shipfloor/config.yml` holds exactly that (cleared removes it), the rest of the file is unchanged, the dispatcher follows it from its next cycle, and a malformed value is refused with an error and not saved.
- **AC-8** — Given `hours` is unset, when the dispatcher cycles at any time, then runs start as today and the dashboard shows no working-hours message.
**Out of scope:** Stopping a session already running when the window closes; per-project hours; different windows per weekday; time zones other than the machine's; a CLI command to set the hours (edit `config.yml` or use Settings); any change to how the manual pause works (a paused factory stays paused inside the window).
**Product fit:** Serves principle 4, "The owner acts only where the factory waits for the owner": runs are held to the hours the owner is there to approve them, and the measured cost is not spent unattended. The exact "starts again at" time follows principle 3. The setting lives in the machine's config, not on the board, so principle 1 holds. No conflict with the positioning or the constraints.
**Touches UI:** yes

## UX
_UX/UI Designer_

Against this worktree: the Settings view and its dispatcher bar (`#disp`, `.disp`) and the alerts line (`#alerts`, `renderFlags`) are both in `scripts/dashboard.html`; nothing waits on another branch. No new component: one text input, existing classes and tokens.

- **Alerts line (outside the window):** one more `add("warn", ...)` span in `renderFlags`, after "Usage limit hit": bold `Outside working hours:` then `starts again at 08:00` (24h, zero-padded, machine time). Warn, not bad: it is the owner's own setting. It reads out through the line's existing `role="status"`.
- **Dispatcher bar, status sentence (`.who p`):** outside the window it reads `Outside working hours: starts again at 08:00` in place of "Running · last cycle ...", and the dot turns warn (`.disp.idle .sdot { background: var(--warn) }`; the bar's border stays `edge-hi`). Inside the window: today's sentence, unchanged.
- **Pause wins:** while the factory is paused, both surfaces keep only the pause message; "starts again at" would be false, since a paused factory stays paused inside the window.
- **The control:** in the bar, between `.who` and "Pause the factory": `<label class="sfl">Working hours <input type="text" ...></label>`. The input takes the page's `textarea` look (`--ground` well, 1px `--edge`, 5px radius, 7px 9px), `--mono`, about 26ch wide, `placeholder="always"`, `spellcheck="false"`, `autocomplete="off"`, and a `title` with the helper text. Value: the windows joined by `, ` (`08:00-23:00, 20:00-04:00`).
- **Unset (AC-8):** empty field showing the placeholder; no message, no dot change, no alert.
- **Editing and saving:** typing sets `SET.draft.hours` (dropped when it equals the saved value), the text turns `--sand` like `.stp.dirty`, and the existing save bar counts it ("1 change not saved."). Save sends it with the machine settings; Discard restores it. An empty field saved clears `hours`. Enter in the field saves; no Save button of its own. While the request runs, Save and Discard are disabled (existing disabled style).
- **Invalid input:** the server decides. On refusal the save bar shows the error in its `.bad` span (already `role="status"`), the field keeps what was typed, gets `aria-invalid="true"` and a `--bad` border, and the draft stays; typing again clears both. Any other failure keeps "The settings were not saved."
- **Malformed in `config.yml` (AC-5):** the field shows the raw value with `aria-invalid="true"`, and the status sentence gains a second sentence in `--warn` saying so; no "Outside working hours" message, since the dispatcher runs as always.
- **Refresh:** the bar is rewritten every 10 s (its "last cycle" clock), so the field must keep its typed text, focus and caret across the rewrite: render its value from the draft and restore focus and selection, as the fold button already does.
- **Keyboard and screen reader:** tab order is the field, then the pause switch. The label names the field; the helper is its `aria-describedby` (a visually hidden span, same text as the `title`). Esc does nothing in the field (existing `typing` guard). The status sentence is not a live region: the alerts line announces the change.
- **Small screen:** `.disp` already wraps; under 1180px the label and field take their own row under the sentence and the field is `width: 100%` with `max-width: 26ch`. The alert wraps as the other alerts do.
- **Copy** (en, then pt-BR for `scripts/lang/dashboard.pt-BR.json`; `exact` unless marked):
  - `Outside working hours:` / `Fora do horário de trabalho:`
  - `rx` `starts again at (\d\d:\d\d)` / `volta a iniciar às $1` (covers the alert and the bar)
  - `Working hours` / `Horário de trabalho`
  - `always` / `sempre`
  - `Windows like 08:00-23:00, separated by commas. Empty means always.` / `Janelas como 08:00-23:00, separadas por vírgula. Vazio significa sempre.`
  - `Working hours not saved: write each window as HH:MM-HH:MM, separated by commas.` / `Horário de trabalho não salvo: escreva cada janela como HH:MM-HH:MM, separadas por vírgula.`
  - `The hours in config.yml are not valid, so the dispatcher runs at all hours.` / `O horário em config.yml não é válido, então o dispatcher roda a qualquer hora.`

## Architecture
_Tech Lead_

**The setting.** `hours` in `~/.shipfloor/config.yml`: a list of strings `"HH:MM-HH:MM"` (24-hour, `00:00` to `23:59`, machine local time). A window includes its start and excludes its end; an end before its start crosses midnight; start equal to end is malformed. Missing or an empty list means always.

**Contracts touched** (all in layer `factory`)
- `scripts/shipfloor_config.py`
  - `hours_problems(raw) -> [str]`: what is wrong with `hours`, each line starting with `hours`. Kept out of `machine_problems`, so a bad `hours` never makes `machine values` unusable.
  - `hours_state(raw, now) -> {"windows": [str], "open": bool, "next": "HH:MM" | None, "error": str | None}`: unset or malformed gives `open: true, next: None`; outside every window `next` is the nearest coming window start. When malformed, `windows` holds the value as written (as text), for the field to show.
  - `now()`: the local time, or `SHIPFLOOR_NOW=HH:MM` when set (the tests' clock; the dispatcher, the health record and the dashboard all read the time here).
  - CLI `machine hours`: prints `open` or `closed HH:MM`, always exit 0.
  - CLI `machine validate`: also prints `<path>: hours ...; ignored, runs start at all hours` on stderr; a config whose only problem is `hours` still exits 0, so the dispatcher goes on.
- `scripts/dispatch.sh`: after the board snapshot is written, reads `shipfloor_machine hours`. When closed it logs one line (`dispatch: outside working hours; runs start again at HH:MM`, through `shipfloor_say`) and skips the four `run_pipeline` calls; `retry_infra`, lock reaping (`live_runs`), `refresh_staged` and the tmp sweep run as on any cycle. The check is not beside `PAUSE`: `PAUSE` exits before the board is read, and AC-1 keeps the board fresh.
- `scripts/shipfloor-dispatch.sh`: no change; it still calls `dispatch.sh` per project and records the health line on exit.
- `scripts/shipfloor_health.py`: `snapshot` adds `"outside_hours": bool` to the line and counts it in `stopped`, so no `idle` key is recorded outside the windows and `alerts` raises nothing for that stretch. Older lines without the field read as `false`.
- `scripts/dashboard.py`
  - `GET /api/overview` and `GET /api/settings` gain `hours`: the `hours_state` object.
  - `POST /api/settings/machine` accepts `hours`: a list of strings sets it, `null` or `[]` removes the key; `hours_problems` on the new config returns 400 `{"error": ...}` and writes nothing. Other keys of `config.yml` keep their values.
- `scripts/dashboard.html`: the alerts line and the Settings dispatcher bar, as in `## UX`; the page splits the field on commas and sends the list, and the server alone judges it.
- `scripts/lang/pt-BR.sed`, `scripts/lang/dashboard.pt-BR.json`: the new dispatcher line and dashboard strings.
- `README.md`: `hours` beside the other `config.yml` keys.

**Migration plan:** none. No stored data changes shape; the health line gains an optional field.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dispatch.test.sh` |
| AC-2 | factory | `scripts/test/dispatch.test.sh` |
| AC-3 | factory | `scripts/test/dispatch.test.sh` |
| AC-4 | factory | `scripts/test/dashboard.test.sh` |
| AC-5 | factory | `scripts/test/machine.test.sh` |
| AC-6 | factory | `scripts/test/health.test.sh` |
| AC-7 | factory | `scripts/test/dashboard.test.sh` |
| AC-8 | factory | `scripts/test/dispatch.test.sh` |

- Every test sets the clock with `SHIPFLOOR_NOW`; none depends on the real time.
- AC-4 and AC-7 are tested at the API (`hours` in the overview and settings, the save and its refusal) and on the strings in `dashboard.html`; how the bar looks is checked against `## UX` in validation.
- AC-5: `machine.test.sh` covers the report and the exit code, and one case in `scripts/test/dispatch.test.sh` shows a run still starts with a malformed `hours`.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- **Window bounds:** start included, end excluded, machine local time; the issue only fixed the start (AC-2), and half-open windows let two windows touch without overlap.
- **Empty list is "always":** `hours: []` reads as unset; a factory that never starts is what the pause is for.
- **Where the check sits:** in `dispatch.sh` after the board read, not beside `PAUSE` as the issue's note suggests; the `PAUSE` check exits before the board refresh that AC-1 keeps.
- **What still runs outside the hours:** the infra retry, lock reaping, the tmp sweep and `refresh_staged` (a script, not an agent session, and off by default); only the four pipelines are held, deploy included, since a deploy can call an agent.
- **A malformed `hours` does not fail `machine validate`:** it is printed as ignored and the exit stays 0 when it is the only problem; exit 1 would stop the dispatcher, against AC-5. The dashboard shows the same error.
- **Clock for tests:** one `SHIPFLOOR_NOW=HH:MM` override read in `shipfloor_config.now()`; three readers of the time must agree, and the tests cannot wait for 23:30.
- **"Rest of the file unchanged" (AC-7):** every other key keeps its value; the file is rewritten by the same writer the pool settings use, so hand-written comments are not kept, as today.
- **"Starts again at":** the nearest coming window start, as HH:MM with no date; windows repeat daily, so it is always within 24 hours.
- **Pause wins:** a paused factory shows the pause, not the working-hours message; the pause is the stronger stop and needs the owner to lift it.
- **The window is saved with the save bar, not at once:** it is typed text that can be wrong mid-way, unlike the pause switch; the existing draft and Save/Discard already handle that.
- **The alert is a warning, not an error:** being outside the hours is the owner's own setting, not a fault.
- **No CLI command for hours:** `shipfloor` gets no `hours` subcommand; the issue asks for the config key and the Settings control only.

## Open questions
- none
