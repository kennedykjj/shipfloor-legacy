# [UX-06] Sistema visual v4: IBM Plex, temas Graphite e Paper, um accent só — spec

**Issue:** #180 · **Branch:** `feat/180-ux-06-sistema-visual-v4-ibm-plex-temas-g` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** the dashboard reads as dense and nothing stands out: the `sand` accent paints money, waiting cards, titles and outlines alike; uppercase Barlow Condensed flattens hierarchy; many 10–11px wide-tracked labels. v4's visual system (Floor v4, "Visual system") fixes type, color and space without changing today's layout.

**Audience:** the factory's owner, in quick checks of the dashboard.

**Acceptance criteria**
- AC-1: Given Graphite and Paper (Floor v4 token values) and every older theme, the old blue "paper" now named Cobalt, each defining `raise`, `accent-ink`, `paper`, `accent-soft`, `accent-line`, When `scripts/test/theme.test.sh` runs, Then it passes with text ≥ 4.5:1 on ground and panels.
- AC-2: Given the theme picker, When the owner chooses Auto, Then the page uses Graphite under a dark system preference and Paper (id `paper`) under a light one, and Cobalt stays selectable.
- AC-3: Given the dashboard page, When it loads, Then IBM Plex Sans (400, 500, 600, 400 italic) and IBM Plex Mono (400, 500) come from embedded woff2 data URIs, nothing from the network, and the existing no-network test stays green.
- AC-4: Given `scripts/dashboard.html`, When `grep -n "text-transform: uppercase"` runs on it, Then it finds nothing beyond the exceptions DESIGN.md lists.
- AC-5: Given the PR, When its body is read, Then it states the byte growth of `dashboard.html`, and that growth is no more than the embedded fonts account for.
- AC-6: Given today's dashboard and layout, When opened in Graphite and in Paper at 1440×900 and at 400px wide, Then no text is clipped.
- AC-7: Given DESIGN.md, When read, Then Typography (Plex, the 34–12px scale, nothing under 12px), Colors (accent marks only what waits for the owner; costs in `text` with `est`), Themes, the Do's and Don'ts (uppercase, accent) and the front matter values match the new system.
- AC-8: Given the README, When read, Then it cites the font license at `scripts/fonts/OFL.txt`, and that file exists in the repo.

**Out of scope:** the v4 layout (belt, work area, scrubber, palette, brief: #28/37 to #31/37); motion changes; new themes beyond Graphite and Paper; any font loaded from the network.

**Product fit:** serves principle 4 (the owner acts only where the factory waits for the owner) by making the accent mean only that, and principle 3 (estimates say so) by keeping `est` on every cost. Fits the stack constraint "no CDN, no build". No conflict with positioning or scope.

**Touches UI:** yes

## UX
_UX/UI Designer_

- **Scope:** layout, flow and components do not change; only the CSS custom properties and the type and shape rules in `scripts/dashboard.html` change. Source of values: Floor v4, "Visual system".
- **Type roles** (Plex Sans unless noted): view/panel title 17px 600; body 15px/1.55; block title 14px 600, segment name 13px 600; meta 13px 500 `muted`, captions 12px 400 `faint`; card numbers, times, costs and code Plex Mono 13px 500 with `font-variant-numeric: tabular-nums`. Reserve 34px 600 (calm headline) and 24px 500 (card title) for the screens that already have that slot. Nothing under 12px; prose at most 64ch.
- **No uppercase:** drop every `text-transform: uppercase` (9 today) and the wide letter-spacing that goes with it; hierarchy comes from weight and size. Exceptions only where DESIGN.md lists them.
- **Theme tokens:** Graphite and Paper take the v4 table values exactly. Every theme, Cobalt (today's `paper`, renamed) included, also defines `raise`, `accent-ink`, `paper`, `accent-soft` (accent at 14%), `accent-line` (accent at 45%). Keep the variable names already in use; map `--sand` to `accent`, not a second accent.
- **Accent rule:** `accent`/`accent-soft`/`accent-line` only on what waits for the owner (cards in Spec Review or waiting on the owner, the action that answers them, the waiting count). Costs, titles, outlines and money totals move to `text`/`edge-hi`, and every cost keeps `est`. Text on an accent fill uses `accent-ink`.
- **Shape and space:** panels 16px radius, flat with a 1px `edge` hairline; the decision panel 14px and `panel-hi`, one of only two raised surfaces; tokens 8px; chips and pills fully rounded (999px). Padding and gaps on the 4/8 grid.
- **Theme picker:** existing control, same position. Order: Auto, Graphite, Paper, then the older themes with Cobalt where Paper used to be. Auto resolves to Graphite (dark) or Paper (light) via `prefers-color-scheme`. A saved choice of `paper` from before now opens the new Paper; that is acceptable (no migration).
- **New copy** (theme names are proper nouns, the same in every language the dashboard supports): `Graphite`, `Paper`, `Cobalt`. No other string changes.
- **States to check, in Graphite and Paper, at 1440x900 and at 400px:** empty board (no cards), loading (first fetch), error (dashboard API unreachable banner), a card waiting for the owner (accent visible, only there), a running card (`raise` token), a flag card (`paper`), the decision panel open. At 400px: no clipped or overlapping text, mono figures do not wrap mid-number, titles wrap rather than truncate where they wrapped before.
- **Fonts:** before the woff2 data URIs decode, the fallback stack (`system-ui`, `ui-monospace`) must not shift layout noticeably; use `font-display: swap`.

## Architecture
_Tech Lead_

One layer (`factory`); no contract, endpoint or event changes. Files:
- `scripts/dashboard.html`: replace the 5 Barlow `@font-face` lines with Plex Sans 400/500/600/400-italic and Plex Mono 400/500, each in latin and latin-ext (`unicode-range`), woff2 data URIs; `--sans`/`--mono` point at Plex and `--cond` goes away (rules using it move to `--sans`); remove the 9 `text-transform: uppercase` and their wide `letter-spacing`; no font-size under 12px; `.prose`-like text capped at 64ch; panels radius 16, decision panel 14, 4/8 spacing; costs use `--text` with `est`, `--sand` kept as the accent token only where something waits for the owner.
- Themes in the same file: add `graphite` and `paper` (v4 table); rename today's `[data-theme="paper"]` block to `cobalt`; every one of the 14 blocks defines `raise`, `accent-ink`, `paper`, `accent-soft`, `accent-line` (`--sand` stays the accent token; Graphite/Paper set it to the table's `accent`). `THEMES.first` becomes `auto, graphite, paper, contrast`; `tape` joins `dark`, `kraft` joins `light`, `cobalt` joins `light`; `theme()` resolves auto to `graphite` / `paper`; the favicon reads the same tokens.
- `scripts/lang/dashboard.*.json` (12 files): add `theme.graphite` ("Graphite"), `theme.cobalt` ("Cobalt"), set `theme.paper` to "Paper" and `theme.auto.sub` to "Graphite in dark, Paper in light" (translated per file; proper names unchanged).
- `scripts/fonts/OFL.txt` (new): SIL OFL text for IBM Plex. `README.md`: cite it. `DESIGN.md` and `.impeccable/design.json`: Typography, Colors, Themes, Do's and Don'ts, front matter as in AC-7.
- Existing tests that pin the old system and must be updated with it: `scripts/test/theme.test.sh` (12→14 themes, first group, 9 dark+light→11), `scripts/test/dashboard.test.sh` (AC-8 contrast: tape/kraft names, "12 themes", the `paper` removal check), `scripts/test/design-doc.test.sh` (Barlow, uppercase captions), `scripts/test/dashboard-accent.test.sh` if the accent rule moves a selector.
- New `scripts/test/visual-v4.test.sh`: fonts embedded and no network URL in the page, uppercase grep, no font-size under 12px, DESIGN.md and README checks.
- Fonts come from the official IBM Plex woff2 files (the `@fontsource/ibm-plex-sans` and `-mono` packages ship the latin and latin-ext subsets); the engineer downloads them to a scratch dir outside the repo, only the base64 goes into the page. Size growth is reported in the PR.
- Migration: none (static file). Saved `paper` preference opens the new Paper.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/theme.test.sh` |
| AC-2 | factory | `scripts/test/theme.test.sh` |
| AC-3 | factory | `scripts/test/visual-v4.test.sh` |
| AC-4 | factory | `scripts/test/visual-v4.test.sh` |
| AC-5 | manual | PR body states the byte growth, checked in review |
| AC-6 | manual | open Graphite and Paper at 1440×900 and 400px, checked in review |
| AC-7 | factory | `scripts/test/design-doc.test.sh` |
| AC-8 | factory | `scripts/test/visual-v4.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The old blue theme id `paper` is renamed `cobalt` and the new Paper takes `paper`: the issue keeps "12 other themes", which only holds with the rename. A saved `paper` opens the new Paper; no migration (cosmetic).
- 14 themes in all; Tape and Kraft leave the first four of the picker (Auto now means Graphite/Paper) and move behind "More themes".
- Fonts are taken from the official Plex woff2 files via fontsource; if the headless session has no network the engineer blocks the card rather than substitute another font.
- AC-5 and AC-6 are checked by hand in review (PR text, rendering); the rest is automated.
- New tokens exist in all 14 themes with the formulas from the doc (`accent-soft` 14%, `accent-line` 45% of the accent).

## Open questions
- none
