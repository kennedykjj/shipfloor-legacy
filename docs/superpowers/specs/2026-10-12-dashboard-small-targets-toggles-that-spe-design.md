# Dashboard: small targets, toggles that speak only in color, and 11px text — spec

**Issue:** #117 · **Branch:** `feat/117-dashboard-small-targets-toggles-that-spe` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** In a quick check the owner has to hit controls under 24px tall (the view buttons, "Board on GitHub", the Lifecycle and Today folds, the Log links), read a Settings switch by its color alone, and read figures and labels set at 11px.
**Audience:** The factory's owner and the other developers who install the plugin, using the dashboard in quick checks.
**Acceptance criteria**
- **AC-1** — Given the demo stack and the Factory view with Lifecycle and Today open, when every visible focusable control is measured, then each has a hit area of at least 24x24 CSS px.
- **AC-2** — Given the Feed view, the Settings view (every section) and an open card drawer (every tab), when every visible focusable control is measured, then each has a hit area of at least 24x24 CSS px.
- **AC-3** — Given two controls that sit side by side, when their hit areas are measured, then the areas do not overlap.
- **AC-4** — Given a Settings switch, when it is on and when it is off, then it has `role="switch"` with `aria-checked` (or `aria-pressed`) equal to its state, and the attribute changes when the switch is flipped by click and by keyboard.
- **AC-5** — Given a Settings switch on and another off in a grayscale screenshot, in a dark theme (Charcoal) and a light one (Kraft), when the two are compared, then the state is told by a visible word or mark and not by the knob's position or the track's tone.
- **AC-6** — Given the Factory view with Lifecycle and Today open, the Feed, Settings and an open drawer, when the computed font size of every visible text node is read, then none is under 12px, except text marked `aria-hidden`.
- **AC-7** — Given a 1280x800 window on the demo stack, when the Factory view loads, then the page still does not scroll as a whole and the summary line stays on one row.
- **AC-8** — Given any of the twelve themes, when `scripts/test/theme.test.sh` runs, then it passes, and `DESIGN.md` names the new caption size and the 24px minimum target.
**Out of scope:** The agent-written review pages inside the iframe and their `EMBED_CSS`; links inside rendered markdown and agent prose (inline links, which the target-size rule excepts); the pressed state of the view buttons, the Feed filters and the theme swatches; contrast, colors and themes; any change to what a control does or to the layout beyond what the sizes need; mobile-specific 44px targets.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner): the few controls the owner has must be hit and read at a glance in a quick check; and principle 3 (numbers are exact and sourced), since chart labels, counts and "est." are 11px today. It contradicts `DESIGN.md` as written (the Caption role is 11px, and Today's chart labels are "11px `faint`"), so that file changes with the page; the positioning and the product's out-of-scope are untouched.
**Touches UI:** yes

## UX
_UX/UI Designer_

No flow, state or behavior changes; only sizes, one word per switch and two attributes. All in `scripts/dashboard.html`, no new component, no new token.

- **Hit areas are the control's real box, never a pseudo-element** (so the measured box, the focus ring and the click agree). Recipe for a text-only control: `display: inline-flex; align-items: center; min-height: 24px; min-width: 24px`, and where the line it sits on is shorter than 24px, `margin-block: -4px` so the row keeps its height. The ink stays where it is: the text is centered in the taller box.
- **Where it applies:** `.views button`, `.sumline button` and `.proj select` get `min-height: 24px` only (their rows, the 68px header and the 36px summary line, already have the room). "Board on GitHub" (`a.cap` in `.stats`), `.lnk` (Log in `.tfoot`, "Open the card"), the `gh()` link in `.tfoot`, the peek's `.acts a` and `.subtoggle` take the full recipe with the negative margin. Any other control the measurement finds under 24px takes the same recipe; inline links in prose stay as they are.
- **No overlap (AC-3):** the boxes grow only in height, and every pair that sits side by side keeps its existing horizontal gap (`.views` 10px or more, `.tfoot` 16px, `.sumline button` 6px after its negative margin). Do not widen a box with padding into that gap.
- **Caption role: 12px, 500, `0.1em`, uppercase** (was 11px, `0.14em`). The tracking drops so a caption is about 3% wider, not 9%: the header and the summary line keep one row at 1280px (AC-7). Applies to `.cap`, `.views button`, `.sumline button`, `.isec h3`, `.proj option`; `.lab .q` and `.iwhere b` go to 12px and keep their `0.1em`; `.iq-k` and `.sgroup > h2` (12px, `0.14em` today) take `0.1em` so the role has one value.
- **Every other text under 12px becomes 12px (Meta), tracking untouched:** the 11px rules (`.est`, `.proj select`, `.tk`, `.chart text`, `.tabs button .b`, `.section-k`, `th`, `.subtoggle`, `.lv time`, `.lv-k`) and the nine 11.5px rules (the Note role: `.dot em`, `.plus`, `.chip small`, `.sgroup code` and the rest). `.tk` moves to `top: -20px` with its tick at `top: 15px`, so the tick still touches the track. Nothing on the page is left under 12px, `aria-hidden` or not.
- **`DESIGN.md`:** Caption becomes 12px / `0.1em` (front matter and Hierarchy); the Note role (11.5px) is removed and "Meta and note" becomes "Meta (12px)"; Today reads "Chart labels are 12px `faint`"; Buttons gains "**Target:** every focusable control has a box of at least 24x24px; a text-only control grows its box, not its ink."; the Settings paragraph says a switch shows its state as a word.
- **Switch (`.sw`, both the pause switches and the `.sand` flips):** a word left of the track, **On** or **Off**, 12.5px (Label role), `text` when on and `muted` when off; the track, knob and colors do not change. Markup: `<span class="sw"><input …><span class="sw-w" aria-hidden="true"><b>On</b><b>Off</b></span><i></i></span>`. `.sw` becomes `inline-flex` with an 8px gap, `i` a 44x24 flex item; the two words share one grid cell (`.sw-w { display: inline-grid }`, both `b` in `grid-area: 1 / 1`, right-aligned) and the one that does not apply is `visibility: hidden`, chosen by `input:checked ~ .sw-w` in CSS. So the width is the longer word's and nothing shifts on a flip, and the word is right before any script runs.
- **The words are real text nodes, not CSS `content`,** so the language catalog rewrites them. The input still covers the whole `.sw` (word and track), so a click on the word flips it; the focus ring stays on the track.
- **Semantics (AC-4):** the checkbox gets `role="switch"` and an explicit `aria-checked="true|false"`, written when it renders and updated in the same `change` handler that flips it (click and Space). Its `aria-label` stays; the word is `aria-hidden` because the role already says the state. A disabled switch (push with no topic) shows "Off" under the existing 50% opacity.
- **Grayscale (AC-5):** in Charcoal and in Kraft the on and off switches differ by the word itself (two letters against three), with weight 500 for both; the tone of the word and of the track is a second cue only.
- **Small screens:** nothing new. Under 1180px the header and the summary line wrap as today, with the taller boxes inside the same rows; where a Settings row stacks, the word stays left of its track on the control's line.
- **Copy (new strings only):** `On` / `Off`; pt-BR in `scripts/lang/dashboard.pt-BR.json` under `exact`: `"On": "Ligado"`, `"Off": "Desligado"`.

## Architecture
_Tech Lead_

**Contracts touched:** none outside the page. No endpoint, event, config key or script argument changes; `scripts/dashboard.py` and its `EMBED_CSS` are untouched.
- Markup of a switch (both render sites in `scripts/dashboard.html`: `sw()` for `data-pause`, `flip()` for `data-nk`): the checkbox gains `role="switch"` and `aria-checked="true|false"`, and a sibling `<span class="sw-w" aria-hidden="true"><b>On</b><b>Off</b></span>`. `data-pause`, `data-nk`, `aria-label`, `checked` and `disabled` stay, so `setPause` and the Settings draft read the input as today.
- `aria-checked` is written at render and again in the one delegated `change` listener (the same one that calls `setPause`), for any `input[role="switch"]`: it covers click and Space, and a re-render after a failed save writes the true state back.
- Language catalog: two new `exact` entries in `scripts/lang/dashboard.pt-BR.json` (`On`, `Off`).

**Layers and modules touched** (all owned by layer `factory`):
- `scripts/dashboard.html` — CSS only for targets and type (the rules UX lists), plus the two switch templates and the `change` listener.
- `scripts/lang/dashboard.pt-BR.json` — the two words.
- `DESIGN.md` and `.impeccable/design.json` — Caption 12px / `0.1em`, the Note role removed, the 24px target rule, the switch's word; "Known deviations" regenerated to match the page (`scripts/test/design-doc.test.sh` compares them).
- `scripts/test/dashboard-targets.test.sh` — new, static like its siblings: Python reads the page's CSS and templates, prints `ok` / `FAIL` lines.
- `scripts/test/design-doc.test.sh` — extended for AC-8 (caption size, the target rule).

**How the tests see it:** the layer has no browser, so the automated tests read the source. Targets: each selector UX names declares `min-height` (and, for the full recipe, `min-width`) of at least 24px, and no rule sets a `height` under 24px on a `button`, `a`, `select`, `input` or `summary`. Type: no `font-size` or `font` shorthand under 12px in any rule, inline style or SVG attribute of the page. Switch: both templates carry the role, the attribute bound to the state and the two words; the `change` listener sets `aria-checked`; the catalog has both words. The pixel measures (AC-3, AC-5, AC-7, and the measured pass over AC-1 and AC-2) are taken by UX/UI in validation on the demo stack (`scripts/test/demo-stack.sh up`).

**Migration plan:** none. One static file and its docs; nothing stored changes shape.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-targets.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-targets.test.sh` |
| AC-3 | manual | measured on the demo stack in validation |
| AC-4 | factory | `scripts/test/dashboard-targets.test.sh` |
| AC-5 | manual | grayscale screenshots in Charcoal and Kraft in validation |
| AC-6 | factory | `scripts/test/dashboard-targets.test.sh` |
| AC-7 | manual | 1280x800 on the demo stack in validation |
| AC-8 | factory | `scripts/test/design-doc.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- No text under 12px is left, rather than keeping 11px for decorative labels: one rule a static test can hold, and no judgment call per label about what is "decorative".
- The 11.5px Note role folds into Meta (12px): AC-6 forbids anything under 12px, and a half-pixel role has no reader-visible job.
- Caption tracking drops from `0.14em` to `0.1em` with the size: keeps the header and the summary line on one row at 1280px; `.iq-k` and `.sgroup > h2` follow so the role has one value.
- `DESIGN.md` and `.impeccable/design.json` change in this card: they define Caption at 11px today, and `design-doc.test.sh` requires them to describe the shipped page.
- Hit areas are the control's real box (min size, negative block margin), not a pseudo-element: the measured box, the focus ring and the click agree.
- A switch says its state with the word On or Off left of the track, for every switch: one word pair to learn; "Paused" on the project row already names the pause.
- The switch stays a native checkbox with `role="switch"` and an explicit `aria-checked`: keeps keyboard, form state and the `data-pause` / `data-nk` handlers as they are, and gives the test an attribute to read.
- Only the Settings switches change; the pressed state of the view buttons, Feed filters and theme swatches stays out: the issue names the toggles of Settings, and those are a separate card if wanted.
- Automated tests are static (source of the page), pixel measures are manual in validation: the `factory` layer has no browser, and `dashboard-first-screen.test.sh` and `dashboard-narrow.test.sh` set that precedent.
- Mobile 44px targets, review pages in the iframe and inline links in prose are out: the issue asks for WCAG 2.2 AA (24px), which excepts inline links.

## Open questions
- none
