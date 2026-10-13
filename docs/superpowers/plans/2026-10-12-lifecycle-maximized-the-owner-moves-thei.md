# Lifecycle maximized: the owner moves their cards by dragging them — plan

**Issue:** #125 · **Spec:** `docs/superpowers/specs/2026-10-12-lifecycle-maximized-the-owner-moves-thei-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

The spec's open question (column names in pt-BR) was approved without an answer: option A, the recommended one and the one the spec is written for. English column and lane names only in the maximized Lifecycle and in the new messages; the catalog's existing column entries stay.

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-move.test.sh`), red.
2. Task 1 (factory), one task: the server and the page change together, because the acceptance file checks both (the server's answers, the overview's new fields, the page read as text, the catalog) and the build runs it whole. Inside the task the server comes first, then the page, then the catalog and the documents.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-move.test.sh` (new): AC-1, AC-2, AC-3, AC-5, AC-6, AC-8. AC-4 and AC-7 are manual (browser, in review).
- Starts the dashboard on a board it writes itself with the fake `gh`, as `dashboard-quick.test.sh` does; the fake records every board edit and every comment in `calls`.
- **AC-1:** `POST /api/card/<project>/<n>/move` with `{column, to}` for M1, M2, M3 and M6 answers `200 {moved_to}` and the fake shows one board edit to the target and no comment.
- **AC-2:** for M4, M5 and M7 an empty `text` answers 400 with no edit and no comment; a non-empty `text` answers 200, and the fake shows the comment with that text before the edit.
- **AC-3:** every other ordered pair of the ten columns answers 403 with no edit and no comment (the card is put in the From column of the pair first, so the 403 is about the pair and not a stale column). The page keeps no second table: it reads what a card accepts from the overview's `moves`.
- **AC-5:** a `move` whose `column` is not where the live board has the card answers `409 {error, column}` with no edit. Page, read as text: a move waits 5 s in `S.pending` before it is sent, and the `pagehide` listener sends what is pending with `keepalive`. `POST /api/card/<project>/<n>/comment` posts the text and edits nothing (`200 {commented: true}`), and refuses an empty one (400).
- **AC-6:** a card with a live run (not an orphan) and a card labelled `blocked:infra` answer `423 {error, locked}` (`run`, `infra`) through `move`, `approve` and `request-changes`, with no edit and no comment; `GET /api/overview` says `lock` for each and `null` for a free card.
- **AC-8:** `GET /api/overview` carries `opened` on each card, `position` (1-based, board order) in Ready for Refinement, Ready for Dev and Ready for Prod and `null` elsewhere, and top-level `moves` equal to M1 to M7 with their `note` flag. Each new string of the spec's UX table that the page shows is in `scripts/lang/dashboard.pt-BR.json` with the spec's translation, and no new entry translates a column or a lane name.
- Before the implementation the tests fail on their assertions (a 404 for `move`, no `lock` / `opened` / `position` / `moves`, strings missing from the catalog), not on a missing file or a crash.

## Task 1 — factory: the owner's moves, one table on the server, and the maximized Lifecycle that drives them

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.py` (change)
- `scripts/dashboard.html` (change)
- `scripts/lang/dashboard.pt-BR.json` (change)
- `DESIGN.md` (change: the inline SVG marks line names the lock as the third)
- `PRODUCT.md` (change: the "Owner-only actions" line names M1, M2 and M5)
- `docs/operation.md` (change: the paragraph on what the owner does in the dashboard names the moves)

**`scripts/dashboard.py`**
- `OWNER_MOVES` becomes the one table of M1 to M7: per From column, its targets with `note` (required or not). `approve` and `request-changes` read their target from it (Spec Review and Staged: the target without a note is the approve, the one with a note is the request for changes). Every other reader of `OWNER_MOVES` (`awaiting`, `review`, `you`) keeps meaning "Spec Review or Staged": the three new From columns do not make a card "awaiting the owner".
- `Factory.owner_move(p, n, seen, to, text, move_only)`: reads the live board (`board_row`), then refuses in this order: stale column (409 with `column`), pair outside the table (403), lock (423 with `locked`), missing note (400); then the comment (a non-empty `text`, unless `move_only`), then `move`. A `gh` failure is 502 with `commented`. `Factory.act` picks `to` from the action and calls it, so `approve` and `request-changes` keep their path, body and answers and gain only the 423.
- Lock, read at the time of the move: `live(p)` for a run on the card that is not an orphan (`run`), and the issue's labels through one `gh api repos/<repo>/issues/<n>/labels` (`blocked:infra` → `infra`, `blocked` → `blocked`). Not from the cached overview.
- `Factory.comment(p, n, text)`: posts the text on the issue and moves nothing; 400 when empty, 502 when `gh` failed.
- `titles()` asks `createdAt` in the query it already sends; `overview()` gives each card `lock` (`"run"`, `"infra"`, `"blocked"` or `null`), `opened` and `position`, and the top level `moves` (`{<from>: [{to, note}]}`). Existing fields stay.
- `Handler.do_POST` accepts `move` (body `{column, to, text, move_only}`) and `comment` (body `{text}`) beside the six actions it lists, under the same token check.

**`scripts/dashboard.html`** (the maximized Lifecycle only: `.band.maxed`, `.lcol`, `.chip`; the collapsed band and the list do not move cards)
- `OWNER` is derived from the overview's `moves`; no second table in the page. What the list and the drawer read from it today (Spec Review and Staged, approve first) keeps working.
- `renderLanes`: a chip shows its wait (`dur` from `since`, or `opened` for a card that never ran) after the state word and, in a queue column, `N of M in line`; a movable chip is `draggable` with `cursor: grab`; a locked one is `aria-disabled`, not draggable, with the 12px inline SVG lock and its reason in the `<small>`. The column labels are English in pt-BR too (left out of the page's rewrite, as the lane names are).
- Hold state `S.hold`: set by `dragstart`, `M` on a focused movable chip, or the touch `Move` button (`pointer: coarse`); cleared by a drop, a digit, a click on an accept line, `Esc` or `dragend`. While held: accepting columns get the dashed `sand` border, the wash and the accept line as a `<button class="btn ghost">` (`Drop to …`, `Press 1 to …` with `<kbd>`, `Tap to …`), numbered left to right in board order; the others dim; a factory column that does not accept says `the factory moves`. `Esc` order: note box, held card, then the maximized panel. `M` and digits are ignored while typing. `M` on a locked or factory card holds nothing and says why in the status line.
- Moves at once (M1, M2, M3, M6) go into `S.pending` as the list's quick approve does (5 s, chip shown in its To column with the `Moving to` caption, Undo drops it before any request leaves, `pagehide` sends with `keepalive`), through the `move` endpoint. M3 and M6 call `lookFirst` first when `reviewDoubt` or an unseen review page says so, exactly as `quick("approve")`, and then send nothing.
- Note moves (M4, M5, M7): the note box (the `.peek` surface, `role="dialog"`, the inbox's `.iconf` form) anchored under the target column's label; the send button is disabled while the note is empty; Cancel or `Esc` closes it and returns focus to the chip, which has not moved. With a note the move takes the same 5 s hold, and the note is posted only when the move leaves.
- Toast (`.itoast`, bottom of the panel): the message, `Comment` (opens the same box as optional; adds `text` to the move while it is pending, calls `comment` once it has left) and `Undo` for 5 s; a note move shows Undo and no Comment. A refused move (409, 423, 403) puts the chip back and says so in the panel's `.pnote`.
- Toggle "Only what I can move" (`.sw.sand`) in the panel's heading row: page state, off at every load, not stored; dims every chip the owner cannot move, and shows the `.empty` line when nothing is movable.
- One polite status line under the heading (`role="status"`) carries the hold with its choices, the let-go, the lock's reason and the result.
- Small screens and motion as the spec's UX section says (lanes scroll sideways below 860px, the first accepting column scrolls into view, the 150ms slide is instant under reduced motion). No new component and no new token.

**`scripts/lang/dashboard.pt-BR.json`**
- Every new string of the spec's UX table, with the translation the table gives; a column or lane name inside one stays in English. No new entry whose key is a column or lane name.

**Documents**
- `DESIGN.md`: the lock is the third allowed inline SVG mark, always beside its reason in words.
- `PRODUCT.md`: "Owner-only actions" names approve and request changes, and the three new moves (send to refinement, take out of the queue, refine again).
- `docs/operation.md`: the paragraph on what the owner does in the dashboard names the seven moves.

**Not touched:** `scripts/board.sh`, the board snapshot format, `send-back`, `accept`, `unblock`, `message`, the collapsed band, the list.

**Risk to keep small:** `origin/main` has moved the dashboard since this branch was cut (six commits, among them #126, #132 and #135 in `scripts/dashboard.html`). The deploy merges main once, on the approved head; keep the edits to existing lines of `dashboard.html` few and local (new functions and new CSS rules in their own blocks) so that merge stays small.

**Done when:** `scripts/test/dashboard-move.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.
