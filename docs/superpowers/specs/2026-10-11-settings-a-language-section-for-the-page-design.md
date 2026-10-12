# Settings: a Language section for the page and for what the factory writes — spec

**Issue:** #37 · **Branch:** `feat/37-settings-a-language-section-for-the-page` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** Language has two keys since #38 (`language` in `~/.shipfloor/config.yml` for this machine, `language` in each project's `.shipfloor/factory.yml` for what the factory writes), and both can only be seen or changed by opening the files. Settings has no place for either.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine.
**Acceptance criteria**
- **AC-1** — Given the page language is English, when the owner picks Portuguese under Settings > Language > "This dashboard" and saves, then on the next load the dashboard's own text is in Portuguese and text the agents wrote is shown as written.
- **AC-2** — Given registered projects, when the owner opens Settings > Language, then "What the factory writes" has one row per registered project with the language the factory writes in for it and the path of the `factory.yml` that sets it, with no control to edit it.
- **AC-3** — Given a language outside `LANGS` (`scripts/shipfloor_config.py`), when it is saved, then the Settings view says why it was refused and `config.yml` keeps the old value.
- **AC-4** — Given the keys of `LANGS`, when the owner opens the language choice, then the options are exactly those keys, each with its name from `LANGS`, so a language added there shows up without a change to the page.
- **AC-5** — Given a `config.yml` or a project's `factory.yml` with no `language` key, when the owner opens the section, then it shows `en`, the default the factory uses.
- **AC-6** — Given a `config.yml` with other keys (pool, stages, stacks, dispatcher), when the owner saves a language, then only `language` changes in the file.
- **AC-7** — Given the section is open, when the owner reads it, then it says that the text a product shows its own users is not a factory setting and is set in the files that project's agents read.
**Out of scope:** Editing a project's `language` from the dashboard (it lives in a file tracked in the project's repository); a language for what other code reads (commit messages, spec headings, card markers, labels); translating what was already written; adding a language or new catalog entries beyond the section's own text; changing the page language without a reload.
**Product fit:** Serves principle 3 (numbers and values are sourced: each language is shown with the file that sets it) and principle 1 (the dashboard keeps no state of its own: the choice lives in `config.yml`, the projects' in their `factory.yml`). It stays inside the positioning: the refusal in AC-3 comes from the same check the scripts use, not from the page. No conflict with what is out of scope for the product (local only, the owner's machine).
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Placement:** fifth and last entry of `secs` in `renderSettings`, after Themes (the two entries about the dashboard itself sit together): `["language", "Language", <sub>]`. Same `.set-nav` button, `aria-current`, and the body follows the other sections: `h1.g`, `p.lead`, then two `.sgroup.panel` blocks. No new component, class or token.
- **Lead (AC-7):** the not-a-factory-setting sentence lives in the lead, so it shows even with no project registered.
- **Group 1, "This dashboard" `~/.shipfloor/config.yml`:** one `row()` with a native `<select id="lang">` as its control, built like `#every`: one option per key of `LANGS` in the order the server sends, labelled `<name> (<code>)`, `class="dirty"` while it differs from the saved value, `aria-label` "Language of this dashboard". A missing key selects `en` (AC-5).
- **Flow:** picking an option only drafts (`SET.draft.language`), like the steppers and the pace; the shared `#set-save` bar appears with Discard and Save. Save posts with the other machine settings; on success the draft clears, the bar hides and focus returns to the select (as `#every` does). Nothing on the page changes language until a reload.
- **Saved, not yet shown:** while the saved language differs from the one the page loaded in, the row's `.sd` reads the "Saved as ..." line instead of the default description. It is derived from the data, so it survives the 5s poll and goes away by itself after the reload.
- **Not saved yet:** when `language` is in the draft, the bar's muted span gains one sentence after the existing one ("The language shows after a reload."), so the "next cycle" text is not read as applying to it.
- **Refused (AC-3):** the existing `SET.err` path: the bar stays, `#set-count` shows the refusal in `.bad` with the server's reason inside the page's sentence (same shape as the pace refusal) and the language still in force. The draft and the `dirty` mark stay; Discard returns the select to the saved value. `#set-save` is already `role="status"`, so it is announced.
- **Group 2, "What the factory writes" `.shipfloor/factory.yml`:** one `row()` per registered project, read-only: `.st` the slug, `.sd` the factory.yml path in `<code>` (mono, wraps with `overflow-wrap: anywhere`), control slot a `.sv` with `<name> (<code>)`. No select, no stepper, no fold button. A project with no `language` key shows `English (en)` and its `.sd` adds " · no language key, the factory default". The group closes with a `.from` line saying where to change it.
- **No registered projects:** the group keeps its heading and shows the existing `<p class="empty">` with the string Projects already uses ("No project registered. Run `shipfloor add <repo>`."); the `.from` line is left out.
- **Small screen:** nothing new. Under 1180px the existing rule stacks `.srow` in one column (select and `.sv` under the text, `.sv` left-aligned) and turns the nav into a scrolling row, where Language is the last button and its `small` is hidden.
- **Keyboard and accessibility:** tab order is nav, select, then Discard and Save when the bar shows; the select is the only focusable thing in the body. Arrow keys change the option without saving. Language is never conveyed by color: the dirty mark is the existing one and the refusal is text. Project slugs, paths and codes are not rewritten by the catalog; the two language names are (they come from `LANGS` in English and get `exact` entries).
- **Copy:** new strings below; each needs an entry in `scripts/lang/dashboard.pt-BR.json` (`exact`, or `rx` where it has a `{...}` part). Reused as is: "No project registered...", "N change(s) not saved.", "The settings were not saved.".

| Where | en | pt-BR |
|---|---|---|
| nav | Language | Idioma |
| nav sub | the page and what the factory writes | a página e o que a fábrica escreve |
| lead | The language of this dashboard, and the language the factory writes in for each project. The text a product shows its own users is not a factory setting: it is set in the files that project's agents read. | O idioma deste dashboard e o idioma em que a fábrica escreve em cada projeto. O texto que um produto mostra aos próprios usuários não é uma configuração da fábrica: ele é definido nos arquivos que os agentes daquele projeto leem. |
| group 1 | This dashboard | Este dashboard |
| row title, `aria-label` | Language of this dashboard | Idioma deste dashboard |
| row text | The dashboard's own text. What the agents wrote is shown as written. Applied when the page is reloaded. | O texto do próprio dashboard. O que os agentes escreveram aparece como foi escrito. Vale quando a página é recarregada. |
| row text, saved | Saved as {name}. Reload the page to see it. | Salvo como {name}. Recarregue a página para ver. |
| bar, drafted | The language shows after a reload. | O idioma aparece depois de recarregar. |
| bar, refused | The language was not changed: {reason}. This dashboard stays in {name}. | O idioma não foi alterado: {reason}. Este dashboard continua em {name}. |
| server reason | language must be one of {codes} | language deve ser um de {codes} |
| group 2 | What the factory writes | O que a fábrica escreve |
| no key | no language key, the factory default | sem a chave language, o padrão da fábrica |
| `.from` | Read-only here: a project's language is part of its repository. To change it, edit `language` in its `.shipfloor/factory.yml`. The dispatcher reads it again on every cycle. | Somente leitura aqui: o idioma de um projeto faz parte do repositório dele. Para mudar, edite `language` no `.shipfloor/factory.yml` do projeto. O dispatcher lê o arquivo de novo a cada ciclo. |
| option names | English · Brazilian Portuguese | Inglês · Português do Brasil |

## Architecture
_Tech Lead_

One layer, `factory`. No migration, no new endpoint, no new file outside the test.

**Contracts touched**
- `GET /api/settings` (`Dashboard.settings`, `scripts/dashboard.py`), three additions, nothing removed:
  - `machine.language`: the code `config.yml` holds, `en` when the key is missing (already in the merged config; added to the keys sent).
  - `languages`: `shipfloor_config.LANGS` as it is, `{code: name}` in its own order. The page builds the options from it and from nothing else (AC-4).
  - `projects[].language`: `{"code": <the project's language, "en" when missing>, "set": <true when factory.yml has the key>, "file": ".shipfloor/factory.yml"}`, read from the same config the row's other fields come from.
- `POST /api/settings/machine` (`Dashboard.set_machine`): accepts `language` beside `pool`, `stacks`, `stack_wait`, `stages` and `dispatcher`. It is copied into the new config before `shipfloor_config.machine_problems` runs, which already refuses a value outside `LANGS` with `language must be one of ...`: 400 with that reason and the file is not written (AC-3). Other keys are kept as today (AC-6). A language change does not call the scheduler.
- `GET /api/lang`: unchanged. The page keeps the `language` it answered at load, to tell "saved, not yet shown" from "shown".

**Modules touched**
- `scripts/dashboard.py`: `settings` and `set_machine` as above.
- `scripts/dashboard.html`: `loadLang` remembers the loaded language; `renderSettings` gets the fifth `secs` entry and the `language` body; `setVal`/`setWas` read `machine.language`; the `#lang` change handler drafts like `#every`; `setSave` sends `language` in the machine request and words the 400 as the UX refusal line; the save bar gains the reload sentence while `language` is drafted.
- `scripts/lang/dashboard.pt-BR.json`: `exact` and `rx` entries for the strings in the UX copy table.
- `README.md`, "Language": one sentence saying the machine's language can also be set in Settings.
- `scripts/test/dashboard-language.test.sh`: new, in the pattern of `scripts/test/dashboard-dispatcher.test.sh` (a server on a temporary home, `curl` against the two endpoints, the file read back, the page's markup checked by text).

**Not touched:** `scripts/shipfloor_config.py` (the check and `LANGS` are already there), any project's `factory.yml`, the `.sed` catalogs.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-language.test.sh` |

How each is checked: AC-1 posts `pt-BR`, then `/api/lang` answers `pt-BR` with its catalog and `RAW` in the page still lists the agents' text; AC-2 and AC-5 read `projects[].language` for a project with the key and one without, and `machine.language` on a `config.yml` without it; AC-3 posts `xx`, expects 400 with the reason and the file byte for byte as before; AC-4 compares `languages` with `LANGS` and checks the page names no language code in the section; AC-6 compares every other key of `config.yml` before and after; AC-7 finds the sentence in the page and its entry in the pt-BR catalog.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The file shown for a project is `.shipfloor/factory.yml` in its repository, not the dispatcher's copy under `~/.shipfloor/projects/`: that is the file the owner edits, and Projects already names it that way.
- The page does not reload itself after a save: it says "Saved as ..., reload the page to see it". The issue asks for "the next load", and a reload could drop a review in progress in another view.
- Language is saved through the shared save bar and `POST /api/settings/machine`, not an endpoint of its own: one check (`machine_problems`) for the whole file, as with pool and stages.
- The options come from `languages` in `/api/settings`, with no list in the page: that is what makes AC-4 hold.
- A missing `language` key is shown as `English (en)` and, for a project, marked as the factory default (AC-5): the owner sees the value in force and that no file sets it.
- A `config.yml` hand-edited to an unknown language is not repaired by the page: the select shows the choices of `LANGS`, and saving one replaces it. `machine_problems` already reports the bad value elsewhere.
- Language sits last in the Settings list, after Themes: the two sections about the dashboard itself stay together.
- No `cybersec` label: the request writes one checked key of a local file, behind the dashboard's existing token.
- New tests go in their own file, `scripts/test/dashboard-language.test.sh`: `--changed` then runs only what this card touches.
- AC-5 to AC-7 were added by the PO from the issue's proposal text (default, other keys untouched, the product-text sentence): each is checkable and none widens the scope.

## Open questions
- none
