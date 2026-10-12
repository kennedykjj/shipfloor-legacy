# DESIGN.md and the dashboard disagree on 12 values — spec

**Issue:** #120 · **Branch:** `feat/120-design-md-and-the-dashboard-disagree-on` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** `impeccable detect scripts/dashboard.html` reports 12 advisories (six font sizes, four radii, two literal colors) that the design system's ramp, scale and tokens do not cover. DESIGN.md lists most of them only as "Known deviations", so the document and the page still disagree and the next drift cannot be told from the old one.
**Audience:** the factory's owner and the developers who install the plugin and change the dashboard.
**Acceptance criteria**
- **AC-1** — Given the branch, when `impeccable detect scripts/dashboard.html` runs, then it exits 0, or every advisory it still prints is a value DESIGN.md names with the rule that uses it.
- **AC-2** — Given the six font sizes (16, 21, 22, 24, 26, 30px), when the dashboard and DESIGN.md are compared, then each is either a step of the documented type ramp with a named role or no longer on the page.
- **AC-3** — Given the four radii (1, 10, 14, 40px), when the dashboard and DESIGN.md are compared, then each is either a step of the documented scale in the front matter and in Shapes, or replaced by an existing step.
- **AC-4** — Given the two literal colors (the decision column's well, the Approve pill's hover), when the dashboard's rules are read, then both come from a token or a `color-mix` over a token and no hex literal remains in those rules.
- **AC-5** — Given any of the twelve themes, when the inbox's decision column and the Approve pill's hover are shown, then their text keeps 4.5:1 contrast and `scripts/test/theme.test.sh` passes.
- **AC-6** — Given DESIGN.md after the change, when "Known deviations" is read, then it lists no value this issue resolved, and every value it still lists is on the page.
- **AC-7** — Given the Factory, Feed and Settings views before and after, when they are compared at 1440px, then no element changes size or radius by more than 2px and the heading hierarchy keeps its order.
**Out of scope:** redesigning the type ramp or the radius scale beyond these 12 values; new themes; the embedded review pages (`EMBED_CSS`); wiring `impeccable detect` into a gate; anti-patterns (none reported).
**Product fit:** serves principle 3 (numbers are exact and sourced): the design document states what the page actually uses. Also principle 2 in spirit, since a clean detector run is a check and not a claim. No conflict with the positioning or the constraints (still one self-contained file, no build).
**Touches UI:** yes

## UX
_UX/UI Designer_

No flow, state, copy or breakpoint changes: twelve values move, nothing else. The largest move is 2px (AC-7).

| Today | Rules in `scripts/dashboard.html` | Becomes | Role in DESIGN.md |
|---|---|---|---|
| 16px | `.lane`, `.thp .n` | **17px** | existing Control (lane title, theme name on a swatch) |
| 21px | `.ique .pnum`, `.iread h2` | **20px** | existing Heading (inbox reader title, inbox queue number) |
| 22px | `.tnum` | **23px** | 23px step, role renamed **Brand / Number**: the card number is one size in Yours and in a tile |
| 24px | `.pnum`, `.disp h1` | **23px** | same step; the dispatcher line's heading |
| 26px | `.band > h1`, `.side h1` | **28px** | new step **Section** (`typography.section`: condensed, 500, 28px, line-height 1, 0.02em, uppercase) |
| 30px | `.set-body > h1` | **28px** | same new step; three rules use it, so it enters the ramp by the ramp's own rule |
| 1px | `.f-bad .fdot` | **0** | no radius, as `.f-sys .fdot` already; not a scale step. A 2px corner would blur the 9px diamond toward the ok dot |
| 10px | `.iopt`, `.thp` | **8px** | existing `ctrl` (Shapes already places option cards there; add the theme swatch) |
| 14px | `.drawer.open.full` | **16px** | existing `panel` (a maximized panel is a panel) |
| 40px | `.stub .pill, .edit .pill` | **40px, kept** | new named step `rounded.pill: "40px"`: the Approve pill in the lists |
| `#0000002e` | `.idec` background | **`var(--well)`** | existing token, set in all twelve themes (dark `#00000040`, light `#ffffff66`) |
| `#fff` | `.pill:hover` background | **`color-mix(in srgb, var(--text) 88%, var(--ground))`** | the fill steps 12% toward the ground |

- **Hierarchy after the change:** Display 34 > Section 28 > Brand / Number 23 > Heading 20 > Headline 18 > Control 17. Every pair that differed keeps its order (Settings title 28 over the dispatcher heading 23; list number 23 over inbox queue number 20); the only pair that meets is the card number in Yours and in a tile, on purpose.
- **Colors in the light themes:** the well goes from an 18% black wash to the theme's own well, so the decision column reads as a well in Kraft, Steel and Drafting paper instead of a grey smear; text over it gains contrast in all twelve. The pill's hover is a real fix there: today a white fill under `ground`-colored text is unreadable in the three light themes, and invisible in High contrast (`--text` is already `#fff`). The mix stays visible and above 4.5:1 in every theme.
- **`.btn.approve:hover`** keeps `filter: brightness(1.08)`; only the pill's hover changes.
- **DESIGN.md, same change:** front matter gains `typography.section` and `rounded.pill`; Hierarchy gains Section and renames the 23px line; Shapes adds the pill step, the swatch at 8px and "marks whose shape carries state (the Feed's diamond and dash) are square"; In Progress says 23px, not 22px; Themes drops the pill hover and the decision well from its exceptions (the white of a plain review page stays); Buttons says the pill's hover mixes 12% of the ground.
- **Known deviations** keeps one line, `15.5px` — `.isec .plain`: the issue does not name it, the scope stops at the 12 values, and it is still on the page (AC-6).
- **Small screens:** nothing to adapt; check at 1440px and 390px that "N wait for you" (now 28px) still fits one line in the Yours heading and that the longest theme name ("Drafting paper", 17px) fits its swatch.

## Architecture
_Tech Lead_

**Contracts touched:** none. No endpoint, event, function or config key changes; only CSS values in the page and the text of the design document.

**Layer:** `factory` owns every file below.

**Files changed**
- `scripts/dashboard.html` — the `<style>` block only, the rules of the UX table: `.lane`, `.thp .n` (17px); `.ique .pnum`, `.iread h2` (20px); `.tnum`, `.pnum`, `.disp h1` (23px); `.band > h1`, `.side h1`, `.set-body > h1` (28px); `.f-bad .fdot` (`border-radius: 0`); `.iopt`, `.thp` (8px); `.drawer.open.full` (16px); `.idec` (`background: var(--well)`); `.pill:hover, .edit .pill:hover` (the `color-mix`). `.pill` keeps 40px. No markup, script or `EMBED_CSS` change.
- `DESIGN.md` — front matter gains `typography.section` (28px) and `rounded.pill: "40px"`; the prose changes listed in UX (Hierarchy, Shapes, In Progress, Themes, Buttons); `## Known deviations` keeps only `15.5px` — `.isec .plain`.
- `.impeccable/design.json` — `typographyMeta` gains `section` and the `brand` purpose names the card number; `generatedAt` is the day of the change. `schemaVersion` stays 2.
- `scripts/test/design-doc.test.sh` — new checks (below); the existing ones stay as they are.
- `scripts/test/theme.test.sh` — new contrast checks for the two rules (below).

**Checks added**
- `design-doc.test.sh`, AC-2/AC-3: no rule of the page uses a font size of 16, 21, 22, 24, 26 or 30px or a radius of 1, 10 or 14px; 28px is in the ramp and 40px in the scale (`rounded.pill`).
- `design-doc.test.sh`, AC-4: the bodies of `.idec` and of the `.pill:hover` rule hold no hex, `rgb()` or named color literal; `.idec` reads `var(--well)`.
- `design-doc.test.sh`, AC-6: every value under `## Known deviations` is used by the selector it names, and none of the ten resolved sizes and radii is listed.
- `theme.test.sh`, AC-5: for each of the twelve themes, `--well` (8-digit hex) composited over `panel` keeps `text`, `soft` and `muted` at 4.5:1, and `ground` over the mix of 88% `text` and 12% `ground` keeps 4.5:1.

**Migration plan:** none; one commit, no data, no stored state.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | manual | `impeccable detect scripts/dashboard.html` on the owner's machine; exit 0, or each advisory matched to a value DESIGN.md names |
| AC-2 | factory | `scripts/test/design-doc.test.sh` |
| AC-3 | factory | `scripts/test/design-doc.test.sh` |
| AC-4 | factory | `scripts/test/design-doc.test.sh` |
| AC-5 | factory | `scripts/test/theme.test.sh` |
| AC-6 | factory | `scripts/test/design-doc.test.sh` |
| AC-7 | manual | Factory, Feed and Settings at 1440px before and after, on the demo stack (`scripts/test/demo-stack.sh up`) |

## Security
_Cybersec_ — n/a

## Rollback
n/a — revert the commit; nothing is stored.

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Each of the ten sizes and radii moves to a step or becomes a named one; a "Known deviations" line does not count: DESIGN.md already lists them all and the detector still reports them.
- 26px and 30px meet at one new step, Section 28px: three rules use it, which is the ramp's own rule for a step, and both moves are 2px.
- 22px and 24px join the existing 23px step instead of adding one: a 1px move each, and the card number becomes one size in Yours and in a tile.
- The 40px pill is kept and named (`rounded.pill`): any existing step would change the shape by far more than 2px (AC-7).
- The diamond's 1px radius becomes 0, which is no radius and not a scale step: `.f-sys .fdot` already does it, and 2px would blur a 9px diamond.
- `.idec` takes the existing `--well` token rather than a new one: every theme already sets it, and the light themes get their own well instead of a black wash.
- The pill's hover is a `color-mix` of `text` and `ground`, not a new token: one rule uses it, and white under `ground` text is unreadable in the light themes.
- `15.5px` stays under Known deviations: the issue does not name it and the scope is the 12 values.
- AC-1 is a manual check: `impeccable` is not in the repository or in CI, so no test of the layer can run it (same call as the 2026-10-11 spec); the static checks of AC-2, AC-3, AC-4 and AC-6 cover the same values.
- AC-7 is a manual check: comparing rendered sizes needs a browser; the UX table fixes every move at 2px or less, and the AC-2/AC-3 checks pin the values.
- The contrast checks go in `theme.test.sh`, which already computes luminance per theme; the document checks go in `design-doc.test.sh`, which already parses the page's rules and DESIGN.md.
- `.impeccable/design.json` is updated with DESIGN.md: `design-doc.test.sh` compares one with the other, and the `factory` layer owns it.
- Wiring `impeccable detect` into a gate is out of scope (PO): the tool is not installed where the gates run.

## Open questions
- none
