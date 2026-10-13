# Dashboard: the accent marks a queue and an infrastructure block, and two stages share a blue — plan

**Issue:** #115 · **Spec:** `docs/superpowers/specs/2026-10-12-dashboard-the-accent-marks-a-queue-and-a-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-accent.test.sh` new; `scripts/test/theme.test.sh` and `scripts/test/design-doc.test.sh` extended), red.
2. Task 1 (factory): the page, DESIGN.md and `.impeccable/design.json`, in one task. They cannot be split: `design-doc.test.sh` fails as soon as the page has a color token the front matter lacks, and the build gate runs after every task.

## Acceptance tests — QA

All three files read `scripts/dashboard.html` and `DESIGN.md` as text with the factory's Python (stdlib only), as `scripts/test/dashboard-narrow.test.sh` and `scripts/test/theme.test.sh` do; no browser and no server. One named check per criterion, so a red run says which criterion is missing. The checks that already pass in the extended files stay as they are.

- **`scripts/test/dashboard-accent.test.sh` (new), AC-1 to AC-4.** Resolves which color token each mark of a waiting tile takes from the page's CSS (the last rule that matches wins, as the cascade does for equal-or-higher specificity), not from one literal line.
  - **AC-1** — on `.tile.wait` with no kind: `.ring` border is `--muted` and it has no fill; `.why` is `--soft`; `.tnum` and `.ttitle` are `--muted`; `.tile.wait.ch` has a `--text` border and its rule comes after `.tile.ch`; none of these marks resolves to `--sand`, `--ok`, `--warn` or `--bad`.
  - **AC-2** — on `.tile.wait.infra`: `.ring` background and border are `--warn`; `.tnum` and `.why` are `--warn`.
  - **AC-3** — the token of the infra tile's ring, number and reason is the token `.dot.infra i` and `.dot.infra em` use (read from the page, not hardcoded); `renderWork` builds the waiting tile's class from `kindOf(key(c), c)` and adds only `infra` or `you`.
  - **AC-4** — the only rules that give a `.tile.wait` mark `--sand` are under `.tile.wait.you` (ring fill and border, `.tnum`, `.why`) and the cost (`.tcost`); the bare `.ring` and `.why` rules no longer name `--sand`.
- **`scripts/test/theme.test.sh` (extended), AC-5 and AC-6.**
  - `validate` joins the tokens held to 4.5:1 on ground, panel and panel-hi; `refine`, `text`, `validate` and `ok` are held to 3:1 on `edge`. Every one of the twelve themes sets `--validate`.
  - **AC-5** — `STAGE_HUE` is read from the page: `validate` is `var(--validate)`, and the bar and the key both read `STAGE_HUE[st]`. On Kraft, Refine and Validate are at least 20 apart (CIE76 ΔE, computed with the stdlib).
  - **AC-6** — per theme, the four `STAGE_HUE` tokens resolve to four colors, every pair at least ΔE 20 apart, and none equals `sand`. A failure names the theme and the pair.
- **`scripts/test/design-doc.test.sh` (extended), AC-7.** "says why in the accent" is gone from DESIGN.md; the "In Progress" paragraph names the hollow `muted` ring, `soft`, `warn` and the owner-only accent; the Settings pool bar sentence names `validate`; the Themes token list ends with `validate`. Its existing check of the front matter against the page's tokens covers `colors.validate`.
- Before the implementation every new check fails on its assertion (the page or the document lacks the rule or the sentence), not on a missing file or a crash.

## Task 1 — factory: waiting tile kinds, `--validate`, the design documents (AC-1 to AC-7)

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` (change)
- `DESIGN.md` (change)
- `.impeccable/design.json` (change)

**What changes**
- **`scripts/dashboard.html`, CSS**
  - `--validate` in the base block (`:root, [data-theme="charcoal"]`) and in each of the other eleven theme blocks, with the values of the spec's `## UX` (charcoal, tape, dock, machine, foundry, terminal `#c896ec`; blueprint `#f06fe0`; night `#d98af5`; contrast `#e29bff`; kraft `#86389a`; steel `#9c2f8c`; paper `#a3277f`).
  - `.ring`: `border: 2px solid var(--muted)`; `.why`: `color: var(--soft)`.
  - `.tile.wait.infra`: `.ring` background and border `--warn`; `.tnum` and `.why` `--warn`.
  - `.tile.wait.you`: `.ring` background and border `--sand`; `.tnum` and `.why` `--sand`.
  - `.tile.wait.ch { border-color: var(--text); }`, after `.tile.ch` so it wins. Running tiles keep `.tile.ch`.
- **`scripts/dashboard.html`, JS**
  - `renderWork` (the waiting tile, line 1094): the class is `tile wait` plus ` infra` or ` you` when `kindOf(key(c), c)` returns that kind; every other kind adds nothing. The `waits` filter does not change.
  - `STAGE_HUE.validate` becomes `"var(--validate)"`.
- **`DESIGN.md`** — front matter `validate: "#c896ec"` after `refine`; "The 19 front matter entries" becomes 20; the Refine line, the "In Progress" last sentence, the Settings pool bar sentence and the Themes token list, worded as the spec's `## UX` gives them.
- **`.impeccable/design.json`** — `colorMeta.validate` (`role: secondary`, `displayName: Validate Stage`, `canonical: #c896ec`); `generatedAt` set to 2026-10-12.
- **A `--validate` value that fails `theme.test.sh`** (the values were computed by hand in refinement) is moved in lightness, keeping its hue, until the 4.5:1, 3:1 and ΔE 20 checks pass; the engineer reports each value changed, and DESIGN.md and `design.json` carry the final charcoal value.

**Done when:** `scripts/test/dashboard-accent.test.sh`, `scripts/test/theme.test.sh` and `scripts/test/design-doc.test.sh` pass whole and the build gate is green.
