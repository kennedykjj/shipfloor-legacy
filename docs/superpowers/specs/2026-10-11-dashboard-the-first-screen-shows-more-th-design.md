# Dashboard: the first screen shows more than a quick check needs — spec

**Issue:** #53 · **Branch:** `feat/53-dashboard-the-first-screen-shows-more-th` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The Factory view opens with the lifecycle band, "Yours", "Today" and "In progress" all at once, so the one thing that asks for action competes with telemetry; the spend-by-hour chart in "Today" is cut off at 900px of height; Settings puts 12 themes at one decision point.
**Audience:** The factory's owner, on a quick check: open, approve what waits, glance at cost and runs, close.
**Acceptance criteria**
- **AC-1** — Given a 1440x900 window and up to 5 cards waiting for the owner, when the Factory view opens, then every waiting card is fully visible in "Yours" without scrolling the page or the panel.
- **AC-2** — Given the Factory view has just opened, when the owner has opened nothing, then "Today" and the lifecycle band are closed and one summary line shows pool in use, spent today (labelled "est.") and runs today with the failed count.
- **AC-3** — Given "Today" or the lifecycle band is closed, when the owner activates its control by mouse or keyboard, then it opens in place, a second activation closes it, and it stays as the owner left it across the page's 5-second refreshes.
- **AC-4** — Given "Today" is open, in the page or maximized, at 1440x900 and at 1280x720, when it shows the spend-by-hour chart, then the whole chart (bars, axis and labels) is inside its panel, none of it cut off.
- **AC-5** — Given Settings, Themes, when "more" is closed, then at most 4 options show (Auto, the dark and the light theme Auto uses, High contrast) and "more" reveals the other themes, all still selectable.
- **AC-6** — Given the chosen theme is one of those behind "more", when Settings opens, then the owner can tell which theme is in use without opening "more".
- **AC-7** — Given no card waits for the owner, when the Factory view opens, then "Yours" says so in one line and the summary line still shows.
- **AC-8** — Given more than 5 cards wait, when the Factory view opens, then "Yours" shows the total and every card stays reachable inside the panel, the oldest wait first.
**Out of scope:** The "In progress" panel, which stays on the first screen as it is; the decision inbox, the Feed, the drawer and the header strip's figures; adding, removing or recoloring themes; remembering what was open across a reload or a new visit (the view always opens closed); layouts below 1280x720.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner): the first screen leads with what waits, telemetry is one click away. Principle 3 holds: the summary line's cost stays labelled as an estimate. The issue's open question is settled here: the lifecycle band opens on demand, since it is a map of the factory's work and not a decision. No conflict with the positioning or with what is out of scope.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **First screen, in order:** a new one-row summary line (`div.sumline`, first row of `#board`, 36px, no panel border), then `.cols` with "Yours" alone in `.side` and "In progress" untouched. `nav#band` and `section.telem` are `hidden` until opened; each opens where it sits today (band between the line and `.cols`, "Today" under "Yours"). No new component: the line is `.cap`-style text plus the Settings fold button.
- **Controls (AC-3):** two `<button>`s at the left of the line, visible text "Lifecycle" and "Today" (existing strings) followed by the existing fold chevron (`.ptitle2 .max` svg, turned by `aria-expanded`); each carries `aria-expanded` and `aria-controls` (`band`, the "Today" section's id). Enter, Space or a click toggles; focus stays on the button; nothing else moves focus. The state lives in memory only (never `localStorage`): closed at every load, kept across the 5-second refreshes and across a switch of view. The buttons are rendered once and never rewritten by a refresh. Focus ring: the existing 2px `--sand` outline.
- **Maximize:** a panel's `data-max` button exists only while the panel is open; Esc or Restore returns to the open in-page panel. Closing the band closes an open peek.
- **Summary line (AC-2):** right of the two buttons, one sentence in 13px `--muted` with figures in `<b>` `--text` tabular: `Pool 2 / 4 in use · $3.41 est. spent today · 12 runs today · 1 failed`. The failed part is `--bad` and is left out at zero; the cost keeps the strip's `title`. It is the closed face of "Today": it shows while "Today" is closed and hides while it is open (the chart headings carry the same figures), so it never repeats beside the charts. The header strip stays as it is: gauges for every view; this line is the Factory view's reading of the day. It is its own render region, apart from the buttons.
- **"Yours" height (AC-1):** with "Today" closed, `.yours` drops `max-height: 62%` and may fill `.side`. At 1440x900 with 5 cards: `#list.scrollHeight <= #list.clientHeight` and the document does not scroll. If 5 do not fit, tighten `.pass` padding; a scrollbar is not the answer.
- **Nothing waits (AC-7):** in the page, the panel is its heading only, "Nothing waits for you" (existing string); the `li.empty` paragraph and the `.foot` key hints are not rendered. The maximized inbox keeps its existing paragraph. The summary line shows as usual.
- **More than 5 (AC-8):** the heading keeps the total ("7 wait for you", existing); `#list` is the only thing that scrolls, with the existing `.cut` fade; the order is the oldest wait first; the page never scrolls.
- **"Today" open, in the page (AC-4):** content order is runs chart, spend chart, then "A stage usually takes". `.telem` is at least as tall as its heading plus both charts whole and at most 60% of `.side`; "Yours" takes the rest and scrolls its list. Measured at scroll 0, at 1440x900 and 1280x720, with the band open or closed: the bounding box of every `svg.chart` (bars, base line, hour labels) is inside the panel's padding box. Only what comes after the spend chart may need the panel's own scroll.
- **"Today" maximized (AC-4):** chart height is `min(170px, 20vh)` (170px at 900, 144px at 720); same measure as above, both charts whole at scroll 0; the "Runs that ended today" table scrolls inside the panel.
- **Themes (AC-5):** one `.sgroup` without a heading holds exactly four `button.thm`, in this order: Auto, Floor tape, Kraft, High contrast. Under it a fold row (the existing `h2.ptitle2` with its `data-fold` button, `aria-expanded`, `aria-controls`) labelled "More themes"; open, it shows the existing "Dark" (7) and "Light" (2) groups without those three. It is closed every time Settings opens and is not saved in `shipfloor.shut`. Picking a theme inside it keeps it open and keeps focus on that swatch.
- **Theme in use behind the fold (AC-6):** the fold row's right-hand `span` reads "In use: <b>Blueprint</b>" (name in `--text`), shown only when the chosen theme is not one of the four; none of the four is `aria-pressed="true"` then, and the swatch inside the fold is.
- **States, small screens, copy:** before the first read the summary line is hidden with `#cols` ("Reading the factory…" stands alone); on a failed read it keeps its last figures under the existing "Not updating" flag. At 1180px and below the line wraps (buttons, then the sentence) and the rules above about height do not apply. New strings and their pt-BR entries (`rx` unless marked): `\bin use\b` → `em uso`; `est\. spent today` → `est. gastos hoje`; `(\d+) runs? today` → `$1 execuções hoje`; `^In use: ` → `Em uso: `; exact `More themes` → `Mais temas`.

## Architecture
_Tech Lead_

**Contracts touched:** none. No endpoint, payload or config key changes: `/api/overview` already carries `pool.used`, `pool.size` and, per project, `hours[]` (`ok`, `failed`, `cost`). `scripts/dashboard.py` is not touched. `localStorage` keys are unchanged (`shipfloor.theme`, `shipfloor.shut`); the open/closed state is never stored.

**Layer:** `factory` only. Files changed:
- `scripts/dashboard.html`: markup, CSS and script, as below.
- `scripts/lang/dashboard.pt-BR.json`: the five new entries listed in UX.
- `DESIGN.md`: the Themes paragraph (four first, the rest under "More themes") and the Factory view's first screen.
- `scripts/test/theme.test.sh`: changed; `scripts/test/dashboard-first-screen.test.sh`: new.

**Markup (`scripts/dashboard.html`):**
- `#board` gains a first row `div.sumline#sumline` (hidden with `#cols` until the first read): two static buttons `button[data-show="band"][aria-controls="band"][aria-expanded="false"]` and `button[data-show="today"][aria-controls="today"][aria-expanded="false"]`, then `span#sum` for the sentence. `.board` grid rows become `auto auto minmax(0, 1fr)`.
- `section.telem` gets `id="today"`; it and `nav#band` are `hidden` in the static markup.

**Script:**
- New state `S.show = { band: false, today: false }`, in memory only. `show(which, on)` sets the panel's `hidden`, the button's `aria-expanded`, restores the panel first if it is maximized, closes an open peek when the band closes, and re-renders `#sum`.
- `renderBoard`: `$("band").hidden` and `$("today").hidden` come from `S.show` (and from "no project"), no longer from the data alone; `#sumline` follows `#cols`. A refresh never rewrites the two buttons.
- New `renderSum(p)`: writes `#sum` through `setHTML`; pool from `S.overview.pool`, spent and runs from the same sums of `p.hours` that `renderTelem` uses; `#sum` is hidden while `S.show.today`.
- `renderTelem(p)`: returns early while "Today" is closed; maximized chart height is `min(170px, 20vh)` computed from `innerHeight`.
- `waiting()`: sorted the oldest wait first (`since`, cards without it last), the comparison `inboxCards` already uses; `inboxCards` keeps only its `gone` filter.
- `renderYours`: with nothing waiting in the page, `#list` is empty and `.foot` hidden; the maximized inbox keeps its own empty text.
- Click handler: one new branch for `[data-show]`. The maximize buttons are unchanged (a closed panel is `hidden`, so its button is too).
- Themes: `THEMES` gains `first: [["auto", …], ["tape", …], ["kraft", …], ["contrast", …]]`; `dark` and `light` keep the other eight. Every theme id stays once in the first 900 characters after `const THEMES` (`theme.test.sh` reads them there). `SET.moreThemes` (false whenever Settings opens) drives the "More themes" fold through a new `data-fold="themes"` branch that does not write `shipfloor.shut`. The fold row shows "In use: <name>" when `THEME` is none of the four.

**CSS:** `.yours` loses `max-height: 62%` (it fills `.side` while "Today" is closed); `.telem` becomes `flex: 0 0 auto; max-height: 60%; min-height:` its heading plus both charts; new `.sumline` rules (36px row, wraps at 1180px and below).

**Migration:** none; no data, no stored state, nothing destructive.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | manual | UX/UI measures it in validation with verify-ui at 1440x900, 5 cards |
| AC-2 | factory | `scripts/test/dashboard-first-screen.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-first-screen.test.sh` |
| AC-4 | manual | UX/UI measures it in validation with verify-ui at 1440x900 and 1280x720, in the page and maximized |
| AC-5 | factory | `scripts/test/theme.test.sh` |
| AC-6 | factory | `scripts/test/theme.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-first-screen.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-first-screen.test.sh` |

The factory tests read `scripts/dashboard.html` as text with Python, as `theme.test.sh` does: the static markup (band and "Today" `hidden`, the two buttons with `aria-expanded="false"` and `aria-controls`, `#sum`), the source of `renderBoard`, `renderSum`, `renderYours` and `waiting`, the `THEMES` constant (four in `first`, twelve in all, each once) and the pt-BR catalog entries.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The lifecycle band opens on demand: the issue proposes it and it is a map of the work, not a decision (principle 4).
- "In progress" stays on the first screen untouched: the issue does not move it and it is the "glance at runs" of a quick check.
- The four themes shown first are Auto, Floor tape, Kraft and High contrast: the issue's three plus Auto, which is the default and resolves to those two.
- What was open is not remembered across a reload: a quick check should always open on what waits.
- The summary line is its own row in the Factory view, not the header strip: AC-2 needs spent today, the strip is shared by every view, and the line hides while "Today" is open so nothing shows twice.
- The line's spent and runs are the project's on screen (the sums "Today" shows); pool is the machine's, as there is one pool: opening "Today" must not change the figures.
- The page's list is sorted the oldest wait first by moving the inbox's sort into `waiting()`: AC-8 asks for it and the two lists then agree.
- AC-1 and AC-4 are pixel measures and the project's tests run no browser: they are checked by UX/UI in validation with verify-ui, not by a text match on the CSS that would prove nothing.
- No server change: every figure the line shows is already in `/api/overview`.
- Layouts at 1180px wide and below keep today's stacked columns; the height rules apply from 1280x720 up.

## Open questions
- none
