# Dashboard: the list of what waits for the owner disappears when Lifecycle and Today are open — plan

**Issue:** #112 · **Spec:** `docs/superpowers/specs/2026-10-12-dashboard-the-list-of-what-waits-for-the-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-short.test.sh`), red.
2. Task 1 (factory), one task: the CSS, the `fit` function and the DESIGN.md sentences change together; they are one mechanism and the build runs the suite once.

AC-1, AC-2 and AC-8 are manual (UX/UI in validation, on the demo stack at 1366x768 and 1440x900 with 4 cards waiting); no task here writes a test for them.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-short.test.sh` (new), AC-3, AC-4, AC-5, AC-6, AC-7.
- Static: reads `scripts/dashboard.html` with Python as `scripts/test/dashboard-narrow.test.sh` does; no browser, no server.
- "The wide rules" are the rules of `<style>` outside every `@media` block. "The narrow block" is the last `@media (max-width: 1180px)` block, the one that sets `body`.
- Rules are matched by selector and declaration, not by line or by the exact text of a line: spacing, the order of declarations and how selectors are grouped are the engineer's. The same for the script: the tests read the source of `fit`, `show` and the key handler for what they do, not for how a line is written.
- AC-3: in the wide rules `.telem` can shrink (its `flex-shrink` is not 0), its `min-height` is no longer 292px and is at most about 100px, it keeps `max-height: 60%` and `overflow-y: auto`; a `.telem.cut` rule carries a bottom mask of 24px; `body` stays `overflow: hidden`. `fit` toggles `cut` on `#today`, and `#today` has a scroll listener that calls `fit`.
- AC-4: `#list` keeps `overflow-y: auto` and the `#list.cut` mask of 44px; the `N` branch of the key handler, after focusing the next `.ptitle`, writes the list's `scrollTop` from the card's position. `fit` itself never writes `scrollTop` and never calls `focus`.
- AC-5: `#list` has `min-height: var(--two, 0px)` (a floor read from a custom property, no pixel constant); `fit` sets `--two` from the rendered `.pass` elements: the second when there is one, the first when one waits, `0px` when none.
- AC-6: `.tiles` keeps `overflow-y: auto`; a `.tiles.cut` rule carries the 44px mask; `fit` toggles `cut` on `#tiles`, and `#tiles` has a scroll listener that calls `fit`; `renderWork` ends in a call to `fit`.
- AC-7: `.tight` is the only thing that compacts: every rule that hides `.yours .foot`, sets the 10px gap or the 6px sub-heading margin is under `.side.tight`; `fit` turns `.tight` on only when Today is open (so both closed never compacts); the narrow block and the `.maxed` rules still win (no `--two` floor, no `.tight` effect and no new mask on a panel that is `.maxed` or inside the narrow block); `show` calls `fit` in both branches. The function named `fade` is gone and nothing calls it.
- Before the implementation the tests of AC-3 to AC-7 fail on their assertions (a rule or a call that is missing or has another value), not on a missing file or a crash. A guard that passes today (such as `body` staying `overflow: hidden`) is allowed beside them, but each AC has at least one assertion that is red now.

## Task 1 — factory: the list keeps two cards, Today gives way

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` (change; the wide rules of `<style>` and the script)
- `DESIGN.md` (change; the "Layout" sentences on Today and on the footer of "Yours")
- `.impeccable/design.json` (change only if `scripts/test/design-doc.test.sh` asks for it)

**`scripts/dashboard.html`, CSS (above 1180px only)**
- First confirm the cause on the demo stack at 1366x768 with Lifecycle and Today open (spec, "Architecture"): `.telem` is `flex: 0 0 auto; min-height: 292px` and never shrinks, so `#list` takes the whole shortage.
- `#list`: `min-height: var(--two, 0px)`.
- `.yours`: `min-height: auto` (heading + list floor + foot) and `flex: 0 1000 auto`, so the list still gives way first, down to two cards, before Today moves.
- `.telem`: `flex: 0 1 auto`, a floor of about 100px in place of 292px; `max-height: 60%` and `overflow-y: auto` stay.
- `.telem.cut`: the `#list.cut` mask at 24px. `.tiles.cut`: the same mask at 44px.
- `.side.tight`: `gap: 10px`; `.yours .foot` hidden; the first sub-heading of Today with a 6px top margin.
- The last `@media (max-width: 1180px)` block and every `.maxed` rule keep winning: no floor, no `.tight` effect, no new mask there. Add what it takes inside that block or to the `.maxed` rules; do not weaken them.

**`scripts/dashboard.html`, JS**
- `fade()` becomes `fit()`, the one place that fits the column:
  - sets `--two` on `#list` to the bottom of the second `.pass` relative to the list's content top (the first when one waits, `0px` when none);
  - toggles `.cut` on `#list`, `#today` and `#tiles` (content remains below);
  - toggles `.tight` on `.side`: on only when Today is open and the column, measured with `.tight` off, cannot hold the list floor, the 20px gap and Today's floor. Decide from the un-tight measure so it does not flip on alternate refreshes.
  - never writes `scrollTop`, never moves focus.
- `fit` runs where `fade` runs now (after `renderYours`, on resize, on the list's scroll), plus at the end of `show()` (both branches), after `renderWork` and `renderTelem`, and on the scroll of `#today` and `#tiles`.
- The `N` key: after focusing the next `.ptitle`, set the list's `scrollTop` so the card's top is at the list's top edge.
- No new or changed string; nothing in `scripts/lang/dashboard.pt-BR.json`.

**`DESIGN.md`**
- "Layout": Today is at most 60% of the column and gives way to the list's two cards, scrolling inside itself with a 24px fade; the key hints of "Yours" (N, A, R, L) hide at the shortest height, and the keys keep working.

**Must stay green unchanged:** `scripts/test/dashboard-narrow.test.sh`, `scripts/test/dashboard-first-screen.test.sh`, `scripts/test/design-doc.test.sh`.

**Done when:** `scripts/test/dashboard-short.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.
