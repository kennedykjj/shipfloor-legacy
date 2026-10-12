# Settings: a Language section for the page and for what the factory writes — plan

**Issue:** #37 · **Spec:** `docs/superpowers/specs/2026-10-11-settings-a-language-section-for-the-page-design.md`
**Layers:** `factory` (path `./`, agent `engineer`). No migration, no new dependency, no new endpoint.

Acceptance tests (written by QA before any task): `scripts/test/dashboard-language.test.sh` (new; AC-1 to AC-7), in the pattern of `scripts/test/dashboard-dispatcher.test.sh`: a server on a temporary home, `curl` against `GET /api/settings`, `POST /api/settings/machine` and `GET /api/lang`, `config.yml` read back, the page's markup and the pt-BR catalog checked by text.

No test may touch the real `~/.shipfloor`: the home is always a temporary one, and the scheduler is the `SHIPFLOOR_SCHEDULER` stub. `scripts/shipfloor_config.py` is not changed by any task: `LANGS` and the check in `machine_problems` are already there.

## Task 1 — the dashboard server

- **Layer:** factory · **Owner:** engineer · **Depends on:** nothing
- **Files:** `scripts/dashboard.py`
- **ACs:** the API half of AC-1, AC-2, AC-3, AC-4, AC-5, AC-6
- `settings()`: three additions, nothing removed.
  - `machine.language`: the code `config.yml` holds, `en` when the key is missing.
  - `languages`: `shipfloor_config.LANGS` as it is, `{code: name}` in its own order.
  - `projects[].language`: `{"code": <the project's language, "en" when missing>, "set": <true when its factory.yml has the key>, "file": ".shipfloor/factory.yml"}`, read from the same config the row's other fields come from.
- `set_machine(changes)`: accepts `language` beside `pool`, `stacks`, `stack_wait`, `stages` and `dispatcher`. It is copied into the new config before `shipfloor_config.machine_problems` runs; a value outside `LANGS` answers 400 with `language must be one of ...` and `config.yml` is not written, byte for byte. Every other key of the file is kept as it was. A language change alone does not call the scheduler.
- `GET /api/lang`: unchanged.

## Task 2 — the Settings view, the catalog and the README

- **Layer:** factory · **Owner:** engineer · **Depends on:** Task 1
- **Files:** `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `README.md`
- **ACs:** the page half of AC-1, AC-2, AC-3, AC-4, AC-5; AC-7
- `loadLang`: remembers the language the page loaded in, to tell "saved, not yet shown" from "shown".
- `renderSettings`: fifth and last `secs` entry `["language", "Language", "the page and what the factory writes"]`, after Themes, and its body: `h1.g`, `p.lead` (the AC-7 sentence lives here, so it shows with no project registered), then two `.sgroup.panel` blocks. No new component, class or token.
  - "This dashboard": one `row()` with a native `<select id="lang">` built like `#every`: one option per key of `languages` in the order the server sends, labelled `<name> (<code>)`, `class="dirty"` while it differs from the saved value, `aria-label` "Language of this dashboard". The page holds no list of languages and names no language code of its own. While the saved language differs from the loaded one, the row's `.sd` reads "Saved as {name}. Reload the page to see it.".
  - "What the factory writes": one read-only `row()` per registered project: `.st` the slug, `.sd` the `factory.yml` path in `<code>`, control slot a `.sv` with `<name> (<code>)`; a project whose `language.set` is false adds " · no language key, the factory default". The group closes with the `.from` line. With no project: the existing `<p class="empty">` string Projects uses, and no `.from` line.
- `setVal` / `setWas` read `machine.language`; the `#lang` change handler drafts `SET.draft.language` like `#every` and returns focus to the select; Discard returns it to the saved value.
- `setSave` sends `language` in the machine request. On 400 with `language` drafted the bar shows "The language was not changed: {reason}. This dashboard stays in {name}." and keeps the draft. While `language` is drafted the bar's muted span gains "The language shows after a reload.". The page does not reload itself.
- `scripts/lang/dashboard.pt-BR.json`: `exact` entries (and `rx` where a string has a `{...}` part) for every string of the spec's copy table, the server reason and the two language names included.
- `README.md`, "Language": one sentence saying the machine's language can also be set in Settings.
