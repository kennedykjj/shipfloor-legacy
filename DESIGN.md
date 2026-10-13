---
name: Shipfloor Dashboard
description: "A dark-by-default instrument for one owner of a software factory: a lifecycle band that shows where every card is, a short list of what waits for the owner, and a drawer for one card."
colors:
  ground: "#0a0a0a"
  panel: "#14171b"
  panel-hi: "#1c2026"
  edge: "#2a2f39"
  edge-hi: "#3d444f"
  text: "#f2f1ee"
  soft: "#d6d8da"
  muted: "#a3abb6"
  faint: "#8f98a3"
  sand: "#c7b9a6"
  glow1a: "#3b4a5e"
  glow1b: "#1c232d"
  glow2: "#2a2622"
  track: "#5a6472"
  track-on: "#c9ced4"
  refine: "#8fa8c7"
  validate: "#c896ec"
  ok: "#9fcbaa"
  warn: "#dcb872"
  bad: "#e58f80"
typography:
  brand:
    fontFamily: 'Barlow Condensed, "Arial Narrow", sans-serif'
    fontSize: "23px"
    fontWeight: 600
    letterSpacing: "0.06em"
  section:
    fontFamily: 'Barlow Condensed, "Arial Narrow", sans-serif'
    fontSize: "28px"
    fontWeight: 500
    lineHeight: 1
    letterSpacing: "0.02em"
  display:
    fontFamily: 'Barlow Condensed, "Arial Narrow", sans-serif'
    fontSize: "34px"
    fontWeight: 500
    lineHeight: 1
    letterSpacing: "0.02em"
  heading:
    fontFamily: 'Barlow Condensed, "Arial Narrow", sans-serif'
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.1
    letterSpacing: "0.05em"
  control:
    fontFamily: 'Barlow Condensed, "Arial Narrow", sans-serif'
    fontSize: "17px"
    fontWeight: 600
    letterSpacing: "0.06em"
  headline:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.3
  base:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.45
  title:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "14.5px"
    fontWeight: 500
    lineHeight: 1.3
  body:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.45
  ui-lg:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "13.5px"
    fontWeight: 400
    lineHeight: 1.35
  ui:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "13px"
    fontWeight: 400
  label:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "12.5px"
    fontWeight: 400
  meta:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "12px"
    fontWeight: 400
  caption:
    fontFamily: 'Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif'
    fontSize: "12px"
    fontWeight: 500
    letterSpacing: "0.1em"
  log:
    fontFamily: 'ui-monospace, "Cascadia Mono", "SF Mono", Menlo, Consolas, monospace'
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.55
rounded:
  bar: "2px"
  sm: "4px"
  md: "5px"
  lg: "6px"
  ctrl: "8px"
  tile: "12px"
  panel: "16px"
  pill: "40px"
  dial: "50%"
spacing:
  xs: "6px"
  sm: "10px"
  md: "14px"
  lg: "20px"
components:
  panel:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.panel}"
    padding: "18px 20px 14px"
  tile:
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "12px 14px 10px"
  tag:
    textColor: "{colors.muted}"
    rounded: "{rounded.sm}"
    padding: "1px 7px"
  gate:
    textColor: "{colors.ok}"
    rounded: "{rounded.sm}"
    padding: "2px 7px"
  button:
    backgroundColor: "{colors.panel-hi}"
    textColor: "{colors.text}"
    rounded: "{rounded.md}"
    padding: "7px 12px"
  button-approve:
    backgroundColor: "{colors.text}"
    textColor: "{colors.ground}"
    rounded: "{rounded.md}"
    padding: "7px 12px"
  drawer:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    width: "min(660px, 52vw)"
---

# Design System: Shipfloor Dashboard

## Overview

**Creative North Star: "The Floor Plan"**

The dashboard is the floor plan of a software factory, read by one owner doing quick checks: look at the lifecycle band to see where every card stands, answer what waits for you, glance at what is running and what it cost, close. It has three views, chosen in the header: **Factory** (the board), **Feed** (a timeline of runs) and **Settings** (the dispatcher, the sessions, the projects, the themes and the prices). A card opens in a drawer; a dot on the lifecycle band opens a small peek first.

The surface is a dark page under a faint grain and two soft glows, with translucent panels and hairline borders. Its type is Barlow for words and Barlow Condensed in uppercase for headings; every number keeps tabular figures. Two roles are colored and nothing else is: the **accent** (`sand`) marks money and whatever waits for the owner, and the outcome trio (ok, warn, bad) marks results. Everything else is ink and hairlines. Color is chosen by the owner: twelve themes change the same tokens and nothing else.

**Key Characteristics:**
- One lifecycle band: every column a cell on a dotted track, every card a dot.
- Panels are translucent washes of the theme's ink over the ground, with a hairline border and a 16px radius.
- Uppercase condensed headings and uppercase tracked captions; sentence case for everything a person reads as prose.
- Hairlines instead of shadows at rest; depth appears for the drawer, the peek, the maximized panel and the hover of a tile.
- Two continuous motions only: the cooldown dial on a running card and the pulse of a running dot, both stopped under reduced motion.

## Colors

Every color is a token of the base block (`:root, [data-theme="charcoal"]`), and every other theme sets the same tokens. The 20 front matter entries are exactly that block. Two more are derived from them in `:root`: `--gold` is `sand`, `--azure` is `text`, `--azure-ink` is `ground` and `--azure-soft` is `text` at 12% (the page still uses these names for the money and the owner's action).

### Neutral
- **Ground** (`colors.ground`): the page, under a grain and the glows (`glow1a`, `glow1b`, `glow2`), and the well of the text area and of code.
- **Panel** (`colors.panel`) and **Raised Panel** (`colors.panel-hi`): the drawer, the peek, a maximized panel and hover rows; ordinary panels on the page are only a 2% wash of the ink over the ground.
- **Hairline** (`colors.edge`) and **Lit Edge** (`colors.edge-hi`): dividers and borders; the lit edge is the border of the drawer, the peek and the buttons. The header rule, the legend, the stats separator and the passes use `--hair`, the theme's ink at 11% (`#ffffff1c` on Charcoal, the edge's tonal ramp in the sidecar).
- **Text steps** (`colors.text`, `colors.soft`, `colors.muted`, `colors.faint`): primary, body, secondary and tertiary text, in that order. Each theme holds every step to 4.5:1 on its ground and panels.
- **Track** (`colors.track`, `colors.track-on`): the lifecycle band's dotted line, and its solid line under a stage that works.

### Accent
- **Sand** (`colors.sand`): the accent. It marks what waits for the owner (the waiting dot, the card number in "Your" list, the `waits for you` words, the focus ring, the open option and the selected nav item) and it is the color of money (`gold` is an alias of it). In Floor tape it is yellow, in Kraft a blue; it is never one of the outcome colors.
- **Refine** (`colors.refine`) and **Validate** (`colors.validate`): the hues of those two stages in the Settings pool bar, where Develop is `text` and Deploy is `ok`. Neither is the accent.

### Outcome trio
- **ok, warn, bad** (`colors.ok`, `colors.warn`, `colors.bad`): results, gates, flags and alerts. A blocked card is `bad` in its number and its dot; infrastructure trouble is `warn`. Never decorative, and never the accent.

### Named Rules
**The Accent Rule.** The accent appears on money and on what waits for the owner or what the owner is doing. Outcomes use their own trio.

**The Estimate Rule.** Every cost is an estimate and says so: "est." next to the figure, or "Spent est." in the header; a missing price shows `$ ?` with an explanation, never a zero.

## Typography

**Sans:** Barlow, "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif
**Condensed:** "Barlow Condensed", "Arial Narrow", sans-serif
**Mono:** ui-monospace, "Cascadia Mono", "SF Mono", Menlo, Consolas, monospace

**Character:** a tool's voice. Both Barlow faces are embedded in the file as `@font-face` data (Barlow 400, 500 and 600; Barlow Condensed 500 and 600), so the page needs no network, no CDN and no build. If a face fails to load, the system stack named after it takes over. Monospace carries logs, code, the Settings hours field and the time in the Feed.

### Hierarchy
- **Display** (condensed, 500, 34px, uppercase): the heading of a panel (`h1.g`), such as Lifecycle or Today.
- **Section** (condensed, 500, 28px, 1, 0.02em, uppercase): the heading of the maximized line, of the Yours column and of a Settings section.
- **Brand / Number** (condensed, 600, 23px, 0.06em, uppercase): the product name in the header, and the card number: one size in Yours and in a tile, and the dispatcher line's heading.
- **Heading** (condensed, 600, 20px, uppercase): a column label in the lifecycle band, the tooltip total, a Settings group title.
- **Control** (condensed, 600, 17px): the steppers and the heading of the decision.
- **Headline** (sans, 600, 18px, 1.3): the drawer's card title.
- **Base** (sans, 15px, 1.45): the page's base text, with tabular figures everywhere.
- **Title** (sans, 14.5px, 500, 1.3, clamped to two lines): a card title in a tile, a pass and the peek.
- **Body** (sans, 14px): sections of the inbox reader, the alerts, descriptions.
- **UI** (13.5px, 13px, 12.5px): buttons, table cells, meta lines, tab labels, notices; 13.5px for the Feed's lines and the tile's last words.
- **Meta (12px)**: keys under stats, the legend, tags, gates, clocks and code. Nothing on the page is set under 12px.
- **Caption** (sans, 500, 12px, 0.1em, uppercase): the uppercase caption of the header (the views, the stats), of the inbox's section titles and of the legend. Captions are always uppercase and tracked wide; headings are condensed and uppercase; only prose is in sentence case.
- **Log** (mono, 12px, 1.55, pre-wrap): the log pane and the Feed's time.

The type ramp is the set of values used by three or more rules, plus 18px, 23px and 34px for their named roles. Section (28px) is used by three rules. The values used by fewer rules are listed under Known deviations. Order: Display 34 > Section 28 > Brand / Number 23 > Heading 20 > Headline 18 > Control 17.

### Named Rules
**The Figures Rule.** Any number keeps tabular figures (`font-variant-numeric: tabular-nums` on the body). Prose stays proportional.

## Layout

The page is a grid of three rows (the header, the alerts when something is wrong, then the view) that does not scroll as a whole above 1180px; each panel scrolls inside itself. The page padding is `clamp(16px, 4vw, 56px)`.

The Factory view opens on what waits. The lifecycle band and "Today" are open at every load, each with a minimize button beside its maximize button, inside the panel. The pool, the runs and the spend of the day are in the header, once; nothing above the panels repeats them. "Yours" stands alone in the left column and takes its height (up to five waiting cards show whole; more than that scroll inside its list, the oldest wait first; with nothing waiting the panel is its heading alone), and "In progress" fills the right. Minimized, a panel is its heading and the button that opens it again, where it sits (the band above the columns, "Today" under "Yours", at most 60% of the column when open, both charts whole). What the owner minimized is kept across the 5-second refreshes and never stored.

The drawer is absolutely positioned over the board's right edge: `min(660px, 52vw)`, widening to `min(1180px, 72vw)` for the Review tab. Drawer content uses a 20px side gutter. Below 860px the header wraps, stats drop their borders, and the drawer takes the full width; below 600px the per-stage slots hide and the brand takes its own line. The drawer is a size container: under 540px the decision stacks and the tooltip stats go two by two.

## Elevation & Depth

Tonal first. A panel is a 2% wash and a 9% hairline; the drawer, the peek, a maximized panel and the select's list are the page's only raised surfaces, and they use the `--shadow` token or the drawer's own cast.

### Shadow Vocabulary
- **Raise** (`--shadow`: `0 10px 30px rgba(0,0,0,.45)` in dark themes; each light theme sets a softer one): the peek, a maximized panel, the select's list.
- **Drawer cast** (`-14px 0 32px -8px rgba(0,0,0,.45)`): the open drawer only; removed when closed.
- **Dial ring** (`0 0 0 2px panel, 0 0 0 3px edge`): the cooldown dial.
- **Hot dot** (`0 0 0 4px` ink at 25%): the dot that is hovered or open.

### Named Rules
**The Flat-At-Rest Rule.** Panels and tiles carry no shadow until something opens over them.

## Shapes

Radii come from one scale: 2px on bars, meters and the tick of a progress step; 4px on tags, gates, keys and code; 5px on buttons, the text area, the hours field and the scrollbar thumb; 6px on small cards (the maximize button, a chip in the lanes, the block note); 8px on selects, option cards, the theme swatch, the peek and the stepper; 12px on a tile, an alert and the save bar; 16px on a panel, a maximized one included; 40px on the Approve pill in the lists (`rounded.pill`); a full circle for dots, the dial and the switch knob. Marks whose shape carries state (the Feed's diamond and dash) are square, with no radius. Borders are 1px hairlines.

## Components

### Header
The brand at the left, then the views as three uppercase captions (the pressed one in `text`, the others `muted`), then the stats at the right, led by **Docs**: a caption link with the external glyph to Shipfloor's README (`#learn-more`, the table of the docs pages), in a new tab, written in the static markup so it is there offline and before the first read; nothing is fetched until it is clicked. With more than one project the figures are the machine's, and the titles of Runs today and Spent est. say so. The project switch is a caption, a value and a small chevron; where the browser allows (`appearance: base-select`) its list is drawn by the page with the raised panel and a sand mark on the checked option. Under 1180px the header wraps.

### Alerts
A line that exists only while something is wrong: a bad-tinted bordered strip with one item per cause, each with a dot in its outcome color. Offline and Not updating (bad), Factory paused (bad), a project the dispatcher skips (bad), Board N min old (warn). It is a polite live region.

### Lifecycle Band
See Layout. A dot is 10px in `text` (running ones pulse once every 2.6s), hollow with a `muted` ring when queued, `sand` when it waits for the owner, `warn` when infrastructure failed and `bad` when blocked; the number under it takes the same color. Clicking a dot opens the line peek.

Maximized, the band is two lanes of chips, and the owner moves their cards there (the moves are the server's table, M1 to M7). A chip shows how long it has waited and, in Ready for Prod, `2 of 5 in line`; in Inbox, Ready for Refinement and Ready for Dev it opens with its position (12px `faint`, tabular, 2ch, with `Position 2 of 5` for screen readers). A chip the owner can move has `cursor: grab`; a locked one (a run in progress, blocked by infrastructure) carries a 12px lock and its reason in words, `cursor: not-allowed`. Picking up a card (drag, `M` on the focused chip, or the ghost `Move` button on a touch screen, `hover: none`) gives it the 2px `sand` outline; each column that takes it gets a 1px dashed `sand` outline over a 7% `sand` wash and a ghost button with what dropping there means ("Drop to approve the spec", "Press 1 to …", "Tap to …"), solid under the pointer; the others dim to .45, a factory column adding `the factory moves`. In its own ordered column a held card goes before the chip it is dropped on: a 2px `sand` bar in the gap shows where; the arrows move it one place, Enter places it, Esc puts it back; on touch, `Up` / `Down` / `Place here` buttons appear under it. A move that needs a note opens the note box, the peek's surface under the target column. Every move and reorder waits 5s in the `.itoast` at the bottom of the panel with Undo (and Comment, for a move that went without a note); a refused one says why in the panel's note line. One status line under the heading (`role="status"`) says what is held and the keys. "Only what I can move", a sand switch in the heading row, dims every other chip; it is off at every load. Column and lane names stay in English in every language.

### Your
Panel titled "N wait(s) for you" or "Nothing waits for you". Each pass is a hairline-separated block: the card number (condensed, sand; bad when blocked), a caption with the column and the age, the title (clamped to two lines), and a footer of plain actions: **Approve** as a pill (`text` fill, `ground` text), Review, the request-changes field and the link to GitHub. The list fades its last 44px through a mask when it overflows. The footer reads N next, A approve, R review, L log. The footer and the number on each inbox option show only where the primary pointer is fine; on a touch screen they are hidden.

### In Progress
Tiles of 320px or more in an auto-fill grid. A running tile has the number (condensed, 23px), the cost in the accent, a clock at the right, the title (two lines), a step bar (done steps `muted`, the current one `text` and breathing), a step line ("Step 4 of 7: Engineer", warn when slower than usual), what the agent said last, and its last tool calls in mono, then a footer with Open session and Log. A waiting tile is dashed, with no fill, its number and title in `muted`, and says why in plain words ("Waiting for the pool · 4 of 4 busy"). Its ring and reason follow the Lifecycle band: hollow `muted` and `soft` when the card only queues, filled `warn` with the number and reason in `warn` when infrastructure failed, and the accent only on a tile that waits for the owner. The cost stays in the accent, as money.

### Cooldown Dial (signature)
A 13px circle filled by a conic sweep in `text` over the lit edge, ringed by the dial ring, turning once every 6s through a registered `--sweep` angle. It appears on a running card. Under `prefers-reduced-motion: reduce` it stops on a static quarter (90deg), and the pulse of the dot, the breathing of the step bar and the card transitions stop as well.

### Today
The day in small charts with a key, and a list of how long each stage usually takes. Chart labels are 12px `faint`.

### Tooltip Drawer
A panel with a lit left edge, `role="dialog"` (non-modal), labelled by its title. The head is a raised-to-panel gradient closed by a hairline in the accent at 60%: the number and title (headline), a bordered Close button at the top right (Esc closes too), a maximize button beside it, a meta line (column, "waits for you" in the accent or a dial and clock when running, the GitHub link), and four stats as `dt`/`dd` pairs: cost Inbox to now (the total, 20px, with "est."), sessions, first to last run, last report. A blocked card adds the block note: "**Blocked** · the factory stopped and waits for your call" (or "infrastructure failed; the factory retries once"), then the one line that says what the owner must decide and the failed gate, both taken from the factory's issue comment, Unblock and retry at the right, and the full report folded under "Full report", rendered from its markdown.

Under the head, for Spec Review and Staged cards only, sits **the decision**, whatever tab is open: "Your decision" with the review progress on the right ("1 of 3 reviewed · 1 change"), Approve with its destination, a hint, the request-changes text area and Request changes (disabled until there is text), plus "Use the review's N changes", which fills the text area from the review marks. When the board snapshot is stale, a warn line says how old it is and that the actions read the live board first; a skipped project adds a bad line. In a drawer narrower than 540px the text area folds until Request changes is clicked. While the review has unreviewed items or asks for changes, Approve turns **soft** (tinted, text in `text`) and asks twice: the first click says "Approve with 2 not reviewed" for 4s. Notices are a polite live region.

The list's passes ("Yours") follow the same decision. Approve in a Staged row, or `A`, waits 5s with Undo, and a decision still in that wait is sent when the page goes away (closing the tab or leaving it; switching tabs does not), so "approve, close" lands; the Inbox's held decision too. When the review has doubt (items not reviewed, changes asked) or its marks were never seen in this session, the row's Approve and `A` send nothing and start no timer: they open the card's drawer on Review. With known doubt the drawer's Approve arrives already armed ("Approve with 2 not reviewed", 4s, focus on it, `aria-describedby` on its hint); with unseen marks it is not armed and the hint reads "Nothing was approved: look at the review first." until the review reports its marks. A send that fails returns the row to waiting with "#12 was not approved: <reason>" in its note.

Then underlined tabs (Live, Sessions, Log, Gates, Review) with mono counts, a real tablist (roving tabindex, arrow keys, Home and End) over one tabpanel. Live is the session as it happens, with a field to say a word to the run that is working. Sessions are a right-aligned numeric table with sticky heads (start, stage and model, input, output, cache read plus written with the split on hover, time, result, cost), dashed sub-rows for subagents and a total row. Gates map outcomes explicitly: ok, done, pass and merged are ok; fail, error and blocked are bad; anything else is muted; a stage with no gates and no notes says "No gates for this stage". The Log tab counts the card's log files; the log scrolls under its own bar and opens at its end. The Review tab hosts the review page in a sandboxed iframe. The marks the owner makes there are kept by the dashboard server, per card and review page, so they survive tab switches and reloads, and a rebuilt page starts clean; the iframe stays sandboxed and hands its marks to the drawer, which saves them quietly.

### How a Card Opens
Where a card opens depends on where it was clicked, so the click never hides what the owner was looking at. A card in In progress, and its Log link, opens **maximized**: the drawer at 90% of the screen over a dimmed, blurred board, a running card on Live and a waiting one on Sessions; the side drawer would cover its own tile. A card that waits for the owner opens the wide side drawer on Review, with the decision. Esc or Close returns to the board, and focus goes back to what opened the card.

### Line Peek
A click on a dot of the lifecycle line opens the **peek**, never the drawer: the line is the map, and a drawer over its right half hides the stages the dot sits in. The peek is a small raised panel (panel-hi, lit hairline border, 8px radius, the drawer's shadow, 340px at most) anchored under its dot by a 10px arrow, clamped to 12px from the window edges. It holds the number and title (14.5px 600), one muted meta line (column, "Develop running 4 min" or the dot's state, "step 2 of 7 · Plan", the cost in the accent), the stage's step bar, and one row of actions: the primary button, then Log (ghost), then the GitHub link. The primary is "Open session" for a running card and "Open card" otherwise, both maximized; a card that waits for the owner says "Review" and opens the wide drawer, so the decision keeps its place. `role="dialog"`, labelled "Card summary"; its dot carries `aria-expanded` and the open ring. Focus moves to the primary button. Esc closes it and returns focus to the dot; so do a click outside, a click on the same dot and leaving the Factory view. Another dot moves it. It follows its dot on every refresh and closes when the dot leaves the line.

### Feed
One timeline, newest first, with a heading where the day changes. Above it, the filters (Runs, which is the view the Feed opens on and holds the run rows only, Waits for you, Failures, Running, Dispatcher), each with its count, and "Newest first". A run is **one row** placed at the time it ended (or started, while it runs): the time in mono, a mark whose shape carries the state (dot ok, diamond failed, ring running, dash for a dispatcher line or a run whose end was never logged), the project when there is more than one, the stage in bold, the card's number and title, and "waits for you" in the accent when the card sits in an owner column after that run. On the right, the duration (or "running 6m", or "· exit 4") and the run's estimated cost. A second line appears only when something is known of what the run left behind, each piece from its own source: why a run failed first, "gates failed: build" (the run's report) or, when no gate is on record, "ended with exit 4 · no failed gate recorded" (the exit code; no log line is shown, as it can read like a success), then "PR #64" (the report), "now in Staged" on the card's newest run (the board), "Step 4 of 7: Engineer" while it runs (its lock). Nothing is inferred from the stage. The whole row opens the card maximized on that run's log; the title is the row's button and keeps focus across refreshes. There is no button in a row. A dispatcher or stacks line repeated in a row is one row with "37× since 00:09".

### Settings
The dispatcher is the top line of the view: a dot (ok, warn when idle, bad when off), its status in words, the working hours field (mono) and the switch that stops it. Below it, a nav of sections at the left (Sessions, Projects, Themes, Costs) and the section at the right in groups: a group is a panel with a condensed title, rows of a label, a description and a control (a stepper, a switch, a select, a value). A switch shows its state as a word, On or Off, left of its track (`role="switch"` with `aria-checked`), so the state never rests on color or on the knob's place alone. A pool bar shows how the stages share the sessions, one hue per stage with a key under it (Refine `refine`, Develop `text`, Validate `validate`, Deploy `ok`; the share no stage uses is the hairline), and warns when they ask for more than the pool allows. While anything is unsaved, a sticky save bar with a sand border counts the changes and offers Discard and Save; a changed control turns its value sand. Under 1180px the nav becomes a row and rows stack. In a stacked row a stepper keeps its width at the row's left edge.

### Language
The page is written in English and shown in the machine's language (`language` in `~/.shipfloor/config.yml`). In another language, every piece of text is rewritten as it enters the document, from the catalog the server sends (`scripts/lang/dashboard.<code>.json`): a whole piece by `exact`, a phrase inside one by `rx`. So a new string needs no code, only an entry; one with no entry shows in English. What the factory did not write is never rewritten: card titles, logs, and what the agents said (the `RAW` selector). Board columns keep their GitHub names in the data and show translated.

### Themes
The owner picks how the dashboard looks in Settings, under Themes. Four come first (Auto, Floor tape, Kraft, High contrast); the rest sit under "More themes", a fold that opens closed every time Settings opens and, when the theme in use is behind it, says `In use: <name>`. A theme only changes color tokens: the base block in `scripts/dashboard.html` is Charcoal, and each `[data-theme="<id>"]` block sets the same tokens (ground, panels, edges, the four text steps, the accent `sand`, ok/warn/bad, the two glows, the lifecycle track, `refine`, `validate`). A light theme also sets `--ov`, `--well`, `--scrim`, `--shadow` and `color-scheme: light`. Almost no color is written out in a rule: tints come from `color-mix` over a token (`--ov`, the ink of the theme, is what makes a panel's wash and hairline), the one exception being the white of a plain review page.

Nine dark themes (Floor tape, Charcoal, Dock, Machine green, Blueprint, Foundry, Night shift, Terminal, High contrast) and three light ones (Kraft, Steel, Drafting paper). Auto, the default, follows the system: Floor tape in dark, Kraft in light. The choice lives in the browser (`localStorage`, `shipfloor.theme`) and is applied before the first paint. In every theme the accent is not one of the outcome colors, so where the accent is yellow the warning is orange.

A swatch is a button that carries its theme's `data-theme`, so it is drawn with the same tokens as the page it stands for. The embedded review page gets the theme's colors as a message. To add a theme: one block in the CSS and one entry in `THEMES`; `scripts/test/theme.test.sh` refuses a theme with a missing token or with text under 4.5:1 on its ground and panels.

### Buttons
- **Button:** raised panel, lit-edge border, 5px radius, 7px 12px; hover turns the border to `text`. **Ghost** drops the fill and sits in `muted` at 12.5px.
- **Approve:** `text` fill, `ground` text, 600 weight; hover brightens 8%. Soft (asks twice): tinted fill. In the lists it is a pill (40px radius, `rounded.pill`) whose hover mixes 12% of the ground into the fill.
- **Disabled:** not-allowed cursor, faint text; progress cursor while a move is in flight.
- **Target:** every focusable control has a box of at least 24x24px; a text-only control grows its box, not its ink.
- **Focus:** a 2px `sand` outline, 2px offset, on every focusable element.

### Embedded Review Pages
Agent-written review pages in the iframe are re-themed by `EMBED_CSS` in `scripts/dashboard.py`: their own header hidden, section headings at 17px 600, their own reviewed count hidden (the decision shows it), transparent buttons with hairline borders. The dashboard sends the page its theme as a message (`page` = ground, `sheet` = panel, `surface` = raised panel, `ink` = text, `muted`, `rule` = hairline), and the embed applies it and, when the owner changes theme, again. While the page loads, the iframe element paints nothing of it and holds the drawer's panel color (`var(--panel)`); it is shown, with one 150ms ease-out opacity fade (instant under reduced motion), once the page has acknowledged the theme (`themed`), and white is its background only under a plain page, one that does not take the embed theme and never announces itself (`ready`), shown when its load ends. The same embed adds a small script that announces `ready`, acknowledges each theme with `themed`, and posts the page's marks (`review-progress`: done, total, the changes as text) to the dashboard, which accepts them only from that iframe.

### Keyboard and Live Updates
Esc closes the peek, the maximized panel or the drawer, in that order (not while typing); in the maximized lifecycle it first closes the note box, then lets go of a held card. On the Your list, N moves to the next waiting card, and A, R and L approve, open the review or open the log of the focused card; in the maximized inbox the keys 1 to 9 pick an option. Arrows, Home and End move between the drawer's tabs. Opening a card moves focus to its title, closing returns it to the card. The overview is read every 2s, the Feed every 5s, the open card every 5s and Settings every 10s, but a region is rewritten only when its markup changed, so focus, scroll, the open select and typed text survive; clocks tick on their own. The first read shows "Reading the factory…", and a failed read raises a "Not updating" alert with the error.

## Known deviations

Values that fewer than three rules use and that have no named role. They stay as they are on the page until a rule widens the ramp or the scale.

- `15.5px` — `.isec .plain`

## Do's and Don'ts

### Do:
- **Do** take every color from a token, and give every new token a value in every theme.
- **Do** keep captions uppercase and tracked, headings condensed and uppercase, and prose in sentence case.
- **Do** keep numbers in tabular figures and label every cost as an estimate.
- **Do** keep surfaces flat at rest and let only what opens (drawer, peek, maximized panel) cast a shadow.
- **Do** keep the dial and the dot's pulse as the only continuous motion, and give any new motion a reduced-motion fallback.
- **Do** keep factory stage and column names verbatim.

### Don't:
- **Don't** color-code columns or cards; position and name identify a stage, and the dot's state is carried by its fill too.
- **Don't** use the accent as decoration, or the outcome colors for anything but results.
- **Don't** add emoji or icon fonts; text labels carry actions (the few inline SVG marks are the maximize and external-link glyphs, and the lock beside the reason a card in the maximized lifecycle cannot move).
- **Don't** link a font or an asset from the network, or add a build step; the dashboard is one self-contained file.
- **Don't** add resting shadows or a third continuous animation.
