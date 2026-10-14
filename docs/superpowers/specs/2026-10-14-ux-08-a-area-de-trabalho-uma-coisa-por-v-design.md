# [UX-08] The work area: one thing at a time, decide without switching screens — spec

**Issue:** #182 · **Branch:** `feat/182-ux-08-a-area-de-trabalho-uma-coisa-por-v` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** To decide, the owner opens each waiting card in a drawer over the page, decides, closes it and hunts for the next one, while "Yours", "In progress" and "History" compete for the same screen.
**Audience:** The factory's owner, in a quick check of the dashboard.
**Acceptance criteria**
- **AC-1** — Given cards wait for the owner (Spec Review, Staged), when the dashboard opens, then a single work area below the belt shows Decide on the oldest waiting card: number, column, time waiting, `1 of N decisions`, the next card, title, the brief and a sticky Your decision panel; "Yours", "In progress" and the drawer are gone.
- **AC-2** — Given Decide is shown and focus is not in a text field, when the owner presses `A`, `R` or `N`, then it approves, opens Request changes (suggestions, note, Send on `Enter`) or skips to the next waiting card; with focus in a text field the keys type text and trigger nothing.
- **AC-3** — Given the owner approves or sends changes, when the 5 s undo window ends, then the decision is sent as today (confirm when items are unreviewed, Undo available, sent if the page closes) and the next waiting card slides in; after the last one the Calm mode appears.
- **AC-4** — Given nothing waits and nothing is selected, when the work area renders, then it shows `Nothing waits for you` and three columns: next decisions (runs nearest a gate), what runs now, and what shipped today with PR, time and cost estimate from Inbox to Done.
- **AC-5** — Given the owner selects a running card on the belt, when the work area renders, then Run mode shows the stage's steps, the last five tool calls, the field to message the run, step, clock, cost estimate, Log and GitHub; selecting any other card shows Card mode with its state in words and cost estimate.
- **AC-6** — Given the OS asks for reduced motion, when the work area swaps content, then the swap is instant with no slide.
- **AC-7** — Given any card, when the owner uses the work area, then every action available today is still reachable: approve, request changes, spec weight on Spec Review, message to a run, unblock and retry, Log, Sessions, Gates and the full Review page.
- **AC-8** — Given the change ships, when DESIGN.md is read, then a section "The Work Area" replaces Your, In Progress, Tooltip Drawer and How a Card Opens.
**Out of scope:** The belt itself (#181) and the brief content/`briefHTML` (#179); moving History to the Feed/logbook (#31/37), so History stays reachable until that issue ships; the address bar, palette and logbook scrubber; any new owner action.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits): waiting decisions open first and are settled in place. Keeps principle 1: the decision queue and "Skip for now" are derived from the board snapshot and the page session, never stored as card state. Cost figures stay labeled as estimates (principle 3). No conflict with the positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

Source: `docs/design/floor-v4.md` (The work area, Motion). Reuses the panel shell, `briefHTML` (#179), the Approve button, `.btn.ghost`, `.lnk`, `.tag`, `.itoast` (Undo), the In Progress step bar and tool-call list, the Live field, and today's maximized card view (90% overlay). No new component beyond the work area panel itself.

- **Mode choice.** A token selected on the belt (#181; click, Enter or Space) decides the mode: waiting → Decide, running → Run, anything else → Card. Nothing selected: Decide on the oldest waiting card, else Calm. Clicking the selected token again, or `Esc` with nothing else open, clears the selection. The selected token keeps #181's selected look, so belt and work area always name the same card.
- **Decide.** Head: mono chip `#120` in `accent`, column, `waiting 3 h 50 min`; right: `1 of 3 decisions`, dashes (done `ok`, current `accent`, rest `edge-hi`), `next: #129`. Title 24px 500, 40ch. Left: `briefHTML`; with no brief, today's sandboxed review iframe in its place. Right, sticky (`panel-hi`, 14px radius): Your decision with Approve (solid `text`, destination as a second 12px line), Request changes (destination line), Skip for now (ghost), then the stale-board/skipped-project lines and, on Spec Review, today's weight select with its hint, unchanged. Under the buttons, one row of `.lnk`: Full review, Sessions, Log, Gates, GitHub; each of the first four opens the maximized card view on that tab.
- **Request changes.** `R` or the button unfolds, inside Your decision: the flag suggestions (accent-tinted `.btn.ghost`, one per flag, plus today's "Use the review's N changes"), the note (focused) and Send (disabled while empty; `Enter` sends, `Shift+Enter` makes a new line). `Esc` folds it back and keeps the typed note for this card.
- **Approve with doubt.** With unreviewed items or changes asked, Approve is soft and the first click or `A` arms it in place (`Approve with 2 not reviewed`, 4 s, focus on it, hint linked by `aria-describedby`); the second sends. With marks never seen in this session, Approve sends nothing and the hint reads today's `Nothing was approved: look at the review first.` with Full review beside it.
- **After a decision.** Your decision becomes the `.itoast` line `Approving #120 in 5 s` / `Sending changes for #120 in 5 s` with Undo; still sent if the page closes. When the window ends, the next waiting card slides in (260 ms out, 400 ms in; instant under reduced motion) and focus moves to its title, so `A`/`R`/`N` keep working; a polite status reads `#129 waits for you, 2 of 3`. A failed send brings the card back as current with today's `#12 was not approved: <reason>` notice. After the last one, Calm.
- **Skip for now.** `N` or the button moves the current card to the end of this page's queue (page session only, never stored) and shows the next; with one card waiting it does nothing and says `Only #120 waits.` A card selected on the belt is decided the same way; after it, the queue resumes.
- **Keys.** `A`, `R`, `N` act only in Decide, with focus outside a text field, select or iframe and no maximized view open. `Esc` order: suggestions/note, maximized view, selection. Today's Your-list keys (N/A/R/L) and their footer go away with the list; the footer becomes `A approve · R request changes · N skip` (fine pointer only, as today).
- **Run.** Left: the stage's steps as a stepper (done `muted`, current `text` 600), the last five tool calls in mono (time, tool, target; newest fades in), then today's Live field. Right: `Step 4 of 7`, the clock, `$0.42 est.` in `text`, Log and GitHub. A run that ends while shown turns into Card mode in place, without a slide.
- **Card.** Head and title as Decide, then one sentence of state (reusing today's words: `Waiting for the pool · 4 of 4 busy`, `2 of 5 in line`, `Done today · PR #66`) and `$1.20 est. from Inbox to now`, then the Sessions, Log, Gates, GitHub links. A blocked card shows today's block note (decision line, failed gate, Unblock and retry, folded Full report) above the links. Loading (card not read yet): head and title only, links disabled, no skeleton.
- **Calm.** `Nothing waits for you` (34px 600), then three columns with 14px 600 titles and 15px rows, each row a button that selects the card: Next decisions (`#131 · Validate, then Staged`), Running now (`#128 · Develop · step 4 of 7`), Shipped today (`#121 · PR #64 · 3 h 10 min · $0.84 est.`). Empty column: one `faint` line. History stays below the work area, unchanged, until #31/37.
- **Small screen.** Under 860px: one column; Your decision moves under the title, before the brief, and is not sticky; buttons full width; the head's right part wraps under the number; Calm columns stack; the tool stream wraps targets. Targets stay at least 24x24.
- **Copy (en / pt-BR; the other 10 catalogs carry the English text):** `waiting {t}`/`esperando há {t}` · `{i} of {n} decisions`/`{i} de {n} decisões` · `next: #{n}`/`próximo: #{n}` · `Skip for now`/`Pular por agora` · `Full review`/`Revisão completa` · `Send`/`Enviar` · `to Ready for Dev`/`para Ready for Dev` · `to Ready for Prod`/`para Ready for Prod` · `back to Refine`/`de volta ao Refine` · `back to Develop`/`de volta ao Develop` · `Approving #{n} in 5 s`/`Aprovando #{n} em 5 s` · `Sending changes for #{n} in 5 s`/`Enviando mudanças de #{n} em 5 s` · `#{n} waits for you, {i} of {k}`/`#{n} espera você, {i} de {k}` · `Only #{n} waits.`/`Só #{n} espera.` · `A approve · R request changes · N skip`/`A aprova · R pede mudanças · N pula` · `Next decisions`/`Próximas decisões` · `Running now`/`Rodando agora` · `Shipped today`/`Saiu hoje` · `then {column}`/`depois {column}` · `No run is near a gate.`/`Nenhuma execução perto de um portão.` · `Nothing runs.`/`Nada está rodando.` · `Nothing shipped today yet.`/`Nada saiu hoje ainda.` · `{cost} est. from Inbox to now`/`{cost} est. da Inbox até agora` · `The work area`/`A área de trabalho` (region label). Column names stay in English, as today.

## Architecture
_Tech Lead_

All in the `factory` layer. No new endpoint and no new owner action: every send goes through today's calls (approve/request-changes move, weight POST, say-to-run, unblock).

- **Contracts read:** the overview's per-card `column`, `since`, `cost`, `running`, `blocked`, `awaiting`, `runOf()/progress()/STEP_COUNT`; the open card's payload (`brief` from #179, review progress, block, live tail) as today. **Added to the overview** in `scripts/dashboard.py` only if #181 did not: per project `shipped` = list of `{issue, title, pr, at, cost}` for cards that reached Done today (from the board snapshot's `since` and the reports' `pr`; `cost` is today's Inbox-to-now estimate, `null` when unpriced).
- **`scripts/dashboard.html`:**
  - New `#work` panel under the belt replaces `#cols` (the "Yours" list and the "In progress" grid); `renderYours` and the in-progress tiles are removed.
  - Pure functions, no DOM access, so tests can run them in node: `decisionQueue(cards, skipped)` (owner-column cards, oldest `since` first, skipped ones last), `workMode(state)` → `decide | run | card | calm`, `nextGates(cards)` (running cards ordered by steps left to their stage's gate).
  - `renderWork()` dispatches to `renderDecide` (rewritten from the drawer's decision block: head, title, `briefHTML`, sticky Your decision with weight select on Spec Review, approve-with-doubt confirmation, suggestions, note, Send), `renderRun` (from today's Live tab and tile: stepper, last five tool calls, say field), `renderCardMode` (state in words, cost, Unblock and retry when blocked), `renderCalm` (three columns).
  - `S.work = {key, skipped: Set}` (page memory only); a belt token click sets `S.work.key` instead of opening the drawer.
  - Swap: one class toggle with CSS transitions (260ms out, 400ms in) keyed by the shown card; `@media (prefers-reduced-motion: reduce)` sets them to none.
  - Keys `A`/`R`/`N`/`Enter`/`Esc` in one `keydown` handler, ignored when `e.target` is an `input`, `textarea`, `select` or `[contenteditable]` (Enter only sends from the note); today's `A`/`R`/`L`/`N` list keys go.
  - The 5 s hold, Undo and `pagehide` keepalive send are reused from today's quick approve (#50), now on the work area.
  - The side drawer goes; its tabs (Sessions, Log, Gates, Review) stay as today's maximized card view, opened from the links of each mode (`data-full` routing).
- **i18n:** new `work.*` keys in all 12 `scripts/lang/dashboard.*.json` (en and pt-BR as UX gives; the other 10 carry English); keys of the removed Yours list, tiles and side drawer decision are deleted from all 12.
- **`DESIGN.md`:** Your, In Progress, Tooltip Drawer and How a Card Opens replaced by **The Work Area**; Layout and Keyboard and Live Updates follow (A/R/N, no Your list).
- **Files:** `scripts/dashboard.html`, `scripts/dashboard.py` (only `shipped`), 12 `scripts/lang/dashboard.*.json`, `DESIGN.md`, new `scripts/test/dashboard-work-area.test.sh`, new `scripts/test/dashboard-work-keys.test.sh`, and the existing tests that name Yours, the tiles or the drawer: `dashboard`, `dashboard-first-screen`, `dashboard-quick`, `dashboard-weight`, `dashboard-names`, `dashboard-narrow`, `dashboard-short`, `dashboard-page`, `dashboard-touch`, `dashboard-targets`, `design-doc` (`.test.sh`).
- **Order:** develop only after #179 (`briefHTML`) and #181 (the belt and its token selection) are merged; rebase on them first.
- **Migration:** none. **Rollback:** revert the commit.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-work-area.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-work-keys.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-quick.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-work-area.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-work-area.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-work-area.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-work-area.test.sh` |
| AC-8 | factory | `scripts/test/design-doc.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- `R` means Request changes (as the issue says); today it opens the review, which is now the "Full review" link.
- The side drawer goes; Sessions, Log, Gates and Review stay in today's maximized card view, opened from each mode's links, so no tab is lost.
- The weight select (Spec Review) and Unblock and retry move into the work area (Decide and Card modes): they lived in the drawer.
- The approve-with-doubt confirmation, the 5 s Undo and the `pagehide` send are reused from #50, now inside Your decision.
- Skip for now and the selection live in page memory only: nothing about a card is stored outside the board (principle 1).
- History stays a panel until #31/37 moves it to the Feed, so it is never unreachable.
- `shipped` is added to the overview only if #181 did not already add what Calm needs; no new endpoint.
- Develop waits for #179 (`briefHTML`) and #181 (the belt); both are still in refinement.
- Weight heavy: 8 acceptance criteria and more than 8 files.

## Open questions
- none
