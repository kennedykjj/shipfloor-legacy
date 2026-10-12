# Dashboard: a quick Approve skips the review check and is lost when the tab closes — plan

**Issue:** #50 · **Spec:** `docs/superpowers/specs/2026-10-11-dashboard-a-quick-approve-skips-the-revi-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-quick.test.sh`), red.
2. Task 1 (factory), one task: the server and the page change together, because the acceptance file checks both (the server's answers and the page's `pagehide` listener) and the build runs it whole.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-quick.test.sh` (new): AC-1, AC-3, AC-5, AC-7. AC-2, AC-4, AC-6 and AC-8 are manual (browser).
- Starts the dashboard on a board it writes itself with the fake `gh`, as `dashboard.test.sh` and `dashboard-titles.test.sh` do.
- **AC-1:** an `approve` POST whose client closes the socket right after sending the request (no read of the answer) still moves the card: the fake's `calls` show the move, and the server log has no traceback or error line for the failed write.
- **AC-3:** a second `approve` for the same card carrying the old column answers 409 and moves nothing (no second move in `calls`).
- **AC-5:** `GET /api/overview` says `"review": true` for a Staged card with `reviews/<n>.html` and `false` for one without; a card that is not awaiting the owner says `false` even with a page.
- **AC-7:** a `request-changes` POST with a note from a client that hangs up posts the note and moves the card.
- **Page, read as text** (the way `theme.test.sh` reads `dashboard.html`): a `pagehide` listener exists and its send uses `keepalive`.
- Before the implementation the tests fail on their assertions (no `review` field, no `pagehide` listener, an error logged for the hung-up client), not on a missing file or a crash.

## Task 1 — factory: a pending decision is sent when the page goes away, and the list asks the drawer's question

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.py` (change)
- `scripts/dashboard.html` (change)
- `scripts/lang/dashboard.pt-BR.json` (change)
- `DESIGN.md` (change: the "Yours" list and decision paragraphs)

**`scripts/dashboard.py`**
- `overview()`: each card gains `"review"`: whether `reviews/<n>.html` exists, read only when `awaiting` is true; `false` for the rest.
- `do_POST` on `/api/card/<project>/<n>/<action>`: once the body is read the action runs to its end whatever the client does. The write of the answer to a client that closed the connection (`BrokenPipeError`, `ConnectionError`) is swallowed: no traceback, no error line, and it is not turned into a second `send(500, ...)`. Request and answers stay as they are.

**`scripts/dashboard.html`**
- **Send on close:** one `pagehide` listener. For every entry of `S.pending` and for `INB.hold`: clear its timer, remove it from the state, then send it with `fetch(..., {keepalive: true})` through `api()` (same path, token header and body as the timer's send; the Inbox one with its note). An entry leaves the state before it is sent, by the timer or by the listener, so neither sends it twice; Undo already removes it. No "Leave site?" prompt.
- **`pageshow` with `persisted`:** read the overview again.
- **The list's check, in `quick("approve")`:** the doubt is `reviewDoubt(S.review[k])` when the marks are known; "unknown" when they are not and the overview card says `review: true`; none otherwise.
  - No doubt: the 5 s timer as today.
  - Known doubt: no timer, no POST; `openCard(k, "review")`, then `S.armed = k` and the 4 s arm timer set after `openCard`'s reset, focus on `#approve`.
  - Unknown: no timer, no POST; `openCard(k, "review")`, Approve not armed, focus on the title as for any opened card; a per-card flag shows the hint "Nothing was approved: look at the review first." until the first `review-progress` for that card or the drawer closing.
  - Repeat while that card's drawer is open: re-arms (known) or leaves the drawer as it is (unknown); only the drawer's Approve sends.
  - The `A` key goes through the same path as the row's button.
- **`#approve`:** `aria-describedby="approve-hint"`.
- **Failed send (AC-8), in `post()`:** for `approve`, `S.note[k]` is "#<n> was not approved: <reason>" (the server's text as it comes), or "#<n> was not approved: the decision did not go through." with no reason; a send that throws (server gone) ends the same way. The other actions keep their text. The row returns to waiting and shows the note in the existing `.pnote`.
- No new component, token or motion.

**`scripts/lang/dashboard.pt-BR.json`**
- "Nada foi aprovado: veja a revisão primeiro."
- An `rx` entry for "#12 não foi aprovado: <reason>" and the fixed line "#12 não foi aprovado: a decisão não foi aplicada."

**`DESIGN.md`**
- The "Yours" list and decision paragraphs say: a decision in its 5 s wait is sent when the page goes away; the row's Approve and `A` open the drawer's confirmation when the review has doubt or has not been seen.

**Done when:** `scripts/test/dashboard-quick.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.
