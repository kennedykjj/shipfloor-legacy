# Dashboard: empty states say the wrong thing or nothing — plan

**Issue:** #116 · **Spec:** `docs/superpowers/specs/2026-10-12-dashboard-empty-states-say-the-wrong-thi-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-empty.test.sh`), red.
2. Task 1 (factory), one task: the four states live in one file (`scripts/dashboard.html`) and share state (`S.tab`, `S.auto`, `S.liveSince`), and the acceptance file is run whole by the build.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-empty.test.sh` (new): AC-1 to AC-8. It reads `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json` as text, the way `dashboard-quick.test.sh` and `theme.test.sh` read the page; no browser, no server.
- **AC-1:** the Staged text "No review page for this pull request." with the Gates tab as a `.lnk` button carrying `data-tab="gates"` and the pull request link; the old string "Refine builds it when the spec is ready." is gone from the page and from the pt-BR catalog.
- **AC-2:** the Spec Review text "No review page yet. Refine has not built it for this spec."; "Refine" appears in no other missing-page text ("No review page for this card." for the other columns).
- **AC-3:** `openCard` picks the tab through `landing(...)`; a card whose overview says `review: false` lands on `gates`, marked automatic (`S.auto`); `loadCard` moves an automatic `gates` to `sessions` when the card has no reports; `selectTab` clears the mark.
- **AC-4:** `landing` keeps `review` for a card with `review: true`.
- **AC-5:** `readHtml` draws a "Gates" section from `d.report.gates` for a card with no review page, through the helper `gatesPane` uses (one definition of the `.gate` chips, not a copy); the cost tag reads "est. so far" and "$… so far" without "est." is gone.
- **AC-6:** the line "Nothing is recorded for this card yet." as `.empty` with a `.lnk` button "Open the log" (`data-open`, `data-go="log"`); "No validation report for this card yet." is gone.
- **AC-7:** a `LIVE_WAIT` constant of 10000; `paintLive` compares `Date.now() - S.liveSince` with it and shows "Nothing to show yet. The Log tab has what the run wrote." with the Log tab as a `.lnk` button (`data-tab="log"`); `S.liveSince` is set in `openCard` and `selectTab`.
- **AC-8:** `followLive` sets the nothing-yet message, not "No factory session for this card yet.", for a running card with no events, and keeps polling, so the events replace the message; the repaint while waiting comes from the 1 s tick.
- **Catalog:** every new English string has its pt-BR entry (the spec's UX section gives each one).
- Before the implementation the tests fail on their assertions (the strings and functions are not there), not on a missing file or a crash.

## Task 1 — factory: each empty state says what is true for the card

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` (change)
- `scripts/lang/dashboard.pt-BR.json` (change)
- `scripts/test/dashboard.test.sh` (change: its line 509 quotes the placeholder this card removes; it follows the new `reviewPane` text for that card's column)
- `DESIGN.md` (change, only if it quotes one of the replaced strings or describes the opening tab)

**`scripts/dashboard.html`**
- **`noReview(column)` and `reviewPane(c, p, n, column)`:** still one `<p class="placeholder">`, text by column as in the spec's UX section. Staged: "Gates tab" is a `<button class="lnk" data-tab="gates">` (the existing tab click handler selects it and moves focus as a click on the tab would); "pull request" links to `https://github.com/<c.repo>/pull/<pr>` in the existing external link style (`gh()` glyph, new tab), `pr` being the newest integer `pr` in `c.reports`, plain text when there is none.
- **`landing(ov)` and `openCard(key, tab)`:** when no tab is asked, or `review` is asked for a card whose overview says `review: false`, the tab is `gates` and `S.auto` is set; a card with `review: true` keeps `review`; any other tab asked for wins. `loadCard()` moves an automatic `gates` to `sessions` when `body.reports` is empty. `selectTab()` clears `S.auto`. `renderDrawer()` and `renderDecide` do not change: the decision stays under the head.
- **`readHtml(c, d)`:** the cost tag reads "$1.23 est. so far" in every column. For a card with `c.review` false, one `sec("Gates", …)` of `d.report.gates` as `.gate pass` / `.gate fail` spans, drawn by a helper shared with `gatesPane`, only when the report has gates; it comes after the `.ifacts` tags and before "What the validation said". When `pr`, `report`, `s` and `c.cost` are all missing: one `<p class="empty">` "Nothing is recorded for this card yet." with a `.lnk` button "Open the log" (`data-open`, `data-go="log"`), in place of "No validation report for this card yet."; the loading skeleton is untouched.
- **Live tab:** `const LIVE_WAIT = 10000`. `S.liveSince = Date.now()` when the Live tab opens for a card (`openCard`, `selectTab`). `paintLive()` with `S.liveHtml` empty shows "Reading the session…" while `Date.now() - S.liveSince < LIVE_WAIT`, then "Nothing to show yet. The Log tab has what the run wrote." ("Log tab" a `<button class="lnk" data-tab="log">`). `followLive()` on a 200 with no events leaves the nothing-yet state for a running card and keeps "No factory session for this card yet." for a card with no run; the 2 s poll goes on, and events replace the message. The 1 s `tick()` repaints the Live pane while it waits. The compose form stays below.
- No new component, class, token or motion. If the `.empty` line and its link break badly at 320px, widen that one line to the pane.

**`scripts/lang/dashboard.pt-BR.json`**
- One entry per new string, as given in the spec's UX section (`exact`; `rx` for the cost tag, which carries a figure). The entry of "No review page for this card. Refine builds it when the spec is ready." and the one of "No validation report for this card yet." go, as does the old cost tag's.

**Done when:** `scripts/test/dashboard-empty.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.
