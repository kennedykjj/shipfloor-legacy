# Dashboard: the list of what waits for the owner disappears when Lifecycle and Today are open — spec

**Issue:** #112 · **Branch:** `feat/112-dashboard-the-list-of-what-waits-for-the` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** On the Factory view, opening both Lifecycle and Today squeezes the "wait for you" list to nothing on common laptop screens (no card visible at 1366x768, one cut card at 1440x900), and the waiting tiles of "In progress" go the same way. The list is the page's main job and it is the first thing to give way.
**Audience:** The factory's owner, on a quick check: open, approve what waits, close.
**Acceptance criteria**
- **AC-1** — Given a 1366x768 window with 4 cards waiting and Lifecycle and Today both open, when the Factory view settles, then at least two cards of the list are fully visible, their action buttons included.
- **AC-2** — Given a 1440x900 window in the same state, when the Factory view settles, then at least two cards of the list are fully visible, their action buttons included.
- **AC-3** — Given either window with both open, when the owner looks at Today, then it takes only the height the list leaves and all of its content is reachable by scrolling inside it, without the page scrolling as a whole.
- **AC-4** — Given either window with both open and more cards waiting than fit, when the owner scrolls the list or presses N, then every waiting card can be reached and brought fully into view.
- **AC-5** — Given either window with both open and one card waiting, when the Factory view settles, then that card is fully visible and the list holds no empty space reserved for a second one.
- **AC-6** — Given either window with both open and cards in "In progress", when the Factory view settles, then at least one tile is visible in full width with its number and title, and the rest are reachable by scrolling inside the panel.
- **AC-7** — Given Lifecycle and Today both closed, when the Factory view settles at 1366x768 and at 1440x900, then the layout is the same as before this change (the list still shows up to five whole cards).
- **AC-8** — Given only one of the two open, when the Factory view settles at either size, then at least two cards of the list are fully visible.
**Out of scope:** The layout at 1180px wide and below (the page already scrolls there); windows shorter than 768px; changing what Lifecycle, Today or a card contain, or whether they open closed at load; the drawer, the Feed and Settings.
**Product fit:** Principle 4, "the owner acts only where the factory waits for the owner": the place where the owner acts must not be the part that disappears. It keeps the design's rule that the page does not scroll as a whole above 1180px, so Today is what gives way. No conflict with the positioning or with what is out of scope.
**Touches UI:** yes

## UX
_UX/UI Designer_

Scope: the Factory view above 1180px wide, 768px tall and up. No new component, token, color or motion; heights change without a transition.

- **List floor (AC-1, AC-2, AC-5, AC-8).** `#list` never gets less than the height of its first two cards as rendered (measured from the cards, not a fixed pixel value, so one-line and two-line titles both hold), and never more than its content: with one card the floor is that card, with none the panel is its heading alone, as today. "Fully visible" means the whole card, its action row included, above the list's bottom fade.
- **Who gives way, in order (AC-1, AC-3).** (1) Today shrinks below its present 292px, down to its floor. (2) Only if Today would still be under its floor (the 1366x768 case with both open): the gap between "Yours" and Today goes from 20px to 10px (`spacing.sm`), and the key-hint foot of "Yours" (N, A, R, L) hides; the keys keep working. Nothing in Lifecycle compacts, its legend included, and no card changes.
- **Today's floor (AC-3).** Its heading and the first sub-heading line with its figures ("Runs that ended, by hour · N clean · N failed", or "No run has ended today.") stay legible; about 100px. In that state the first sub-heading's top margin may drop from 16px to 6px (`spacing.xs`). Today is never hidden or folded by the layout; only the owner's "Today" button closes it.
- **Today shows there is more (AC-3).** When its content is taller than the panel, Today scrolls inside itself and fades its bottom edge with the same mask as `#list.cut`, 24px instead of 44px so the first sub-heading stays clear; the fade leaves at the end of the scroll. Its existing Maximize button still shows it whole. The page never scrolls as a whole.
- **When there is room (AC-7, AC-8).** Today keeps its present size (its content, at most 60% of the column, at least 292px) whenever the list has its two cards without help; the compaction of step (2) applies in no other state. With both closed, nothing in this section applies and up to five whole cards show.
- **Reaching every card (AC-4).** The list scrolls inside itself with the existing 44px fade while cards remain below. N puts the next card's top at the list's top edge, so the card is whole and clear of the fade; on the last card the list sits at its end and the fade is gone. Focus ring: the existing 2px `sand` outline, not clipped by the list's edges.
- **In progress (AC-6).** The right column keeps the full height of the columns row. The first tile shows at full tile width with its number and title; the rest, the "Waiting" group included, scroll inside `.tiles`, which takes the same 44px bottom fade while tiles remain below.
- **States.** Nothing waiting: "Yours" is its heading alone and Today takes the freed height up to its present cap. "Reading the factory…" and the "Not updating" alert are unchanged. The floors are recomputed on window resize, on opening or closing Lifecycle or Today, and when a refresh changes the list, without moving the list's scroll or focus.
- **Copy.** No new or changed string; nothing to add to `scripts/lang/dashboard.pt-BR.json`.
- **Small screens.** At 1180px wide and below nothing changes: the page scrolls, no floor, no compaction, the key hints stay.
- **Design system.** `DESIGN.md`, Layout, says Today is "at most 60% of the column, both charts whole" and that the footer of "Yours" reads N, A, R, L; both sentences need the new rule (Today gives way to the list's two cards; the hints hide at the shortest height) in the same change.

## Architecture
_Tech Lead_

**Cause.** In `.side`, `.telem` is `flex: 0 0 auto; min-height: 292px` and never shrinks; `.yours` is `flex: 0 1 auto; min-height: 0` and `#list` is `min-height: 0`, so the list takes the whole shortage (17px of list at 1366x768).

**Contracts touched:** none. No endpoint, no payload field, no string, no stored state. One layer, `factory`; no migration.

**Files** (all owned by `factory`):
- `scripts/dashboard.html`, CSS above 1180px only:
  - `#list` gets `min-height: var(--two, 0px)`; `.yours` stops shrinking under its content floor (`min-height: auto`, heading + list floor + foot) and keeps shrinking first (`flex: 0 1000 auto`), so the list still gives way down to two cards before Today moves.
  - `.telem` becomes `flex: 0 1 auto` with a floor of about 100px in place of 292px (`max-height: 60%` stays); `.telem.cut` takes the `#list.cut` mask at 24px, `.tiles.cut` at 44px.
  - `.side.tight`: gap 10px, `.yours .foot` hidden, the first sub-heading of Today with a 6px top margin.
  - The `@media (max-width: 1180px)` block and every `.maxed` rule keep winning: no floor, no `.tight`, no new mask there.
- `scripts/dashboard.html`, JS:
  - `fade()` becomes the one place that fits the column (name it `fit`): sets `--two` on `#list` to the bottom of the second `.pass` (the first when one waits, `0px` when none), toggles `.cut` on `#list`, `#today` and `#tiles`, and toggles `.tight` on `.side`.
  - `.tight` is on only when Today is open and the column, measured with `.tight` off, cannot hold the list floor, the 20px gap and Today's floor; deciding from the un-tight measure keeps it from flipping on alternate refreshes.
  - `fit` runs where `fade` runs now (after `renderYours`, on resize, on the list's scroll), plus at the end of `show()` (both branches), after `renderWork` and `renderTelem`, and on the scroll of `#today` and `#tiles`. It never writes `scrollTop` and never moves focus.
  - The `N` key: after focusing the next `.ptitle`, set the list's `scrollTop` so the card's top is at the list's top edge.
- `DESIGN.md`: the Layout sentence on Today ("at most 60% of the column, both charts whole") and the footer of "Yours" take the new rule; `.impeccable/design.json` only if `scripts/test/design-doc.test.sh` asks for it.
- `scripts/test/dashboard-short.test.sh` (new): static, reads the CSS and the source of `fit`, `show` and the key handler, in the style of `scripts/test/dashboard-narrow.test.sh`.

**Existing tests that must stay green unchanged:** `scripts/test/dashboard-narrow.test.sh`, `scripts/test/dashboard-first-screen.test.sh` (it reads `renderYours`, `show` and the board rows), `scripts/test/design-doc.test.sh`.

**Pixel measures** (AC-1, AC-2, AC-8) are taken by UX/UI in validation on the demo stack (`scripts/test/demo-stack.sh up`), as #51 and the first-screen card did; the headless test runner has no browser.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1, AC-2, AC-8 | manual | UX/UI in validation, on the demo stack at 1366x768 and 1440x900 with 4 cards waiting: both open, then each one alone; the first two cards of `#list` lie whole inside the list's box, action row included |
| AC-3 | factory | `scripts/test/dashboard-short.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-short.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-short.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-short.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-short.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Today gives way and scrolls inside itself; the page does not scroll: `DESIGN.md` says the page never scrolls as a whole above 1180px.
- The list shrinks first, down to two cards, and only then Today: on a roomy screen with many cards waiting Today keeps its size as it does now, so the change shows only where the list was lost.
- The list floor is measured from the rendered cards, not a pixel constant: a card's height changes with a two-line title, a note or the open text area.
- At the shortest height the key hints of "Yours" hide and the gap halves, rather than Today shrinking to its heading alone: the keys keep working, and a Today with no figure visible says nothing. Reversible in one CSS rule.
- Nothing in Lifecycle compacts: changing its content is out of scope.
- "In progress" is in scope with one modest criterion (AC-6) and a bottom fade: the issue names its vanishing tiles in the problem but not in its acceptance list.
- Added criteria for one card waiting, more cards than fit and only one panel open: the issue's fix would otherwise be free to break them.
- Windows shorter than 768px and widths of 1180px and below are out of scope: the issue measures at 768 and 900, and the narrow layout already scrolls.
- Pixel criteria are checked by UX/UI in validation, the mechanism by a static test: the test runner has no browser, as on #51.
- No new or changed string, so no pt-BR catalog entry.

## Open questions
- none
