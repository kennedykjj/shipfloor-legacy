# Cost limits: flag and block a card, stop starting runs for the day — spec

**Issue:** #36 · **Branch:** `feat/36-cost-limits-flag-and-block-a-card-stop-s` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The dashboard estimates what each card and each day cost, but nothing acts on it: a card that goes in circles keeps spending (one passed US$ 27 on 2026-10-11 while most end under US$ 12) and the day passed US$ 90 with no signal.
**Audience:** The factory's owner, who runs Shipfloor on their own machine and checks the dashboard in quick visits.
**Acceptance criteria**
- **AC-1** — Given `costs.card_warn: 20` and a card whose estimate is US$ 21, when the owner opens the dashboard, then the card is flagged as over the warning in the In progress panel and on the lifecycle board.
- **AC-2** — Given `costs.card_block: 40` and a card whose estimate is US$ 41, when the dispatcher would start its next run, then no run starts, the card gets the `blocked` label and a comment giving the estimated total and the estimate per stage, labeled as an estimate.
- **AC-3** — Given a card blocked by cost, when the owner opens it in the decision inbox, then the "why" is the spend per stage against the limit, and unblocking it lets it spend up to `card_block` again, counted from the unblock, before it is blocked once more.
- **AC-4** — Given `costs.day_stop: 80` and today's estimate across all projects is US$ 81, when the dispatcher cycles, then no new run starts, running sessions finish, and the dashboard's alerts line says runs are stopped for the day by the cost limit.
- **AC-5** — Given the day stop is in effect, when the machine's local day changes, then runs start again on the next cycle without the owner doing anything and the alert is gone.
- **AC-6** — Given a card ran on a model with no price, when limits are evaluated, then its estimate is unknown, no card limit flags or blocks it, its runs add nothing to the day total, and the dashboard says the price is missing.
- **AC-7** — Given no `costs` in `config.yml`, or only some of the three keys, when the dispatcher and dashboard run, then each absent limit does nothing and behavior is as today.
- **AC-8** — Given the Settings view, when the owner sets, changes or clears any of the three values in the "Costs" section above the price table, then `config.yml` holds the change, it applies from the next dispatcher cycle, and a value that is not a positive number, or a `card_warn` above `card_block`, is refused with a message.
**Out of scope:** Cutting a session that is already running (a run may carry a card or the day past its limit); budgets per project or per month; real billing (numbers stay an estimate from tokens and `prices.yml`); a per-card limit override ("raise the limit for this card"): unblocking already grants one more allowance; new decision-inbox actions beyond the existing unblock and send back; notifications outside the dashboard and the card comment.
**Product fit:** Serves principle 3 (limits act on the same sourced estimate the dashboard shows, and every figure says it is an estimate) and principle 4 (the owner is called only when a card waits on them); the block lives on the board as the `blocked` label and a comment, so principle 1 holds. No contradiction with the positioning: the limit is enforced by the dispatcher from the transcripts, not by an agent's word.
**Touches UI:** yes

## UX
_UX/UI Designer_

All in `scripts/dashboard.html`; no new color token, no new action. Figures are mono (`.num`), written `$41.20` like every cost on the page, and each one carries "est.". Copy is given as English / pt-BR; every pt-BR line is an entry in `scripts/lang/dashboard.pt-BR.json` (`exact`, or `rx` where it holds a number). With no limit set, none of the below renders (AC-7).

- **Over-warning flag, In progress (AC-1).** A `.tag.warn` right after `.tcost` in the tile's `.thead`, on running and waiting tiles: "over $20 est." / "acima de $20 est.", `title` "This card's estimate passed the warning set in Settings, Costs. Nothing stops until the block limit." / "A estimativa deste card passou do aviso definido em Configurações, Custos. Nada para até o limite de bloqueio." Text and outline in `--warn`; the cost stays gold, the tile gets no border or fill. `.thead` wraps, so on a narrow tile the flag drops to its own line.
- **Over-warning flag, lifecycle board (AC-1).** The dot keeps its kind and gains `over`: a static 2px `--warn` outline, 2px off, on its `i` (no motion); its `title` and `aria-label` end with ", over the cost warning" / ", acima do aviso de custo". In the peek, the same warn text follows the gold cost on the meta line; in the maximized lanes it is appended to the chip's `small`.
- **Cost block in the inbox (AC-3).** Same reading pane and the same actions (Unblock & retry, Details, Log, GitHub). Changed strings: queue meta "Blocked · cost limit" / "Bloqueado · limite de custo"; heading key "A card reached its cost limit" / "Um card chegou ao limite de custo"; a `.tag.bad` "cost limit" / "limite de custo" where the gate tag sits. "Where it stopped", the test diff and the "left no note" empty line do not render.
- **Its "Why" (AC-3).** One sentence, then the stages: "Spent $41.20 est. since it was last unblocked; the limit for a card is $40.00." / "Gastou $41,20 est. desde o último desbloqueio; o limite por card é $40,00." (never unblocked: "Spent $41.20 est. since Inbox; …" / "Gastou $41,20 est. desde o Inbox; …"). Under it a two-column table in `.swrap`, the Sessions table's style: one row per stage that ran (existing stage names), amount right-aligned, a total row, head "stage" / "est. cost" ("etapa" / "custo est."). When earlier allowances exist, a muted last line: "$83.10 est. since Inbox." / "$83,10 est. desde o Inbox."
- **What unblocking gives (AC-3).** A muted hint under the actions, cost blocks only: "Unblocking lets it spend up to $40.00 more, counted from now." / "Desbloquear deixa o card gastar até mais $40,00, contados a partir de agora."
- **Day stop (AC-4, AC-5).** One `bad` entry in the alerts line, after "Factory paused": **"Runs stopped for today"** "Today's estimate, $81.20, passed the day limit of $80.00. Sessions already running finish; runs start again tomorrow. The limit is in Settings, Costs." / **"Execuções paradas por hoje"** "A estimativa de hoje, $81,20, passou do limite do dia de $80,00. As sessões em andamento terminam; as execuções voltam amanhã. O limite fica em Configurações, Custos." Waiting tiles say why in `.why`, checked right after the pause: "Stopped for today by the cost limit" / "Parado por hoje pelo limite de custo". Both disappear on the first read after the local day changes; nothing to dismiss.
- **Price is missing (AC-6).** The existing gold `$ ?` marker, now also on waiting tiles (today they show no cost when it is unknown), and never an over-warning flag beside it. Its `title` becomes "A model in this card has no price, so its cost is unknown and the cost limits skip it. Add it to ~/.shipfloor/prices.yml." / "Um modelo deste card não tem preço, então o custo é desconhecido e os limites de custo não o contam. Adicione em ~/.shipfloor/prices.yml." Visible without hover, as a `.note.warn` at the foot of the Limits group when any card on the board is unpriced: "2 cards ran on a model with no price. The limits do not count them." / "2 cards rodaram em um modelo sem preço. Os limites não os contam."
- **Settings, Costs: the Limits group (AC-8).** A `.sgroup.panel` above Prices, heading "Limits `~/.shipfloor/config.yml · costs`" / "Limites"; three `row()`s; the nav subtitle becomes "limits and the prices behind the estimate" / "limites e os preços por trás da estimativa". Rows: "Warn on a card" / "Avisar em um card" · "Flags a card whose estimate passes this. Nothing stops." / "Marca o card cuja estimativa passa disto. Nada para."; "Block a card" / "Bloquear um card" · "Its next run does not start and the card waits for your call. Unblocking grants the same amount again." / "A próxima execução não começa e o card espera sua decisão. Desbloquear libera o mesmo valor de novo."; "Stop the day" / "Parar o dia" · "Past this, across every project, no new run starts until tomorrow. Sessions already running finish." / "Acima disto, somando todos os projetos, nenhuma execução começa até amanhã. As sessões em andamento terminam."
- **The control (AC-8).** A stepper does not fit a typed amount that can be empty, so each row holds a text field inside the existing `.sknob`: `inputmode="decimal"`, 9ch, mono, with the stepper's border, radius, 34px height and `.dirty` sand; a "$" prefix in muted; labelled by the row title. The `small` under it reads "no limit" (existing string) when empty and "US$, est." otherwise. Emptying the field is how a limit is turned off. Edits go through the existing save bar ("N changes not saved", Save, Discard); nothing is written on keystroke.
- **Validation (AC-8).** Checked on input; the message replaces the `small` in `--bad`, the field gets `aria-invalid` and `aria-describedby`, and Save is disabled while any field is invalid: "Enter an amount above 0, or leave it empty for no limit." / "Informe um valor acima de 0, ou deixe vazio para sem limite."; on the warning field, "The warning cannot be above the block ($40)." / "O aviso não pode ficar acima do bloqueio ($40)." A refusal from the server shows in the save bar through the existing `SET.err`, and the draft is kept.
- **States.** Loading and failed reads are the existing ones (skeleton in the inbox pane, "Not updating" in the alerts). Success in Settings is the save bar closing with the saved values in the fields; the board follows on the dispatcher's next cycle, as the bar already says.
- **Small screen.** Below 1180px `.srow` already stacks: the field sits under its text, left-aligned (`.sknob` aligns to the start there). The stage table scrolls inside `.swrap`; the alerts line already wraps; the peek keeps its 340px.

## Architecture
_Tech Lead_

One layer, `factory`. No database, no migration.

**Contracts**
- Machine config `~/.shipfloor/config.yml`: optional mapping `costs: {card_warn, card_block, day_stop}`, each a number > 0 in US$ (int or float); `card_warn` ≤ `card_block` when both are set; an unknown key under `costs` is an error. No defaults: an absent key is no limit.
- `scripts/shipfloor_config.py`: `machine_problems(raw)` validates `costs` (so `machine validate`, the dispatcher and the dashboard refuse the same things); `machine values costs.<key>` prints an empty value for an absent key.
- `scripts/dashboard_cost.py`, the shared estimate:
  - `spend(sessions, prices, today)` → `{"cards": {issue: {"total": usd|None, "stages": {stage: usd}}}, "today": usd}`; a card with an unpriced session has `total: None`, and an unpriced session adds nothing to `today`. `Factory.overview()` and `Factory.card()` use it instead of their own sums.
  - `over(spend, costs, baselines)` → `{"day_stop": bool, "warn": [issue], "block": [issue]}`; a card's figure against both card limits is `total - baseline` (baseline: its estimate at its last cost block, 0 if never); a limit acts at `>=`; `total: None` is never in `warn` or `block`.
  - CLI `dashboard_cost.py limits --home <SHIPFLOOR_HOME> --project <slug> [--claude-dir <dir>]`: prints `day_stop<TAB><today><TAB><limit>` when the day is stopped, then one `block<TAB><issue>` per card of the project at or over `card_block`. Transcripts already parsed are kept in `<SHIPFLOOR_HOME>/cost-cache.json` keyed by path, size and mtime, so a cycle parses only what changed.
  - CLI `dashboard_cost.py block --home <SHIPFLOOR_HOME> --project <slug> --issue <n> --out <file>`: writes the comment body (first line `Cost limit: blocked.`, the estimated total, the limit, one line per stage, the word "estimate") and the marker below.
- Marker `<project home>/cost/<n>.json`: `{"at", "limit", "total", "baseline", "stages": {stage: usd}}` (`stages`: the spend of the counted span, from `baseline` to `total`; `total`: the card's whole estimate). Written when the dispatcher blocks a card by cost; its `total` is the card's next baseline; removed when the card leaves the board snapshot.
- `scripts/dispatch.sh`:
  - with no `costs` in the machine config, no new process starts and the cycle is as today (AC-7);
  - right after `usage_limited`: on a `day_stop` line it logs `dispatch: today's estimate US$ <x> reached costs.day_stop (US$ <y>); no new run until tomorrow` and exits 0. Running sessions are untouched; "today" is the machine's local date, so the next day's first cycle starts runs again;
  - in `start_run`, before `launch`: a card in the `block` list is not launched; the dispatcher runs the `block` CLI, posts the comment (`gh issue comment --body-file`, through `FACTORY_GH`), then `board.sh label <n> add blocked`. A failed comment or label fails the cycle's status and the card is still not launched.
- `scripts/shipfloor_health.py`: `snapshot()` records `cost_stop: bool` and counts it as stopped, so a day stop does not raise the "free slot and cards waiting" alert.
- `scripts/dashboard.py`:
  - `GET /api/overview`: adds `costs: {card_warn, card_block, day_stop, day_stopped}` beside the existing `today.cost`; each card gains `over: "warn" | null` and `spent` (the figure the limits use, `total - baseline`); `cost: null` stays "price missing".
  - `GET /api/settings`: `machine.costs` (the three keys, `null` when absent) and `unpriced` (how many cards on the boards have an unknown estimate).
  - `POST /api/settings/machine`: accepts `costs: {key: number | null}`; `null` removes the key (an empty `costs` is dropped from the file); answers 400 with `machine_problems`' messages.
  - `Factory.block()` / `decide`: when the marker exists and the newest block note opens with `Cost limit: blocked.`, the block is `{"kind": "cost", "limit", "total", "stages"}` in place of stage, step and tried. Unblock and send back are the existing endpoints, unchanged.
- `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json`: the flag, the alert line, the cost "why", the "Costs" section in Settings and its strings, as `## UX` says.
- `README.md`: the `costs` keys beside the other machine settings.

**Files:** `scripts/dashboard_cost.py`, `scripts/shipfloor_config.py`, `scripts/dispatch.sh`, `scripts/shipfloor_health.py`, `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `README.md`, `scripts/test/dispatch-cost.test.sh` (new), `scripts/test/dashboard.test.sh`, `scripts/test/machine.test.sh`; all owned by `factory`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard.test.sh` |
| AC-2 | factory | `scripts/test/dispatch-cost.test.sh` |
| AC-3 | factory | `scripts/test/dispatch-cost.test.sh` |
| AC-4 | factory | `scripts/test/dispatch-cost.test.sh` |
| AC-5 | factory | `scripts/test/dispatch-cost.test.sh` |
| AC-6 | factory | `scripts/test/dispatch-cost.test.sh` |
| AC-7 | factory | `scripts/test/dispatch-cost.test.sh` |
| AC-8 | factory | `scripts/test/dashboard.test.sh` |

The dashboard halves of AC-3 (the cost "why"), AC-4 (the alert) and AC-6 ("price missing") are asserted in `scripts/test/dashboard.test.sh`; the `costs` validation of AC-8 also in `scripts/test/machine.test.sh`.

## Security
_Cybersec_ — n/a

## Rollback
n/a — nothing destructive: removing `costs` from `config.yml` turns every limit off; the markers under `cost/` and `cost-cache.json` are inert without it.

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- A limit acts at "at or above" (`>=`): `card_block: 40` means a card that has spent 40 starts nothing more; the issue says both "over" and "reaches".
- "Counts from the unblock" is kept as a baseline in a marker file written at the block, not as the unblock's time: nothing spends while a card is blocked, so the two are the same figure, and it works however the label was removed (dashboard or GitHub) with no extra GitHub read per cycle.
- The warning uses the same figure as the block (spend since the last cost block): one number against both limits; the card's total stays on screen as today.
- A card is blocked only when the dispatcher is about to start a run for it, never while it sits in a column waiting for the owner (Spec Review, Staged): the block is about stopping spend, not a second notice.
- No per-card limit override ("raise the limit for this card", from the issue's notes): unblocking already grants one more `card_block`; the inbox keeps unblock and send back.
- The day total covers every project on the machine and turns at the machine's local midnight, as the dashboard's "today" does; the account and the bill are one per machine.
- An unpriced session adds nothing to the day total and makes its card's estimate unknown, as the dashboard computes today; no limit acts on a number that is not there.
- The day stop also holds deploy runs: a deploy can call an agent for conflicts, and "no new run starts" has no exception in the issue.
- `costs` has no default values: AC-7 asks that nothing changes without it, and with no `costs` the dispatcher does not even start the estimate.
- The dispatcher reads the estimate through a CLI in `scripts/dashboard_cost.py` with a small parse cache on disk: the same code as the dashboard, without parsing every transcript on every 3-minute cycle.
- The health history records the day stop as a stop: otherwise the "free slot and cards waiting" alert would fire all day.
- Settings validation (AC-8) lives in `machine_problems`, so the CLI, the dispatcher and the dashboard refuse the same values.
- The cost block's "why" shows the spend of the counted span (since the last cost block) per stage, with the card's whole total as a muted extra line: after one unblock a whole-card total alone would read as far over the limit.
- The three Settings fields are typed fields, not steppers: a stepper cannot be emptied to turn a limit off.
- Figures are written `$41.20` with "est.", as every cost on the dashboard, not `US$ 41.20` as in the issue.
- Spec template read from the worktree's `templates/spec-template.md` (the installed copy is outside what this run may read); the two are the same file on `main`.

## Open questions
- none
