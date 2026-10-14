# Plan — #180 [UX-06] Visual system v4: IBM Plex, Graphite and Paper themes, one accent

Spec: `docs/superpowers/specs/2026-10-14-ux-06-sistema-visual-v4-ibm-plex-temas-g-design.md`
Token source: Floor v4, "Visual system" (branch `claude/beautiful-gates-svtmiu`, `docs/design/floor-v4.md`).
A copy of that document sits in the card's tmp dir as `floor-v4.md`.

One layer: `factory` (path `./`, agent `engineer`). Tasks run one at a time in the shared worktree.

## Acceptance tests (QA, before any task)
- `scripts/test/theme.test.sh`: AC-1 (14 themes, Graphite and Paper with the v4 values, every theme defines
  `raise`, `accent-ink`, `paper`, `accent-soft`, `accent-line`, text ≥ 4.5:1 on ground and panels, Cobalt is the
  old blue theme), AC-2 (first group `auto, graphite, paper, contrast`; Auto resolves to graphite / paper; cobalt
  selectable).
- `scripts/test/visual-v4.test.sh` (new): AC-3 (Plex Sans 400/500/600/400 italic and Plex Mono 400/500 as woff2
  data URIs, no Barlow, no network URL), AC-4 (no `text-transform: uppercase` beyond the DESIGN.md exceptions),
  no font-size under 12px, AC-8 (`scripts/fonts/OFL.txt` exists and README cites it).
- `scripts/test/design-doc.test.sh`: AC-7 (Typography, Colors, Themes, Do's and Don'ts, front matter).
- AC-5 and AC-6 are manual (PR body, review).

## Tasks

### T1 — Fonts and type (factory, engineer)
Depends on: acceptance tests.
Files: `scripts/dashboard.html`, `scripts/fonts/OFL.txt` (new), `README.md`.
- Download the official IBM Plex woff2 files (fontsource `@fontsource/ibm-plex-sans`, `@fontsource/ibm-plex-mono`,
  latin and latin-ext subsets) into a scratch dir under the card's tmp dir, never into the repo. No network → stop
  and answer blocked; never substitute another font.
- Replace the Barlow `@font-face` rules with Plex Sans 400/500/600/400-italic and Plex Mono 400/500, latin and
  latin-ext with `unicode-range`, `font-display: swap`. `--sans`/`--mono` point at Plex (fallback `system-ui`,
  `ui-monospace`); `--cond` goes away and its rules move to `--sans`.
- Remove every `text-transform: uppercase` and its wide `letter-spacing`; type roles and scale from the spec's UX
  section (34/24/17/16/15/14/13/12, nothing under 12px, prose max 64ch, mono figures tabular-nums).
- Space and shape: panels radius 16, decision panel 14 and `panel-hi`, tokens 8, chips/pills 999px, 4/8 grid.
- Add `scripts/fonts/OFL.txt` (SIL OFL 1.1 text for IBM Plex) and cite it in `README.md`.
- Record the byte growth of `dashboard.html` (before/after) in the task's answer; it goes into the PR body.

### T2 — Themes and accent rule (factory, engineer)
Depends on: T1.
Files: `scripts/dashboard.html`, `scripts/lang/dashboard.*.json` (12 files), `scripts/test/dashboard.test.sh`,
`scripts/test/dashboard-accent.test.sh` (only where they pin the old theme set or accent selectors).
- Add `graphite` and `paper` theme blocks with the v4 table values; rename the old `[data-theme="paper"]` to
  `cobalt`; every one of the 14 blocks defines `raise`, `accent-ink`, `paper`, `accent-soft` (accent 14%),
  `accent-line` (accent 45%). `--sand` stays the accent token (Graphite/Paper set it to the table's accent).
- `THEMES.first` = `auto, graphite, paper, contrast`; `tape` joins dark, `kraft` and `cobalt` join light;
  `theme()` resolves auto to `graphite` / `paper` via `prefers-color-scheme`; the favicon reads the same tokens.
- Accent rule: accent only on what waits for the owner; costs, titles, outlines and money totals move to
  `text`/`edge-hi`, every cost keeps `est`; text on accent fill uses `accent-ink`.
- Lang files: `theme.graphite` "Graphite", `theme.cobalt` "Cobalt", `theme.paper` "Paper", `theme.auto.sub`
  translated "Graphite in dark, Paper in light".

### T3 — Design docs (factory, engineer)
Depends on: T2.
Files: `DESIGN.md`, `.impeccable/design.json`.
- Typography (Plex, the 34–12px scale, nothing under 12px), Colors (accent marks only what waits for the owner;
  costs in `text` with `est`), Themes (14, Graphite/Paper under Auto, Cobalt), Do's and Don'ts (no uppercase, the
  accent rule, listing any uppercase exception), front matter values.
