# Dashboard on a phone: keyboard hints on a touch screen and a stretched stepper — plan

**Issue:** #118 · **Spec:** `docs/superpowers/specs/2026-10-12-dashboard-on-a-phone-keyboard-hints-on-a-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-touch.test.sh`), red.
2. Task 1 (factory), one task: the two CSS rules and the two DESIGN.md sentences change together; all are small and the build runs the suite once.

No AC is manual: the eight are covered by the one static test. How the page renders at 390px is seen by the owner in review, on the demo stack.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-touch.test.sh` (new), AC-1 to AC-8.
- Static, in the manner of `scripts/test/dashboard-narrow.test.sh`: reads `scripts/dashboard.html` with Python, parses the CSS of the inline `<style>` and reads the script text; no browser, no server.
- Rules are matched by selector and declaration, not by line or by the exact text of a line: spacing, the order of declarations, how selectors are grouped and where in `<style>` a block sits are the engineer's.
- "The Settings block" is the `@media (max-width: 1180px)` block that sets `.srow` to one column. The other blocks at that breakpoint (the maximized inbox, the feed, the narrow page) are not it and are not read as it.
- AC-1, AC-2: inside a `@media (pointer: coarse)` block `.foot` and `.iopt kbd` are `display: none`.
- AC-3: it is `.foot` itself that is hidden there, not only its `kbd` elements or its `.keys-list` / `.keys-inbox` spans; the coarse block declares nothing but `display: none`.
- AC-4: no width query and no top-level rule hides `.foot` or `.iopt kbd` (the existing `.foot[hidden]` rule is not one of them: it names the attribute); the query is `pointer`, not `any-pointer` or `hover`. Outside media blocks `.foot` is still `display: flex` and `.yours.maxed .foot .keys-inbox` still shows.
- AC-5: the script has no `matchMedia` on `pointer`, and the key handler still names `n`, `a`, `r`, `l`, `1`–`9` and `Escape`. This one passes today; it guards the shortcuts.
- AC-6: in the Settings block `.srow > .stp` has `justify-self: start`.
- AC-7: the `stepper()` template still gives minus and plus their `aria-label`s and `setStep` is still what they call; the `.stp button` size (34px) and `.stp.dirty output` are unchanged. Passes today; a guard.
- AC-8: outside media blocks `.stp` has no `width`, `flex` or `justify-self`, and `.srow` keeps its two columns (`minmax(0, 1fr) auto`). Passes today; a guard.
- Before the implementation the tests of AC-1, AC-2, AC-3 and AC-6 fail on their assertions (a rule that is missing), not on a missing file or a crash. AC-4, AC-5, AC-7 and AC-8 describe what must not change: where one of them can be given an assertion that fails today (for example AC-4 asking that the coarse block exists and is the only place the hints are hidden), it is; otherwise it is a guard that passes and is named as such in the test's output.

## Task 1 — factory: the key hints follow the pointer, and the stepper keeps its width

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` (change; CSS only, in the inline `<style>`)
- `DESIGN.md` (change; one sentence in "Your", one in "Settings")

**`scripts/dashboard.html`**
- A new top-level block after the `.foot` rules (lines 251–252): `@media (pointer: coarse) { .foot, .iopt kbd { display: none; } }`. It hides the parent, so it wins over `.yours.maxed .foot .keys-inbox { display: flex; }`, and it coexists with `.foot[hidden]` (line 194).
- In the Settings block `@media (max-width: 1180px)` (line 392), one more rule: `.srow > .stp { justify-self: start; }`. Cause of the stretch: `.srow` is a one-column grid there and a grid item stretches by default; the `.sknob` steppers are already held by `align-items: flex-start`.
- Nothing else changes: no markup, script, string, color or token; no `matchMedia`; the `keydown` handler, `setStep` and the `stepper()` template stay as they are. The `.stp` rule outside media blocks gets no width, `flex` or `justify-self`.

**`DESIGN.md`**
- "Your": after "The footer reads N next, A approve, R review, L log.", one sentence: the footer and the number on each inbox option show only where the primary pointer is fine.
- "Settings": one sentence: in a stacked row (1180px and below) a stepper keeps its width at the row's left edge.

**Done when:** `scripts/test/dashboard-touch.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.
