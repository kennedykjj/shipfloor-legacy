# Lifecycle maximized: a blocked card can go back to the spec, to refinement or to the Inbox — spec

**Issue:** #127 · **Branch:** `feat/127-lifecycle-maximized-a-blocked-card-can-g` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** A card blocked for the owner offers only "Unblock & retry". When the block shows the spec was wrong, or the card is not worth finishing now, the owner cannot take it back from the dashboard.
**Audience:** The factory's owner, in a quick check of the maximized Lifecycle.
**Prerequisite:** #125 (drag gesture, lit columns, comment box, `M` + digit). This spec adds only the blocked-card moves.
**Acceptance criteria**
- **AC-1** — Given a card blocked for the owner in Coding or Validation, when the owner picks it up (drag or `M`), then exactly Ready for Dev, Ready for Refinement and Inbox light up, each saying what dropping there means.
- **AC-2** — Given a card blocked for the owner in any other column, when the owner picks it up, then only Ready for Refinement and Inbox light up, and the page and the server's endpoint both refuse a move to Ready for Dev or to any other column.
- **AC-3** — Given a blocked card dropped on a lit column, when the comment box opens, then "Move" with an empty comment moves the card and posts nothing, "Move" with text also posts that text on the issue, and Cancel leaves the card where it was, still blocked.
- **AC-4** — Given a blocked card with an open pull request, when it is moved to the Inbox, then the pull request is closed and its branch still exists.
- **AC-5** — Given a blocked card with an open pull request, when it is moved to Ready for Dev or Ready for Refinement, then the pull request stays open and the branch exists.
- **AC-6** — Given a blocked card was moved, when the board is next read, then the issue has no `blocked` label and the card shows no block mark or block note on the board, in the list or in the band.
- **AC-7** — Given a card blocked by infrastructure, when the owner tries to pick it up by drag or `M`, then it does not move, shows the lock and says the factory retries it; the server's endpoint refuses it too.
- **AC-8** — Given a card blocked for the owner, when it is shown, then "Unblock & retry" is still on the card and works as before, and the new texts exist in English and pt-BR with column names kept in English.
**Out of scope:** The gesture itself and the non-blocked moves (#125); Undo for a blocked-card move (the box's "Move" is the confirmation; a closed pull request is not silently reopened); deleting the branch or reopening the pull request from the page; moving blocked cards in the collapsed band or in the list; the order inside a queue; any change to how the factory retries infrastructure blocks.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner: a block for the owner is exactly that, an infrastructure block is not) and principle 1 (the move goes to the GitHub board and label; the dashboard keeps no state of its own). It extends the owner-only actions in "Capabilities and Constraints" beyond approve and request changes, as #125 already does; no contradiction with the positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

Only what a blocked card adds to #125's gesture; the pick-up, the lit and dimmed columns, the note box, the toast region and `M` + digit are #125's and are reused as they are. No new component, no new token.

- **Pickable card (blocked for the owner):** the existing `.chip.stop` (`bad` border, number in `bad`), with #125's grab affordance and the existing line "Blocked · waits for your call" as its `small`. With "Only what I can move" on, it stays lit.
- **Locked card (blocked by infrastructure):** the existing `.chip.infra` (`warn` border) with #125's lock, `aria-disabled="true"`, never draggable, dimmed by "Only what I can move". A drag attempt or `M` moves nothing and shows the existing line "Blocked by infrastructure; the factory retries it" where #125 shows why a running card does not move (also the chip's `title`). No new string.
- **Lit columns:** blocked in Coding or Validation: Inbox, Ready for Refinement, Ready for Dev. Blocked anywhere else: Inbox, Ready for Refinement. Every other column dims as in #125 (a factory column still says "the factory moves"). Each lit column shows its drop line (table below) in #125's drop-line style; the line wraps to two lines, never truncates.
- **Keyboard:** `M` on a focused pickable chip holds it; digits number the lit columns left to right (1 Inbox, 2 Ready for Refinement, 3 Ready for Dev when lit) and the lines read "Press 1 to …". A digit opens the comment box; `Esc` lets go, and inside the box `Esc` is Cancel. Focus goes to the text area on open and back to the chip on Cancel or on a failed move.
- **Comment box:** #125's note box, with three differences: the label says the comment is optional, the primary button is the pill "Move" and is never disabled (empty is accepted and posts nothing), and a drop on Inbox adds one `muted` hint line under the text area about the pull request. Cancel is the plain button beside it. No toast with Undo follows: "Move" is the confirmation.
- **Moving:** after "Move" the box closes and the chip sits in the target column with the existing caption "Moving to <column>" and the existing `.bar`, locked, progress cursor; it is not pickable until the answer arrives.
- **Moved:** #125's toast region (`role="status"`, `ok`) shows the moved line, with no Undo and no "Comment" link. The chip is then an ordinary chip of its column: no `bad` border, no block line; the pass in "Yours", the band's dot and the drawer's block note go with the next board read.
- **Failed move:** the chip returns to its column, still `.chip.stop`, and the same region shows the failed line in `bad`, kept until the next pick-up. A move to Inbox whose pull request could not be closed is a failed move: the pull request is closed before the card moves, so the card is still blocked where it was and the move can be repeated.
- **"Unblock & retry":** unchanged and where it is today: the pill in the card's pass in "Yours" and the button in the drawer's block note, which a click (no drag) on the chip still opens. No button is added inside the chip: a chip is a `<button>`, and its click must stay "open the card".
- **Small screens:** the lanes keep #125's layout. The comment box takes the panel's full width under 860px and stacks its buttons, "Move" first; the hint line wraps.
- **Language:** new strings go in `scripts/lang/dashboard.pt-BR.json`. Column names inside them stay in English in pt-BR, so these entries must come before (and not be rewritten by) the catalog's `\bReady for …\b` rules, as #125 does for its own lines.

| English | pt-BR |
|---|---|
| Drop to redo the code from the approved spec | Solte para refazer o código a partir da spec aprovada |
| Drop to refine the spec again | Solte para refinar a spec de novo |
| Drop to take it out of the factory | Solte para tirar da fábrica |
| Press 1 to take it out of the factory (same three endings, any digit) | Pressione 1 para tirar da fábrica |
| Move #12 to Ready for Dev? A comment is optional; it is posted on the issue. | Mover #12 para Ready for Dev? O comentário é opcional; ele é publicado na issue. |
| An open pull request is closed; its branch is kept. | Um pull request aberto é fechado; a branch é mantida. |
| Move | Mover |
| #12 moved to Ready for Dev. The board confirms it on the dispatcher's next read. | #12 foi movido para Ready for Dev. O quadro confirma na próxima leitura do dispatcher. |
| #12 moved to Inbox; its pull request was closed. The board confirms it on the dispatcher's next read. | #12 foi movido para Inbox; o pull request foi fechado. O quadro confirma na próxima leitura do dispatcher. |
| #12 was not moved: <reason> | #12 não foi movido: <motivo> |

## Architecture
_Tech Lead_

**Contract (new):** `POST /api/card/<project>/<n>/take-back`, body `{"to": "Ready for Dev" | "Ready for Refinement" | "Inbox", "text": "<optional comment>"}`, same token check as the other card actions.
- `200 {"moved_to": <column>, "commented": <bool>, "pr_closed": <number or null>, "unblocked": true}`
- `400` when `to` is not one of the three columns.
- `409 {"error", "column"}` when the card is not on the board, is not blocked, is blocked by infrastructure, has a run in progress, or `to` is not allowed from its column.
- `502 {"error", "commented", "pr_closed"}` when a `gh` call fails; the body says what was already done.

**Rule (one table, server side):** `BLOCKED_MOVES` in `scripts/dashboard.py`: from Coding or Validation → Ready for Dev, Ready for Refinement, Inbox; from any other column → Ready for Refinement, Inbox. The page mirrors it to light the columns; the server decides.

**Order of a move** (`Factory.take_back`, next to `send_back`): read the block labels fresh (not the 60 s cache) and the live board row (`board_row`) → refuse or go on → comment on the issue when `text` is not blank → for Inbox, close the card's open pull request → move the card (`Factory.move`, as `act` does: `board.sh move` refuses owner columns on purpose) → take the labels off (`Factory.unblock`, which also drops the cached block and reason). A failure stops there and leaves the card blocked where it was, so the same move can be repeated.

**Pull request:** found among the repository's open pull requests by its branch, `feat/<n>-…` (`gh pr list --state open --json number,headRefName`), then `gh pr close <number>` with no `--delete-branch`. No open pull request is not an error (`pr_closed: null`). Nothing local is touched: the worktree and the local branch stay.

**Block note:** it is read from the issue's comments only while the label is there, so taking the label off and dropping `_blocked` / `_reasons` clears it on the board, in the list and in the band; no comment is deleted.

**Files** (all in layer `factory`):
- `scripts/dashboard.py` — `BLOCKED_MOVES`, `Factory.take_back`, the route in `do_POST`.
- `scripts/dashboard.html` — on #125's pick-up: a card with `blocked === "owner"` can be held and lights the columns of the table; one with `blocked === "infra"` keeps the lock; the note box in its optional form with "Move"; the call to `take-back` and the refresh after it.
- `scripts/lang/dashboard.pt-BR.json` — the new texts.
- `scripts/test/dashboard-take-back.test.sh`, `scripts/test/dashboard-take-back-page.test.sh` — new.

**Migration:** none (no stored data, no config key).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-take-back-page.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-take-back.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-take-back.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-take-back.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-take-back.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-take-back.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-take-back.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-take-back-page.test.sh` |

The server file drives the real `dashboard.py` against the `gh` stub, as `scripts/test/dashboard.test.sh` does (the stub's log shows the comment, the `pr close` without `--delete-branch`, the move and the label removal). The page file reads `scripts/dashboard.html` and the pt-BR catalog as text, as `scripts/test/dashboard-page.test.sh` does: no browser.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- No Undo after a blocked-card move: "Move" in the box is the confirmation, and a closed pull request is not reopened silently.
- The server refuses every move the table does not list, not only the page: #125 holds its own moves to the same rule.
- A card blocked outside Coding and Validation (Technical Refinement, or during deploy) gets Ready for Refinement and Inbox only: there is no code run to redo from the spec, or the deploy is not redone from Ready for Dev.
- A card with a run in progress is refused (409): #125's lock applies to every card, blocked or not.
- A new endpoint, `take-back`, instead of widening `send-back`: `send-back` requires a note and goes to Coding; it stays as it is, in the drawer.
- The pull request is closed before the card moves, so a failed close leaves the card blocked and the move repeatable; there is no "moved, but the pull request is open" state (AC-4 always holds after a move).
- The pull request is found by its branch `feat/<n>-…` among the open ones, not through the reports: a card blocked before its report was written still has its pull request closed.
- The block labels are read fresh on the move, not from the 60 s cache: a card unblocked a moment ago must not be moved as blocked.
- The block note needs no deletion: it shows only while the label is there; the comments stay on the issue as history.
- The local worktree and local branch are left alone on a move to the Inbox: the issue asks to keep the branch, and removing a worktree is not the dashboard's work.
- "Unblock & retry" stays where it is today (the pass in "Yours" and the drawer's block note), with no button inside the chip: a chip is a `<button>`, and one nested in it is invalid and would fight the drag.
- Digits number the lit columns left to right (1 Inbox, 2 Ready for Refinement, 3 Ready for Dev): #125 states no order, the board's is the one the owner already reads.
- The Inbox hint about the pull request is always shown: the page does not need to ask whether one exists before the drop.
- The label `ui` is not on the issue, but the page changes, so UX/UI wrote its section.
- Two test files (server against the `gh` stub, page read as text), as the dashboard's tests are split today; no browser, so no new layer.

## Open questions
- **Order with #125:** hold this card in Spec Review until #125 is in `main` (recommended) or fold #125's gesture into this card — #125 is still open and nothing of its gesture (pick-up, lit columns, note box, `M` + digit) is in the code; developed first, this card would have to build it.
