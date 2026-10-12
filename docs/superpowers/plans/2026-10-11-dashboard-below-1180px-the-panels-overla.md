# Dashboard: below 1180px the panels overlap and the decision list cannot be reached — plan

**Issue:** #51 · **Spec:** `docs/superpowers/specs/2026-10-11-dashboard-below-1180px-the-panels-overla-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-narrow.test.sh`), red.
2. Task 1 (factory), one task: the narrow block and the DESIGN.md sentence change together; both are small and the build runs the suite once.

AC-2, AC-4 and AC-7 are manual (UX/UI in validation, on the running dashboard at 390x844 and 960x800); no task here writes a test for them.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-narrow.test.sh` (new), AC-1, AC-3, AC-5, AC-6, AC-8.
- Static: reads `scripts/dashboard.html` with Python as `scripts/test/theme.test.sh` does; no browser, no server.
- "The narrow block" is the last `@media (max-width: 1180px)` block of `<style>`, the one that sets `body`. The two other blocks at that breakpoint (the maximized inbox, Settings) are not it and are not read as it.
- Rules are matched by selector and declaration, not by line or by the exact text of a line: spacing, the order of declarations and how selectors are grouped are the engineer's.
- AC-1: in the narrow block `.cols` has one column, `.side` is `display: contents`, and the `order` of `.yours`, `.work`, `.telem` is 1, 2, 3.
- AC-3: in the narrow block `body` has `height: auto` and `overflow: auto`; no rule for `.yours`, `.work` or `.telem` there sets a `max-height` other than `none` or any value in `vh`.
- AC-5: in the narrow block `#list` and `.tiles` are `overflow: visible`, under a selector that leaves a `.maxed` panel out.
- AC-6: in the narrow block the `.tiles` columns use `minmax(min(320px, 100%), 1fr)`; `.band` has `overflow-x: auto` (wherever it is set) and the narrow block does not take it away.
- AC-8: outside every media block `body` is `overflow: hidden` with `grid-template-rows: auto auto minmax(0, 1fr)` and `.cols` has two columns. This one passes today; it guards the wide layout.
- Before the implementation the tests of AC-1, AC-3, AC-5 and AC-6 fail on their assertions (a rule that is missing or has another value), not on a missing file or a crash.

## Task 1 — factory: one column at natural height, and the page scrolls

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` (change; only the last `@media (max-width: 1180px)` block of `<style>`)
- `DESIGN.md` (change; one sentence in "Layout")

**`scripts/dashboard.html`**
- First confirm the cause in a browser at 390px and 960px (spec, "Architecture"): `body` keeps `height: 100%` while its rows are `auto`, and `main`, `.board`, `.cols`, `.side` and the panels keep `min-height: 0` with inner scrollers, so the rows shrink to the window.
- `body`: `height: auto; min-height: 100%`, stays `overflow: auto`; the document is the only vertical scroller and nothing makes it scroll sideways (`min-width: 0` stays where it is).
- `.board`: rows `auto auto`. `.cols`: one column. `.side`: `display: contents`. `order`: `.yours` 1, `.work` 2, `.telem` 3. The markup order does not change.
- `.yours:not(.maxed)`, `.work:not(.maxed)`, `.telem:not(.maxed)`: `max-height: none; min-height: auto; flex: none; overflow: visible`. The `.yours { max-height: 70vh }` and `.work { min-height: 320px }` rules go away.
- `#list` and `.tiles` inside a panel that is not `.maxed`: `overflow: visible`. `.tiles` columns: `repeat(auto-fill, minmax(min(320px, 100%), 1fr))`.
- `header`: wraps, each stat whole on one line, not sticky, and the content starts below its last line. `.band` keeps `overflow-x: auto`.
- Feed and Settings: their last line can still be reached at these widths (a window-tall inner scroller or the page scroll, either is fine).
- A maximized panel, the drawer (full width, as today) and the peek keep today's rules.
- Nothing outside that block changes: no markup, script, string, color or token; the two other `@media (max-width: 1180px)` blocks stay as they are.

**`DESIGN.md`**
- "Layout" says the page never scrolls. Add one sentence: at 1180px and below the Factory view is one column and the page scrolls.

**Done when:** `scripts/test/dashboard-narrow.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.
