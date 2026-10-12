# Dashboard: below 1180px the panels overlap and the decision list cannot be reached — spec

**Issue:** #51 · **Branch:** `feat/51-dashboard-below-1180px-the-panels-overla` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** In a browser window 1180px wide or narrower, the Factory view's "waits for you", "in progress" and "Today" panels print over one another and the page does not scroll, so the owner cannot reach or act on the decisions that wait for them.
**Audience:** The factory's owner (and other developers who install the plugin) doing a quick check with the browser at half screen beside a terminal, or in a narrower window.
**Acceptance criteria**
- **AC-1** — Given the Factory view with cards in all three panels, when the window is 960px wide, then the lifecycle band, "waits for you", "in progress" and "Today" stack in one column in that order and no panel's box intersects another's.
- **AC-2** — Given the same view, when the window is 390px wide, then no panel's box intersects another's and no text of one panel is drawn over another panel.
- **AC-3** — Given either width and more content than the window is tall, when the owner scrolls the page, then the page scrolls vertically and the bottom of the last panel can be brought into view.
- **AC-4** — Given a card in Spec Review or Staged, when the owner scrolls to its row in "waits for you" at 390px or 960px and clicks Approve, then the click lands on that button (nothing covers it) and the card moves as it does on a wide window.
- **AC-5** — Given "waits for you" holds more rows than fit one screen, when the owner scrolls at 390px or 960px, then every row and its actions can be reached.
- **AC-6** — Given either width, when the page is loaded, then the page itself has no horizontal scroll; a lifecycle band wider than the window scrolls sideways inside its own panel.
- **AC-7** — Given either width, when the header wraps, then every header item stays visible and none is drawn over the panels below.
- **AC-8** — Given a window wider than 1180px, when the Factory view is loaded, then the layout is what it is today: two columns, no page scroll.
**Out of scope:** A phone layout or touch targets (the dashboard is local only, no phone access; 390px is only the narrow bound of a desktop window); reducing how many lines the header wraps to; redesigning the lifecycle band for narrow widths; the Feed and Settings views, the drawer, the peek and the maximized panels beyond not regressing; changing the 1180px breakpoint; any change to content, copy, colors or actions.
**Product fit:** Serves principle 4, "The owner acts only where the factory waits for the owner": the one place the owner acts must be reachable at the window size they actually use, per the "quick checks" use in Users. No conflict with positioning; "no remote or phone access" stands, so this is a narrow-window fix, not mobile support.
**Touches UI:** yes

## UX
_UX/UI Designer_

All changes sit in the existing `@media (max-width: 1180px)` block of `scripts/dashboard.html`; no new component, token, color or string (so no catalog entry in `scripts/lang/`). Above 1180px nothing changes.

- **Flow (960px and 390px):** the owner opens the Factory view, scrolls the page down past the lifecycle band to "waits for you", and acts on a row in place (Approve, Review, Log) exactly as on a wide window. The document is the only vertical scroller.
- **Order, one column:** header, alerts (when any), lifecycle band, "waits for you", "in progress", "Today". "in progress" moves above "Today" visually only (CSS order; `.side` stops being a box); the markup order stays, so the wide layout and the tab order (waits for you, Today, in progress) are untouched.
- **Heights:** every panel takes its natural height. The narrow block drops the caps and floors it sets today (`.yours` 70vh, `.work` 320px) and the inner vertical scrolling of `#list`, `.tiles` and `.telem`; the page grows past the window instead of squeezing its rows into it.
- **"waits for you":** all rows are laid out in full, so the bottom fade (`#list.cut`) never shows at these widths; the key hints (`.foot`) stay as the panel's last line.
- **"in progress":** tiles keep the existing auto-fill grid, two per row at 960px and one at 390px; the tile's minimum becomes "320px or the panel's width, whichever is smaller", so a tile never pushes the page sideways.
- **Lifecycle band:** unchanged in content and height; it keeps its 1040px line and scrolls sideways inside its own panel (the one horizontal scroller on the page). The legend wraps under it as today.
- **Header:** not sticky; it wraps onto as many lines as it needs and the content starts below its last line (it scrolls away with the page). Brand and views first, then the stats, each stat kept whole on one line.
- **Widths:** the page never scrolls sideways; panels use the full column inside the existing `--pad` gutter, with the existing 16px between band and panels and 20px between panels.
- **Overlays:** a maximized panel, the card drawer (full width, as today) and the peek stay fixed to the window and keep their own inner scrolling; the natural-height rules must not apply to a `.maxed` panel. The peek keeps following its dot while the page scrolls.
- **States:** loading ("Reading the factory…") and an empty factory fit one screen with nothing to scroll; empty panels ("Nothing waits for you", no tiles) shrink to their heading and message, no reserved blank height; the alerts strip and the "not updating" flag wrap inside the page width; the 5s refresh keeps the page's scroll position and typed text.
- **DESIGN.md:** "Layout" says the page never scrolls; with this change that holds only above 1180px, so the same PR adds one sentence there: at 1180px and below the Factory view is one column and the page scrolls. Focus ring, themes and reduced-motion behavior are untouched (no new motion).

## Architecture
_Tech Lead_

**Cause (read from the CSS, to be confirmed in a browser by the engineer):** at 1180px and below `body` keeps `height: 100%` while its rows become `auto`, and `main`, `.board`, `.cols`, `.side` and the panels keep `min-height: 0` with inner scrollers (`#list`, `.tiles`, `.telem`), so the rows shrink to the window and the panel content is drawn outside its box, over the next panel. `header` keeps `white-space: nowrap`, so wrapped lines are wider than the window.

**Contracts touched:** none. No endpoint, event, function, string or markup changes; `dashboard.py` is untouched.

**Layers and files** (all owned by layer `factory`):
- `scripts/dashboard.html` — only the `@media (max-width: 1180px)` block at the end of `<style>` (the two other blocks at that breakpoint, for the maximized inbox and for Settings, stay as they are):
  - `body`: `height: auto; min-height: 100%` and stays `overflow: auto`, so the document is the vertical scroller; `overflow-x` is never caused by content (each rule below keeps `min-width: 0`).
  - `.board`: rows `auto auto`; `.cols`: one column; `.side`: `display: contents`; order `.yours` 1, `.work` 2, `.telem` 3.
  - `.yours:not(.maxed)`, `.work:not(.maxed)`, `.telem:not(.maxed)`: `max-height: none; min-height: auto; flex: none; overflow: visible`; the `70vh` and `320px` rules are removed.
  - `#list`, `.tiles` inside a panel that is not `.maxed`: `overflow: visible`; `.tiles` columns `repeat(auto-fill, minmax(min(320px, 100%), 1fr))`.
  - `header`: wraps, each stat whole on its line; nothing sticky. `.band` keeps `overflow-x: auto`.
  - Feed and Settings keep a usable height at these widths (their inner scrollers `.feed` and `.set-cols` either keep a window-tall box or give way to the page scroll; either is fine as long as their last line can be reached).
- `DESIGN.md` — one sentence in "Layout": at 1180px and below the Factory view is one column and the page scrolls.
- `scripts/test/dashboard-narrow.test.sh` — new; reads `scripts/dashboard.html` with Python as `scripts/test/theme.test.sh` does and checks the rules above.

**Migration plan:** none (CSS only, no data, no config).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-narrow.test.sh` — the narrow block sets one column, `.side` to `display: contents` and the order yours, work, telem |
| AC-3 | factory | `scripts/test/dashboard-narrow.test.sh` — in the narrow block `body` has `height: auto` and `overflow: auto`, and no `max-height` or `vh` cap is left on `.yours`, `.work` or `.telem` |
| AC-5 | factory | `scripts/test/dashboard-narrow.test.sh` — in the narrow block `#list` and `.tiles` are `overflow: visible` outside a `.maxed` panel |
| AC-6 | factory | `scripts/test/dashboard-narrow.test.sh` — `.tiles` minimum is `min(320px, 100%)` in the narrow block and `.band` keeps `overflow-x: auto` |
| AC-8 | factory | `scripts/test/dashboard-narrow.test.sh` — outside the media blocks `body` is still `overflow: hidden` with rows `auto auto minmax(0, 1fr)` and `.cols` still has two columns |
| AC-2, AC-4, AC-7 | manual | UX/UI in validation, on the running dashboard at 390x844 and 960x800: no panel box intersects another, Approve in a "waits for you" row takes the click, every header item is visible and above the panels |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- 390px is the narrow bound of a desktop window, not a phone: PRODUCT.md says no remote or phone access, so touch targets and a phone layout are out.
- The 1180px breakpoint stays: the issue is about what happens below it, not where it is.
- "in progress" goes above "Today" by CSS `order`, not by moving markup: the wide layout (AC-8) stays byte-for-byte; the cost is that the tab order at these widths is waits for you, Today, in progress.
- The header is not sticky: wrapped to several lines at 390px it would take a large part of the window.
- The page is the only vertical scroller at these widths; `#list`, `.tiles` and `.telem` stop scrolling on their own, so no panel hides rows behind a second scrollbar.
- A maximized panel, the drawer and the peek keep today's rules (`:not(.maxed)` on the new ones): out of scope beyond not regressing.
- The lifecycle band scrolls sideways inside its panel instead of being redesigned: smallest change that makes all of it reachable.
- The tile minimum becomes `min(320px, 100%)`: a 320px tile is wider than the panel at 390px and would scroll the page sideways.
- DESIGN.md gets one sentence in the same PR: its "Layout" says the page never scrolls, which is now true only above 1180px.
- The suite gets a static test of the CSS rules, and geometry (overlap, the click on Approve, the header) is checked by hand in validation: the suite has no browser (Bash and Python stdlib only) and a browser dependency is not worth one media block.
- No security section: no label `cybersec`, and the change is CSS only.

## Open questions
- none
