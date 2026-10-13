# Settings: choose the language the factory writes in, per project, apart from the dashboard's — spec

**Issue:** #129 · **Branch:** `feat/129-settings-choose-the-language-the-factory` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** In Settings > Language the dashboard's language is a choice, but the language the factory writes in (specs, pull requests, issue comments, reports, log lines) is read-only per project: it is the `language` key of the repository's `.shipfloor/factory.yml`, so changing it costs a commit to `main`. The owner cannot run a dashboard in one language and a project written in another from the page.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine.
**Acceptance criteria**
- **AC-1** — Given Settings > Language, when the page loads, then each project under "What the factory writes" has a select with the languages the factory has (English, pt-BR) plus an "as the repository says" option, showing the language in effect.
- **AC-2** — Given a project whose `factory.yml` has no `language`, when the owner chooses pt-BR, then the project's next run writes its spec, issue comments and log lines in pt-BR and the repository has no new commit or changed file.
- **AC-3** — Given a project with a language override, when the owner chooses "as the repository says", then the override is removed and the project's `overrides.yml` is deleted if it holds nothing else, and kept with its other keys otherwise.
- **AC-4** — Given a project whose override differs from its `factory.yml`, when the row is shown, then it also says what the repository says.
- **AC-5** — Given the dashboard in English and a project in pt-BR (and the reverse), when either choice is changed, then the other keeps its value and each surface uses its own language.
- **AC-6** — Given a request to set a project's language to one the factory does not have, when the server receives it, then it refuses with an error and no file changes.
- **AC-7** — Given a session already running when the language is changed, when it goes on, then it keeps the language it started with; the change applies from the dispatcher's next cycle, and the page says so.
- **AC-8** — Given registered projects, when `shipfloor doctor` runs, then it shows for each project the language it writes in and where it comes from (repository or this machine).
**Out of scope:** Adding languages beyond English and pt-BR; writing `language` into the repository's `factory.yml` from the page; the text a product shows its own users (set in the files the project's agents read); rewriting specs, PRs or comments already written; a factory-wide default language for all projects.
**Product fit:** Serves principle 3 (numbers and facts are sourced): the page and `doctor` say which language is in effect and whether it comes from the repository or this machine. Consistent with the operating context: the choice is local to this machine under `~/.shipfloor`, the repository's `factory.yml` stays the default, and nothing leaves the machine. No contradiction with positioning or scope.
**Touches UI:** yes

## UX
_UX/UI Designer_

Screen: Settings > Language, group "What the factory writes" (`scripts/dashboard.html`, the `SET.sec === "language"` branch). Lead, group title, row label (the slug) and row description (`<code>file</code>` and "· no language key, the factory default") stay as they are. No new component, class or token.

- **Control.** The read-only `<span class="sv">` of each project row becomes `<span class="sknob"><select>…</select><small>…</small></span>`, the same shape as the model selects in Agents and models. Options, in this order: `As the repository says: English (en)` (value empty, naming the language the repository yields, the factory default when it has no `language` key), then one per language the factory has, worded as the dashboard's own select words them (`English (en)`, `Brazilian Portuguese (pt-BR)`). Selected: the override when there is one, else the first option.
- **Flow.** Choosing is a draft under the key `p|<slug>|language`, like the project steppers: the select turns sand (`.sknob select.dirty`), the row gets `.dirty`, the save bar counts one change per project, Discard restores it, picking the saved value again drops the draft. Save posts it to `/api/settings/project` with the project's other drafts; the first option is sent as `null` (remove the override). A language picked by name is kept as an override even when it equals the repository's, so it holds if the repository changes later; this is the one difference from the steppers, which send `null` on an equal value.
- **Hint (AC-4).** While the saved or drafted value is an override, the `<small>` under the select reads `set on this machine · the repository says English (en)` (`.sknob small`, muted). With the first option selected there is no `<small>`: the option already names the repository's value.
- **Note (AC-7).** The `.from` paragraph under the rows is replaced by: `Kept on this machine, over what the repository says; the repository's <code>.shipfloor/factory.yml</code> is not changed. A change applies from the dispatcher's next cycle; a session already running keeps the language it started in.` The save bar keeps its sentence; its "The language shows after a reload." stays tied to the dashboard's own select only, never to a project's.
- **Independence (AC-5).** A project select never changes `#lang` or its draft, and the reverse; a project's language names are shown in the dashboard's language, like every other label.
- **States.** No projects: the existing `No project registered. Run shipfloor add <repo>.` and no note. Saving: the existing busy save bar (Save and Discard disabled), the select keeps its sand value until the answer; no spinner. Success: sand clears, the hint follows the saved value, nothing else is announced. Error: the save bar's `.bad` line, the draft kept so the owner can retry or discard: `The language of <slug> was not changed: <the server's reason>. It still writes in English (en).` A refusal that is not about the language keeps the server's own text.
- **Refresh.** The 10-second Settings read must not rewrite a project select while it is focused or open (the guard `#every` and `#lang` have in `loadSettings`); after a choice re-renders the section, focus returns to the same select, as `setModel` does.
- **Keyboard and labels.** A native `<select>`: Tab reaches it in row order, arrows and typing choose, the 2px sand focus ring applies. `aria-label="Language the factory writes in for <slug>"`; the `<small>` has an id and is the select's `aria-describedby`. The dirty state is not carried by color alone: the save bar's count says it.
- **Small screens.** At 1180px and below the row stacks (the existing `.srow` rule): select and hint sit under the description, left-aligned, the select at `max-width: 100%` so the long first option truncates inside the control instead of widening the page. Check at 360px.
- **Copy, pt-BR** (`scripts/lang/dashboard.pt-BR.json`; the `exact` entry "Read-only here: a project's language is part of its repository. To change it, edit" is removed with its sentence):
  - rx `^As the repository says: (.+)$` → `Como o repositório diz: $1`
  - rx `^set on this machine · the repository says (.+)$` → `definido nesta máquina · o repositório diz $1`
  - rx `^Language the factory writes in for (\S+)$` → `Idioma em que a fábrica escreve em $1`
  - rx `^The language of (\S+) was not changed: (.*)\. It still writes in (.*)\.$` → `O idioma de $1 não foi alterado: $2. Ele continua escrevendo em $3.`
  - exact `Kept on this machine, over what the repository says; the repository's` → `Fica nesta máquina, por cima do que o repositório diz; o`
  - exact `is not changed. A change applies from the dispatcher's next cycle; a session already running keeps the language it started in.` → `do repositório não é alterado. Uma mudança vale a partir do próximo ciclo do dispatcher; uma sessão que já roda continua no idioma em que começou.`

## Architecture
_Tech Lead_

One layer, `factory`. No migration: `overrides.yml` gains one optional top-level key, and a file without it reads as today.

**Contracts touched**
- `overrides.yml` (per project, `~/.shipfloor/projects/<slug>/`): new top-level scalar `language: <code>`, beside `limits` and `deploy`.
- `shipfloor_config.with_overrides(raw, over)`: accepts `language` when it is a string and lays it over `raw["language"]`; any other shape is the existing "cannot be overridden" error, whose list of what may be overridden now names `language`. `problems()` on the merged config already refuses a code outside `LANGS`. Every reader that goes through `main()` (`describe`, `get language`, `values … language` in `deploy.sh`) follows with no change of its own.
- `shipfloor-config.sh language` (new command): prints `<code>\t<source>`, source `machine` when `overrides.yml` sets it, else `repository` (also when `factory.yml` has no key and the default applies). Honors `FACTORY_LANGUAGE` like the others.
- `FACTORY_LANGUAGE` (new environment variable): the language a run started with. `dispatch.sh` `launch()` reads the project's language once and adds it to the run's `envs`; `shipfloor_config.py` `main()` puts it over the merged config when it is in `LANGS`, and `gate.sh` uses it before reading any file. This is what pins a running session (AC-7).
- `gate.sh`, the language shortcut at the end: with no `FACTORY_LANGUAGE`, the same line read runs on `overrides.yml` beside `$FACTORY_CONFIG` first, then on `$FACTORY_CONFIG`. Still no python start per gate call.
- `GET /api/settings`, each project's `language`: `{code, set, file}` becomes `{code, repo, from, set, file}`: `code` the language in effect, `repo` what `factory.yml` yields (its key, or `en`), `from` `machine` or `repository`, `set` whether `factory.yml` has the key.
- `POST /api/settings/project` (`Factory.set_project`): `values` may hold `language`: a code in `LANGS`, or `null` to remove the override. Anything else (not a string, unknown code) is `400 {"error": "language must be one of …"}` before any file is written. Pruning and the delete of an empty `overrides.yml` are the existing ones; the file's comment line says "overrides of the project", no longer only "operational limits".
- `shipfloor doctor`, per valid project: `ok   <slug>: writes in <Language> (<code>), from the repository` or `…, from this machine`, read with `shipfloor_cfg language`.

**Files**
- `scripts/shipfloor_config.py`: `with_overrides`, the `language` command, `FACTORY_LANGUAGE` in `main()`.
- `scripts/gate.sh`: the shortcut above.
- `scripts/dispatch.sh`: `launch()` adds `FACTORY_LANGUAGE`.
- `scripts/dashboard.py`: `settings()` payload, `set_project`.
- `scripts/dashboard.html`: the Language section as `## UX` says, `loadSettings` guard, draft key `p|<slug>|language`.
- `scripts/lang/dashboard.pt-BR.json`: the entries of `## UX`. `scripts/lang/pt-BR.sed`: the doctor line is not translated (doctor's other lines are not).
- `scripts/shipfloor`: `cmd_doctor`.
- `scripts/test/demo_home.py`: one demo project with a language override, so the page shows the hint.
- `docs/operation.md`: the `overrides.yml` paragraph names `language`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-2 | factory | `scripts/test/config.test.sh` |
| AC-3 | factory | `scripts/test/dashboard.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-language.test.sh` |
| AC-6 | factory | `scripts/test/dashboard.test.sh` |
| AC-7 | factory | `scripts/test/gate-acceptance.test.sh` |
| AC-8 | factory | `scripts/test/shipfloor-cli.test.sh` |

AC-2 is checked at the readers: with `language: pt-BR` in `overrides.yml` and none in `factory.yml`, `describe` and `get language` say pt-BR, a failing gate speaks pt-BR, and `factory.yml` is byte-identical. AC-7: with `FACTORY_LANGUAGE=en` and a pt-BR override, the gate and `describe` stay in English.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Only English and pt-BR, the languages in `LANGS`; the select lists whatever `LANGS` holds, so a new language needs no change here.
- The page never writes `language` into the repository's `factory.yml`: the choice is this machine's, as the issue says.
- No factory-wide default language for all projects, and nothing already written is rewritten: neither is asked for.
- A language picked by name stays an override even when it equals the repository's, so it holds if the repository changes later; only "As the repository says" removes it.
- One hint whenever an override is set ("set on this machine · the repository says …"), also when both are equal: one string instead of two variants.
- A running session is pinned by `FACTORY_LANGUAGE`, set at launch: without it a gate called mid-run would switch language, against AC-7.
- `deploy.sh` reads the language once when it starts and is not pinned further: it is one short script run, not a session.
- The source has two values, `repository` and `machine`; a `factory.yml` with no key counts as `repository` (the factory default), as the issue names only those two.
- `gate.sh` keeps its direct line read and extends it to `overrides.yml`, not `shipfloor_cfg`: one python start per gate call is the cost the shortcut exists to avoid.
- The doctor line stays in English: none of doctor's lines are translated today.
- The server's refusal reuses the save bar's error line; no new saving state.

## Open questions
- none
