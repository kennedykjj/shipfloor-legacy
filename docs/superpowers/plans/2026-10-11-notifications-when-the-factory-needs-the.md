# Notifications when the factory needs the owner — plan

**Issue:** #35 · **Spec:** `docs/superpowers/specs/2026-10-11-notifications-when-the-factory-needs-the-design.md`

**Goal:** at the end of every dispatcher cycle a notifier compares what waits for the owner with what it already told and sends one notification per new item (a Windows toast, a phone push through ntfy), with one reminder per wait, quiet hours and a "Notifications" section in the dashboard's Settings.

**Layers:** one, `factory` (path `./`, agent `engineer`, Bash and Python 3 stdlib + PyYAML). No new dependency, no migration.

## Decided before planning

- **Open question of the spec (phone push vs "Local only"):** the card was moved to Ready for Dev with no answer, so the recommended option A stands: the ntfy push ships (one-way, off until a topic is set, only project, number, title and state) and `PRODUCT.md`'s "Local only" constraint is amended to say so (task 4). AC-6 stays.

## Global constraints

- The notifier never fails a cycle: the dispatcher drops its stdout, ignores its exit code and leaves its stderr in the dispatcher's log.
- No GitHub read except titles, once per project and only when there is something to tell.
- The ntfy topic is a secret: never in a log line, never in an error sentence.
- A notification is built only from project, number, title and state (AC-6): no skip reason, cost, waited time or path.
- `SHIPFLOOR_NOTIFY_SEND=<command>` replaces both senders (`<command> <channel> <title> <body>`, its exit code is the channel's result) and `cycle --now <ISO time>` replaces the clock: the tests need neither Windows, the network nor the clock.
- State is one file, `~/.shipfloor/notify.json`, rewritten whole through a temp file and a rename.
- The acceptance tests (`scripts/test/notify*.test.sh`) are QA's: an implementer who thinks one is wrong answers `test-wrong`.
- No dead code, no narrating comments, no speculative options; match the surrounding code.

## Tasks

Run in order; they share the worktree.

### Task 1 — config and health line
- **Layer:** factory · **Owner:** engineer · **Depends on:** none
- **Files:** `scripts/shipfloor_config.py`, `scripts/shipfloor_health.py`
- `MACHINE_DEFAULTS["notify"] = {events: {waiting, blocked, reminder, stuck: true, done: false}, channels: {toast: true, ntfy: false}, ntfy_topic: "", reminder_min: 60, quiet: ""}`.
- `machine_problems` checks `notify`: a mapping; `events.*` and `channels.*` booleans; `reminder_min` an integer 15..720; `quiet` empty or `HH:MM-HH:MM` with different ends; `ntfy_topic` empty or `^[A-Za-z0-9_-]{1,64}$`; `channels.ntfy` on needs a topic; unknown keys under `notify`, `notify.events` and `notify.channels` are errors. The error sentences are the spec's Settings copy where it has one ("The topic takes letters, digits, - and _, up to 64.", "Quiet hours need both times, and they cannot be the same.", "The reminder takes 15 to 720 minutes.").
- The health line gains `projects.<slug>.blocked_cards: [n, ...]` (owner-blocked cards that are on the board, sorted). Additive: `alerts` and the dashboard ignore it.

### Task 2 — the notifier and its place in the cycle
- **Layer:** factory · **Owner:** engineer · **Depends on:** task 1
- **Files:** `scripts/shipfloor_notify.py` (new), `scripts/lang/notify.pt-BR.json` (new), `scripts/shipfloor-dispatch.sh`
- `shipfloor_notify.py cycle --home H [--now <ISO time>]` with `waiting`, `stuck` and `send` as the spec's Architecture describes them; state in `<home>/notify.json` (`cards`, `stuck`, `columns`, `moved_at`, `held`).
- Rules: a wait is told once and marked told when at least one enabled channel delivered (every channel failed: tried again next cycle); one reminder per wait after `reminder_min`; a stuck cause tells once until it has cleared and come back; "reached production" only for a card seen earlier in another column, off by default; the first cycle with no state file tells what waits now; leaving the state drops the entry.
- Quiet hours: nothing is sent and `held` is set; the first cycle outside them sends one digest (oldest wait first, at most 4 lines, then "and N more"), marks all of it told and clears `held`; no digest when nothing was held or nothing is left; "reached production" inside quiet hours is dropped.
- Texts are the spec's "Notification copy", in the machine's language through `scripts/lang/notify.pt-BR.json`; titles cut at 80 characters with "…"; a failed title read sends the number only and logs the failure.
- Senders: `toast` through `powershell.exe` (WinRT `ToastNotificationManager`), `ntfy` a POST to `https://ntfy.sh/<topic>` with a `Title` header; 20 s timeout per channel; a failure is one stderr line `<time> shipfloor: notify: <channel> failed: <reason>` per channel per cycle, and the other channel still delivers.
- `shipfloor-dispatch.sh`: the `health` trap runs the notifier after the health line is written, stdout dropped, stderr kept, exit code ignored. The cycle's own exit code is unchanged.

### Task 3 — Settings: API and the "Notifications" section
- **Layer:** factory · **Owner:** engineer · **Depends on:** task 1
- **Files:** `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `scripts/lang/pt-BR.sed`
- `settings()` returns `machine.notify` merged with the defaults; `set_machine` accepts `notify` as a partial mapping merged key by key (`events` and `channels` too) and checked with `machine_problems` before the file is written; same endpoint, `POST /api/settings/machine`.
- The section as the spec's UX describes it: a fifth `set-nav` entry, three `.sgroup.panel` groups (Events, Channels, Quiet hours), the `--sand` switch modifier, the `.stp` stepper 15..720 by 15 dimmed while the reminder is off, the topic and time inputs, drafts on the existing save bar, the disabled phone switch with an empty topic, "Windows only" off Windows, the two warn notes, the field at fault marked `aria-invalid="true"` on a refused save. Strings are the spec's "Settings copy", pt-BR in the catalog.

### Task 4 — documents
- **Layer:** factory · **Owner:** engineer · **Depends on:** tasks 2 and 3
- **Files:** `README.md`, `PRODUCT.md`
- `README.md`: the `notify` block of `~/.shipfloor/config.yml`, the Settings section, and how to choose an ntfy topic (long and random: whoever knows it reads the notifications).
- `PRODUCT.md`: the "Local only (127.0.0.1); no remote or phone access" constraint amended: the dashboard stays local; the one thing that leaves the machine is the optional one-way ntfy push, off until a topic is set, carrying only project, card number, title and state.

## Acceptance tests (QA, before any task)

| AC | Test file |
|---|---|
| AC-1 to AC-4 | `scripts/test/notify.test.sh` |
| AC-5 | `scripts/test/notify-quiet.test.sh` |
| AC-6, AC-7 | `scripts/test/notify-channels.test.sh` |
| AC-8 | `scripts/test/notify-settings.test.sh` |

They drive `shipfloor_notify.py cycle --now <time>` against a temporary home (`board.tsv`, a health line, `config.yml`) with `SHIPFLOOR_NOTIFY_SEND` recording what each channel was handed and the fake `gh` for titles; AC-7 also runs `shipfloor-dispatch.sh` with a failing sender; AC-8 covers `/api/settings`, `POST /api/settings/machine` and the section's markup.

## Review focus

Not covered by the tests; reviewers check them in code, and the owner tries them once by hand:

1. A real toast on Windows (`powershell.exe`, WinRT) and a real push to ntfy.sh.
2. The topic never reaches a log line or an error message, also when `urllib` raises with the URL in its text.
3. Text handed to `powershell.exe` is passed as data (arguments or environment), never spliced into the script: a card title is untrusted.
4. How the Settings section looks and behaves (validation's UX check).
