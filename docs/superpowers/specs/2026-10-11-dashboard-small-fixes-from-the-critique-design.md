# Dashboard: small fixes from the critique (pause without undo, drawer focus, shortcut legend, Feed) — spec

**Issue:** #55 · **Branch:** `feat/55-dashboard-small-fixes-from-the-critique` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** Six minor findings from the 2026-10-11 dashboard critique, all still present on this branch: a pause whose only named way back is a CLI command, a maximized drawer that keyboard focus can leave, a stale-link message a screen reader never hears, inbox keys 1-9 missing from an 11px legend, a Feed whose times carry no day, and the accent on lane headings that are not the owner's.
**Audience:** The factory's owner (and other developers who install the plugin) doing quick checks in the dashboard, including by keyboard and screen reader.
**Acceptance criteria**
- **AC-1** — Given the factory or one project is paused, when the "paused" alert shows on any view, then it carries a Resume button that lifts that pause in one click and the alert goes away.
- **AC-2** — Given a card open maximized over the dimmed board, when the owner presses Tab or Shift+Tab repeatedly, then focus cycles inside the drawer and never lands on the board behind, and the drawer reports `aria-modal="true"`.
- **AC-3** — Given a card open in the side drawer (board not dimmed), when the owner tabs past its last control, then focus reaches the board as today and the drawer reports `aria-modal="false"`.
- **AC-4** — Given the dashboard is opened with a link from an earlier run (the server answers 403), when the stale-link message appears, then it sits in an alert live region, so a screen reader announces it without the owner moving focus.
- **AC-5** — Given the decision inbox is open with options on screen, when the owner looks at the keyboard legend, then it is visible and names keys 1-9 as choosing an option, beside the keys that already act there.
- **AC-6** — Given any view that shows the keyboard legend, when it renders, then the legend text and its key caps are at least 12px.
- **AC-7** — Given a Feed with events from more than one calendar day, when it renders, then a row naming the day precedes the first event of each day, and opening a run row in place works as before.
- **AC-8** — Given the Lifecycle lanes, when they render in any theme, then lane headings use a neutral text token, not the accent; the accent stays on "waits for you" and the focus ring.
**Out of scope:**
- A confirmation before pausing: closed. A pause is urgent, starts nothing new, lets running sessions finish and is undone in one click (AC-1); a confirm step would slow the one action meant to be immediate.
- A Feed filter: closed. The Feed is capped at the last 400 lines and each run row already takes its outcome color; a filter is a feature, not a small fix, and gets its own issue if the owner asks for it.
- Giving the focus ring its own color: closed. DESIGN.md names the accent as the focus ring; with lane headings neutral (AC-8) the accent again means only the owner.
- The accent also standing for cost (`--gold` is `--sand`), focus inside maximized panels other than the drawer, and any change to the pause API or `shipfloor pause`/`resume`.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner): the accent and the keyboard point only at the owner's decisions, and the one urgent control has a visible way back. AC-7 serves principle 3 (a time without its day is not exact). No conflict with the positioning; nothing here keeps card state in the dashboard (principle 1).
**Touches UI:** yes

## UX
_UX/UI Designer_

All in `scripts/dashboard.html`; tokens are the ones in its CSS (`--text`, `--soft`, `--muted`, `--edge`, `--edge-hi`, `--sand`). No new component. Languages: English and pt-BR (`scripts/lang/dashboard.pt-BR.json`).

- **AC-1, place and copy** — In `#alerts`, each "paused" alert ends with a Resume button: existing `.btn.ghost`, label in `--text` (one rule, as `.notice .btn` does). The CLI hint leaves the text. Factory: **Factory paused** "No new run starts. Running sessions finish." + `Resume` (`aria-label="Resume the factory"`). Project: **<slug> paused** "No new run starts there. Running sessions finish." + `Resume` (`aria-label="Resume <slug>"`). Both paused: two alerts, each button lifts only its own pause.
- **AC-1, states** — Click: the button is disabled (`.btn:disabled`) until the answer comes, and stays so across the 5s refresh. Success: the overview is read again, the alert goes, the Settings switch (if on screen) shows off, and focus moves to the pressed view button in the header (`[data-view][aria-pressed="true"]`). Error: the alert stays, its sentence becomes "Still paused: the resume did not go through." and the button is enabled again; `#alerts` is already `role="status"`, so both outcomes are announced. Small screen: `.alerts` wraps; the button stays on its alert's line.
- **AC-2** — While the drawer is maximized (`.drawer.full`, `#dim` showing) it reports `aria-modal="true"`; Tab on its last control (Close) goes to its first, Shift+Tab on the first (or on the title, where focus lands on open) goes to Close. Esc and focus return are unchanged. No visual change.
- **AC-3** — The attribute follows the maximize button live: restore to the side drawer and it is `aria-modal="false"` again, with Tab leaving to the board as today. Under 1180px the side drawer is full width but not dimmed: it stays non-modal.
- **AC-4** — For the stale-link message only, `#msg` gets `role="alert"`, set before the text is written; "Reading the factory…" stays a plain paragraph. Copy and look unchanged, focus is not moved. English only: a stale link cannot read the language catalog.
- **AC-5** — Same `<p class="foot cap">`, same place (the bottom of "what waits for you"), now also shown when the inbox is open, with the keys that act there: `<kbd>1–9</kbd>choose` `<kbd>Esc</kbd>close`. The list keeps `N next · A approve · R review · L log`; those four are hidden in the inbox, where they do nothing. Under 1180px the legend stays under the scrolling inbox, wrapping as today.
- **AC-6** — `.foot` text is 12px (the `.cap` default of 11px stays elsewhere); its `kbd` inherits it. `.iopt kbd` goes from 11px to 12px. Colors unchanged (`--muted` text, `--text` on the key, `--faint` border).
- **AC-7** — A day row precedes the first event of each calendar day, always (also when the Feed has one day): an `<h2>` inside `#feed`, full width, the Feed's mono at 12px, `--muted`, 600, a `--edge` hairline under it, 10px above (none on the first). Text: `Today`, `Yesterday`, else the browser's date as `when()` writes dates, with the weekday (`Fri, 09/10`). Under a day row the time column shows the time only. An event with no time stays under the day above it. Not a button, not focusable; a screen reader reaches it as a heading. Run rows, the open row, focus and follow-the-end are untouched. Small screen: the row is its own line, no grid change.
- **AC-8** — `.lane` color goes from `--sand` to `--soft`; its `small` stays `--muted` and the rule `--edge-hi`. All themes get it from the token; nothing else changes.
- **Copy, pt-BR (new catalog entries)** — "No new run starts. Running sessions finish." → "Nenhuma execução nova começa. As sessões que já rodam terminam."; "No new run starts there. Running sessions finish." → "Nenhuma execução nova começa nele. As sessões que já rodam terminam."; "Resume" → "Retomar"; "Resume the factory" → "Retomar a fábrica"; rx `^Resume (\S+)$` → "Retomar $1"; "Still paused: the resume did not go through." → "Continua pausado: a retomada não foi aplicada."; "choose" → "escolher"; "close" → "fechar"; "Yesterday" → "Ontem" ("Today" exists). The day row must not sit under the `RAW` selector (`.ev > span`), or it carries `data-t`.

## Architecture
_Tech Lead_

**Layer:** `factory` only. No server change: `scripts/dashboard.py` and its API stay as they are.

**Files**
- `scripts/dashboard.html` (change) — all eight criteria.
- `scripts/lang/dashboard.pt-BR.json` (change) — the new strings listed under UX.
- `scripts/test/dashboard-page.test.sh` (new) — reads the page and the catalog as text, as `scripts/test/theme.test.sh` does.

**Contracts touched:** none new. AC-1 reuses `POST /api/settings/pause` with `{project: <slug> | null, paused: false}`, the call the Settings switch already makes; the answer is the settings body, as today.

**Changes in the page, by criterion**
- **AC-1** — `renderFlags()` (the `add(...)` calls for `o.paused` and `p.paused`): each paused alert gets `<button class="btn ghost" data-resume="<slug or empty>">`. The document click handler routes `[data-resume]` to a new `resume(target)`, which posts the pause off, reads the overview again (`loadOverview()`), refreshes `SET.data` when Settings is loaded, and keeps `S.resuming` (the target in flight) and `S.resumeErr` so the 5s re-render keeps the disabled state and the error sentence.
- **AC-2, AC-3** — `renderDrawer()` sets `aria-modal` to `String(!!(S.open && S.full))` beside `d.inert`. The existing document `keydown` listener gains a Tab branch that runs only when `S.open && S.full`: first and last focusable inside `#drawer` wrap to each other; focus outside the drawer is pulled to the first. The static `aria-modal="false"` in the markup stays as the closed state.
- **AC-4** — in the 403 branch of the overview read, `#msg` gets `role="alert"` before `setHTML`; every other writer of `#msg` removes the attribute.
- **AC-5, AC-6** — the `.foot` paragraph holds two groups, list keys (`N A R L`) and inbox keys (`1–9`, `Esc`); CSS shows one group by `.yours.maxed`, and `.yours.maxed .foot` leaves the `display: none` rule. `.foot` and `.iopt kbd` are 12px.
- **AC-7** — `renderFeed()` tracks the local calendar day of the last timed event and emits `<h2 class="ev-day">` when it changes; a new `day(iso)` helper returns `Today`, `Yesterday` or weekday and date; rows under a day row print the time only. `evId`, `S.feedOpen`, focus restore and follow-the-end are untouched.
- **AC-8** — `.lane { color: var(--soft) }`.

**Migration:** none. No stored data, config or API changes.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-page.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-page.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-page.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-page.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-page.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-page.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-page.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-page.test.sh` |

The test asserts on the page source and the catalog (markup, CSS rules, the handlers named above, every new string having a pt-BR entry). Lifting a pause through the API is already covered by `scripts/test/dashboard.test.sh`.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- No confirmation before a pause; the paused alert gets a Resume button instead — a pause is urgent and starts nothing destructive, and one visible click undoes it.
- No Feed filter — the Feed is capped at 400 lines and rows carry their outcome color; a filter is a feature and gets its own issue.
- The focus ring keeps the accent — DESIGN.md names it so; with lane headings on `--soft` the accent means only the owner again.
- The drawer is modal only when maximized — the side drawer sits beside a live board by design (DESIGN.md), and only the maximized one dims what is behind.
- The stale-link message is the only `#msg` text with `role="alert"` — "Reading the factory…" on every load should not be announced assertively.
- The day row shows for a one-day Feed too — the same Feed reads the same way on any day, and a line that says `Today` costs one row.
- In the inbox the legend shows only `1–9` and `Esc` — `N A R L` act on the list rows, which the inbox does not render.
- No server change — the Resume button reuses the pause endpoint the Settings switch calls.
- All criteria are tested by reading the page source, in one new test file — the layer runs Bash and Python with no browser, as `theme.test.sh` already does; the focus cycle (AC-2, AC-3) and the announcement (AC-4) are also seen on the running page by UX in validation.
- The existing "<slug> paused" title keeps no pt-BR entry — the string does not change here; out of this card's scope.
- A WIP limit of 0 for refinement was read as "no limit" — that is how `dispatch.sh` applies it, so the card was refined with 8 cards in Spec Review.

## Open questions
- none
