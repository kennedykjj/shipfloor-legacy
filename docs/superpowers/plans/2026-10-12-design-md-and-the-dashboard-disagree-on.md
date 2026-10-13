# DESIGN.md and the dashboard disagree on 12 values — plan

**Issue:** #120 · **Spec:** `docs/superpowers/specs/2026-10-12-design-md-and-the-dashboard-disagree-on-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA extends the acceptance tests (`scripts/test/design-doc.test.sh`, `scripts/test/theme.test.sh`), red.
2. Task 1 (factory), one task: the page, `DESIGN.md` and `.impeccable/design.json` change together, because `design-doc.test.sh` compares each with the others and a half-done state fails its existing checks.

## Before the plan

The branch is one commit behind `origin/main` (#124, which touched `scripts/dashboard.html`). It is not merged here: the deploy does that once, on the approved head. The twelve rules of this card are found by selector, never by line number.

## Acceptance tests — QA

New checks only; every existing check of both files stays as it is. No server, no network: the tests read `scripts/dashboard.html`, `DESIGN.md` and `.impeccable/design.json`.

**`scripts/test/design-doc.test.sh`**
- AC-2: no rule of the page's `<style>` block uses a `font-size` (or a `font:` shorthand size) of 16, 21, 22, 24, 26 or 30px; `28px` is a `fontSize` of the front matter's `typography` (`typography.section`). A failure names the size and the selector that uses it.
- AC-3: no rule uses a `border-radius` of 1, 10 or 14px; `rounded.pill` is `"40px"` in the front matter. A failure names the radius and the selector.
- AC-4: the body of `.idec` and the body of the `.pill:hover` rule (`.stub .pill:hover, .edit .pill:hover`) hold no hex, `rgb()`/`hsl()` or named color literal; `.idec` reads `background: var(--well)`; the hover's background is a `color-mix` over tokens.
- AC-6: every bullet under `## Known deviations` names a value its selector uses on the page; none of 16, 21, 22, 24, 26, 30px and 1, 10, 14, 40px is listed.
- `EMBED_CSS` and `iframe.plain` are outside these checks (out of scope in the spec).

**`scripts/test/theme.test.sh`**
- AC-5, for each of the twelve themes: `--well` (8-digit hex) composited over `panel` keeps `text`, `soft` and `muted` at 4.5:1; `ground` over the mix of 88% `text` and 12% `ground` keeps 4.5:1. A failure names the theme, the pair and the ratio.
- The well check may already pass on today's page (the tokens exist); the AC is red through the AC-4 checks, which fail until `.idec` and the hover read the tokens. QA reports which AC-5 checks are red and which already hold.

Before the implementation the new checks fail on their assertions (the page and the document are parsed and found wrong), not on a crash. AC-1 and AC-7 are manual: no test.

## Task 1 — factory: the twelve values move, and the document says so

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` — the `<style>` block only
- `DESIGN.md`
- `.impeccable/design.json`

**`scripts/dashboard.html`** (the UX table of the spec; no markup, script or `EMBED_CSS` change)
- 17px: `.lane`, `.thp .n` (a `font:` shorthand).
- 20px: `.ique .pnum`, `.iread h2`.
- 23px: `.tnum`, `.pnum`, `.disp h1`.
- 28px: `.band > h1`, `.side h1`, `.set-body > h1`.
- `.f-bad .fdot`: `border-radius: 0`.
- 8px: `.iopt`, `.thp`. 16px: `.drawer.open.full`. `.stub .pill, .edit .pill` keeps 40px.
- `.idec`: `background: var(--well)`.
- `.stub .pill:hover, .edit .pill:hover`: `background: color-mix(in srgb, var(--text) 88%, var(--ground))`. `.btn.approve:hover` is not touched.

**`DESIGN.md`**
- Front matter: `typography.section` (condensed, 500, 28px, line-height 1, 0.02em, uppercase) and `rounded.pill: "40px"`.
- Prose, as the spec's UX section lists: Hierarchy (Section added, the 23px line renamed Brand / Number), Shapes (the pill step, the swatch at 8px, state marks are square), In Progress (23px), Themes (the pill hover and the decision well leave the exceptions; the white of a plain review page stays), Buttons (the hover mixes 12% of the ground).
- `## Known deviations` keeps only `` `15.5px` — `.isec .plain` ``.

**`.impeccable/design.json`**
- `typographyMeta` gains `section`; the `brand` purpose names the card number; `generatedAt` is 2026-10-12; `schemaVersion` stays 2.

**Done when:** `scripts/test/design-doc.test.sh` and `scripts/test/theme.test.sh` pass, and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.

## Manual checks (validation, owner)

- AC-1: `impeccable detect scripts/dashboard.html` on the owner's machine.
- AC-7: Factory, Feed and Settings at 1440px and 390px on the demo stack; "N wait for you" fits one line, "Drafting paper" fits its swatch.
