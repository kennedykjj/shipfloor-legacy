# Dashboard: a quick Approve skips the review check and is lost when the tab closes — spec

**Issue:** #50 · **Branch:** `feat/50-dashboard-a-quick-approve-skips-the-revi` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** A decision given in the list waits 5 s in a browser timer before it is sent, so "approve, close the tab" (the page's main use) silently approves nothing; and the list's Approve button and the `A` key skip the drawer's review check, so a card with unreviewed items or requested changes moves on one click.
**Audience:** The factory's owner (and developers who install the plugin), using the dashboard in quick checks: open, approve what waits, close.
**Acceptance criteria**
- **AC-1** — Given a card whose review is complete with no changes asked (or that has no review page), when the owner clicks Approve in its row or presses `A` and closes the tab within 1 s, then the card moves to its next column on the board.
- **AC-2** — Given an approval still inside its 5 s wait, when the owner clicks Undo, then the card does not move, now or when the tab is later closed.
- **AC-3** — Given several approvals inside their wait, when the tab is closed, then every one of them is sent and none is sent twice.
- **AC-4** — Given a card whose review has unreviewed items or asks for changes, when the owner clicks Approve in its row or presses `A`, then nothing is sent and no timer starts: the card's drawer opens showing the same "N not reviewed / N changes asked" confirmation as the drawer's own Approve.
- **AC-5** — Given a card that has a review page the dashboard has no marks for yet (never opened in this session), when the owner clicks Approve in its row or presses `A`, then it is treated as AC-4: the drawer opens on the review and nothing is approved by that click or key.
- **AC-6** — Given the confirmation opened from the list, when the owner confirms Approve there, then the card moves exactly as it does from the drawer; when they close the drawer instead, the card stays.
- **AC-7** — Given a decision confirmed in the Inbox view and still inside its 5 s wait, when the tab is closed, then it is sent with its note, and one that was undone is not.
- **AC-8** — Given an approval whose send fails while the page is open, when the response arrives, then the row returns to waiting with a message naming the card and the reason; nothing shows a card as moved that the board did not move.
**Out of scope:** changing the 5 s wait or the Undo design; persisting pending decisions across sessions or retrying them on the next open (the dashboard keeps no card state); a server-side review check; changes to Request changes, Unblock, or the drawer's own approve flow; reporting a failed send after the tab is already gone (the board, read on the next open, is the answer).
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner: an action given must land or be reported) and principle 1 (no decision lives only in the browser; the board stays the truth). Holding the list to the drawer's check is in the spirit of principle 2. No conflict with positioning; the cost is that a Staged card with a review page can no longer be approved unseen by one key.
**Touches UI:** yes

## UX
_UX/UI Designer_

No new component, token or motion: the row (`passHtml`), its `.pnote`, the drawer's decision (`renderDecide`, `syncDecide`) and the soft Approve are reused as they are. Applies to Staged rows only; a Spec Review row has no Approve and `A` still does nothing there.

- **Clean card (AC-1, AC-2, AC-3):** the row looks exactly as today: "Moving to <column>", the 5 s bar, Undo. Closing the tab shows nothing: no "Leave site?" prompt, no toast, no extra state. Same for the Inbox toast (AC-7).
- **Review with known doubt (AC-4):** Approve in the row, or `A`, opens the card's drawer the way "Review" does (wide, Review tab) and the row stays as it was: no "Moving to", no bar, no Undo. The drawer's Approve arrives **already armed**: soft, "Approve with 2 not reviewed" (or "Approve with 1 change asked"), hint "Click again to move it anyway.", for the same 4 s. The list click counts as the first of the two asks, so the owner sees the confirmation itself, not a button to click to get it.
- **Focus (AC-4):** lands on the drawer's Approve, not the title, so Enter or Space confirms and a screen reader reads the armed label. `#approve` gets `aria-describedby="approve-hint"`, so the hint is read with it.
- **Armed lapses:** after 4 s the button returns to "Approve → <column>" (still soft) with the existing hint ("2 items not reviewed yet" / "The review asks for 1 change."); focus stays on it. From there it is the drawer's own flow.
- **Review page with no marks yet (AC-5):** the drawer opens the same way, focus on the title as for any opened card, Approve **not armed** (there is no count to confirm yet) and the hint slot reads the new line below. When the review reports its marks the hint gives way to the existing ones; the line is also dropped when the drawer closes. Focus is kept off Approve here so `A` then Enter cannot approve a review that has not loaded.
- **Repeat (AC-4, AC-5):** Approve in the row or `A` again while that card's drawer is open sends nothing: it re-arms (AC-4) or leaves the drawer as it is (AC-5). Only the drawer's Approve sends.
- **Confirm or leave (AC-6):** confirming shows the drawer's existing busy state and "Moved to <column>…" notice; the row leaves the list as after any drawer approve, with no 5 s wait and no Undo. Esc or Close: the row is unchanged, with no note, and focus returns to it.
- **Send fails (AC-8):** the row goes back to its waiting state (Approve, Review, Request changes) with the message in the existing `.pnote` (13px, `bad`, `role="status"`, so it is announced without moving focus). It stays until the owner acts on that row again. The Inbox keeps its `#ierr` line.
- **Small screen:** nothing new. Below 860px the drawer covers the list at full width; under 540px the decision stacks with Approve and its hint first, so the armed label is visible without scrolling.
- **Copy (new or changed; en / pt-BR in `scripts/lang/dashboard.pt-BR.json`):**
  - AC-5 hint: "Nothing was approved: look at the review first." / "Nada foi aprovado: veja a revisão primeiro."
  - AC-8 row message: "#12 was not approved: <reason>" / "#12 não foi aprovado: <reason>" (an `rx` entry; the reason is the server's text, shown as it comes).
  - AC-8 with no reason from the server: "#12 was not approved: the decision did not go through." / "#12 não foi aprovado: a decisão não foi aplicada."

## Architecture
_Tech Lead_

A decision that waits in a browser timer is sent when the page goes away; the list asks the drawer's question before it starts a timer. The server's actions do not change.

**Layer:** `factory`. Files: `scripts/dashboard.html` (send on close, the list's check, the armed arrival, the row message), `scripts/dashboard.py` (one field in the overview; a client that hangs up does not stop an action), `scripts/lang/dashboard.pt-BR.json` (the new copy), `scripts/test/dashboard-quick.test.sh` (new), `DESIGN.md` (the "Yours" list and decision paragraphs).

**Contracts**
- **`GET /api/overview`:** each card gains `"review": true|false`, whether `reviews/<n>.html` exists for it; read only for cards with `awaiting` true, `false` for the rest.
- **`POST /api/card/<project>/<n>/<action>`:** same request and answers. New guarantee: once the body is read the action runs to its end even if the client closed the connection; the failed write of the answer is swallowed, not logged as an error.
- **`dashboard.html`, send on close:** one `pagehide` listener takes every entry of `S.pending` and `INB.hold`, clears its timer, removes it from the state and then sends it with `fetch(..., {keepalive: true})` (same path, token header and body as today; `api()` already passes the option through). An entry is removed before it is sent, by the timer or by the listener, so neither sends it twice (AC-3); Undo removes it, so there is nothing to send (AC-2, AC-7). On `pageshow` with `persisted` the overview is read again.
- **`dashboard.html`, the list's check:** `quick("approve")` computes the card's doubt: `reviewDoubt(S.review[k])` when the marks are known; "unknown" when they are not and the overview says `review: true`; none otherwise. No doubt: the 5 s timer as today. Doubt: no timer and no POST; `openCard(k, "review")`, then, with known marks, `S.armed = k` and the 4 s arm timer set after `openCard`'s reset, focus on `#approve`; with unknown marks a per-card flag shows the AC-5 hint until the first `review-progress` for that card or the drawer closing.
- **`dashboard.html`, failed send (AC-8):** `post()` writes `S.note[k]` as "#<n> was not approved: <reason>" for `approve`; the other actions keep their text.

**Migration:** none.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-quick.test.sh` |
| AC-2 | manual | `scripts/dashboard.html` (in the browser: Approve, Undo, close the tab; the card stays in Staged) |
| AC-3 | factory | `scripts/test/dashboard-quick.test.sh` |
| AC-4 | manual | `scripts/dashboard.html` (in the browser: leave an item unmarked, close the drawer, press `A` on the row) |
| AC-5 | factory | `scripts/test/dashboard-quick.test.sh` |
| AC-6 | manual | `scripts/dashboard.html` (in the browser: confirm the armed Approve; then repeat and press Esc) |
| AC-7 | factory | `scripts/test/dashboard-quick.test.sh` |
| AC-8 | manual | `scripts/dashboard.html` (in the browser: stop the server, Approve a row, wait 5 s) |

The automated rows test the server's side with a fake `gh`: an approve whose client closes the socket right after sending still moves the card (AC-1); a second approve for the same card with the old column answers 409 and moves nothing (AC-3); the overview says `review: true` for a Staged card with a review page and `false` for one without (AC-5); a request-changes with a note from a client that hangs up posts the note and moves the card (AC-7). The same file checks, by reading `dashboard.html` as text the way `theme.test.sh` does, that the `pagehide` listener is there and sends with `keepalive`.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- A card with a review page and no marks known to the page counts as not reviewed: otherwise the check would hold only for cards already opened, which is the case the issue complains about. Cost: a Staged card with a review page is no longer approved unseen by one key.
- Send on `pagehide`, not on `visibilitychange`: switching tabs must not end the 5 s in which Undo works; closing or leaving the page must.
- `fetch` with `keepalive`, not `sendBeacon`: the actions need the token header, which a beacon cannot carry.
- The Inbox's held decision is sent on close too (AC-7), but the review check is not extended to the Inbox: it shows the spec before the decision, and the issue is about the list.
- Nothing is kept or retried after the tab is gone: the dashboard holds no card state (principle 1); the board on the next open is the answer.
- The list click is the first of the two asks, so the drawer arrives armed when the marks are known; with unknown marks it arrives not armed with focus off Approve, so `A` then Enter cannot approve a review that has not loaded.
- The drawer's own Approve stays one click while the marks are unknown: the drawer flow is out of scope here, and #11 (marks kept by the server) closes most of that gap.
- The overview carries only whether a review page exists, not its marks: marks reach the server with #11; until then the page's memory is what is known.
- No server-side review check: marks are the owner's draft, and the server refusing an approve would make the dashboard decide.
- AC-2, AC-4, AC-6 and AC-8 are checked by hand: they happen in the browser and the factory layer has no JavaScript runner (same call as #11).
- #11 also adds a `pagehide` send in `dashboard.html`: whichever lands second merges into one listener.

## Open questions
- none
