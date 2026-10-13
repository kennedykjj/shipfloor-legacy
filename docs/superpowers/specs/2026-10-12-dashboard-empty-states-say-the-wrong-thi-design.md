# Dashboard: empty states say the wrong thing or nothing — spec

**Issue:** #116 · **Branch:** `feat/116-dashboard-empty-states-say-the-wrong-thi` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** Four empty states of the dashboard mislead the owner during a quick check: a Staged card without a review page blames Refine, still opens on the empty Review tab, shows a blank reading pane in the maximized decision box, and a running card with no transcript says "Reading the session…" forever.
**Audience:** The factory's owner, doing quick checks in the dashboard (open, approve what waits, close).
**Acceptance criteria**
- **AC-1** — Given a Staged card with no review page, when the owner opens its Review tab, then the text says there is no review page for this pull request and points to the Gates tab and the pull request, and never names Refine.
- **AC-2** — Given a Spec Review card with no review page, when the owner opens its Review tab, then the text says Refine has not built the page yet (the only column where Refine is named).
- **AC-3** — Given a card that waits for the owner and has no review page, when it is opened without a tab being asked for (list row, Review button, `R`, peek), then the drawer opens on Gates, or on Sessions when the card has no gate results; the decision stays in place.
- **AC-4** — Given a card that waits for the owner and has a review page, when it is opened, then it still opens on Review as today.
- **AC-5** — Given a Staged card with no review page in the maximized decision box, when the owner selects it, then the reading pane shows under the title the pull request (number, CI, size), the gate results and the estimated cost, each only when known.
- **AC-6** — Given that same card with no pull request, no gates and no cost known, when the owner selects it, then the reading pane says in one line that nothing is recorded for it yet and offers the log, never a blank area.
- **AC-7** — Given a running card whose session has no transcript, when the Live tab has been open 10 seconds, then "Reading the session…" is replaced by a message that there is nothing to show yet and that the Log tab has what the run wrote.
- **AC-8** — Given that message is showing, when the transcript arrives, then the session replaces it without the owner reloading or switching tabs.
**Out of scope:** Building a review page for Staged cards; changing how review pages are generated or which stage writes them; other empty states (Sessions, Log, Gates, Feed, Settings); the request-changes and approve flows; new server endpoints or data beyond what the card already carries.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner: each empty state says what is true and what to do instead) and principle 3 (facts shown are the sourced ones, cost labelled as an estimate; nothing is inferred when missing). No conflict with positioning or scope.
**Touches UI:** yes

## UX
_UX/UI Designer_

No new component, class or token: every state reuses `.placeholder` (drawer panes), `.empty` (reading pane), `.lnk`, `.tag`, `.isec`, `.gate-list` / `.gate` and the muted text step. Prose in sentence case; column and tab names verbatim. pt-BR goes in `scripts/lang/dashboard.pt-BR.json` (`exact`, or `rx` where a figure is inside).

- **Review tab, no page (AC-1, AC-2)** — one `.placeholder` paragraph where the iframe would be, copy by column:
  - Spec Review: "No review page yet. Refine has not built it for this spec." / "Ainda não há página de revisão. O refine ainda não a montou para esta spec."
  - Staged: "No review page for this pull request. The Gates tab has what validation checked; the changes are in the pull request." / "Não há página de revisão para este pull request. A aba Gates tem o que a validação verificou; as mudanças estão no pull request."
  - Any other column (under the existing "Nothing to decide…" line): "No review page for this card." / "Não há página de revisão para este card."
  - The old string "No review page for this card. Refine builds it when the spec is ready." and its catalog entry are removed.
- **Links in the Staged text** — "Gates tab" is a `.lnk` button that selects the Gates tab (focus moves to the tab, as a click on it would); "pull request" is the existing external link style (`gh()` glyph, new tab) when the card carries the PR number, plain text otherwise. No button, no accent: nothing here waits for the owner.
- **Opening tab (AC-3, AC-4)** — no copy. A card that waits for the owner and has no review page opens on Gates when it has at least one report, else on Sessions; the drawer stays wide and the decision stays under the head, so nothing shifts. The list's "Review" button, `R` and the peek keep their labels. A tab asked for explicitly (Log, a tab the owner already chose on the same card) still wins.
- **Reading pane of the maximized decision box, Staged, no page (AC-5)** — under the title, in this order, each only when known: the existing `.ifacts` tags (`CI green` in its outcome color, `PR #64 · 3 files · +120 −14`, the cost), then one `.isec` titled "Gates" / "Gates" holding a `.gate-list` of the newest report's gates as `.gate pass` / `.gate fail` chips, exactly as the Gates tab draws them. The existing "What the validation said" and "Acceptance criteria" sections follow when they have content.
- **Cost tag (Estimate Rule)** — the tag reads "$1.23 est. so far" / "$1,23 est. até agora" instead of "$1.23 so far", in every column of the reading pane; it stays a plain `.tag`, not the accent.
- **Reading pane, nothing known (AC-6)** — one `.empty` line in place of "No validation report for this card yet.": "Nothing is recorded for this card yet." / "Ainda não há nada registrado para este card." followed on the same line by a `.lnk` button "Open the log" / "Abrir o log" (`data-open` + `data-go="log"`). While the card's detail is still loading the existing skeleton stays; the line appears only once the read ended with nothing.
- **Live tab, three states (AC-7, AC-8)** — all inside `#live`, `.placeholder`:
  - Reading (first 10 s after the tab opens on a running card with no transcript): "Reading the session…" (unchanged).
  - Waiting (after 10 s, still nothing): "Nothing to show yet. The Log tab has what the run wrote." / "Ainda não há nada para mostrar. A aba Log tem o que a execução escreveu." with "Log tab" as a `.lnk` button that selects the Log tab. The compose form stays below it, usable.
  - Arrived: the next read replaces the message with the stream, scrolled to its end; no reload, no tab switch, no transition (no new motion).
  - The 10 s count restarts when the owner opens another card or returns to the tab; "No factory session for this card yet." (card not running) is unchanged.
- **Errors** — none new: a failed read keeps the existing "Not updating" alert, and the pane keeps the state it was in.
- **Small screens** — nothing to lay out: `.placeholder` (64ch) and `.empty` wrap in the full-width drawer below 860px, tags and gate chips wrap in their flex rows, and the `.lnk` buttons stay inline in the sentence. In the reading pane widen the one-line `.empty` to the pane (it is capped at 34ch) only if the line and its link break badly at 320px.
- **Accessibility** — the in-text `.lnk` controls are real `<button>`s with the sand focus ring; the Live message swap is not announced (the stream is not a live region today and stays so).

## Architecture
_Tech Lead_

Client only: every fact is already in `/api/overview` (`review`, `column`, `cost`, `running`), `/api/card` (`reports`, `sessions`, `review`) and `/api/decide` (`pr`, `report.gates`, `spec`). No endpoint, field or server code changes.

**Files (all owned by layer `factory`)**
- `scripts/dashboard.html` — the four states below.
- `scripts/lang/dashboard.pt-BR.json` — one entry per new string; the entry of the removed string goes.
- `scripts/test/dashboard-empty.test.sh` — new, reads `dashboard.html` as text like `dashboard-quick.test.sh`.
- `scripts/test/dashboard.test.sh` — its AC-6 line (509) quotes the old placeholder literally; it follows the new `reviewPane` text.

**Functions touched in `scripts/dashboard.html`**
- `reviewPane(c, p, n, column)` — the missing-page paragraph comes from a new `noReview(column)`: Staged text names the Gates tab and the pull request; Spec Review text names Refine; any other column says the card has no review page. Still one `<p class="placeholder">`, never an iframe.
- `openCard(key, tab)` — a new `landing(ov)` picks the tab when none is asked or when `review` is asked for a card whose overview says `review: false`: `gates`. The choice is marked automatic (`S.auto`); `loadCard()` moves an automatic `gates` to `sessions` when `body.reports` is empty. `selectTab()` clears the mark, so a tab the owner clicked is never moved. A card with `review: true` keeps `review`.
- `renderDrawer()` — unchanged apart from reading `S.tab`; the decision box (`renderDecide`) does not depend on the tab, so it stays.
- `reviewPane` links — the Staged text's "Gates tab" is a `.lnk` button with `data-tab="gates"` (the existing click handler selects it); "pull request" links to `https://github.com/<c.repo>/pull/<pr>` with `pr` the newest integer `pr` in `c.reports`, plain text when there is none.
- `readHtml(c, d)` — the `.ifacts` tags stay (CI, PR, cost; the cost tag reads "est. so far" in every column). For a Staged card with no review page (`c.review` false) one `sec("Gates", …)` draws `d.report.gates` as the `.gate` spans of `gatesPane` (shared helper, not a copy), only when the report has gates. When `pr`, `report`, `s` and `c.cost` are all missing: one `<p class="empty">` line plus a `.lnk` button with `data-open` and `data-go="log"`, replacing "No validation report for this card yet.".
- `openCard()`, `paintLive()`, `followLive()` — `S.liveSince` is set when the Live tab opens for a card (in `openCard` and `selectTab`). `paintLive()` shows "Reading the session…" only while `Date.now() - S.liveSince < LIVE_WAIT` (a constant, 10000 ms); after that, with `S.liveHtml` empty, it shows the nothing-yet message. `followLive()` on a 200 with no events sets the nothing-yet message for a running card instead of "No factory session for this card yet." (kept for a card with no run), and events replace it on the next 2 s poll as today. The existing `tick()` (1 s) repaints the Live pane while it waits, so the message changes without a reply from the server.

**Migration:** none. No stored state, no config key.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-empty.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-empty.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-empty.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-empty.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-empty.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-empty.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-empty.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-empty.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Refine is named only on a Spec Review card: it is the one column where Refine still owes the page.
- A card with no review page opens on Gates, and on Sessions when it has no report: the overview does not carry the report count, so the fallback happens when the card's detail arrives, and only for a tab the owner did not pick.
- An explicit `data-go="review"` (list's Review button, `R`, peek, "Open the card") is treated as "no tab asked" when the card has no page: the labels stay, the landing tab changes.
- The Live wait is 10 seconds, counted in the page from when the tab opens: the stuck text comes from a read that never answers with events, so the bound cannot depend on the server's reply.
- A running card whose session read returns no events shows the nothing-yet message, not "No factory session for this card yet.": a run is working, so that sentence is false there.
- The reading pane's cost tag says "est. so far" in every column: DESIGN.md's Estimate Rule, and one string instead of two.
- No server change: the pull request, gates and cost are already in `/api/decide`, `/api/card` and `/api/overview`.
- Tests read `dashboard.html` as text in a new `scripts/test/dashboard-empty.test.sh`: the repo has no browser runner, as in `dashboard-quick.test.sh`; the timed swap in a real browser is checked by hand in review.
- `scripts/test/dashboard.test.sh` line 509 is updated with the new placeholder: it quotes the string this card removes.

## Open questions
- none
