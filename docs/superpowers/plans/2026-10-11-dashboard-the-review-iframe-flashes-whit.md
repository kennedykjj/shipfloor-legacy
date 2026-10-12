# Dashboard: the review iframe flashes white in the dark theme — plan

**Issue:** #12 · **Branch:** `feat/12-dashboard-the-review-iframe-flashes-whit`
**Spec:** `docs/superpowers/specs/2026-10-11-dashboard-the-review-iframe-flashes-whit-design.md`

One layer, `factory` (path `./`, agent `engineer`). The acceptance tests come first, from QA, in
`scripts/test/dashboard.test.sh`; the tasks below make them pass. Tasks run one at a time, in order.

## Acceptance tests (QA, before any task)

- **File:** `scripts/test/dashboard.test.sh` (selector `scripts/test/dashboard.test.sh`).
- One or more assertions per AC, as the spec's test plan lists them: the base `iframe` rule
  (`var(--panel)`, hidden, no `#fff`), `.themed` and `.plain`, `ready` before the `load` listener and a
  `themed` post in the `?embed=1` response, the `EMBED_CSS` `<style>` block byte for byte, a page
  without `</head>` returned unchanged, the `.placeholder` paragraph with no iframe.

## Task 1 — the embed script announces itself early and acknowledges the theme

- **Layer:** factory · **Owner:** engineer · **Depends on:** the acceptance tests
- **Files:** `scripts/dashboard.py`
- Inside `EMBED_CSS`, the `<script>` only; the `<style>` block stays byte for byte (AC-5).
- Register the `theme` message listener when the script is parsed in `<head>`, then post
  `{shipfloor:"ready"}` right after it: both leave the `load` handler. `ready` must come before the
  text `addEventListener("load"` in the injected script (AC-2).
- After each `theme` message is applied to the root, post `{shipfloor:"themed"}` (no fields) to the parent.
- `review-progress` (`send`, the `MutationObserver`, the `input` listener) stays in the `load` handler.
- No change to the route: same status, same headers, injection only before a `</head>`.

## Task 2 — the iframe paints nothing until the page has the theme

- **Layer:** factory · **Owner:** engineer · **Depends on:** task 1 (the `themed` message)
- **Files:** `scripts/dashboard.html`
- CSS: the base `iframe` rule gets `background: var(--panel)` and hides its content
  (`visibility: hidden`, `opacity: 0`), keeps `flex: 1`, never `display: none`, and holds no `#fff`.
  `iframe.themed` and `iframe.plain` show it; `iframe.plain` alone carries `background: #fff`.
  The reveal is one 150 ms ease-out opacity fade, instant inside the existing
  `prefers-reduced-motion: reduce` block.
- `message` listener: `ready` from the pane's iframe still answers with `themeReview()`, marks the
  iframe as having announced itself and removes `.plain`; `themed` from that iframe's window adds `.themed`.
- One `load` listener on `#pane` (capture: `load` does not bubble) for its iframe: after a 200 ms
  grace, no `ready` seen → `.plain`; `ready` seen but no `themed` → `.themed` (a page is never left hidden).
- The state lives on the element only (classes, a property), never in the HTML string `reviewPane`
  returns, so `setHTML` keeps the element across the 5 s refresh. `reviewPane`'s `.placeholder`
  branch is untouched (AC-6).
- `themeReview()` keeps the message shape `{shipfloor: "theme", light, vars}`; a theme change with the
  page open recolors in place and does not hide it again.

## Task 3 — the design system says what the iframe now does

- **Layer:** factory · **Owner:** engineer · **Depends on:** task 2
- **Files:** `DESIGN.md`
- "Embedded Review Pages": the sentence on the iframe's white background becomes panel
  (`var(--panel)`) while the page loads, white only under a plain page that does not take the embed theme.

## Not in this card

No change to `scripts/lang/dashboard.*.json` (no new strings), to review page templates, to the
embed palette, or to the route's headers. The flash itself is checked on the running screen by
UX/UI in validation.
