# The owner orders the queues, and the dispatcher takes cards from the top — spec

**Issue:** #128 · **Branch:** `feat/128-the-owner-orders-the-queues-and-the-disp` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The order in which the factory takes cards is not the owner's: the dispatcher takes what it finds in a column, and the order the owner wants lives in a hand-written list (#56) the factory never reads.
**Audience:** The factory's owner, in a quick check of the dashboard.

Builds on #125 and uses its words (held card, accept line, toast, Undo, lock). The *ordered columns* are Inbox, Ready for Refinement and Ready for Dev.

**Acceptance criteria**
- **AC-1** — Given the maximized Lifecycle, when the owner looks at an ordered column, then each of its cards shows its position (1, 2, 3...) and the cards are listed in the order of the GitHub board, in English and pt-BR.
- **AC-2** — Given a movable card of an ordered column, when the owner drops it on another card of the same column, then it takes the place before that card, and after the dispatcher's next read a reload shows the new order and the GitHub board has the items in that order.
- **AC-3** — Given a card of an ordered column held with `M`, when the owner presses the up or down arrow, then the card moves one place in its column and the positions follow; `Esc` lets go and leaves the order as it was before the hold.
- **AC-4** — Given two or more cards in Ready for Refinement or Ready for Dev and one free slot of that stage, when the dispatcher runs, then it starts the topmost card it can start, and it starts a lower one only when every card above it cannot start.
- **AC-5** — Given a reorder that just landed, when the toast shows, then it names the card and its new position and offers Undo for 5 s, which leaves the page and the GitHub board in the previous order.
- **AC-6** — Given a card with a lock, or a card outside the ordered columns, when a reorder is attempted by drag, by keyboard or by a direct request to the server's endpoints, then the order does not change and the page says why.
- **AC-7** — Given a reorder whose card, or the card it was dropped on, is no longer in that column on the live board, when it is sent, then it is refused, the page says so and the board's order does not change.
- **AC-8** — Given a drop on a card of another column, when it lands, then #125's rules decide alone (an allowed move or nothing) and no order changes.
- **AC-9** — Given a card the owner moves from the page into an ordered column (#125's M1 to M5), when the move reaches the board, then the card is the last of that column on the page and on the GitHub board, and the cards already there keep their order.

**Out of scope:** Reordering any other column (Ready for Prod keeps #125's place in line). Reordering in the collapsed band or in the list. A card moved on GitHub itself: it lands where the owner drops it there. Priority labels and any ordering rule of the factory's own. Editing or migrating #56's list: the owner sets the order once in the page and closes #56. Anything #125 already defines (moves between columns, the note box, the lock, the toggle).
**Product fit:** Serves principle 1 (the order is the item's position in the GitHub Project; the dashboard stores none and reads it back) and principle 4 (the owner acts on the queues, where a card waits before a run starts; the dispatcher, a script, follows that order). The Inbox is ordered though the factory never takes from it: there the position is the owner's own triage order and changes nothing the factory does. It changes two things #125's spec decided: the Inbox now shows a position, and the position in Ready for Refinement and Ready for Dev is the board's order, not "oldest first". It also adds a position write to #125's moves into those three columns (M1 to M5), so a card that enters a queue never jumps ahead of the ones the owner ranked. `PRODUCT.md`'s "Owner-only actions" line has to name ordering the three columns. Nothing contradicts the positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

Screen: `scripts/dashboard.html`, the maximized Lifecycle. An addition to #125's UX (held chip, accept lines, lock, toast, status line, touch `Move`): everything there holds unless a bullet below changes it. No new component and no new token.

- **Position.** In Inbox, Ready for Refinement and Ready for Dev each `.chip` opens with its position as a figure before the `#12`: meta (12px), `faint`, tabular, right-aligned in a fixed 2ch so the numbers line up, followed by a `.vh` text (`Position 2 of 5`) for the accessible name. It replaces #125's `2 of 5 in line` in those columns; Ready for Prod keeps #125's text. A locked or dimmed chip shows its position too. One card in the column still shows `1`; an empty column shows nothing new.
- **Held card, its own column.** While a card of an ordered column is held, its column neither dims nor gets an accept line; the other columns behave as in #125. The other chips of the column are drop targets, locked ones included (a locked chip still cannot be held).
- **Drop indicator (pointer).** A 2px `sand` bar, 2px radius, the chip's width, drawn in the 6px gap above the chip under the pointer: "it goes before this one". Over the column below its last chip the bar sits under the last chip: "it goes last". Chips do not shift while dragging. No bar where the drop changes nothing (on the held card or on the one after it): letting go there lets go, with no toast. The column scrolls when the pointer is within 24px of its top or bottom edge.
- **Keyboard.** With the card held by `M`: `↑` and `↓` move it one place in its column, at once on the page, and the positions follow; at the first or last place the key does nothing. `Enter` drops it where it is (the reorder is now pending, with its toast); `Esc` lets go and puts the order back as it was before the hold. A digit still moves the card to its column (#125) and discards the arrows. `Esc` order stays #125's: note box, held card, maximized panel. While a card is held, the arrows and `Enter` are taken from the page (no scroll, the card does not open); all are ignored while typing.
- **Touch (`pointer: coarse`).** No drag. `Move` holds the card as in #125; under the held chip of an ordered column a row of three ghost buttons (44px targets) appears: `Up`, `Down`, `Place here`. `Up` and `Down` are the arrows (disabled at the first and last place), `Place here` is `Enter`; a tap elsewhere lets go and puts the order back.
- **After a reorder.** The column shows the new order and positions at once and keeps them until the snapshot agrees (as #125's moved chip; no caption on the chip). #125's `.itoast` names the card and its new position, with `Undo` for 5 s and no `Comment` link. Holding the same card again inside the 5 s continues the same reorder: one toast, the 5 s restart, and `Undo` returns to the order before the first hold. After `Undo` the toast says where the card is back.
- **Refused.** The column returns to the board's order and the panel's `.pnote` (`role="status"`, `bad`) says why: the card left the column, the card it was dropped before left the column, or the server's reason (locked, not an ordered column). `M` or `Move` on a locked chip answers with #125's locked status line.
- **Status line (#125's, `role="status"`).** On hold in an ordered column: the card, its position, the column, then the choices (digits first, then arrows, `Enter`, `Esc`). After each arrow: the card and its new position. Letting go reuses #125's `#12 let go. It did not move.` The drop itself is announced by the toast, not repeated here.
- **Focus.** It stays on the chip (by `data-key`) through every arrow, after `Enter`, after a pointer drop and after `Place here`; the chip is kept in view (`scrollIntoView`, nearest). After `Undo` focus goes to the chip in its old place, as the `Undo` button is gone.
- **Motion.** A chip that changes place slides with #125's one 150ms ease-out; instant under reduced motion. The drop bar appears and leaves with no animation.
- **Small screens.** Below 860px a held card of an ordered column keeps its own column in view: #125's scroll to the first accepting column does not happen for it (the status line names the choices; the accepting column is one sideways scroll away). The `Up` / `Down` / `Place here` row wraps inside the column's 168px.
- **Language.** New entries in `scripts/lang/dashboard.pt-BR.json`; column names inside them stay in English. Reused as they are: `Undo`, `Move`, #125's let-go and locked status lines, and its accept-line meanings.

| Where | English | pt-BR |
|---|---|---|
| Chip, position (screen reader) | Position 2 of 5 | Posição 2 de 5 |
| Touch row | Up / Down / Place here | Subir / Descer / Deixar aqui |
| Toast | #12 is now 2 of 5 in Ready for Dev. The board confirms it on the dispatcher's next read. | #12 agora é o 2 de 5 em Ready for Dev. O quadro confirma na próxima leitura do dispatcher. |
| Toast after Undo | #12 is back at 4 of 5 in Ready for Dev. | #12 voltou para 4 de 5 em Ready for Dev. |
| Refused, card left | #12 was not reordered: it is no longer in Ready for Dev. | #12 não foi reordenado: ele não está mais em Ready for Dev. |
| Refused, neighbour left | #12 was not reordered: #9 is no longer in Ready for Dev. | #12 não foi reordenado: o #9 não está mais em Ready for Dev. |
| Refused, other | #12 was not reordered: \<reason\> | #12 não foi reordenado: \<motivo\> |
| Status, held (keyboard) | Holding #12, 4 of 5 in Ready for Dev. Press 1 to refine again, Up or Down to reorder, Enter to place it, Esc to let go. | Segurando o #12, 4 de 5 em Ready for Dev. Aperte 1 para refinar de novo, seta para cima ou para baixo para reordenar, Enter para deixar no lugar, Esc para soltar. |
| Status, held (touch) | Holding #12, 4 of 5 in Ready for Dev. | Segurando o #12, 4 de 5 em Ready for Dev. |
| Status, after an arrow | #12, 3 of 5. | #12, 3 de 5. |

## Architecture
_Tech Lead_

One layer, `factory`. No migration, no new dependency, no build.

**Depends on #125.** Its code (`move`, `owner_move`, `OWNER_MOVES` as the table M1 to M7, the overview's `lock`, `position` and `moves`, the page's `S.hold` and `S.pending`) is not in `main` yet. Develop starts after #125 is merged, on this branch brought up to `main`.

**How the board orders.** A GitHub Project keeps one order for all its items; a column's order is that order filtered by Status, and a change of Status leaves it as it was. `updateProjectV2ItemPosition(projectId, itemId, afterId)` puts an item right after another one, or first in the project without `afterId`. Board order below means this order.

**Contracts**
- New: `POST /api/card/<project>/<n>/reorder`, body `{column, before}` (`column` is where the page saw the card; `before` is the issue number of the card it goes before, or `null` for the end of the column). Answers:
  - `200 {position}`: the card's new place in its column, 1-based. A card already in that place is a `200` with no write.
  - `400 {error}`: `before` is the card itself, or neither a number nor `null`. Nothing changed.
  - `403 {error}`: `column` is not Inbox, Ready for Refinement or Ready for Dev. Nothing changed.
  - `409 {error, column, gone}`: on the live board the card is not in `column`, or `before` is not in it; `gone` is the issue number of the one that left. Nothing changed.
  - `423 {error, locked}`: the card has a lock, as #125's `move` answers. Nothing changed.
  - `502 {error}`: `gh` failed. Nothing changed.
- Changed: #125's `POST /api/card/<project>/<n>/move`, same path, body and answers. A move whose target is Inbox, Ready for Refinement or Ready for Dev (M1 to M5) first puts the item after the last card of the target column, then changes its Status. A failed position write is the existing `502` with nothing moved.
- `GET /api/overview`: a card's `position` (from #125) is also filled in the Inbox; in every column it is the place in board order. `cards` come in board order (they already do). Top level gains `ordered`: the three column names, as the server holds them.
- `scripts/board.sh`: the board query asks for the order by name (`orderBy: {field: POSITION, direction: ASC}`). Output format, `eligible` and `first` unchanged: they already keep the order of the read, and `dispatch.sh` already walks `eligible` from the first line and skips a card it cannot start.

**Modules**
- `scripts/board.sh`: the `orderBy` in `BOARD_QUERY`. Nothing else: no owner path for the agents here.
- `scripts/dispatch.sh`: not changed. Its behaviour of AC-4 is pinned by a test.
- `scripts/dashboard.py`
  - `ORDERED`: the three columns.
  - `Factory.board_rows(p)`: the live board, every row in order; `board_row` reads from it.
  - `Factory.place(p, num, owner, item, after)`: the mutation through `gh api graphql` (no `--jq`), the project id from `board-ids` or `gh project view`, as `move` finds it.
  - `Factory.owner_reorder(p, n, seen, before)`: reads the live board, then refuses in this order: bad `before`, column not ordered, card not in `seen`, `before` not in it, lock. `after` is the item right before `before` in board order, the moved card left out (none: first in the project); for `null`, the column's last card.
  - `Factory.owner_move` (#125): the position write before the Status write, for a target in `ORDERED` that has a card.
  - After a write that worked, the rows as they now stand go into the dashboard's own board read (`_snap`), so the next overview has the new order without waiting for the dispatcher.
  - `overview()`: `position` in the Inbox, and `ordered`.
  - `Handler.do_POST` accepts `reorder`.
- `scripts/dashboard.html`
  - A chip of an ordered column shows its position; which columns are ordered comes from the overview's `ordered`.
  - While a card of an ordered column is held (`S.hold`), the other chips of its column and the column's end are drop targets; a drop on a chip of another column goes to #125's rules alone.
  - With `M`, the arrows change the held card's place on the page only; `Enter` makes the reorder, `Esc` puts it back.
  - A reorder goes into `S.pending` as a move does: one entry per card (holding the card again inside the 5 s continues it, and Undo goes back to the order before the first hold), 5 s on the page with the column shown in the new order, Undo drops it before any request leaves, `pagehide` sends it with `keepalive`. The page keeps showing the new order until the overview agrees, as `S.moving` does for a column.
  - A refusal puts the column back as the overview has it and says why in `.pnote`.
- `scripts/lang/dashboard.pt-BR.json`: every new string of the UX table.
- `scripts/test/fake-gh` and `scripts/test/demo-gh`: a GraphQL call that carries `updateProjectV2ItemPosition` is recorded and moves the row in the fake board, so a read after it sees the new order.
- `scripts/test/dashboard-order.test.sh` and `scripts/test/dispatch-order.test.sh`: new.
- `PRODUCT.md`, line "Owner-only actions": names ordering the three columns.
- `docs/how-it-works.md`: where it says how the dispatcher picks a card, it says from the top of the column and who sets the order.

**Not touched:** the board snapshot format (`board.tsv`), `scripts/dispatch.sh`, Ready for Prod, the list and the collapsed band.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-order.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-order.test.sh` |
| AC-3 | manual | review: hold a card with `M`, move it with the arrows, drop it; hold again and `Esc` |
| AC-4 | factory | `scripts/test/dispatch-order.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-order.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-order.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-order.test.sh` |
| AC-8 | manual | review: drop a Ready for Dev card on a card of Ready for Refinement and on a card of Spec Review |
| AC-9 | factory | `scripts/test/dashboard-order.test.sh` |

What the automated files prove per AC: AC-1, the overview gives `position` 1, 2, 3 in board order in the three columns, and each new string is in the pt-BR catalog; AC-2, `reorder` sends the mutation with the right `afterId` (before the first card, in the middle, `null` for the end) and the next overview has the new order; AC-4, with the real `board.sh` over the fake `gh`, two cards in Ready for Dev and one slot start the first of the board, and the second when the first is blocked, and the query names the order; AC-5, the page holds a reorder for 5 s and sends it on `pagehide`, read as text as `dashboard-quick.test.sh` does; AC-6, a locked card is a 423 and a card of another column a 403, with no write; AC-7, a stale `column` or `before` is a 409 with no write; AC-9, each of M1 to M5 writes the position after the column's last card before the Status, and a failed position write moves nothing. The gestures (drag, arrows, Undo in the toast) are checked by hand in review, as #125 does.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Develop waits for #125 in `main`: this change extends its endpoint, its overview fields and its hold and pending state, and none of that code exists on `main` yet.
- The order is the Project's own item position, written with `updateProjectV2ItemPosition`: the issue says the board is the source of truth, and the dashboard stores nothing.
- The dispatcher's code does not change: `eligible` already keeps the order of the board read and the dispatcher already skips a card it cannot start. The query now names the order instead of relying on the default, and a test pins the behaviour.
- A card moved from the page into an ordered column lands last (AC-9): a Status change keeps the item's old place in the Project, which can be the top of a queue, and the dispatcher would take a card the owner never ranked.
- That position write goes before the Status write: if the second fails the card has not moved; the other way round a failure leaves a card on top of a queue.
- The factory needs no such write: `board.sh move` refuses the three queues as targets, so only the owner brings a card into them.
- A reorder is `{column, before}` with `null` for the end, not a number of places: it says what the owner saw, so a stale page is refused (409) instead of landing somewhere else.
- Undo is the 5 s hold of #125, not a second write that restores: nothing reaches the board until the 5 s pass. Several arrow presses on one card leave as one write.
- After a write the dashboard keeps the new rows in its own board read: a reload shows the new order at once, and `board.tsv` stays the dispatcher's to write.
- By keyboard, `Enter` places the held card and the arrows alone send nothing: AC-3 says `Esc` leaves the order as it was, and a stray arrow must not reach the board.
- A locked card cannot be reordered, on the page and on the server (423), as it cannot be moved in #125; another card can still be dropped before it.
- Ready for Prod is not reorderable: the issue names three columns and that one is not among them.
- The board read stays at the first 100 items of the Project: unchanged here, and a board that large is its own issue.
- `position` in the overview is the place in board order in every column that has one, replacing "oldest first" in #125's UX text: the dispatcher takes cards in that order, so that is the line the owner needs.
- #56 is closed by the owner after ordering the columns in the page: its list is not migrated, and the pipeline closes only its own issue.
- The gestures (AC-3, AC-8) are checked by hand in review: the factory layer has no browser runner, as in #125. The server side of every other AC is automated.

## Open questions
- none
