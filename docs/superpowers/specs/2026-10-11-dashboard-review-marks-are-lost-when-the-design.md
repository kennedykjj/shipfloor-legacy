# Dashboard: review marks are lost when the review iframe reloads — spec

**Issue:** #11 · **Branch:** `feat/11-dashboard-review-marks-are-lost-when-the` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** Inside the dashboard drawer the review page forgets its Keep/Change marks and Change notes every time it reloads (tab switch, reopening the card, reloading the dashboard), so the decision bar counts items as not reviewed again and Approve asks twice for work the owner already did.
**Audience:** The factory's owner (and any developer running the plugin) reviewing Spec Review and Staged cards in the dashboard, in quick checks.
**Acceptance criteria**
- **AC-1** — Given a review page open in the drawer with an item marked Keep, when the owner switches to another drawer tab and back, then the item is still marked Keep and the page counter shows it as reviewed.
- **AC-2** — Given marks on a card's review page, when the owner closes the card and reopens it, or reloads the dashboard in the browser, then the same marks are shown.
- **AC-3** — Given an item marked Change with a typed note, when the review page reloads by any of those paths, then the item is still Change and the note text is intact, and the copied review text includes it.
- **AC-4** — Given every item marked Keep and the page reloaded, when the owner presses Approve, then the decision bar reports nothing left to review and Approve does not ask for a second confirmation.
- **AC-5** — Given marks on card A, when the owner opens card B (same or another project), then card B shows only its own marks and card A's are unchanged when reopened.
- **AC-6** — Given marks on a review page, when the page is rebuilt with different content (spec reworked) and opened again, then every item starts unmarked and the decision bar counts them all as not reviewed.
- **AC-7** — Given restored marks, when the owner confirms "Clear marks", then all marks and notes are gone and stay gone after the page reloads.
- **AC-8** — Given the review page opened standalone (outside the dashboard), when the owner marks items and reloads, then marks persist as they do today.
**Out of scope:** Carrying marks over to a rebuilt review page or matching old marks to new items; sharing marks across browsers or machines; any new visible element, counter or indicator; changing what Approve / Request changes do or send; loosening the iframe sandbox.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner): a review done once is not asked for twice. Principle 1 is respected, not contradicted: marks are the owner's unsent review draft, not card state; the board still holds the column and the dashboard decides nothing from marks beyond the existing confirmation. Stays local only.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

The dashboard server keeps each card's marks and hands them back inside the embedded page; the sandboxed page never gets storage or the API.

**Layer:** `factory`. Files: `scripts/dashboard.py` (store, endpoint, injection, embed script), `scripts/dashboard.html` (relay), `scripts/test/dashboard-marks.test.sh` (new), `scripts/test/review-page.test.sh`, `DESIGN.md` (the drawer's review paragraph). `scripts/review-template.html` and `scripts/review_page.py` do not change.

**Contracts**
- **Store:** `<home>/projects/<project>/reviews/<n>.marks.json` = `{"rev": "<rev>", "marks": {"<item id>": {"s": "ok"|"chg", "n": "<note>"}}}`, written to a temp file and renamed. `rev` is the first 16 hex of the SHA-256 of `reviews/<n>.html` as it is on disk.
- **`POST /api/card/<project>/<n>/marks`** (token in the header, like the other card actions), body `{"rev": "<rev>", "marks": {...}}`.
  - `200 {"ok": true}`: stored; empty `marks` deletes the file.
  - `409`: `rev` is not the current page's (the page was rebuilt); nothing is stored.
  - `400`: more than 500 ids, an id not matching `^[a-z0-9-]{1,80}$`, `s` not `ok`/`chg`, `n` not a string or over 2000 characters, or a body over 256 KB.
  - `404`: unknown project or no review page.
- **`GET /review/<project>/<n>?embed=1`:** before the embed block the server adds `<script>window.__shipfloorMarks={"rev":"<rev>","marks":{...}}</script>`; `marks` is `{}` when the file is missing, unreadable or of another `rev`. The JSON is written with `<`, `>` and `&` escaped as `<`-style sequences. Without `embed=1` the page is served as today. The `Content-Security-Policy: sandbox allow-scripts` header and the iframe's `sandbox="allow-scripts"` stay.
- **Embed script (`EMBED_CSS`):** on load, when `__shipfloorMarks.marks` has entries, it sets the page's `st` to them and calls `render()` before the first `review-progress`; after every change it also posts `{shipfloor: "review-marks", rev, marks: st}` to the parent.
- **Drawer (`dashboard.html`):** takes `review-marks` only from the open card's iframe (same check as `review-progress`), remembers the card key it arrived for, and sends the POST debounced (at most 500 ms); a waiting save is sent at once when the iframe is replaced or the dashboard page is hidden (`fetch` with `keepalive`). A failed save changes nothing on screen.

**Migration:** none. Review pages already built work as they are, because the server injects the script when it serves them.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | manual | `scripts/dashboard.html` (in the browser: mark Keep, open Sessions, come back) |
| AC-2 | factory | `scripts/test/dashboard-marks.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-marks.test.sh` |
| AC-4 | manual | `scripts/dashboard.html` (in the browser: all Keep, switch tab and back, Approve asks once) |
| AC-5 | factory | `scripts/test/dashboard-marks.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-marks.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-marks.test.sh` |
| AC-8 | factory | `scripts/test/review-page.test.sh` |

The automated rows test the server's side of each criterion with `curl`: what was saved comes back inside a fresh embedded page (AC-2, AC-3 with a note holding `</script>`), per card and project (AC-5), not after the page file changes (AC-6), not after an empty save (AC-7), and never in the page served without `embed=1` (AC-8).

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Marks live on the dashboard server under `reviews/<n>.marks.json`, not in the dashboard page's memory or `localStorage`: AC-2 needs them after a browser reload, and a server store can be tested with `curl`.
- The server writes the marks into the embedded page instead of the drawer posting them after load: the page has them before its first progress message, so the decision bar never shows a stale count.
- The marks are tied to a hash of the page file: a rebuilt page starts clean (AC-6) with no matching of old items to new ones.
- The save carries the `rev` the page was served with and the server refuses another: marks made on an old page cannot land on a rebuilt one.
- The review template is untouched and the embed script reads the page's own `st`: pages already built get the fix, and the standalone page keeps its `localStorage` (AC-8).
- The sandbox stays as it is: review pages are written by agents and must not reach the dashboard's origin or token; what they post is validated and bounded, and stored only as data for the same page.
- AC-1 and AC-4 are checked by hand: they happen inside the browser and the factory layer has no JavaScript runner (tests are Bash and Python); adding one for two checks is not worth a new dependency.
- No UX section: nothing new is shown, the page only gets back the state it already draws.
- A marks file left behind by an older page is ignored and overwritten by the next save; no cleanup job.

## Open questions
- none
