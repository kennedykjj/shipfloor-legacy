# Models per stage and per agent are configuration, not code — plan for #34

**Goal:** `~/.shipfloor/config.yml` gains an optional `models` map (`stages`, `agents`). The dispatcher reads each stage's model from it, the stage skills pass an agent's configured model to the Agent tool, `shipfloor doctor` reports bad entries, and Settings gets an "Agents and models" section with the 7-day average cost per card for each stage.

**Spec:** `docs/superpowers/specs/2026-10-11-models-per-stage-and-per-agent-are-confi-design.md`

**Layers:** `factory` only (path `./`, agent `engineer`, Bash and Python 3; the dashboard is one HTML file, no build).

## Constraints

- With no `models` key every command line is byte-for-byte today's: validate and deploy carry `--model sonnet`, refine and develop carry no `--model`.
- A bad `models` entry never makes `config.yml` invalid: `machine validate` stays 0 (the dispatcher exits 2 on an invalid machine config), and the bad key falls back to today's model.
- `agents/*.md`, a project's `.claude/agents`, `.shipfloor/factory.yml` and `templates/prices.yml` are not touched.
- The dashboard's writes round-trip the whole file: `models` survives a save of any other setting, and a row the owner did not touch is not rewritten.
- A cost is never shown as zero when nothing was priced: `avg` is null with `cards: 0`.
- Minimal change: no new component in the page, no new CLI command, no dead code, no narrating comments.
- `scripts/test/dispatch-launch.test.sh`, `scripts/test/dashboard.test.sh` and the rest of the suite keep passing unchanged.

## Tasks

### Task 0 — Acceptance tests (QA, before any implementation)

- **Owner:** `qa-engineer`
- **Files:** creates `scripts/test/models.test.sh`, `scripts/test/dispatch-models.test.sh`, `scripts/test/dashboard-models.test.sh`
- AC-1 to AC-8 as the spec's test plan and test notes say:
  - `scripts/test/models.test.sh` (AC-2, AC-3, AC-4, AC-5): config and skills, no server.
  - `scripts/test/dispatch-models.test.sh` (AC-1): the fake `claude` of `scripts/test/dispatch-launch.test.sh`.
  - `scripts/test/dashboard-models.test.sh` (AC-6, AC-7, AC-8): the server setup of `scripts/test/dashboard.test.sh`, transcripts dated inside and outside the 7 days, a test `prices.yml`.
- Each AC must fail on the current code with a message that names the missing behaviour.

### Task 1 — The setting, the dispatcher, doctor and the skills

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 0
- **Files:** changes `scripts/shipfloor_config.py`, `scripts/dispatch.sh`, `scripts/shipfloor`, `skills/refine/SKILL.md`, `skills/develop/SKILL.md`, `skills/validate/SKILL.md`, `skills/deploy/SKILL.md`

`scripts/shipfloor_config.py`:
- `MODELS`, `STAGE_MODELS` and `PLUGIN_AGENTS` as the spec's config contract gives them.
- `model_problems(raw, project_agents=())` and `models_of(raw, project_agents=())` as specified; `model_problems` stays out of `machine_problems`.
- `machine stage-models`: the four stage models in `STAGES` order, NUL-terminated, empty for "no flag".
- `machine models-check [<project agent>...]`: one line per problem on stderr in the spec's two wordings, exit 1 when any.
- `describe` prints `agent models: <name>=<model>, ...` after `language:` only when at least one valid agent entry is set, reading the machine `config.yml` beside the projects folder and passing this project's `layers[].agent` names; an unreadable file prints no line.

`scripts/dispatch.sh`:
- `mapfile -d '' -t STAGE_MODEL < <(shipfloor_machine stage-models)` beside the `POOL` read, once per cycle.
- In `launch`, the `case "$p" in validate|deploy` line adds `--model <name>` when the stage's entry is not empty. A running lock is never touched.

`scripts/shipfloor` (doctor):
- After the project loop: `shipfloor_machine models-check <every valid project's layer agents>`; each line as `WARN models: <line>`, none → `ok   models`. A WARN, not a FAIL.

Skills: one sentence next to the `Project:` paragraph of each of the four stage skills, the same in all four: when describe prints `agent models:` and it names the agent about to be called, pass that model as the Agent tool's `model`; otherwise pass none.

**Done when:** `scripts/test/models.test.sh` and `scripts/test/dispatch-models.test.sh` pass.

### Task 2 — Dashboard API: models in Settings, cost per stage

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 1
- **Files:** changes `scripts/dashboard.py`, `scripts/dashboard_cost.py`

- `GET /api/settings` gains `models` in the spec's shape: `choices`, `stages` (`value`, `default`, `priced`, `cost: {avg, cards}`), `agents` (the five plugin agents, then every registered project's `layers[].agent` that is not one of them, with `projects`), `problems`.
- `priced` is false only when `value` is set and no `prices.yml` key matches `claude-<value>-*`.
- `cost`: every project's sessions started in the last 7 days, grouped by (project, issue, stage); a card's cost sums its sessions of that stage, subagents included; a card with an unpriced session is left out; `avg` rounded to 2 places, null when `cards` is 0. Reuses `sessions()`, `session_cost()` and the transcript cache.
- `POST /api/settings/machine` accepts `models: {"stages": {...}, "agents": {...}}`: null removes a key, empty maps and an empty `models` are pruned, keys not in the request stay as they are. A problem the change introduces → 400 with the spec's message and no write; problems already in the file do not block.

**Done when:** the API cases of `scripts/test/dashboard-models.test.sh` pass (AC-6 save and removal, AC-7, AC-8 `priced`).

### Task 3 — The Settings section, its catalog and the README

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 2
- **Files:** changes `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `README.md`

- The `models` entry in `secs` right after Sessions and the section as the spec's `## UX` says: two `.sgroup.panel` groups, one `row` per stage and per agent, a native `<select>` in `.sknob`, the cost line on stage rows, the two `--warn` lines, the `p.note.warn` per unknown key.
- Draft keys `m|stages|<name>` and `m|agents|<name>` in `SET.draft`, sent by `setSave` inside the one `machine` request; `setWas` and the draft-clearing rule learn the `m|` prefix. A refused save keeps the draft and shows the server's message in `SET.err`.
- Under 1180px: `.sknob { align-items: flex-start }`, the select `min-width: 12ch`, `max-width: 100%`.
- Every string of the spec's copy table in the page and in `scripts/lang/dashboard.pt-BR.json` (`rx` entries where a value is interpolated).
- `README.md`: the `models` key with its two maps, the four model names, and that unset keys keep the shipped models.

**Done when:** every acceptance test of the three files passes and the layer's build (`TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main`) is green.

## Review focus

- No `models` key: the dispatcher's command lines are unchanged, and nothing writes the key until the owner does.
- A bad value in the file: the dispatcher still exits 0 and uses today's model for that key; doctor warns; Settings shows it and does not rewrite it.
- The cost average leaves out a card with an unpriced session instead of counting it low, and is null (not 0) with no priced run.
- Gold only on the cost figure, every cost followed by "est.", `--warn` only on the two warnings.
