# Notifications when the factory needs the owner — spec

**Issue:** #35 · **Branch:** `feat/35-notifications-when-the-factory-needs-the` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The factory stops for the owner (a spec to approve, a pull request to ship, a blocked run) or stops by itself, and only an open dashboard shows it; on 2026-10-11 specs waited about 1.5 hours and a blocked card more than 10.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine and checks the dashboard in quick visits.
**Acceptance criteria**
- **AC-1** — Given a card starts waiting for the owner (it enters Spec Review or Staged, or its run is blocked), when the next dispatcher cycle ends, then each enabled channel gets one notification with the project, the card's number and title and its state (the column, or for a block the stage it stopped in), and later cycles send no second one for that wait.
- **AC-2** — Given the reminder is set to 60 minutes and a card has waited for the owner for 60 minutes, when a cycle ends, then exactly one reminder is sent for that wait, not one per cycle.
- **AC-3** — Given the factory is stuck (the usage limit was hit, a project is skipped, or no card moved for an hour while cards sit in the factory's columns and nothing is paused), when a cycle ends, then one notification names the cause and the project, and none follows until that cause has cleared and come back.
- **AC-4** — Given "reached production" is on (it is off by default), when a card reaches Done, then one notification says so with its number and title.
- **AC-5** — Given quiet hours `23:00-08:00` (this machine's time) and a card starts waiting at 01:00, when cycles end before 08:00, then nothing is sent, and the first cycle after 08:00 sends one notification listing everything that still needs the owner.
- **AC-6** — Given an ntfy topic is set, when a notification is pushed, then it carries only the project, the card's number, title and state (no spec text, code, paths or tokens); with no topic set, nothing leaves the machine.
- **AC-7** — Given a channel fails (no network, toast unavailable), when the cycle ends, then it ends as it would have without notifications, the failure is one line in the dispatcher's log, and the other channel still delivers.
- **AC-8** — Given the dashboard's Settings view, when the owner opens "Notifications", then each event and each channel has its own on/off switch beside the ntfy topic, the reminder minutes and the quiet hours, a saved change applies from the next cycle, and with every event or every channel off nothing is sent.

**Out of scope:** E-mail, Slack, Telegram; acting on a notification (approving from the phone or the toast); desktop notifications on macOS and Linux (the phone push covers them); self-hosted or authenticated ntfy servers; per-project notification settings (they are this machine's); a "send a test notification" button; notifications for cards that do not wait for the owner (run started, stage finished, cost).
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner): it tells the owner when that moment comes, and "reached production" is the one event that asks nothing, so it is off by default. Principle 1 holds: what was already told is a delivery record, not card state. It does contradict the constraint "Local only (127.0.0.1); no remote or phone access": the ntfy push sends card numbers and titles to a third-party server and to a phone. The spec keeps it one-way, off until the owner sets a topic and limited to AC-6's fields; the dashboard itself stays local.
**Touches UI:** yes (a new "Notifications" section in the dashboard's Settings view)

## UX
_UX/UI Designer_

- **Where:** a fifth entry in `set-nav`, after Projects: "Notifications" with the sub line "when the factory needs you". The body follows the other sections: `h1.g`, `p.lead`, then three `.sgroup.panel` groups of `.srow` rows: **Events**, **Channels**, **Quiet hours**. No new component.
- **Controls:** events and channels use the existing `.sw` switch with a modifier whose checked track is `--sand` (the plain `.sw` turns `--bad`, which means "paused"; here on is the normal state). Reminder minutes use the `.stp` stepper, 15 to 720 by 15, default 60, so the page cannot produce an invalid value; the stepper dims (50%, as disabled buttons) while the reminder switch is off. The topic is one text `input` and quiet hours are two `input type="time"` ("From", "To"), all drawn as the request-changes textarea is (`--well` ground, `--edge-hi` hairline, 5px radius, mono 13px, `--sand` focus ring).
- **Defaults:** the four events that need the owner on, "reached production" off; Windows notification on (on Windows), phone push off; topic and quiet hours empty.
- **Save:** every control is a draft, like the steppers: a changed row shows in `--sand`, the existing `set-save` bar counts it ("2 changes not saved.") and Save and Discard act on it. Nothing here applies at once (the pause stays the only switch that does). No success message: the bar leaving is the feedback, as today.
- **Empty topic:** the phone switch is disabled and off, and its description ends with "Set a topic to turn this on."; emptying the field turns the switch off in the same draft. On macOS and Linux the Windows row shows the `.sv` value "Windows only" in place of the switch.
- **Nothing would be sent:** with every channel off, or every event off, a warn `.note` line sits under that group ("No channel is on: nothing is sent." / "Every event is off: nothing is sent."). It warns and does not block Save.
- **Errors:** a refused save keeps the draft and shows the server's sentence in the save bar in `--bad` (the existing `SET.err`), and the field at fault takes a `--bad` border with `aria-invalid="true"`. The first load and a failed read behave as the rest of Settings does.
- **Small screens:** the existing rule under 1180px already stacks each row and turns the nav into a scrolling row; the topic field then takes the full width and the two time fields stay side by side. Switches and fields keep a 34px-high target or more.
- **Notification text:** the same title and body go to the toast and to the push, in the machine's language (`language`), built only from project, number, title and state. Card titles are never translated and are cut at 80 characters with "…". Column names, the waits line ("spec to review", "ready to ship") and stage names are the ones the dashboard already shows and translates. No emoji, no cost, no waited time, no skip reason, no paths.
- **Quiet-hours digest:** one notification, oldest wait first, one line per card (`<project> #<n> <title> · <state>`) and one per cause that still holds (`<project> · <cause>`), at most 4 lines and then "and N more". Only what still needs the owner when quiet hours end is listed; "reached production" inside quiet hours is dropped, not listed. With nothing left, nothing is sent.

**Settings copy** (new strings; pt-BR goes in `scripts/lang/dashboard.pt-BR.json`)

| English | pt-BR |
|---|---|
| Notifications · when the factory needs you | Notificações · quando a fábrica precisa de você |
| The factory tells you when it waits for you or stops by itself. These settings are this machine's, for every project. A change applies from the dispatcher's next cycle. | A fábrica avisa quando espera você ou para sozinha. Estas configurações são desta máquina, para todos os projetos. Uma mudança vale a partir do próximo ciclo do dispatcher. |
| Events / Channels / Quiet hours | Eventos / Canais / Horário de silêncio |
| A card waits for your decision — It entered Spec Review or Staged. | Um card espera a sua decisão — Entrou em Spec Review ou Staged. |
| A run is blocked — It stopped and waits for your call. | Uma execução bloqueou — Ela parou e espera a sua decisão. |
| Remind me of a card that still waits — Once per wait, never once per cycle. | Lembrar de um card que ainda espera — Uma vez por espera, nunca uma por ciclo. |
| Minutes before the reminder — Counted from when the card started waiting. | Minutos até o lembrete — Contados de quando o card começou a esperar. |
| The factory is stuck — The usage limit was hit, a project is skipped, or no card moved for an hour. | A fábrica travou — O limite de uso foi atingido, um projeto foi pulado ou nenhum card andou em uma hora. |
| A card reached production — Asks nothing of you. | Um card chegou em produção — Não pede nada de você. |
| Windows notification on this machine — A toast on this desktop. / Windows only | Notificação do Windows nesta máquina — Um aviso nesta área de trabalho. / Só no Windows |
| Push to your phone — Through ntfy.sh. Sends the project and the card's number, title and state to that service, and nothing else. / Set a topic to turn this on. | Push no celular — Pelo ntfy.sh. Envia o projeto e o número, o título e o estado do card para esse serviço, e nada mais. / Defina um tópico para ligar. |
| ntfy topic — Subscribe to the same topic in the ntfy app. Anyone who knows the topic can read these notifications: pick a long, random one. | Tópico do ntfy — Assine o mesmo tópico no app do ntfy. Quem souber o tópico lê estas notificações: escolha um longo e aleatório. |
| Quiet hours — Nothing is sent between these times, on this machine's clock. Afterwards one notification lists what still needs you. Leave both empty for none. / From / To | Horário de silêncio — Nada é enviado entre estes horários, no relógio desta máquina. Depois, uma notificação lista o que ainda precisa de você. Deixe os dois vazios para não ter. / De / Até |
| No channel is on: nothing is sent. / Every event is off: nothing is sent. | Nenhum canal está ligado: nada é enviado. / Todos os eventos estão desligados: nada é enviado. |
| The topic takes letters, digits, - and _, up to 64. | O tópico aceita letras, dígitos, - e _, até 64. |
| Quiet hours need both times, and they cannot be the same. | O horário de silêncio precisa dos dois horários, e eles não podem ser iguais. |
| The reminder takes 15 to 720 minutes. | O lembrete aceita de 15 a 720 minutos. |

**Notification copy** (title, then body; body lines are separated by a line break)

| Event | English | pt-BR |
|---|---|---|
| Waits for a decision | `<project> · #<n> waits for you` / `<title>` / `<column> · <waits line>` | `<project> · #<n> espera você` / same body, translated |
| Run blocked | `<project> · #<n> is blocked` / `<title>` / `Stopped in <stage>` | `<project> · #<n> está bloqueado` / `<title>` / `Parou em <stage>` |
| Reminder | `<project> · #<n> still waits for you` / same body as the first notification of that wait | `<project> · #<n> ainda espera você` |
| Stuck: usage limit | `Shipfloor · the factory is stuck` / `The Claude usage limit was hit. New runs wait for it to reset.` | `Shipfloor · a fábrica travou` / `O limite de uso do Claude foi atingido. Novas execuções esperam ele voltar.` |
| Stuck: project skipped | `<project> · the factory is stuck` / `The dispatcher skips this project. The dashboard says why.` | `<project> · a fábrica travou` / `O dispatcher está pulando este projeto. O dashboard diz por quê.` |
| Stuck: nothing moves | `<project> · the factory is stuck` / `No card moved for an hour and nothing is paused.` | `<project> · a fábrica travou` / `Nenhum card andou em uma hora e nada está pausado.` |
| Reached production | `<project> · #<n> reached production` / `<title>` | `<project> · #<n> chegou em produção` / `<title>` |
| Digest | `Shipfloor · 1 card needs you` or `N cards need you`; with causes only, `Shipfloor · the factory is stuck` / the lines above / `and N more` | `Shipfloor · 1 card precisa de você` or `N cards precisam de você`; `Shipfloor · a fábrica travou` / `e mais N` |
| Digest cause lines | `usage limit hit` · `project skipped` · `no card moved for an hour` | `limite de uso atingido` · `projeto pulado` · `nenhum card andou em uma hora` |

## Architecture
_Tech Lead_

One layer (`factory`), no new dependency (Python stdlib + PyYAML; the toast is `powershell.exe`, the push is `urllib`).

**Flow.** `scripts/shipfloor-dispatch.sh` already ends every cycle in its `health` trap (also when the usage limit stopped it or a project was skipped). After the health line is written, the trap runs `shipfloor_notify.py cycle --home <home>`: stdout dropped, stderr left to the dispatcher's log, exit code ignored, bounded by a 20 s timeout per channel. A globally paused factory runs no cycle, so it sends nothing.

**New: `scripts/shipfloor_notify.py`** (no GitHub read of its own except titles)
- `cycle --home H [--now <ISO time>]`: reads the machine config, each project's `board.tsv` (the dispatcher's snapshot), the last line of `logs/health-*.jsonl`, each project's `SKIPPED` and `PAUSE`, and its own state; decides; sends; writes the state. `--now` is for tests.
- `waiting(home) -> [{project, n, state, since}]`: cards in Spec Review or Staged, plus cards in `blocked_cards` with `state = "blocked in <stage>"`; the stage comes from the card's column (Ready for Refinement, Technical Refinement → refine; Ready for Dev, Coding → develop; Validation → validate; Ready for Prod, Staged → deploy).
- `stuck(home, state, now) -> [{cause, project}]`: `usage_limit` (the health line's `usage_limited`), `skipped` (a project's `SKIPPED` file), `idle` (per project: none of its cards changed column for 60 min while an unblocked card sits in Ready for Refinement, Technical Refinement, Ready for Dev, Coding, Validation or Ready for Prod, and neither the factory nor that project is paused).
- `send(channel, title, body) -> ok`: `toast` runs `powershell.exe` (WinRT `ToastNotificationManager`, no module to install), `ntfy` POSTs the body to `https://ntfy.sh/<topic>` with a `Title` header. Titles are read once per project with news (`gh issue list --json number,title`, as the dashboard does); if that fails the notification goes out with the number only and the failure is logged.
- Test seam: `SHIPFLOOR_NOTIFY_SEND=<command>` replaces both senders; it is called as `<command> <channel> <title> <body>` and its exit code is the channel's result.
- Log lines (stderr, English, through the machine language like the dispatcher's): `<time> shipfloor: notify: <channel> failed: <reason>`, one per failed channel per cycle; never the topic.

**State: `~/.shipfloor/notify.json`** (a delivery record, rewritten whole each cycle through a temp file and a rename)
- `cards: {"<project>#<n>": {state, since, told, reminded}}`: an entry lives while the card waits in that state; leaving the state drops it, so a card that comes back waits anew.
- `stuck: {"<cause>:<project>": {since, told}}`, `columns: {"<project>": {"<n>": column}}`, `moved_at: {"<project>": time}`, `held` (something was kept back in quiet hours).
- A card is marked told when at least one enabled channel delivered; if every enabled channel failed it is tried again next cycle.
- First cycle with no state file: what waits now is told; "reached production" fires only for a card seen earlier in another column.
- Quiet hours: nothing is sent and `held` is set when something would have been; the first cycle outside them sends one digest of everything that waits and every stuck cause, marks all of it told, and clears `held`. No digest when nothing was held or nothing is left; "reached production" inside quiet hours is dropped.

**Changed**
- `scripts/shipfloor_health.py`: the health line gains `projects.<slug>.blocked_cards: [n, ...]` (owner-blocked cards on the board; the labels are already read there). Additive; `alerts` and the dashboard ignore it.
- `scripts/shipfloor_config.py`: `MACHINE_DEFAULTS["notify"] = {events: {waiting: true, blocked: true, reminder: true, stuck: true, done: false}, channels: {toast: true, ntfy: false}, ntfy_topic: "", reminder_min: 60, quiet: ""}`; `machine_problems` checks it: booleans, `reminder_min` integer 15..720, `quiet` empty or `HH:MM-HH:MM` with different ends, `ntfy_topic` empty or `^[A-Za-z0-9_-]{1,64}$`, and `channels.ntfy` on needs a topic. Unknown keys under `notify` are errors.
- `scripts/dashboard.py`: `settings()` returns `machine.notify` (merged with the defaults); `set_machine` accepts `notify` (a partial mapping, merged key by key, checked with `machine_problems` before the file is written). Same endpoint: `POST /api/settings/machine`.
- `scripts/dashboard.html`: the "Notifications" section of the Settings view (see UX); `scripts/lang/dashboard.pt-BR.json` and `scripts/lang/pt-BR.sed`: the new phrases.
- `scripts/lang/notify.pt-BR.json` (new): the notification texts in the machine's language, same shape as the dashboard's catalog.
- `README.md`: the `notify` block of `~/.shipfloor/config.yml` and how to choose an ntfy topic. `PRODUCT.md`: the "Local only" constraint, only if the owner picks A below.

**Migration.** None: a `config.yml` without `notify` reads as the defaults; `notify.json` is created on the first cycle. Deleting it only makes the next cycle tell again what waits.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/notify.test.sh` |
| AC-2 | factory | `scripts/test/notify.test.sh` |
| AC-3 | factory | `scripts/test/notify.test.sh` |
| AC-4 | factory | `scripts/test/notify.test.sh` |
| AC-5 | factory | `scripts/test/notify-quiet.test.sh` |
| AC-6 | factory | `scripts/test/notify-channels.test.sh` |
| AC-7 | factory | `scripts/test/notify-channels.test.sh` |
| AC-8 | factory | `scripts/test/notify-settings.test.sh` |

The tests drive `shipfloor_notify.py cycle --now <time>` against a temporary home (a `board.tsv`, a health line, a `config.yml`) with `SHIPFLOOR_NOTIFY_SEND` recording what each channel was handed, and the fake `gh` for titles; AC-7 also runs `shipfloor-dispatch.sh` with a failing sender and compares the exit code and the log. AC-8 covers the API (`/api/settings`, `POST /api/settings/machine`) and the section's markup; how the section looks is checked in validation by UX. A real toast and a real push are tried once by hand in review.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- **Blocked runs are part of AC-1:** the issue's AC-1 and AC-2 are the same rule ("a card starts waiting for the owner"); the state names the stage it stopped in.
- **The project is in every notification:** one dispatcher serves several projects and a bare card number is ambiguous.
- **"Nothing moved for an hour" is per project and qualified:** only while an unblocked card sits in a column the factory owns and nothing is paused, so an idle or paused factory stays silent. A live run does not exempt it: a card that sits an hour in one column is worth a look.
- **Stuck causes tell once:** none follows until the cause has cleared and come back, the same rule as for cards.
- **"Reached production" is in scope, off by default, and dropped in quiet hours:** it is the one event that asks nothing of the owner.
- **Defaults:** waits, blocks, reminder (60 min) and stuck on; toast on; phone push off until a topic is set. The feature should work the day it is installed, and nothing leaves the machine unasked.
- **Settings are this machine's (`~/.shipfloor/config.yml`), not per project:** channels belong to the machine, like the pool. Per-project settings are out of scope.
- **Out of scope:** desktop notifications on macOS and Linux, self-hosted or authenticated ntfy servers, a "send a test notification" button. The issue names none of them, and no token has to be stored.
- **The notifier runs from the dispatcher's `health` trap, as its own process:** that is the one place every cycle ends, including the ones the usage limit or a skip cut short; a separate process keeps its stderr in the dispatcher's log while the health record stays silent.
- **No GitHub read for the diff:** the notifier reads `board.tsv` and the health line, which gains the list of blocked cards; only titles are asked for, once per project and only when there is something to tell. The issue's "no extra calls" holds except for that one.
- **State is one file, `~/.shipfloor/notify.json`:** a delivery record, not card state; losing it only repeats a notification.
- **A wait is told when one channel delivered:** two channels cover for each other; with every channel down it is tried again next cycle rather than lost.
- **The first cycle after install tells what already waits:** that is what the owner is missing today; cards already in Done are not announced.
- **One sender seam (`SHIPFLOOR_NOTIFY_SEND`) and `--now`:** the tests need neither Windows, nor the network, nor the clock.
- **The reminder takes 15 to 720 minutes, in steps of 15 on the page:** the page cannot produce an invalid value and the server refuses the rest.
- **The topic is treated as a secret:** it lives only in this machine's config, is never written to a log, and the page says that whoever knows it can read the notifications. No `cybersec` label, so no security review was run.
- **Notification texts follow the machine's language and carry no skip reason, cost or waited time:** the skip reason comes from git and can hold paths (AC-6).
- **UX: drafts and the existing save bar, a `--sand` switch, "Windows only" in place of the toast switch elsewhere, a warning (not a refusal) when nothing would be sent, a digest of at most 4 lines:** all follow the existing Settings patterns and what a toast can show.

## Open questions
- **Phone push vs "Local only (127.0.0.1); no remote or phone access" in `PRODUCT.md`:** A (recommended) keep the ntfy push (one-way, off until a topic is set, only project, number, title and state) and amend that constraint to say so, or B ship the Windows toast only — B drops AC-6 and leaves you unreachable away from the machine.
