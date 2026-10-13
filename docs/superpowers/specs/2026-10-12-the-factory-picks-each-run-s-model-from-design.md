# The factory picks each run's model from the card's weight, and steps up when it fails — spec

**Issue:** #133 · **Branch:** `feat/133-the-factory-picks-each-run-s-model-from` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** A run's model is fixed per stage and per agent, so a one-line fix costs the same per token as a change across three layers; Opus is 66% of the estimated spend (152 runs, list prices, measured 2026-10-12) and the Refine and Develop lead sessions alone are 56%.
**Audience:** The factory's owner, a developer who runs Shipfloor on their own machine.
**Acceptance criteria**
- **AC-1** — Given a card in Technical Refinement, when Refine finishes, then the spec records exactly one weight (`light`, `standard` or `heavy`), and the refine gate fails a spec with no weight or any other value.
- **AC-2** — Given the default table, when a develop session starts, then a `light` or `standard` card starts with `--model sonnet` and a `heavy` card with `--model opus`.
- **AC-3** — Given a spec refined before this change (no weight), when its develop run starts, then it runs as `standard` and is not refused.
- **AC-4** — Given a develop run below the top model that ends with a failed gate, when the dispatcher picks the card up again, then it runs once more one model up, and the run's log and the Feed name both models and the reason.
- **AC-5** — Given a run that already stepped up, or that ran on the top model, when it fails a gate, then no further step-up run is started and the failure is handled as it is today.
- **AC-6** — Given a card in Spec Review, when the owner changes its weight there and approves, then the card shows the new weight and the next run uses the model for it.
- **AC-7** — Given Settings > Agents and models, when the owner sets a model per weight for a stage and saves, then the machine's config holds it and the dispatcher's next cycle starts runs with it, without a restart.
- **AC-8** — Given a card with a weight, when the owner opens it in the dashboard, then the card shows its weight and the Sessions tab shows the model each session ran on, the stepped-up one included.
**Out of scope:** Changing models in the middle of a session; routing by anything the factory cannot read from the spec; the weight table for agents (they keep their per-agent model); History totals broken down per model; step-up for Refine, Validate and Deploy runs (their defaults stay as the issue states: Refine on Sonnet with Opus as the owner's choice, Validate and Deploy as today); more than one step-up per run.
**Product fit:** Serves principle 2 (the step-up is triggered by a failed gate, not by an agent's judgment of its own work, and the weight is checked by the refine gate) and principle 4 (the owner sets the weight only in Spec Review, where the factory already waits). Principle 3 holds: the model of each session stays read from the transcripts, and the savings stay an estimate. No conflict with the positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

Copy is `English` → `pt-BR` (an `exact` or `rx` entry in `scripts/lang/dashboard.pt-BR.json` for each). The weights show as `light`, `standard`, `heavy` → `leve`, `normal`, `pesado` (`normal`, because `Padrão` already translates "Default" in the same selects); the spec line keeps the English value. No new component, token or color: a weight is never color-coded and never the accent.

- **Settings > Agents and models, stage rows.** Develop, Validate and Deploy show three selects in the row's `.sknob`, side by side, each under a caption (`Light`, `Standard`, `Heavy` → `Leve`, `Normal`, `Pesado`); each is today's select with today's options (`Default (Sonnet)` first, so Validate and Deploy read "Default" three times until the owner changes one). `aria-label`: `Model for Develop, light cards` → `Modelo de Develop, cards leves` (same for standard → `normais`, heavy → `pesados`). Refine keeps its single select, and its description gains `Runs before the card has a weight, so it has one model.` → `Roda antes de o card ter peso, então tem um modelo só.`
- **Same rows, states.** A changed select turns sand and counts as one change in the existing save bar; Discard and Save as today. The `default is …`, no-price and unknown-value notes stay as they are, one line each under the trio, prefixed with the weight when it is not obvious (`Heavy: ` → `Pesado: `). The 7-day cost line stays one per stage. Up to 1180px the trio stays on one line under the description; under 600px the three selects stack, caption at the left of each.
- **Same section, lead** (replaces today's): `Which model each stage's session and each agent runs on. A stage picks its model from the card's weight, which Refine writes in the spec; a card with no weight runs as standard. A Develop run that fails a gate runs once more, one model up. Default keeps the model the plugin ships with. A change takes effect on the dispatcher's next cycle; sessions already running keep their model.` → `Em qual modelo roda a sessão de cada estágio e cada agente. O estágio escolhe o modelo pelo peso do card, que o Refine escreve na spec; um card sem peso roda como normal. Uma execução de Develop que falha em um gate roda mais uma vez, um modelo acima. Padrão mantém o modelo que vem com o plugin. A mudança vale a partir do próximo ciclo do dispatcher; as sessões que já estão rodando continuam no modelo delas.`
- **Card drawer, head.** One `.tag` at the end of the meta line, after the column and state: `weight: heavy` → `peso: pesado`. A card whose spec has no weight line shows `weight: standard` with `title` `The spec names no weight, so the card runs as standard.` → `A spec não diz o peso, então o card roda como normal.` A card with no spec yet (before Refine ends) shows no tag. The tag wraps with the meta line on a narrow drawer.
- **Where the owner changes it (AC-6): the decision block of the drawer, Spec Review cards only**, not the review page (its iframe is sandboxed and sends nothing, and the decision is where the factory already waits). A line between the "Your decision" heading and Approve: label `Weight` → `Peso`, a native `<select id="weight">` (styled as the Settings select, 8px radius) with the three weights, then a hint in muted 12.5px: `Develop will run on Sonnet.` → `O Develop vai rodar em Sonnet.` (the model the table gives that weight now). With no weight line the select sits on Standard and the hint is the no-weight sentence above. Staged cards and every other column show only the tag.
- **Changing it.** Choosing an option sends the one POST at once; there is no extra button. While it is in flight the select and Approve are disabled (progress cursor) and the hint reads `Saving…` → `Salvando…`. Success: the select, the head's tag and the hint show the new weight, and the existing `#notice` (polite live region) says `Weight is now heavy. Develop will run on Opus.` → `O peso agora é pesado. O Develop vai rodar em Opus.` Failure: the select returns to the previous weight, focus stays on it, and the notice (bad) says `The weight was not changed: <reason>` → `O peso não foi alterado: <motivo>`; when the card already left the column the reason is `the card is no longer in Spec Review.` → `o card não está mais em Spec Review.`
- **The review and the decision keep their state.** Writing the weight must not reset the owner's review marks or the typed request-changes text, and Approve's doubt state (soft, asks twice) is unchanged by it. The review page does not show the weight (it renders no spec header, and a rebuilt page would drop the marks): the drawer's tag and select are where it is read.
- **Keyboard and focus.** The select is in the tab order before Approve, opens and moves with the browser's own keys, and keeps the 2px sand focus ring; no new shortcut, and A/R/L/N are untouched. The 5-second card refresh never rewrites the select while it is focused or open (same guard as `#every` and `#lang`).
- **Narrow drawer (under 540px).** Label and select share one line, the hint wraps under them; the rest of the decision stacks as today.
- **Sessions tab.** No new column: the model stays in `stage · model`. The stepped-up session adds a plain `.tag` after the model, `stepped up` → `subiu de modelo`, with `title` `Ran one model up after Sonnet failed a gate: build.` → `Rodou um modelo acima depois que o Sonnet falhou em um gate: build.` The gate names are raw (never translated).
- **Feed.** The stepped-up run's row gains one piece on its second line, first in the line: `stepped up from Sonnet to Opus: the run before failed build` → `subiu de Sonnet para Opus: a execução anterior falhou em build`. The failed run's own row keeps `gates failed: build` and adds `runs again on Opus` → `roda de novo em Opus`. No new filter, mark or color; a second failure reads as any failure does today.
- **Empty and loading.** While the card loads, the head shows no tag and the decision line shows the select disabled with no hint; nothing is guessed before the spec is read.

## Architecture
_Tech Lead_

One layer, `factory`. No migration, no new dependency.

**Contracts**
- **Spec header line** `**Weight:** light|standard|heavy`, on its own line before the first `## ` (`templates/spec-template.md`). It is the only place a weight is stored.
- **`gate.sh weight <spec>`** (new): pass when the header has exactly one such line with one of the three values; exit 1 otherwise (none, two, another value), exit 2 when the spec is missing. Refine runs it in step 6, before the commit.
- **`gate.sh`, every gate:** when `SHIPFLOOR_RUN_LOCK` names a directory, the verdict is also written to `<lock>/last-gate` as `<gate name>\t<pass|FAIL|INFRA>` (overwritten by each gate). This is how the dispatcher knows a run ended on a failed gate without asking the agent.
- **Machine config `models.stages.<stage>`:** a model (every weight, as today) or a mapping `{light, standard, heavy}` → model; a weight left out keeps its default. `refine` takes a model only (a mapping there is a `shape` problem). Defaults (`shipfloor_config.STAGE_MODELS`): refine `sonnet`; develop `sonnet`, `sonnet`, `opus`; validate and deploy `sonnet` for every weight. `model_problems` gains keys `models.stages.<stage>.<weight>` (`name` for an unknown weight, `model` for an unknown model); a problem entry keeps the default, as today.
- **`shipfloor-config machine stage-models`:** prints 12 NUL-ended values, the four stages in order × light, standard, heavy (was 4). `dispatch.sh` reads them once per cycle, as today.
- **`shipfloor_config.MODEL_LADDER = ("haiku", "sonnet", "opus")`** and **`machine model-up <model>`**: prints the next model up, nothing for the top one or a model outside the ladder (`fable`).
- **`lib/project.sh` `shipfloor_card_spec <n>`:** the card's spec in its worktree (`<worktrees>/<n>/<specs>*-<slug>-design.md`, slug from the worktree's branch, as `deploy.sh` finds it today; `deploy.sh` uses the helper). **`shipfloor_card_weight <n>`:** the header's weight, `standard` when there is no worktree, no spec, no line or another value.
- **`dispatch.sh launch`:** the model is `stage-models[<stage>][<weight of the card>]`, replaced by the step-up marker's model when `<home>/stepup/<n>` exists (develop only). The start line carries it: `== start /sf:develop <n> <ts> pid=<pid> model=<model> weight=<weight>` (trailing fields, `RUN_LINE` already ignores what follows the time).
- **Step-up, in `launch` after a develop agent ends** (before the lock goes): if the agent exited 0, `<lock>/last-gate` says `FAIL`, there is no `<home>/stepup/<n>` and `model-up` of the run's model prints a model, then write `<home>/stepup/<n>` (`<from>\t<to>\t<gate>`), `board.sh label <n> remove blocked`, and log `== step-up /sf:develop <n> <from> -> <to>: gate <gate> failed <ts>`. The card is then an orphan in Coding and the next cycle resumes it, on `<to>`, inside the pool, the hours and the cost limits as any run. Otherwise nothing changes: the card stays blocked as today (AC-5). `INFRA` never steps up (the infra retry owns it).
- **Marker life:** `<home>/stepup/<n>` stays while the card is in Coding (an unblocked card keeps the higher model and never steps again) and is removed by the dispatcher when the board snapshot shows the card in another column or gone, the way `cost/<n>.json` goes.
- **`shipfloor weight <project> <n> <light|standard|heavy>`** (new, owner only): refuses unless the card is in Spec Review with no live run; rewrites (or adds) the header line in the worktree's spec, commits `docs(<slug>): weight <weight> for #<n>` and pushes the branch; a failed push undoes the commit and exits 1 with the reason. It does not rebuild the review page, so the owner's marks and typed text stay.
- **`POST /api/card/<project>/<n>/weight`** body `{"weight": "light|standard|heavy"}` → runs `shipfloor weight`; `200 {"weight", "model"}`, `400` for another value, `409 {"error": "the card is no longer in Spec Review."}`, `500 {"error"}` with the command's reason.
- **`GET /api/card/...`** gains `weight` (`null` when the card has no spec yet), `weight_set` (the spec has the line), `weight_models` (`{light, standard, heavy}` → what the table gives Develop now); each session gains `model` (from its run's start line, else the transcript's main model) and `stepped` (`{"from", "gates": [..]}` or `null`, from the `== step-up` line before its run).
- **Feed** (`feed_runs`): a run event gains `model`; the stepped-up run gains `stepped: {"from", "to", "gates"}` and the failed run before it `again: "<to>"`.
- **`GET /api/settings` `models.stages.<stage>`:** `value` and `default` become `{light, standard, heavy}` for develop, validate and deploy (a configured single model fills the three); refine keeps one value. **`POST /api/settings/machine` `models.stages.<stage>`** accepts a model, `null`, or a mapping whose `null` removes that weight; three equal weights are saved as they are sent (no rewrite of a hand-written single model unless that stage is in the request).

**Files**
- `scripts/shipfloor_config.py`, `scripts/lib/project.sh`, `scripts/dispatch.sh`, `scripts/gate.sh`, `scripts/deploy.sh` (helper only), `scripts/shipfloor` (the `weight` command and its usage line), `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `scripts/lang/pt-BR.sed` (the two new dispatcher lines).
- `templates/spec-template.md` (the `**Weight:**` header line), `skills/refine/SKILL.md`: step 6 sets the weight from the spec and runs `gate.sh weight`; the rework rule compares a "Spec review" comment with the last `spec for #<n>` commit (an owner's `weight ... for #<n>` commit is not one), and a rework keeps a weight the owner set.
- **How Refine sets the weight** (written in the skill, checked only for validity by the gate): `heavy` when the spec touches 2+ layers, or has a `## Security` section filled, or a destructive migration, or more than 6 acceptance criteria, or more than 8 files in `## Architecture`; `light` when it touches one layer, has at most 3 acceptance criteria and 3 files, `Touches UI: no` and no security section; `standard` otherwise.
- `docs/configuration.md` (`models.stages` per weight, the new defaults), `docs/how-it-works.md` (weight and step-up), `DESIGN.md` only if it lists the Settings rows or the drawer's decision block.
- Tests of earlier cards that assert the old defaults change with them: `scripts/test/dispatch-models.test.sh`, `scripts/test/dispatch-launch.test.sh`, `scripts/test/dashboard-models.test.sh`, `scripts/test/models.test.sh`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-weight.test.sh` |
| AC-2, AC-3 | factory | `scripts/test/dispatch-weight.test.sh` |
| AC-4, AC-5 | factory | `scripts/test/dispatch-stepup.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-weight.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-models.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-weight.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a — nothing destructive. Reverting the change leaves `**Weight:**` lines in specs (ignored) and `<home>/stepup/` files (ignored); a `models.stages.<stage>` mapping written by the new Settings must be turned back into one model by hand, or the old code reports it as a model it does not know and uses its default.

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The weight lives only in the spec header, on the card's branch — one source for the gate, the dispatcher, the dashboard and GitHub; no label or machine-local copy to drift.
- The owner changes it from the drawer's decision block with one POST that commits and pushes the line; it saves when the option is chosen, not with Approve — a failed write is seen before the card moves (the UX designer's question, decided).
- No Refine rerun to change a weight — a rerun would cost more than the change saves.
- The weight write does not rebuild the review page, and the page does not show the weight — a rebuilt page starts clean and would drop the owner's marks.
- Step-up is decided by the dispatcher from the last gate's verdict (`last-gate` in the run's lock), not from the agent's report — product principle 2.
- The stepped-up run starts on the dispatcher's next cycle as a resumed orphan, not inside the failed run — it then respects the pool, the working hours and the cost limits.
- The step-up marker lasts while the card is in Coding — a card that already failed on the cheaper model keeps the higher one after an unblock, and steps up once per card's Develop, not once per run.
- Ladder is haiku → sonnet → opus; `fable` and a stage on the owner's default model (no `--model`) never step up — the factory cannot rank a model it does not name.
- Develop only steps up; Refine, Validate and Deploy fail as today (PO's scope call).
- Refine takes one model, not three — it runs before the weight exists; its default moves from the owner's default to Sonnet, as the issue states.
- Validate and Deploy get the per-weight table with Sonnet for every weight — "as today" by default, and the owner can raise heavy cards.
- A single model in `models.stages.<stage>` keeps meaning "every weight" — configs written before this keep working.
- Agents keep their per-agent model; no weight table for them, and no History totals per model (the issue says "may" and "can then be read"; PO's scope call).
- A new gate `weight`, not a check inside `test-plan` — Refine may publish with a failing `test-plan` (no layer fits), and a missing weight must always refuse.
- The thresholds of light and heavy are a rule in the refine skill, not code — the gate checks only that a valid weight is there, and the owner corrects a wrong call in Spec Review.
- pt-BR shows `standard` as `normal` — `Padrão` already means "Default" in the same selects (UX call).
- This spec carries no `**Weight:**` line — the factory that refined it does not know the line yet; it will run as `standard`, or as the owner's default model until the change is installed.

## Open questions
- none
