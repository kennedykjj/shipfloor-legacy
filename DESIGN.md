---
name: Shipfloor Dashboard
description: A deep-slate item shop for a software factory: cards are items, the drawer is the item tooltip.
colors:
  ground: "#0d1014"
  panel: "#151a21"
  panel-hi: "#1b212a"
  edge: "#262e39"
  edge-hi: "#36404e"
  parchment: "#ebe5d5"
  muted: "#8f8b80"
  faint: "#8b887f"
  gold: "#e2b356"
  coin: "#e2b356"
  coin-rim: "#4a3206"
  azure: "#63b2ff"
  azure-ink: "#0b2440"
  ok: "#7cc58a"
  warn: "#d9a45b"
  bad: "#f06a5f"
  stone-ground: "#e7e7e4"
  stone-panel: "#f4f4f2"
  stone-panel-hi: "#fbfbfa"
  stone-edge: "#d9d9d4"
  stone-edge-hi: "#c4c4bd"
  stone-ink: "#23262b"
  stone-muted: "#5a5955"
  stone-faint: "#686661"
  stone-gold: "#855a0c"
  stone-coin: "#c99a3c"
  stone-azure: "#1a5fb4"
  stone-ok: "#2f7d43"
  stone-warn: "#9a5b12"
  stone-bad: "#c23b31"
typography:
  stat:
    fontFamily: "ui-monospace, Cascadia Mono, SF Mono, Menlo, Consolas, monospace"
    fontSize: "19px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.01em"
    fontFeature: "tabular-nums"
  stat-sm:
    fontFamily: "ui-monospace, Cascadia Mono, SF Mono, Menlo, Consolas, monospace"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.15
    fontFeature: "tabular-nums"
  total:
    fontFamily: "ui-monospace, Cascadia Mono, SF Mono, Menlo, Consolas, monospace"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.1
    fontFeature: "tabular-nums"
  headline:
    fontFamily: "Segoe UI Variable Text, Segoe UI, system-ui, -apple-system, Helvetica Neue, sans-serif"
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.3
  title:
    fontFamily: "Segoe UI Variable Text, Segoe UI, system-ui, -apple-system, Helvetica Neue, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  body:
    fontFamily: "Segoe UI Variable Text, Segoe UI, system-ui, -apple-system, Helvetica Neue, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Segoe UI Variable Text, Segoe UI, system-ui, -apple-system, Helvetica Neue, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.45
    letterSpacing: "0.02em"
  log:
    fontFamily: "ui-monospace, Cascadia Mono, SF Mono, Menlo, Consolas, monospace"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.55
rounded:
  sm: "4px"
  md: "5px"
  card: "6px"
  dial: "50%"
spacing:
  xs: "6px"
  sm: "10px"
  md: "14px"
  lg: "20px"
components:
  card:
    backgroundColor: "{colors.panel-hi}"
    textColor: "{colors.parchment}"
    rounded: "{rounded.card}"
    padding: "9px 10px"
  card-awaiting:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.azure}"
    rounded: "{rounded.card}"
    padding: "9px 10px"
  button-approve:
    backgroundColor: "{colors.azure}"
    textColor: "{colors.azure-ink}"
    rounded: "{rounded.md}"
    padding: "7px 12px"
  button-secondary:
    backgroundColor: "{colors.panel-hi}"
    textColor: "{colors.parchment}"
    rounded: "{rounded.md}"
    padding: "7px 12px"
  flag:
    textColor: "{colors.muted}"
    rounded: "{rounded.sm}"
    padding: "1px 7px"
  gate:
    textColor: "{colors.ok}"
    rounded: "{rounded.sm}"
    padding: "2px 7px"
  drawer:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.parchment}"
    width: "min(660px, 52vw)"
---

# Design System: Shipfloor Dashboard

## Overview

**Creative North Star: "The Item Tooltip"**

The dashboard is an item shop for a software factory. Every card on the board is an item; opening one slides in its tooltip, the drawer: name, gold cost, tabbed sections for sessions, log, gates and review, and one decision. Surfaces are deep slate with a top-lit edge in dark mode and neutral pale stone in light mode, both following `prefers-color-scheme`. The mood is a quiet, dense, glanceable instrument for one owner doing quick checks: open, approve what waits, glance at cost and runs, close.

Two colors carry meaning and nothing else does. Gold means money: the cost numerals and the coin mark. Azure means the owner: what waits for them and the actions they take. Everything else is slate, parchment (or ink on stone) and hairlines. The system rejects the generic grey kanban with colored tags: column identity comes from position and name, never from tag color.

**Key Characteristics:**
- Item cards with a top-lit border and a faint vertical gradient; the drawer is the same material at tooltip scale.
- Two meaningful hues (gold for cost, azure for the owner), plus ok/warn/bad for outcomes only.
- Monospace tabular figures for every number; system sans for everything else.
- Hairline borders instead of shadows at rest; depth appears on hover and for the drawer.
- One signature motion: the cooldown dial on running cards.

## Colors

A slate-and-parchment ground with one coin-gold and one azure signal. The light theme keeps the same roles with darkened gold and azure for contrast on stone.

### Primary
- **Owner Azure** (`colors.azure`, light `colors.stone-azure`): the owner's color. Used for the "awaiting you" count and its card chips, the awaiting card's border, inset ring and tint, the waits line, the approve button fill (text is `azure-ink`), the focus ring, and the selection tint.

### Secondary
- **Coin Gold** (`colors.gold`, light `colors.stone-gold`): cost only. Cost numerals on cards, the session table and the drawer total, the header's spent-today figure, the `$ ?` unpriced marker, the coin mark (`.coin`), and the hairline rule under the tooltip header (gold at 60% mix). The coin itself is a struck disc: `colors.coin` (light `colors.stone-coin`, brighter than the text gold so it reads as metal on stone) lit by a white highlight at the top left, with a 1px rim mixed toward `colors.coin-rim`.

### Neutral
- **Deep Slate Ground** (`colors.ground`, light `colors.stone-ground`): page background and the textarea well.
- **Slate Panel** (`colors.panel`) and **Raised Panel** (`colors.panel-hi`): header, drawer, cards (gradient from raised to panel), hover rows. Light: `stone-panel`, `stone-panel-hi`.
- **Hairline** (`colors.edge`) and **Lit Edge** (`colors.edge-hi`): dividers and borders; the lit edge is the top border of cards and the drawer's left border.
- **Parchment** (`colors.parchment`, light `colors.stone-ink`): primary text; also the running dial and the selected-tab underline.
- **Muted** (`colors.muted`) and **Faint** (`colors.faint`): secondary text, column headings, table heads, "est." marks. Light: `stone-muted`, `stone-faint`.
- **Outcome trio** (`colors.ok`, `colors.warn`, `colors.bad`; light `stone-ok`, `stone-warn`, `stone-bad`): run results, gate pass/fail, paused/offline flags, notices. Never decorative.

### Named Rules
**The Coin Rule.** Gold appears only on money: cost numerals, the coin mark, the unpriced marker, and the tooltip header's cost rule. Never on buttons, headings, borders of cards or status.

**The Owner Rule.** Azure appears only on what waits for the owner or what the owner does. If a thing does not need a human, it is not azure.

**The Estimate Rule.** Every cost is labelled "est." in faint small type next to the figure; a missing price shows the gold `$ ?` marker with an explanatory title, never a zero.

## Typography

**Display/Body Font:** system sans (Segoe UI Variable Text, Segoe UI, system-ui, -apple-system, Helvetica Neue, sans-serif)
**Mono Font:** ui-monospace stack (Cascadia Mono, SF Mono, Menlo, Consolas, monospace)

**Character:** a tool's voice, not a brand's. Sans carries words; monospace with tabular figures carries every count, id, token total and cost so columns align and values do not jitter as they update. No webfonts, no CDN.

### Hierarchy
- **Stat** (mono, 600, 19px, 1.15; `stat-sm` 15px for per-stage slots and the tooltip stats): the header strip figures, with a 13px faint denominator.
- **Headline** (sans, 600, 18px, 1.3): the tooltip title; the tooltip cost is `total`, mono 20px 600.
- **Title** (sans, 400, 13px, 1.35, clamped to two lines): the card title.
- **Body** (sans, 14px, 1.45): page base; tables at 12.5px, meta lines 12.5px.
- **Label** (sans, 11-12px; 600 for column headings and section headers, 11px at 0.02em for section keys): column headings, table heads, flags, keys under stats. Sentence case, never uppercase.
- **Log** (mono, 12px, 1.55, pre-wrap): the log pane.

### Named Rules
**The Figures Rule.** Any number is mono with `tabular-nums` (`.num`). Prose stays sans.

## Layout

A full-height flex column that never scrolls the page: a slim header strip, then `main` holding the board and the drawer. The strip is a row of stats separated by hairlines (brand, awaiting you, pool in use, per-stage slots with 3px meters, runs today with ok/failed counts, spent today, then factory state right-aligned). Awaiting you comes first because it is the one number that asks for action; at zero it turns muted. The board is ten columns in factory order, each `flex: 1 1 180px` with a 166px floor; empty columns collapse to a 92px stub with a wrapping heading. The two owner columns (Spec Review, Staged) get full-strength headings. Cards stack with an 8px gap inside 10px column padding, and the board scrolls horizontally when columns do not fit. A column whose cards overflow fades its last 34px through a mask, so the cut reads as "more below".

The drawer is absolutely positioned over the board's right edge: `min(660px, 52vw)`, widening to `min(1180px, 72vw)` for the Review tab. Drawer content uses a 20px side gutter. Below 860px the header wraps, stats drop their borders, and the drawer takes the full width; below 600px the per-stage slots hide and the brand takes its own line. The drawer is a size container: under 540px the decision stacks and the tooltip stats go two by two.

## Elevation & Depth

Hybrid, mostly tonal. At rest depth is conveyed by surface steps (ground, panel, raised panel) and hairline borders with a lit top edge; there are no resting shadows. Cards lift 1px with a soft shadow on hover. The drawer casts a leftward soft shadow over the board.

### Shadow Vocabulary
- **Hover lift** (`box-shadow: 0 10px 30px rgba(0,0,0,.45)`, light `rgba(40,36,28,.14)`; via `--shadow`): card hover with `translateY(-1px)`.
- **Drawer cast** (`box-shadow: -14px 0 32px -8px rgba(0,0,0,.45)`): open drawer only; removed when closed.
- **Dial ring** (`0 0 0 2px panel, 0 0 0 3px edge`): the cooldown dial's inset ring.

### Named Rules
**The Flat-At-Rest Rule.** Cards and panels carry no shadow until hovered or, for the drawer, open.

## Shapes

Small, tool-like radii: 4px on flags, gates, chips and selects; 5px on buttons and the textarea; 6px on cards; a full circle for the dial and the coin. Borders are 1px hairlines; the awaiting card adds a 1px inset azure ring. The tooltip header is closed by a gold hairline, and the drawer is a flat-edged panel with no radius.

## Components

### Cards
Item tiles: raised-to-panel gradient, 1px border with a lit top edge, 6px radius, 9px 10px padding, number (mono, muted) at left and gold cost at right, title below, optional status line. Hover lifts 1px. A running card gains the lit border and a dial line. A blocked card adds a small neutral-outlined flag whose first word carries the outcome color: **blocked** (bad) · needs you, or **infra** (warn) · retrying; the red never fills or borders the card, so the owner's azure stays the loudest thing on the board. An awaiting card takes the azure border, inset azure ring, azure-tinted gradient, a top edge lit in azure (azure mixed 55% with parchment) and a footer band: the waits line ("spec to review" or "ready to ship", 12px 600 azure) runs edge to edge on an azure tint under an azure hairline, the owner's version of the tooltip head's gold rule. A card being moved dims to 55% and reads "moving...". The open card gets a parchment border. A card in Done shows its cost muted, without the coin: it is history, not a decision, and gold stays rare. A card whose title could not be read from GitHub says "Title not loaded" in faint italic instead of repeating its number. Each card's accessible name is short and ordered: number, title, status, blocked, cost.

Column headings are text only: owner columns read their name in parchment followed by a small azure "yours"; factory columns are muted. Done shows its last five cards and a dashed "Show N more" button.

### Cooldown Dial (signature)
A 13px circle filled by a conic gradient sweep in parchment over lit-edge, ringed by the dial ring, rotating a full turn every 6s linearly via a registered `--sweep` angle. Appears only on running cards. Under `prefers-reduced-motion: reduce` it stops and shows a static quarter (90deg); card and drawer transitions are also disabled. It is the only continuous motion; the log skeleton shimmer is a loading state only.

### Header Strip
Stats with a 12px muted key under a 19px mono value; slot meters are 3px parchment bars at 75% opacity. The "awaiting you" stat is azure and lists the waiting card numbers as small azure mono buttons that open the card. Flags are 12px, 4px-radius outlines; warn and bad take their outcome color. When the board snapshot is older than 5 minutes, a warn flag "board N min old" replaces the neutral "running". A project the dispatcher skips raises a bad flag "<project> skipped since HH:MM" with the reason in its title, and a bad line in the decision. The awaiting key carries a small `kbd` "n" for the next-card key; its buttons carry the column and title as their accessible name. On a narrow screen the board fades its right edge while more lanes scroll in.

### Tooltip Drawer
Panel with a lit left edge, `role="dialog"` (non-modal), labelled by its title. The tooltip head reads like an item tooltip: the number and title (headline), a bordered Close button pinned at the top right (it comes last in the tab order, after the decision and the tabs; Esc closes too), a meta line (column, the state in azure "waits for you: ..." or a dial and clock when running, the GitHub link), then a stat row of four `dt`/`dd` pairs: cost Inbox to now (gold `total` with "est."), sessions, first to last run, last report (pipeline plus its outcome color, and "(before develop)" when another stage runs now). A blocked card adds the block note: "**Blocked** · the factory stopped and waits for your call" (or "infrastructure failed; the factory retries once"), then the one line that says what the owner must decide and the failed gate, both pulled from the factory's issue comment, Unblock & retry at the right, and the full report folded under "Full report" (rendered from its markdown: headings, bullets, code). The gold hairline closes the head.

Under the head, for Spec Review and Staged cards only, sits **the decision**, whatever tab is open: "Your decision" with the review progress on the right ("1 of 3 reviewed · 1 change", mono), Approve with its destination, a hint, the request-changes textarea and Request changes (disabled until there is text), plus "Use the review's N changes", which fills the textarea from the review marks. When the board snapshot is stale, a warn line in the decision says how old it is and that the actions read the live board first. A review with nothing to mark says so ("nothing to mark in the review"). In a drawer narrower than 540px the textarea folds: the first click on Request changes opens it. While the review has unreviewed items or asks for changes, Approve turns **soft** (azure tint, azure text) and asks twice: the first click becomes "Approve with 2 not reviewed" for 4s. After a move the notice names the next waiting card as a button. Notices are a polite live region. A card in an owner column opens on the Review tab and keeps the wide drawer on every tab, so tabs never reflow it; any other card opens on Sessions in the narrow drawer.

Then underlined tabs (Sessions, Log, Gates, Review) with mono counts, a real tablist (roving tabindex, arrow keys, Home and End) over one tabpanel. Sessions are a right-aligned numeric table with sticky heads (start, stage and model, input, output, cache read plus written with the split on hover, time, result, cost), dashed sub-rows for subagents and a total row. Gates map outcomes explicitly: ok, done, pass and merged are ok; fail, error and blocked are bad; anything else is muted; a stage with no gates and no notes says "No gates for this stage". The Log tab counts the card's log files; the log scrolls under its own bar and opens at its end. The Review tab hosts the review page in a sandboxed iframe.

### How a Card Opens
Where a card opens depends on where it was clicked, so the click never hides what the owner was looking at. A card in In progress, and its Log link, opens **maximized**: the drawer at 90% of the screen over a dimmed, blurred board, a running card on Live and a waiting one on Sessions; the side drawer would cover its own tile. A card that waits for the owner opens the wide side drawer on Review, with the decision. Esc or Close returns to the board, and focus goes back to what opened the card.

### Line Peek
A click on a dot of the lifecycle line opens the **peek**, never the drawer: the line is the map, and a drawer over its right half hides the stages the dot sits in. The peek is a small raised panel (panel-hi, lit hairline border, 8px radius, the drawer's shadow, 340px at most) anchored under its dot by a 10px arrow, clamped to 12px from the window edges. It holds the number and title (14.5px 600), one muted meta line (column, "Develop running 4 min" or the dot's state, "step 2 of 7 · Plan", the cost in gold), the stage's step bar, and one row of actions: the primary button, then Log (ghost), then the GitHub link. The primary is "Open session" for a running card and "Open card" otherwise, both maximized; a card that waits for the owner says "Review" and opens the wide drawer, so the decision keeps its place. `role="dialog"`, labelled "Card summary"; its dot carries `aria-expanded` and the open ring. Focus moves to the primary button. Esc closes it and returns focus to the dot; so do a click outside, a click on the same dot and leaving the Factory view. Another dot moves it. It follows its dot on every refresh and closes when the dot leaves the line.

### Feed
One timeline, newest first, with a heading where the day changes. Above it, the filters (All, Waits for you, Failures, Running, Dispatcher), each with its count, and "Newest first". A run is **one row** placed at the time it ended (or started, while it runs): the time in mono, a mark whose shape carries the state (dot ok, diamond failed, ring running, dash for a dispatcher line or a run whose end was never logged), the project when there is more than one, the stage in bold, the card's number and title, and "waits for you" in the accent when the card sits in an owner column after that run. On the right, the duration (or "running 6m", or "· exit 4") and the run's estimated cost. A second line appears only when something is known of what the run left behind, each piece from its own source: the last line of a run that failed (the log), "PR #64" and "gates failed: build" (the run's report), "now in Staged" on the card's newest run (the board), "Step 4 of 7: Engineer" while it runs (its lock). Nothing is inferred from the stage. The whole row opens the card maximized on that run's log; the title is the row's button and keeps focus across refreshes. There is no button in a row. A dispatcher or stacks line repeated in a row is one row with "37× since 00:09".

### Language
The page is written in English and shown in the machine's language (`language` in `~/.shipfloor/config.yml`). In another language, every piece of text is rewritten as it enters the document, from the catalog the server sends (`scripts/lang/dashboard.<code>.json`): a whole piece by `exact`, a phrase inside one by `rx`. So a new string needs no code, only an entry; one with no entry shows in English. What the factory did not write is never rewritten: card titles, logs, and what the agents said (the `RAW` selector). Board columns keep their GitHub names in the data and show translated.

### Themes
The owner picks how the dashboard looks in Settings, under Themes. A theme only changes color tokens: the base block in `scripts/dashboard.html` is Charcoal, and each `[data-theme="<id>"]` block sets the same tokens (ground, panels, edges, the four text steps, the accent `sand`, ok/warn/bad, the two glows, the lifecycle track, `refine`). A light theme also sets `--ov`, `--well`, `--scrim`, `--shadow` and `color-scheme: light`. No color is written out in a rule: tints come from `color-mix` over a token.

Nine dark themes (Floor tape, Charcoal, Dock, Machine green, Blueprint, Foundry, Night shift, Terminal, High contrast) and three light ones (Kraft, Steel, Drafting paper). Auto, the default, follows the system: Floor tape in dark, Kraft in light. The choice lives in the browser (`localStorage`, `shipfloor.theme`) and is applied before the first paint. In every theme the accent is not one of the outcome colors, so where the accent is yellow the warning is orange.

A swatch is a button that carries its theme's `data-theme`, so it is drawn with the same tokens as the page it stands for. The embedded review page gets the theme's colors as a message. To add a theme: one block in the CSS and one entry in `THEMES`; `scripts/test/theme.test.sh` refuses a theme with a missing token or with text under 4.5:1 on its ground and panels.

### Buttons
- **Approve:** azure fill, `azure-ink` text, 600 weight, 5px radius, 7px 12px; hover brightens 8%.
- **Secondary (Request changes, Retry):** raised panel, lit-edge border, parchment text; hover border turns parchment.
- **Disabled:** 50% opacity, progress cursor.
- **Focus:** 2px azure outline, 2px offset on every focusable element.

### Embedded Review Pages
Agent-written review pages in the iframe are re-themed by `EMBED_CSS` in `scripts/dashboard.py`: their own header hidden, section headings at 17px 600, its own reviewed count hidden (the decision shows it), and their page, sheet, surface, ink, muted and rule variables remapped to ground, panel, raised panel, parchment, muted and hairline (and the stone set in light), system sans for display and body, 600 headings, transparent buttons with hairline borders. While the page loads, the iframe element paints nothing of it and holds the drawer's panel color (`var(--panel)`); it is shown, with one 150ms ease-out opacity fade (instant under reduced motion), once the page has acknowledged the theme (`themed`), and white (`#fff`) is its background only under a plain page, one that does not take the embed theme and never announces itself (`ready`), shown when its load ends. The same embed adds a small script that announces `ready`, acknowledges each theme with `themed`, and posts the page's marks (`review-progress`: done, total, the changes as text) to the dashboard, which accepts them only from that iframe.

### Keyboard and Live Updates
Esc closes the drawer (not while typing); n opens the next card awaiting you; arrows move between tabs. Opening a card moves focus to its title, closing returns it to the card. The page polls every 5s but rewrites a region only when its markup changed, so focus, scroll, the open select and typed text survive; clocks tick on their own. The first read shows "Reading the factory…", and a failed read raises a "not updating" flag with the error in its title.

## Do's and Don'ts

### Do:
- **Do** use gold only for cost and the coin mark, and azure only for the owner's waiting items and actions.
- **Do** set every number in mono with tabular figures and label every cost "est.".
- **Do** keep surfaces flat at rest and express hierarchy with the panel steps and hairlines.
- **Do** provide the light-theme value for every new color token in the `prefers-color-scheme: light` block, darkening gold and azure for contrast.
- **Do** keep the cooldown dial as the single continuous animation and give any new motion a reduced-motion fallback.
- **Do** keep factory stage and column names verbatim.

### Don't:
- **Don't** color-code columns or cards with tags or per-stage hues; position and name identify a stage.
- **Don't** use gold or azure as decoration (borders, headings, icons, dividers) or use red/green for anything but outcomes.
- **Don't** add emoji, icon fonts or glyph icons; text labels carry actions and column ownership.
- **Don't** add webfonts, CDN assets or a build step; the dashboard is one self-contained file.
- **Don't** add resting shadows, gradients beyond the panel step, or a second continuous animation.
