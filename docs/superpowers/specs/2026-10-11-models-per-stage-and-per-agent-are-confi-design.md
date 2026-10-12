# Models per stage and per agent are configuration, not code — spec

**Issue:** #34 · **Branch:** `feat/34-models-per-stage-and-per-agent-are-confi` · **Date:** 2026-10-11
**Roles:** PO, UX/UI, Tech Lead

## Product
_Product Owner_

**Problem:** Which model runs each stage and each agent is written in the plugin (`dispatch.sh` and the `agents/*.md` frontmatter), so trying a cheaper model for one role means editing the plugin, the choice is lost on the next update, and nothing shows what a stage costs to judge the change by.
**Audience:** The factory's owner, on their own machine; other developers who install the plugin get the same setting.
**Acceptance criteria**
- **AC-1** — Given `models.stages.develop: sonnet` in `~/.shipfloor/config.yml`, when the dispatcher starts a develop run, then the run's command carries `--model sonnet`.
- **AC-2** — Given no `models` key, or a stage or agent left out of it, when runs and subagents start, then each uses the model it uses today (validate and deploy on Sonnet, refine and develop on the default, each agent on its frontmatter model).
- **AC-3** — Given `models.agents.engineer: haiku`, when develop starts an engineer, then that subagent runs on Haiku, shown in its transcript and in its sub-row of the card's Sessions tab.
- **AC-4** — Given `models.agents.<name>` names a project agent a layer refers to (`layers[].agent`), when a stage starts that agent, then it runs on the configured model.
- **AC-5** — Given a model name the factory does not know, or a stage or agent name that does not exist, when the config is validated (`shipfloor doctor`, a save in Settings), then the key and value are reported, Settings does not save it, and a run started meanwhile uses today's model for that key.
- **AC-6** — Given the owner changes a model in the Settings section "Agents and models" and saves, when the next cycle starts runs, then they use it, `config.yml` holds it, and sessions already running keep their model.
- **AC-7** — Given runs in the last 7 days, when the section is shown, then each stage shows its average cost per card from the transcripts, labelled "est."; a stage with no priced run in that window shows no figure, never a zero.
- **AC-8** — Given a chosen model has no entry in `prices.yml`, when the section is shown, then that choice carries a warning that its cost cannot be estimated, and it can still be saved.
**Out of scope:** Reasoning effort per role; model choices per project (`factory.yml` or `overrides.yml`); changing today's defaults; editing `prices.yml` from the dashboard; changing the model of a running session; cost per agent or a projection of what a change would cost.
**Product fit:** Serves principle 3 (numbers are exact and sourced; estimates say so): the per-stage cost comes from the transcripts, is labelled an estimate, and an unpriced model is flagged instead of shown as zero. It stays inside the Settings view's existing scope (this machine's limits, saved to `~/.shipfloor/config.yml`, read on the next cycle) and does not touch the gates, so principle 2 holds whatever model is chosen. No conflict with the positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Where:** a fifth entry in `secs`, right after Sessions: id `models`, name "Agents and models", sub "which model runs each role". Body is the usual `h1.g` + `p.lead`, then two `.sgroup.panel` groups: "Stages `config.yml · models.stages`" and "Agents `config.yml · models.agents`". No new component; everything is `row`, `.sknob`, the base `select` and the `set-save` bar.
- **Flow:** open Settings → Agents and models → pick a model in a row's select → the row turns dirty and the Save bar appears with its existing text → Save (or Discard). Picking the value the row had before removes it from the draft, as the steppers do. Picking Default saves the key as unset.
- **Rows:** one `row` per stage, in factory order, titled with `STAGE_NAME` and described by the existing `STAGE_HELP` (no new text). Then the five plugin agents, then the project agents sorted by name; an agent's title is its name verbatim in mono (it is the config key), with the one-line description from the table. A project agent used by several projects or layers is one row that lists them all. With no project agent, the Agents group simply ends after the five.
- **Control:** a native `<select>` inside `.sknob` (34px tall like `.stp`, 4px radius, `--edge-hi` border, `aria-label` "Model for <row title>"). Options, in this order: "Default (<today's model>)", Opus, Sonnet, Haiku, Fable. Today's model in the first option is "Sonnet" for validate and deploy, "Claude Code's" for refine and develop, and the frontmatter model for an agent ("the session's" when the frontmatter names none). While the value is in the draft the select's text and border take `--sand`, like `.stp.dirty output`. When a row is not on Default, the `.sknob small` line reads "default is <today's model>".
- **Cost (stage rows only):** a second `.sknob small` line: the figure in gold mono (`.num`, the dashboard's existing cost format) followed by the `.est` mark, then muted "per card · N cards, last 7 days". It describes past runs and does not change while a draft is open. A null cost shows the muted sentence "No priced run in the last 7 days." and no figure, no `$ 0`, no `$ ?`. Agent rows carry no cost line.
- **Unpriced model (AC-8):** when the row's current value (saved or draft) has no price, a `.sknob small` line in `--warn` appears under the select as soon as it is picked; Save stays enabled. It names the model and the file; no icon.
- **Refused save (AC-5):** the server's message goes in the existing `SET.err` slot of the Save bar (`.bad`), naming key and value; the draft is kept so the owner can fix the row. A value written by hand in `config.yml` that the factory does not know shows the row on Default with a `--warn` line naming the value; a key for a stage or agent that does not exist shows as one `p.note.warn` per key above the first group. Neither blocks saving other rows, and a row the owner did not touch is not rewritten.
- **States:** loading is the Settings view's own (nothing is drawn until `/api/settings` answers); success is the Save bar closing and the row losing its dirty color; there is no empty state, since the four stages and five agents always exist.
- **Small screen:** under 1180px `.srow` is already one column: the select and its lines drop under the description, left-aligned (`.sknob { align-items: flex-start }` inside that media query, which also fixes the Projects knobs), the select `min-width: 12ch`, `max-width: 100%`. The `--warn` line wraps; nothing scrolls sideways.
- **Tokens and rules:** gold only on the cost figure (Coin Rule), every cost followed by "est." (Estimate Rule), `--warn` only on the two warnings, `--sand` only for dirty. No per-model or per-stage color, no badges. Model names are shown capitalised (Opus, Sonnet, Haiku, Fable) and are not translated.
- **Copy** (English in the page, pt-BR in `scripts/lang/dashboard.pt-BR.json`; `rx` entries where a value is interpolated):

| English | pt-BR |
|---|---|
| Agents and models | Agentes e modelos |
| which model runs each role | qual modelo roda cada papel |
| Which model each stage's session and each agent runs on. Default keeps the model the plugin ships with. A change takes effect on the dispatcher's next cycle; sessions already running keep their model. | Em qual modelo roda a sessão de cada estágio e cada agente. Padrão mantém o modelo que vem com o plugin. A mudança vale a partir do próximo ciclo do dispatcher; as sessões que já estão rodando continuam no modelo delas. |
| Stages / Agents | Estágios / Agentes |
| Model for {row} | Modelo de {row} |
| Default ({model}) | Padrão ({model}) |
| Claude Code's / the session's | o do Claude Code / o da sessão |
| default is {model} | o padrão é {model} |
| per card · {n} card(s), last 7 days | por card · {n} card(s), últimos 7 dias |
| No priced run in the last 7 days. | Nenhuma execução com preço nos últimos 7 dias. |
| No price for {model} in prices.yml: its cost cannot be estimated. | Sem preço para {model} em prices.yml: não dá para estimar o custo. |
| config.yml says "{value}", which the factory does not know. Runs use the default until you pick a model. | O config.yml diz "{value}", que a fábrica não conhece. As execuções usam o padrão até você escolher um modelo. |
| config.yml names {key}, which is not a stage or an agent here. It is ignored. | O config.yml cita {key}, que não é um estágio nem um agente daqui. Ele é ignorado. |
| {key}: "{value}" is not a model the factory knows. Nothing was saved. | {key}: "{value}" não é um modelo que a fábrica conhece. Nada foi salvo. |
| Writes the Product section of a spec. (product-owner) | Escreve a seção Product da spec. |
| Writes the UX section and checks the screens in validation. (ux-designer) | Escreve a seção UX e confere as telas na validação. |
| Writes the acceptance tests before the code. (qa-engineer) | Escreve os testes de aceitação antes do código. |
| Implements a layer that names no agent of its own. (engineer) | Implementa uma camada que não indica um agente próprio. |
| Writes the Security section and reviews the diff. (cybersec) | Escreve a seção Security e revisa o diff. |
| Project agent · {project}, layer {layer} | Agente do projeto · {project}, camada {layer} |

## Architecture
_Tech Lead_

**Layer and files:** `factory` only.
- Changes: `scripts/shipfloor_config.py`, `scripts/dispatch.sh`, `scripts/shipfloor` (doctor), `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `skills/refine/SKILL.md`, `skills/develop/SKILL.md`, `skills/validate/SKILL.md`, `skills/deploy/SKILL.md`, `README.md`.
- Creates: `scripts/test/models.test.sh`, `scripts/test/dispatch-models.test.sh`, `scripts/test/dashboard-models.test.sh`.
- Not touched: `agents/*.md` (the frontmatter model stays as each agent's default), a project's `.claude/agents`, `.shipfloor/factory.yml`, `templates/prices.yml`.

**Config contract** (`~/.shipfloor/config.yml`, machine-wide, both maps optional)
```yaml
models:
  stages: {develop: sonnet}        # keys: refine, develop, validate, deploy
  agents: {engineer: haiku}        # keys: a plugin agent or a registered project's layers[].agent
```
- A model is one of `MODELS = ("opus", "sonnet", "haiku", "fable")`: the names both `claude --model` and the Agent tool's `model` accept.
- Defaults live in `shipfloor_config.py`: `STAGE_MODELS = {"refine": None, "develop": None, "validate": "sonnet", "deploy": "sonnet"}` (None = no `--model` flag) and `PLUGIN_AGENTS = {"product-owner": "opus", "ux-designer": "opus", "qa-engineer": "sonnet", "engineer": "sonnet", "cybersec": "opus"}` (what the frontmatter says; used for validation and for the "Default (…)" label only).
- `machine set` and the dashboard's writes keep `models` as they find it (they already round-trip the whole file).

**`shipfloor_config.py`**
- `model_problems(raw, project_agents=())` → list of `{"key": "models.agents.x", "value": ..., "why": "model" | "name" | "shape"}`: unknown model, unknown stage or agent name, `models` or a map that is not a mapping.
- `model_problems` is not part of `machine_problems`: `machine validate` stays 0 on a bad model, so the dispatcher (which exits 2 on an invalid `config.yml`) keeps running.
- `models_of(raw, project_agents=())` → `{"stages": {stage: model or None}, "agents": {name: model}}` with the defaults applied to stages and every problem entry dropped (it falls back to today's model).
- `machine stage-models`: the four stage models in `STAGES` order, NUL-terminated, empty for "no flag" (same shape as `machine values`).
- `machine models-check [<project agent>...]`: one line per problem on stderr (`models.agents.x: "gpt" is not a model the factory knows (opus, sonnet, haiku, fable)` / `models.stages.x: not a stage or an agent here`), exit 1 when any, else 0.
- `describe` gains one line after `language:`, only when at least one valid agent entry is set: `agent models: engineer=haiku, qa-engineer=opus`. It reads the machine `config.yml` beside the projects folder (the same file `shipfloor_machine` reads) and passes this project's `layers[].agent` names as `project_agents`; an unreadable file prints no line.

**`dispatch.sh`**
- Beside the `POOL` read: `mapfile -d '' -t STAGE_MODEL < <(shipfloor_machine stage-models)`, once per cycle.
- In `launch`, the `case "$p" in validate|deploy` line becomes: add `--model <name>` when the stage's entry is not empty. With no `models` key the command lines are byte-for-byte today's.
- A lock already running is never touched: the model is read only when a run starts.

**Skills** (`skills/refine|develop|validate|deploy/SKILL.md`, one sentence each next to the `Project:` paragraph)
- "When describe prints `agent models:` and it names the agent you are about to call, pass that model as the Agent tool's `model`; otherwise pass none." That covers plugin agents and a layer's own agent alike, and overrides the frontmatter for that call only.

**`shipfloor doctor`**
- After the project loop: `shipfloor_machine models-check <every valid project's layer agents>`; each problem line is printed as `WARN models: <line>`; none → `ok   models`. A WARN, not a FAIL: the factory runs on the defaults.

**Dashboard API**
- `GET /api/settings` gains `models`:
  ```json
  {"choices": ["opus", "sonnet", "haiku", "fable"],
   "stages": {"develop": {"value": null, "default": null, "priced": true, "cost": {"avg": 3.41, "cards": 6}}},
   "agents": {"engineer": {"value": "haiku", "default": "sonnet", "priced": true, "projects": []}},
   "problems": [{"key": "models.agents.x", "value": "gpt", "why": "model"}]}
  ```
  - `value`: the valid configured model or null; `default`: today's model or null ("Claude Code's" for a stage, "the session's" for a project agent).
  - `agents`: the five plugin agents, then every registered project's `layers[].agent` that is not one of them, with `projects: [{"project", "layer"}]`.
  - `priced`: false when `value` is set and no `prices.yml` key matches `claude-<value>-*`; true otherwise.
  - `cost`: over every project's sessions that started in the last 7 days, grouped by (project, issue, stage): a card's cost is the sum of its sessions of that stage, subagents included; a card with an unpriced session is left out; `avg` is the mean rounded to 2 places, or null when `cards` is 0. Reuses `sessions()`, `session_cost()` and the transcript cache.
- `POST /api/settings/machine` accepts `models: {"stages": {name: model | null}, "agents": {name: model | null}}`: null removes the key, empty maps and an empty `models` are pruned, keys not in the request are left as they are (a hand-written bad value survives until the owner changes that row). A problem the change introduces → 400 with `"<key>: \"<value>\" is not a model the factory knows. Nothing was saved."` and the file is not written. Problems that were already in the file do not block the save.

**`dashboard.html`**
- The `models` section as in `## UX`; draft keys `m|stages|<name>` and `m|agents|<name>` in `SET.draft`, sent by `setSave` inside the one `machine` request; `setWas` and the draft-clearing rule learn the `m|` prefix.
- The Sessions tab already lists a subagent's models from its transcript (`s.subagents[].tokens` keys): no change there.

**Migration:** none. No `models` key means today's behaviour, and nothing writes the key until the owner does.

**Test notes**
- `scripts/test/models.test.sh` (config and skills, no server): `stage-models` with and without `models` (AC-2); `describe` prints `agent models: engineer=haiku` and the four skills carry the rule that passes it to the Agent tool (AC-3); a project agent from the fixture's `layers[].agent` is accepted and printed (AC-4); `models-check` and `shipfloor doctor` report an unknown model, stage and agent while `machine validate` stays 0 and `stage-models` falls back (AC-5); `PLUGIN_AGENTS` matches the `model:` line of every `agents/*.md`.
- `scripts/test/dispatch-models.test.sh` (same fake `claude` as `scripts/test/dispatch-launch.test.sh`): `models.stages.develop: sonnet` → the develop log has `--model sonnet` (AC-1); `models.stages.validate: opus` → `--model opus`; a bad value → today's flags and the dispatcher still exits 0.
- `scripts/test/dashboard-models.test.sh` (same server setup as `scripts/test/dashboard.test.sh`, transcripts dated inside and outside the 7 days): POST saves to `config.yml`, a later `stage-models` reads it, null removes the key, a bad model is 400 and the file is unchanged (AC-6); `cost.avg` and `cards` per stage, null with no priced run (AC-7); `priced: false` for a model missing from a test `prices.yml`, and the save still succeeds (AC-8); the page carries the section's strings and the pt-BR catalog has them.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dispatch-models.test.sh` |
| AC-2 | factory | `scripts/test/models.test.sh` |
| AC-3 | factory | `scripts/test/models.test.sh` |
| AC-4 | factory | `scripts/test/models.test.sh` |
| AC-5 | factory | `scripts/test/models.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-models.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-models.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-models.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a (no data migration; removing `models` from `config.yml` restores today's behaviour)

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Models are the four aliases `opus`, `sonnet`, `haiku`, `fable`, not full model ids: they are what both `claude --model` and the Agent tool's `model` take, and they survive a model release.
- Unset stays unset: refine and develop get no `--model` flag (Claude Code's default), validate and deploy keep `sonnet`; the issue's example map with `opus` for refine and develop is not written as a default, since AC-2 asks for today's behaviour.
- A bad `models` entry is a warning, never an invalid `config.yml`: the dispatcher exits on an invalid machine config, and one mistyped model must not stop the factory (AC-5).
- The agent model is passed at call time by the stage skill (Agent tool `model`), read from a new `describe` line: no agent file is rewritten, so a project's `.claude/agents` (a forbidden path) needs no change and plugin updates lose nothing.
- `agents/*.md` keep their `model:` line as the default; a test keeps `PLUGIN_AGENTS` in step with them.
- AC-3's "runs on Haiku" is tested up to the factory's edge (the `describe` line and the skills' rule); the transcript of a real subagent is seen on the first card that runs with the setting, since a test cannot start a paid session.
- Agent names are checked against the plugin's five agents plus the registered projects' `layers[].agent`: that is every agent a stage can start.
- The 7-day cost is machine-wide (all projects together), like the setting itself; a card with an unpriced session is left out of the average rather than counted low.
- The cost shown after a model change is still the past 7 days on the earlier model, labelled "last 7 days": a projection is out of scope (UX's question, decided).
- A stage's own model with no price is not warned about when the row is on Default for refine and develop: the factory does not know which model Claude Code's default is.
- Settings saves only the rows the owner changed and refuses only problems the change introduces: a hand-written bad value is shown with its warning and does not block other settings (UX's two points, confirmed).
- A project agent with no known default shows "Default (the session's)": the dashboard does not read a project's `.claude/agents`.
- No `shipfloor` CLI command for models: the issue asks for the config key and the Settings section; the file is one line to edit by hand.
- New test files instead of growing `scripts/test/dispatch-launch.test.sh` and `scripts/test/dashboard.test.sh`: acceptance tests in their own files keep `acceptance-intact` simple.
- UX was called although the issue has no `ui` label: the PO wrote "Touches UI: yes". No Cybersec: no `cybersec` label.
- The Save bar and dirty state use `--sand` as the Settings code does today, not the azure `DESIGN.md` names: one screen, one convention; aligning the two is a separate card.

## Open questions
- none
