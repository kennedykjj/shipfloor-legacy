# Dashboard on a phone: keyboard hints on a touch screen and a stretched stepper — spec

**Issue:** #118 · **Branch:** `feat/118-dashboard-on-a-phone-keyboard-hints-on-a` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** On a narrow touch screen (measured at 390px) the "Yours" footer advertises keys (N, A, R, L) the device does not have, and a Settings stepper stretches to the full row width, leaving an empty box beside its plus button.
**Audience:** The factory's owner, doing a quick check of the dashboard on a touch screen or a narrow window.
**Acceptance criteria**
- **AC-1** — Given a device whose primary pointer is coarse, when the Factory view shows the "Yours" list, then the footer hints N next, A approve, R review, L log are not visible.
- **AC-2** — Given a device whose primary pointer is coarse, when the inbox is maximized, then the footer hints 1–9 choose and Esc close and the number key on each option button are not visible.
- **AC-3** — Given a device whose primary pointer is coarse, when the key hints are hidden, then the footer leaves no empty row or gap under the list.
- **AC-4** — Given a device whose primary pointer is fine (mouse or trackpad), when the "Yours" list or the maximized inbox shows at any width, including 390px, then the key hints show as they do today.
- **AC-5** — Given a coarse-pointer device with a keyboard attached, when the owner presses N, A, R, L, 1–9 or Esc, then each key still does what it does today.
- **AC-6** — Given a 390px-wide viewport, when any Settings section shows a stepper (Sessions at once, stage limits, local stacks, project limits, reminder minutes), then the stepper is as wide as it is on desktop, with no empty box beside the plus button.
- **AC-7** — Given a 390px-wide viewport, when the owner uses a stepper, then minus, value and plus work and mark the change as unsaved exactly as on desktop.
- **AC-8** — Given a viewport above 1180px with a fine pointer, when the Factory and Settings views show, then nothing looks different from today.
**Out of scope:** Any other finding of the 2026-10-12 critique; touch gestures or touch replacements for the shortcuts; changing or removing the shortcuts themselves; larger touch targets; a wider redesign of Settings rows on a phone; reaching the dashboard from another device (it stays on 127.0.0.1).
**Product fit:** Serves the Users line, a dashboard for quick checks, and principle 4 (the owner acts only where the factory waits for the owner): the page stops offering actions the device cannot perform. It does not contradict the local-only positioning: no remote access is added, only how the same local page reads on a touch screen or a narrow window.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Trigger:** the key hints follow the primary pointer, `@media (pointer: coarse)`, never the width; the stepper follows the existing `max-width: 1180px` block. Neither needs JS, a new component or a new token. (AC-1, AC-4, AC-6)
- **Footer on a coarse pointer:** the whole `.foot` is not rendered (`display: none`), so its hairline (`--hair`), its 12px padding and its `margin-top: auto` go with it; the "Yours" panel ends on its last pass, or on the inbox when maximized. Hiding only the `kbd` elements or only the two spans is not enough: the border and padding would leave the empty row AC-3 forbids. (AC-1, AC-2, AC-3)
- **Option buttons on a coarse pointer:** the `kbd` inside `.iopt .t` is not rendered. The title keeps its place at the left (`space-between` with one child); nothing replaces the number, and the button's height does not change. (AC-2)
- **Fine pointer, any width:** footer and option numbers exactly as today, including at 390px, where the footer already wraps (`flex-wrap`, gap 4px 16px). (AC-4, AC-8)
- **States:** with nothing waiting the footer stays hidden as today (`hidden` set by the script); the coarse rule only adds a second reason to hide it and must not fight that attribute. Loading, error and success states are unchanged; there is no new state.
- **Stepper in a one-column row:** a `.stp` that is a direct child of `.srow` keeps its content width (two 34px buttons and the 46px value, about 116px with its border) and sits at the row's left edge, under the label and description (`justify-self: start`). That is the same left edge the stepper inside `.sknob` and the `.sv` value already take in that block, so every control of a stacked row lines up. (AC-6)
- **Stepper look and behavior:** border `--edge-hi`, radius 8px, 34px buttons, Control type (condensed 600, 17px), `--sand` on the value when dirty, `.off` and `.bad` all unchanged; the 6px row gap between description and stepper stays. Above 1180px the stepper stays at the right of its row. (AC-7, AC-8)
- **Accessibility:** `display: none` takes the hints out of the accessibility tree too, so a screen reader on a touch device is not told about keys either, and the option button's name becomes its title without the trailing number. The shortcuts themselves stay bound on every device (AC-5); nothing is added to or removed from the tab order, and the 2px `--sand` focus ring is untouched.
- **Accessibility, stepper:** the minus and plus buttons keep their `aria-label`s and their 34px size; larger touch targets are out of scope, and the stepper must not shrink below what desktop shows.
- **Copy:** no new or changed string, so no catalog entry in `scripts/lang/`.
- **DESIGN.md:** two sentences to add with the change: under "Your", that the footer and the option numbers show only where the primary pointer is fine; under "Settings", that in a stacked row a stepper keeps its width at the row's left edge.

## Architecture
_Tech Lead_

- **Contracts touched:** none. No endpoint, event, payload, config key or script interface changes; the page's markup and JS stay as they are.
- **Layer:** `factory` only.
- **`scripts/dashboard.html` (CSS only, in the inline `<style>`):**
  - a new top-level block `@media (pointer: coarse) { .foot, .iopt kbd { display: none; } }`, placed after the `.foot` rules (line 252) so it wins over `.yours.maxed .foot .keys-inbox { display: flex; }` by hiding the parent; it coexists with `.foot[hidden]` (line 194), which already means `display: none`;
  - in the Settings block `@media (max-width: 1180px)` (line 392), one more rule: `.srow > .stp { justify-self: start; }`. Cause of the stretch: there `.srow` becomes a one-column grid and a grid item stretches by default; `.sknob` steppers are already held by `align-items: flex-start`.
- **Not touched:** the `keydown` handler (line 1795), `setStep` (line 1605) and the `stepper()` template (line 1476); AC-5 and AC-7 hold because no JS changes and no `matchMedia` is added.
- **`DESIGN.md`:** the two sentences the UX section asks for (under "Your" and under "Settings").
- **`scripts/test/dashboard-touch.test.sh` (new):** static, in the manner of `scripts/test/dashboard-narrow.test.sh`: parses the CSS of `dashboard.html` and reads the script text. It checks that `.foot` and `.iopt kbd` get `display: none` inside `@media (pointer: coarse)` and in no width query or top-level rule; that the coarse block declares nothing else; that `.srow > .stp` has `justify-self: start` inside the 1180px Settings block and `.stp` has no width, `flex` or `justify-self` outside media blocks; that the script has no `matchMedia` on `pointer` and the key handler still names `n`, `a`, `r`, `l`, `1-9` and `Escape`.
- **Migration:** none; no data, no stored state.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-touch.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-touch.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-touch.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-touch.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-touch.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-touch.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-touch.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-touch.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The inbox hints (1–9, Esc) and the number on each option button are hidden too, not only N, A, R, L: the same reason applies and one media block covers all of them.
- The whole `.foot` is hidden on a coarse pointer, not only its `kbd` elements: it holds nothing but key hints, and its hairline and padding would stay as an empty row.
- The hints follow `pointer: coarse` (the primary pointer), not the width and not `any-pointer`: the issue asks for it, and a narrow window with a mouse keeps its hints.
- Shortcuts stay bound on every device: a tablet with a keyboard still uses them, and it means no JS change.
- The stepper is fixed with `justify-self: start` on `.srow > .stp` in the existing 1180px block, not with a fixed width: the stepper keeps its content width and lines up with the `.sknob` steppers and `.sv` values of a stacked row.
- All eight criteria are covered by one static test of the CSS and script text, as `dashboard-narrow.test.sh` does: the headless session has no browser; rendering at 390px is seen by the owner in review on the demo stack.
- `DESIGN.md` is updated with the change: it describes the footer and the Settings rows, and the two new rules would otherwise contradict it.
- Larger touch targets and touch replacements for the shortcuts stay out: other cards of the same critique cover targets (#117), and the issue asks only for these two fixes.

## Open questions
- none
