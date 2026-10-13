# Lifecycle maximized: the owner moves their cards by dragging them — spec

**Issue:** #125 · **Branch:** `feat/125-lifecycle-maximized-the-owner-moves-thei` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The maximized Lifecycle only shows where each card is. To take an issue out of the Inbox the owner goes to GitHub, and to decide a spec or a pull request they leave the view of the whole.
**Audience:** The factory's owner, in a quick check of the dashboard.

**Allowed moves** (the whole list; M1 to M7 are referenced by the criteria)

| # | From | To | Meaning | On drop |
|---|---|---|---|---|
| M1 | Inbox | Ready for Refinement | send it to refinement | moves at once |
| M2 | Ready for Refinement | Inbox | take it out of the queue | moves at once |
| M3 | Spec Review | Ready for Dev | approve the spec | moves at once |
| M4 | Spec Review | Ready for Refinement | request changes | note required |
| M5 | Ready for Dev | Ready for Refinement | refine again | note required |
| M6 | Staged | Ready for Prod | approve and ship | moves at once |
| M7 | Staged | Coding | request changes | note required |

**Acceptance criteria**
- **AC-1** — Given a movable card in the maximized Lifecycle, when the owner drags it to the target column of M1, M2, M3 or M6, or presses `M` on the focused card and then the digit shown on that column, then the card moves at once, with no further prompt.
- **AC-2** — Given a card dropped (or sent by `M` + digit) on the target of M4, M5 or M7, when the note box opens, then a non-empty note moves the card and is posted on the issue, an empty note is refused and the card does not move, and Cancel puts the card back.
- **AC-3** — Given any from/to pair outside M1 to M7 (including every factory column as a target beyond what the table lists), when it is attempted by drag, by `M` + digit or by a direct request to the server's endpoints, then the card does not move and the request is refused.
- **AC-4** — Given a card picked up by pointer or held with `M`, when it is held, then the columns that accept it light up with a line saying what dropping there means (by keyboard, "Press 1 to ..."), the other columns dim, a factory column also says "the factory moves", and `Esc` lets go without moving.
- **AC-5** — Given a move that went at once, when it lands, then a toast says the board confirms it on the dispatcher's next read and offers Undo for 5 s, which leaves the board as it was, and a "Comment" link that opens the same box with an optional comment for the issue; every move reads the live board first and is refused if the card is no longer in its From column.
- **AC-6** — Given a card with a run in progress or blocked by infrastructure, when the owner tries to pick it up by pointer or `M`, or its move is requested from the server's endpoints, then it does not move, shows a lock and says why.
- **AC-7** — Given a Spec Review or Staged card with unreviewed items or requested changes (the #50 check), when it is dropped or sent to its approve column (M3, M6), then the drawer's confirmation opens instead of the move, and a Staged card is not shipped by the drop alone.
- **AC-8** — Given the maximized Lifecycle in English or pt-BR, when the owner looks at it, then each card shows how long it has waited and, in a queue column, its position; the heading's "Only what I can move" toggle dims every card the owner cannot move; and all new text is in both languages, with column and lane names in English in pt-BR.

**Out of scope:** Moving blocked cards and reordering inside a queue (their own issues). Moving cards in the collapsed band or in the list. Any move outside M1 to M7. Changes to what the drawer's approve and request-changes do today.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner: Inbox, Spec Review, Staged, and the queues before a run starts) and principle 1 (the move reads the live board, and the toast says the board confirms it; the dashboard keeps no card state). It widens one line of the product context: "Owner-only actions: approve and request changes on Spec Review and Staged cards" does not cover M1, M2 and M5, which are new; that line of `PRODUCT.md` has to be updated with this change. Nothing here contradicts the positioning: the factory's columns stay the factory's.
**Touches UI:** yes

## UX
_UX/UI Designer_

Screen: `scripts/dashboard.html`, the maximized Lifecycle (`.band.maxed`, `.lcol`, `.chip`). No new component and no new token.

- **Card.** Every `.chip` keeps its click (opens the card) and gains, in its `<small>`, the wait after the state word (`waits for you · 2 d`, from `dur(c.since)`) and, in Ready for Refinement, Ready for Dev and Ready for Prod, its place (`2 of 5 in line`, oldest first). *Movable* (a From column of M1 to M7, no run, not blocked): `cursor: grab`, `draggable`. *Held*: `.chip.hot` plus the 2px `sand` outline of the Focus rule, `aria-pressed="true"`; it stays in its column at 50% opacity while dragged. *Locked* (AC-6): not draggable, `cursor: not-allowed`, `aria-disabled="true"`, a 12px inline SVG lock (`aria-hidden`, `currentColor`, `muted`) before the reason, always visible in the `<small>`; `warn` border stays for infrastructure. *Dimmed* by the toggle: opacity .45, still opens.
- **Toggle.** In the heading row of the panel, right of `Lifecycle`: the Settings switch (`.sw.sand`, its `aria-label` is the text beside it, 13px `muted`). Off at every load, never stored (as the folds). On with nothing movable: one `.empty` line under the heading.
- **Columns while a card is held.** *Accepts*: 1px dashed `sand` border, `color-mix(sand 7%)` wash, and under its `.lab` the line as a real `<button class="btn ghost">` (so a click or a tap also moves): `Drop to <meaning>`; under the pointer the border turns solid and the fill `panel-hi`. *Others*: opacity .45. A factory column (one that carries a stage name in its label: Refine, Develop, Validate, Deploy) that does not accept also shows `the factory moves` at 11.5px `faint`; Coding as the target of M7 shows only its accept line. Letting go outside an accepting column, or `Esc`, lets go without moving.
- **Note box (M4, M5, M7 and the toast's Comment).** The peek's surface (`.peek`: `panel-hi`, lit hairline, 8px, `--shadow`, 340px, clamped 12px from the edges) anchored under the target column's label, `role="dialog"` labelled by its heading, holding the inbox's `.iconf` (text area as `#inote`, `.ihint`, `.btn` + `.btn.ghost` Cancel). Focus goes to the text area. Required: the send button is disabled while the note is empty and the hint is the existing `Write the note first: it goes with the decision.`; Cancel or `Esc` closes it, the card has not moved and gets focus back. Optional (Comment): same box, the hint says it is optional, sending empty is not possible, Cancel just closes.
- **After a move.** The chip appears in the To column with the existing `Moving to <column>` caption (`S.moving`) until the snapshot agrees; `progress` cursor while the request is in flight. The existing `.itoast` (`role="status"`, the `ok` border) sits at the bottom of the panel with the message, the `Comment` link (underlined, as `.itoast button`) and `Undo`; Undo leaves after 5 s, the toast stays until the board confirms or the next move. A note move shows the same toast with Undo and no Comment. A refused move (card no longer in its From column, a run started meanwhile) puts the chip back and says so in the panel's `.pnote` (`role="status"`, `bad`).
- **Approve with doubt (AC-7).** A drop or digit on Ready for Dev or Ready for Prod for a card the #50 check holds sends nothing and opens the wide drawer on Review exactly as the list's Approve does (armed `Approve with N not reviewed`, or `Nothing was approved: look at the review first.`). No new copy.
- **Keyboard.** Chips are already in the tab order. `M` on a focused movable chip holds it; the accept lines become `<kbd>1</kbd> Press 1 to <meaning>`, numbered left to right in board order (two at most); the digit moves, `Esc` lets go. `Esc` order: note box, held card, then the maximized panel. Digits and `M` are ignored while typing. Focus stays on the chip while held and follows it (by `data-key`) to its new column; after Undo it returns with the card. `M` on a locked or factory card holds nothing and says why.
- **Screen reader.** One polite line under the heading (`role="status"`, 12.5px `muted`, also the visible hint for keyboard users) carries: the hold with its choices, the let-go, the lock's reason and the result; the toast and `.pnote` announce themselves. Accept lines are buttons named by their text; a locked chip's reason is part of its accessible name.
- **Touch (`pointer: coarse`).** No drag. A movable chip's row ends with a ghost `Move` button (a sibling of the chip, 44px target) that holds the card; accept lines read `Tap to <meaning>`; a tap elsewhere lets go.
- **Small screens.** Below 860px each lane scrolls sideways (columns `minmax(168px, 1fr)`, scroll snap) and the first accepting column scrolls into view when a card is held; the toggle wraps under the heading; the note box takes `calc(100vw - 24px)`; the toast's actions wrap under its text. The chip's slide to its new column is one 150ms ease-out, instant under reduced motion.
- **Language.** New entries in `scripts/lang/dashboard.pt-BR.json`; column and lane names inside them stay in English (as `Devolver para Coding` already does), and in the maximized Lifecycle the column labels show in English in pt-BR too. Existing strings reused as they are: `Undo`, `Cancel`, `Request changes`, `Send back to Coding`, `What should change in the spec?` (M4), `What should change?` (M7), `Write the note first: it goes with the decision.`, `Moving to `.

| Where | English | pt-BR |
|---|---|---|
| Toggle | Only what I can move | Só o que eu posso mover |
| Toggle on, nothing movable | Nothing for you to move right now. | Nada para você mover agora. |
| Chip, queue place | 2 of 5 in line | 2 de 5 na fila |
| Chip, locked by a run | locked · a run is in progress | travado · uma execução está em andamento |
| Chip, locked by infrastructure | locked · blocked by infrastructure, the factory retries | travado · bloqueado por infraestrutura, a fábrica tenta de novo |
| Accept line, prefixes | Drop to … / Press 1 to … / Tap to … | Solte para … / Aperte 1 para … / Toque para … |
| Meaning M1 | send it to refinement | mandar para o refinamento |
| Meaning M2 | take it out of the queue | tirar da fila |
| Meaning M3 | approve the spec | aprovar a spec |
| Meaning M4, M7 | request changes | pedir mudanças |
| Meaning M5 | refine again | refinar de novo |
| Meaning M6 | approve and ship | aprovar e publicar |
| Factory column | the factory moves | a fábrica move |
| Touch button | Move | Mover |
| Note box heading, required | Request changes on #12 / Refine #12 again | Pedir mudanças no #12 / Refinar o #12 de novo |
| Note box placeholder, M5 | What should the refinement do differently? | O que o refinamento deve fazer diferente? |
| Note box button, M5 | Refine again | Refinar de novo |
| Note box, optional | Comment on #12 · Optional: a comment, posted on the issue · Post comment | Comentar no #12 · Opcional: um comentário, publicado na issue · Publicar comentário |
| Toast | #12 moved to Ready for Dev. The board confirms it on the dispatcher's next read. | #12 foi para Ready for Dev. O quadro confirma na próxima leitura do dispatcher. |
| Toast link | Comment | Comentar |
| Toast after Undo | #12 is back in Spec Review. | #12 voltou para Spec Review. |
| Toast after a comment | Comment posted on #12. | Comentário publicado no #12. |
| Refused | #12 was not moved: it is no longer in Spec Review. / #12 was not moved: \<reason\> | #12 não foi movido: ele não está mais em Spec Review. / #12 não foi movido: \<motivo\> |
| Status, held | Holding #12. Press 1 to request changes, 2 to approve the spec, Esc to let go. | Segurando o #12. Aperte 1 para pedir mudanças, 2 para aprovar a spec, Esc para soltar. |
| Status, let go | #12 let go. It did not move. | #12 solto. Ele não se moveu. |
| Status, locked | #12 cannot move: a run is in progress. / #12 cannot move: blocked by infrastructure, the factory retries. | #12 não pode ser movido: uma execução está em andamento. / #12 não pode ser movido: bloqueado por infraestrutura, a fábrica tenta de novo. |
| Status, factory card | #12 is the factory's to move. | Quem move o #12 é a fábrica. |

## Architecture
_Tech Lead_

One layer, `factory`. No migration, no new dependency, no build.

**Contracts**
- New: `POST /api/card/<project>/<n>/move`, body `{column, to, text, move_only}` (`column` is where the page saw the card; `to` is the target column). Answers:
  - `200 {moved_to}`: the card moved; a non-empty `text` was posted on the issue first.
  - `400 {error}`: the pair needs a note (M4, M5, M7) and `text` is empty. Nothing moved.
  - `403 {error}`: the pair `column` → `to` is not one of M1 to M7. Nothing moved.
  - `409 {error, column}`: the live board has the card in another column than `column`. Nothing moved.
  - `423 {error, locked}`: `locked` is `run` (a run that is not an orphan works on the card), `infra` (label `blocked:infra`) or `blocked` (label `blocked`). Nothing moved.
  - `502 {error, commented}`: `gh` failed; `commented` says whether the note is already on the issue (as `approve` answers today).
- New: `POST /api/card/<project>/<n>/comment`, body `{text}`: posts the text on the issue and moves nothing. `200 {commented: true}`, `400 {error}` when empty, `502 {error}` when `gh` failed.
- Unchanged in path and body: `POST /api/card/<project>/<n>/approve` and `/request-changes`. They now go through the same function as `move` (the action picks `to`), so they gain the `423` answer and nothing else.
- `GET /api/overview`: each card gains `lock` (`"run"`, `"infra"`, `"blocked"` or `null`), `opened` (the issue's `createdAt`) and `position` (1-based place among the cards of its column in board order, only in Ready for Refinement, Ready for Dev and Ready for Prod; else `null`). Top level gains `moves`: `{<from>: [{to, note}]}`, the table M1 to M7 as the server holds it. Existing fields stay.

**Modules**
- `scripts/dashboard.py`
  - `OWNER_MOVES` becomes the one table of M1 to M7 (from, to, note required); `approve` and `request-changes` read their target from it.
  - `Factory.owner_move(p, n, seen, to, text, move_only)`: reads the live board (`board_row`), then refuses in this order: stale column, pair outside the table, lock, missing note; then comment, then `move`. `Factory.act` calls it.
  - Lock, read at the time of the move and not from the minute-old cache: `live(p)` for a run on the card, and the issue's labels through one `gh api repos/<repo>/issues/<n>/labels`.
  - `titles()` asks `createdAt` in the query it already sends; `overview()` fills `lock`, `opened`, `position` and `moves`.
  - `Factory.comment(p, n, text)` for the toast's comment after the move has left.
  - `Handler.do_POST` accepts `move` and `comment` beside the six actions it lists.
- `scripts/dashboard.html`
  - `renderLanes`: a chip carries its wait, its queue position, its lock and whether the owner can move it; a column carries its drop line while a card is held. What a card accepts comes from the overview's `moves`, not from a second table in the page (the `OWNER` constant is derived from it).
  - Hold state (`S.hold`): set by `dragstart`, `M` or the touch `Move` button, cleared by a drop, a digit, a click on an accept line, `Esc` or `dragend`. Drag is the HTML drag and drop of a fine pointer; touch and keyboard share the accept lines, which are buttons.
  - Every move (with or without a note) goes into `S.pending` as the list's quick approve does: 5 s on the page with the chip shown in its To column, Undo drops it before any request leaves, `pagehide` sends what is pending with `keepalive`. The toast's "Comment" adds `text` to the move while it is pending (Undo drops both) and calls `comment` once it has left.
  - M3 and M6 call `lookFirst` when `reviewDoubt` or an unseen review page says so, exactly as `quick("approve")`.
  - A chip's wait is `since` (when the card's last run ended) and, for a card that never ran, `opened`. Its place is `position` of the column's count.
  - "Only what I can move" is page state, off at every load, not stored.
  - The column labels of the maximized Lifecycle are left out of the page's rewrite to pt-BR, as the lane names are since #121.
- `scripts/lang/dashboard.pt-BR.json`: every new string of the UX table; a column or lane name inside one stays in English.
- `DESIGN.md`: the line on inline SVG marks names the lock as the third.
- `PRODUCT.md`, line "Owner-only actions": names the three new moves (M1, M2, M5).
- `docs/operation.md`: the paragraph on what the owner does in the dashboard names the moves.
- `scripts/test/dashboard-move.test.sh`: new, server with the fake `gh` and the page read as text, as `dashboard-quick.test.sh`.

**Not touched:** `scripts/board.sh` (`board.sh move` keeps refusing owner-only targets for the agents; the dashboard moves with `gh` directly, as today), the board snapshot format, `send-back`, `accept`, `unblock`, `message`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-move.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-move.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-move.test.sh` |
| AC-4 | manual | review: hold a card by pointer and by `M`, read the lit and dimmed columns, `Esc` |
| AC-5 | factory | `scripts/test/dashboard-move.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-move.test.sh` |
| AC-7 | manual | review: drop a Staged card with unreviewed items on Ready for Prod; the drawer's confirmation opens and the board does not change |
| AC-8 | factory | `scripts/test/dashboard-move.test.sh` |

What the automated file proves per AC: AC-1 and AC-2, each of M1 to M7 through `move` (the fake `gh` records the edit and the comment; an empty note is a 400 with no edit); AC-3, every other pair of the ten columns is a 403 with no edit; AC-5, a stale `column` is a 409 with no edit, and the page holds a move for 5 s and sends it on `pagehide`; AC-6, a card with a live run and one with `blocked:infra` are a 423 through `move`, `approve` and `request-changes`, and the overview says `lock`; AC-8, the overview carries `opened` and `position`, and each new string of the page is in the pt-BR catalog with no entry for a column or lane name. The gestures themselves (drag, `M` + digit, Undo in the toast, the note box) are checked by hand in review, as #50 did.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- One new endpoint, `move`, and `approve` / `request-changes` keep their paths: a path is a contract, and the three share one function so the table is enforced in one place.
- The lock is enforced on the server too, for `move`, `approve` and `request-changes`: the acceptance says no other move is possible from the endpoints, and a page check alone is not a guard.
- A move is refused when the live board shows the card outside the column the page saw (409): that is what Approve does today.
- A card with the `blocked` label is not movable either, and `move` refuses it (423): blocked cards are out of scope and keep the drawer's actions. `send-back`, `accept` and `unblock` are not changed.
- The #50 check holds for approving a spec by drop (M3) as for shipping (M6): the list's Approve already asks it in both columns.
- Undo is the list's 5 s hold, not a move back: nothing reaches the board until the 5 s pass, so Undo leaves it as it was by construction. Note moves (M4, M5, M7) get the same hold, and their note is posted only when the move leaves.
- The toast's Comment after the 5 s uses a new `comment` endpoint that only posts: the move has already left and must not be sent twice.
- How long a card has waited is counted from the end of its last run, or from when the issue was opened if it never ran: both are exact and already read. The moment a card entered its column is not in the board snapshot, and adding it would change a file 16 scripts read.
- Queue position is the card's place in board order in Ready for Refinement, Ready for Dev and Ready for Prod: that is the order the dispatcher takes cards. The Inbox is not a queue the factory takes from, so it shows no position.
- The page learns the table from the overview (`moves`): one table, on the server, instead of a copy in the page that could drift.
- "Only what I can move" is off at every load and not stored, as the panel's folds.
- Touch gets a `Move` button and tappable accept lines instead of drag; the keyboard gets `M` + digit: one mechanism (the accept line is a button) serves both, and WCAG 2.5.7 is met.
- The lock is a 12px inline SVG beside its reason in words, and `DESIGN.md` gains it as the third allowed mark: the issue says the card shows a lock, and the reason never depends on the glyph.
- `PRODUCT.md`'s "Owner-only actions" line is updated in this change to name the three new moves: the product context must not contradict what ships.
- Drag, `M` + digit, the toast and the confirmation of #50 are checked by hand in review (AC-4, AC-7): the factory layer has no browser runner, and #50 was accepted the same way. The server side of every AC is automated.

## Open questions
- **Column names in pt-BR:** A (recommended) English only in the maximized Lifecycle and in the new messages, or B English everywhere in the dashboard — today the pt-BR catalog translates them ("Ready for Dev" is "Pronto para dev"), so with A the collapsed band and the list keep the Portuguese names beside this panel's English ones; B removes ten catalog entries and changes screens outside this issue.
