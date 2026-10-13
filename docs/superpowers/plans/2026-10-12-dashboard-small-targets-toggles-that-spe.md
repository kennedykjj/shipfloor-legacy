# Dashboard: small targets, toggles that speak only in color, and 11px text — plan

**Issue:** #117 · **Spec:** `docs/superpowers/specs/2026-10-12-dashboard-small-targets-toggles-that-spe-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-targets.test.sh` new, `scripts/test/design-doc.test.sh` extended), red.
2. Task 1 (factory): the page, the catalog and the design documents, in one task. `scripts/test/design-doc.test.sh` compares `DESIGN.md` with the shipped page, and the build gate runs after every task, so the page and its documents cannot land in separate tasks.

## Acceptance tests — QA

- **Files:** `scripts/test/dashboard-targets.test.sh` (new; AC-1, AC-2, AC-4, AC-6) and `scripts/test/design-doc.test.sh` (extended; AC-8).
- Static, as `scripts/test/dashboard-page.test.sh` and `scripts/test/theme.test.sh`: the factory's Python reads `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `DESIGN.md` and `.impeccable/design.json` as text; no browser and no server. One named check per criterion, printing `ok` / `FAIL` lines, so a red run says which criterion is missing.
  - **AC-1, AC-2 (targets)** — each selector the spec's UX section names declares `min-height` of at least 24px: `.views button`, `.sumline button`, `.proj select`; and, for the full recipe, `min-height` and `min-width` of at least 24px with `display: inline-flex`: `a.cap` in `.stats` ("Board on GitHub"), `.lnk`, the `gh()` link in `.tfoot`, the peek's `.acts a`, `.subtoggle`. No rule sets a `height` (or `max-height`) under 24px on a `button`, `a`, `select`, `input` or `summary`. No target is made by a pseudo-element (`::before` / `::after` with the size on it).
  - **AC-4 (switch)** — both templates (`sw()` for `data-pause`, `flip()` for `data-nk`) carry `role="switch"`, an `aria-checked` bound to the state, and `<span class="sw-w" aria-hidden="true"><b>On</b><b>Off</b></span>` before the track; `data-pause`, `data-nk` and `aria-label` are still there; the delegated `change` listener sets `aria-checked` for `input[role="switch"]`; CSS picks the word by `input:checked ~ .sw-w` with `visibility: hidden`, not with `content`; the catalog has `"On": "Ligado"` and `"Off": "Desligado"` under `exact`.
  - **AC-6 (type)** — no `font-size`, `font` shorthand, inline `style` or SVG `font-size` attribute under 12px anywhere in the page (11px and 11.5px are both gone); the Caption rules (`.cap`, `.views button`, `.sumline button`, `.isec h3`, `.iq-k`, `.sgroup > h2`) are 12px with `letter-spacing: 0.1em`, and no `0.14em` is left on them.
  - **AC-8 (documents)** — in `scripts/test/design-doc.test.sh`: `DESIGN.md` gives the Caption role as 12px and `0.1em` (front matter and Hierarchy), has no 11px or 11.5px role, names the 24x24px minimum target under Buttons, and says a Settings switch shows its state as a word; `.impeccable/design.json` agrees on the caption size. `scripts/test/theme.test.sh` stays green (it is run as a `green` selector, unchanged).
- Before the implementation every new check fails on its assertion (the page or the document lacks the rule), not on a missing file or a crash. The checks `design-doc.test.sh` already has keep passing.
- AC-3, AC-5 and AC-7 are pixel measures: manual, taken by UX/UI in validation on the demo stack. QA writes no test for them.

## Task 1 — factory: targets, type, the switch's word, catalog and design documents (AC-1, AC-2, AC-4, AC-6, AC-8)

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` (change)
- `scripts/lang/dashboard.pt-BR.json` (change)
- `DESIGN.md` (change)
- `.impeccable/design.json` (change)

**What changes**
- **Targets (AC-1, AC-2)** — CSS only, as the spec's UX section lists. `.views button`, `.sumline button`, `.proj select`: `min-height: 24px`. "Board on GitHub" (`a.cap` in `.stats`), `.lnk`, the `gh()` link in `.tfoot`, the peek's `.acts a`, `.subtoggle`: `display: inline-flex; align-items: center; min-height: 24px; min-width: 24px`, with `margin-block: -4px` where the line is shorter than 24px. The box is the control's own, never a pseudo-element; boxes grow in height only, the horizontal gaps stay (AC-3). Any other `button`, `a`, `select`, `input` or `summary` with a `height` under 24px takes the same recipe; inline links in prose stay.
- **Type (AC-6)** — Caption becomes 12px, 500, `0.1em`, uppercase on `.cap`, `.views button`, `.sumline button`, `.isec h3`, `.proj option`; `.lab .q` and `.iwhere b` go to 12px and keep `0.1em`; `.iq-k` and `.sgroup > h2` take `0.1em`. Every other 11px and 11.5px rule, inline style and SVG attribute becomes 12px, tracking untouched. `.tk` moves to `top: -20px` with its tick at `top: 15px`.
- **Switch (AC-4, AC-5)** — both render sites (`sw()` and `flip()`): the checkbox gains `role="switch"` and `aria-checked="true|false"`; a sibling `<span class="sw-w" aria-hidden="true"><b>On</b><b>Off</b></span>` sits before `<i></i>`. `.sw` is `inline-flex` with an 8px gap, `i` a 44x24 flex item, `.sw-w` an `inline-grid` with both words in `grid-area: 1 / 1`, right-aligned, 12.5px, weight 500, `text` when on and `muted` when off; the word that does not apply is `visibility: hidden`, chosen by `input:checked ~ .sw-w`. The input still covers the whole `.sw`; the focus ring stays on the track. The one delegated `change` listener writes `aria-checked` for any `input[role="switch"]`. `data-pause`, `data-nk`, `aria-label`, `checked` and `disabled` stay.
- **Catalog** — `"On": "Ligado"` and `"Off": "Desligado"` under `exact` in `scripts/lang/dashboard.pt-BR.json`.
- **Documents (AC-8)** — `DESIGN.md`: Caption 12px / `0.1em` (front matter and Hierarchy); the Note role (11.5px) removed and "Meta and note" becomes "Meta (12px)"; Today reads "Chart labels are 12px `faint`"; Buttons gains the target rule ("**Target:** every focusable control has a box of at least 24x24px; a text-only control grows its box, not its ink."); the Settings paragraph says a switch shows its state as a word; "Known deviations" regenerated to match the page. `.impeccable/design.json` follows.

**Not touched:** `scripts/dashboard.py` and its `EMBED_CSS`; what any control does; colors and themes; the pressed state of the view buttons, the Feed filters and the theme swatches.

**Done when:** `scripts/test/dashboard-targets.test.sh`, `scripts/test/design-doc.test.sh` and `scripts/test/theme.test.sh` pass whole and the build gate is green.
