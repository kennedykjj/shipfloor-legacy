# Dashboard: the review iframe flashes white in the dark theme — spec

**Issue:** #12 · **Branch:** `feat/12-dashboard-the-review-iframe-flashes-whit` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** Every time the owner opens a card's Review tab in a dark theme, the review area flashes white before the page appears; the control room blinks at the exact spot where the owner is asked to decide.
**Audience:** The factory's owner (and any developer running the dashboard), during quick checks to approve or send back Spec Review and Staged cards.
**Acceptance criteria**
- **AC-1** — Given a dark dashboard theme, when the owner opens the Review tab of a card whose review page takes the embed theme, then from the click until the page is shown the review area never paints white: it shows the current theme's panel color.
- **AC-2** — Given any dashboard theme, dark or light (kraft, steel, paper), when the Review tab loads, then the review area shows no color from another theme before the page settles (no dark frame in a light theme, no light frame in a dark one), whatever the OS light/dark preference.
- **AC-3** — Given a dark theme and a review page that does not take the embed theme (no `</head>`, or hand-written with no background of its own), when it finishes loading, then it renders on a light background with its text readable, as today.
- **AC-4** — Given a dark theme, when the owner closes and reopens the Review tab or opens the Review tab of another card, then no white frame appears on any of those openings.
- **AC-5** — Given a dark theme and a review page that takes the embed theme, when it has finished loading, then it looks the same as today (same colors, same layout, same approve / request changes controls).
- **AC-6** — Given a card with no review page, or one whose review page fails to load, when the Review tab opens in a dark theme, then the empty review area shows the panel color, not white.
**Out of scope:** Redesigning review pages or the embed palette; new themes or a theme picker change; loading spinners or skeletons; faster review page loading; any change to review pages opened outside the dashboard (without `?embed=1`).
**Product fit:** Serves principle 4, "the owner acts only where the factory waits for the owner": the Review tab is that place, and it should hold still while the owner reads and decides. No conflict with the positioning; it stays local, adds no state to the dashboard (principle 1) and changes no number or gate.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Flow:** the owner opens the Review tab (or another card's, or reopens it); the review area holds the drawer's own color while the page loads, then the page appears in place. Nothing else in the drawer moves: the decision, the tabs and the drawer width are untouched.
- **Loading:** the review area is `var(--panel)`, the same surface as the drawer around it, so it reads as "not there yet", not as a frame. The iframe keeps its `flex: 1` box from the first frame (held with `visibility: hidden` / `opacity: 0`, never `display: none`), so the reveal causes no reflow. None of the page's own paint is visible in this state: neither the embed's fixed dark palette nor its OS-light one.
- **Themed page shown:** revealed only after the page has received the theme colors (the answer to its "ready"). It looks as today: page on `--ground`, sheets on `--panel`, raised on `--panel-hi`, text `--text` / `--muted`, rules `--edge`. The step from the hold color (`--panel`) to the page ground (`--ground`) is the only change the owner sees, and both belong to the current theme.
- **Plain page shown** (does not take the embed theme, never announces itself): revealed when its load ends, on `#fff` behind the page, as today, in every theme. White is allowed only in this state, and only once the page is ready to read.
- **No page:** the existing `.placeholder` paragraph on the drawer's `--panel`, unchanged.
- **Failed load:** while no document arrives, the review area stays `var(--panel)`; never white, never a color from another theme. An error body that does load is a plain page (readable on `#fff`). No new message in this issue.
- **Motion:** the reveal is one opacity fade, 150ms ease-out (the duration the settings switch already uses), the same for themed and plain pages; no slide, no scale. Under `prefers-reduced-motion: reduce` it is instant, added to the existing reduced-motion block. No spinner, skeleton or shimmer.
- **Theme change with the page open:** as today, the colors are sent again and the page recolors in place; it is not hidden again. While still loading, the hold color follows the new theme's `--panel` at once.
- **Accessibility:** while held, the iframe is out of the tab order and the accessibility tree (`visibility: hidden`), so nobody tabs into an invisible page; the reveal moves no focus and announces nothing. The iframe keeps its `title` ("Review page for #N") and its sandbox.
- **Small screen:** no layout change. Below 860px the drawer is full width and the review area fills what is left under the decision, in all four states.
- **Copy:** no new or changed strings, so no entry in `scripts/lang/dashboard.<code>.json`.
- **Design system:** tokens only (`--panel`; `#fff` stays as the one written-out fallback under plain pages). No new component. `DESIGN.md`, "Embedded Review Pages", changes its sentence about the iframe's white background to match: panel while loading, white only under a plain page.

## Architecture
_Tech Lead_

**Cause.** Two colors show before the review page settles: the iframe element's own `background: #fff` (`scripts/dashboard.html`, `iframe { … }`) until the document first paints, then the fixed palette of `EMBED_CSS` (`scripts/dashboard.py`; dark, or light when the OS prefers light) until the page's `load` handler asks the dashboard for its theme.

**Approach.** The iframe paints nothing until the page inside it has the dashboard's colors; the drawer's `var(--panel)` shows through meanwhile. A page that never announces itself is shown on white, as today.

**Layer and files** (all owned by `factory`)
- `scripts/dashboard.html` — the `iframe` rule, the `message` listener, `themeReview()`, one `load` listener on `#pane`.
- `scripts/dashboard.py` — the `<script>` inside `EMBED_CSS` only; its `<style>` block does not change (AC-5).
- `scripts/test/dashboard.test.sh` — the assertions below.
- `DESIGN.md` — "Embedded Review Pages": the sentence on the iframe's white background becomes panel while loading, white only under a plain page.

**Contracts touched**
- Embed script → dashboard, `postMessage`:
  - `{shipfloor: "ready"}` — unchanged shape; now posted when the script is parsed in `<head>`, not inside the `load` handler. The `theme` listener is registered before it. `review-progress` stays in the `load` handler.
  - `{shipfloor: "themed"}` — new, no fields; posted after each `theme` message has been applied to the root.
- Dashboard → embed script: `{shipfloor: "theme", light, vars}` — unchanged.
- `GET /review/<project>/<n>?embed=1` — same status, headers (`Content-Security-Policy: sandbox allow-scripts`) and injection rule (only before a `</head>`); only the injected script's text changes. Without `embed=1` the bytes are the file's, as today.
- Iframe element state, in the DOM only (never in the HTML string `reviewPane` returns, so `setHTML` keeps the element across the 5 s refresh):
  - default: `background: var(--panel)`, content not painted (`visibility: hidden`);
  - `.themed`: content painted — set when `themed` arrives from that iframe's window;
  - `.plain`: content painted on `background: #fff` — set when the iframe's `load` fires and no `ready` came from it within a 200 ms grace; a `ready` arriving later removes it.
  - Safety: `load` + grace with `ready` seen but no `themed` → paint anyway (`.themed`), so a page is never left hidden.
  - Reveal: one 150 ms ease-out opacity fade for both classes, instant inside the existing `prefers-reduced-motion: reduce` block; the box keeps `flex: 1` throughout (never `display: none`).
- No white anywhere in the base `iframe` rule; `#fff` appears only under `.plain`.

**AC notes**
- AC-4: every opening creates a new iframe element in the default state, so the rule above covers reopening and switching cards.
- AC-6: a card without a review page has no iframe (the `.placeholder` paragraph on the drawer's panel, unchanged). A request that never produces a document never fires the `.plain` path and stays on the panel color. An error body that does load is a page that did not announce itself: it follows AC-3.

**Migration.** None: no data, no stored state, no config. Old review pages already on disk get the new script on the next `?embed=1` request.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard.test.sh` |
| AC-2 | factory | `scripts/test/dashboard.test.sh` |
| AC-3 | factory | `scripts/test/dashboard.test.sh` |
| AC-4 | factory | `scripts/test/dashboard.test.sh` |
| AC-5 | factory | `scripts/test/dashboard.test.sh` |
| AC-6 | factory | `scripts/test/dashboard.test.sh` |

What each row asserts (no browser in this layer; the tests check the contract the page and the server ship):
- AC-1, AC-4: `GET /` — the base `iframe` rule has `background: var(--panel)`, hides its content, and holds no `#fff`; `.themed` shows it.
- AC-2: `GET /review/shop/<n>?embed=1` for a page with `</head>` — `shipfloor:"ready"` is posted before the `addEventListener("load"` text, and the script posts `shipfloor:"themed"`; `GET /` reveals on `themed`, not on `ready`.
- AC-3: `GET /` — `.plain` carries `#fff` and is set from the `load` path; `?embed=1` on a page without `</head>` returns the file's bytes unchanged.
- AC-5: the `?embed=1` response still holds the `EMBED_CSS` `<style>` block byte for byte (`header.top{display:none}` through `border-color:var(--rule)}`).
- AC-6: `GET /` — `reviewPane` still renders the `.placeholder` paragraph, and no iframe, when the card has no review page.
- The flash itself is checked on the running screen by UX/UI in validation (dark and light themes, OS preference flipped).

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Hide the iframe until the page is themed, instead of only swapping `#fff` for `var(--panel)`: the swap alone still shows the embed's fixed palette (wrong for a light theme, or a dark one on a light OS) until `load`, which AC-2 forbids.
- A new `themed` acknowledgement rather than revealing on `ready`: the theme message is applied asynchronously, so revealing on `ready` can still paint one frame of the fixed palette.
- `ready` moves out of the `load` handler: the dashboard can then tell a page that takes the embed theme from one that does not by the time the iframe's `load` fires, and the theme arrives before images and fonts finish.
- White for a page that does not announce itself stays `#fff`, not a theme color: such a page brings no colors of its own and dark text on a dark panel would be unreadable (the issue asks for a light background).
- 200 ms grace after `load` before calling a page plain: message and `load` order is not guaranteed across a sandboxed frame; short enough not to read as a delay.
- AC-6 "fails to load" is read as "no document arrives"; an error body that loads is treated as a plain page (AC-3) so its text stays readable. The sandboxed frame hides its status, and a probe request per opening is not worth it for a cosmetic fix; the UX line on failed load was aligned to this.
- Hold color is `--panel`, not the page's `--ground` (UX): the loading area matches the drawer and the no-page state; the one step to `--ground` stays inside the theme.
- Every theme is covered, not only the dark ones (PO): the wrong-palette frame in a light theme is the same defect.
- Tests assert the shipped contract (CSS rule, message order, injected bytes) in `scripts/test/dashboard.test.sh`: the `factory` layer has no browser; the visual check is UX/UI's in validation.
- Spec started from the repository's `templates/spec-template.md` (the installed copy was not readable from this session; same file).

## Open questions
- none
