# Dashboard: say why a card is blocked, link the docs, and stop repeating the header — spec

**Issue:** #119 · **Branch:** `feat/119-dashboard-say-why-a-card-is-blocked-link` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** In a quick check the owner cannot decide on a blocked card from the list: it says "Blocked · waits for your call" and offers "Unblock & retry" while the reason sits behind "Details". The page has no way to the docs, the header and the summary line repeat the pool, runs and spend, and "96h08" is hard to read past a day.
**Audience:** The factory's owner (and other developers who install the plugin), in quick checks of the dashboard.
**Acceptance criteria**
- **AC-1** — Given a blocked card whose factory comment states what the owner must decide, when the owner looks at the list, then the card shows that reason as one line (truncated, never wrapped to more) next to "Unblock & retry", without opening anything.
- **AC-2** — Given a blocked card with no reason in the factory's comment, when the list renders, then the card keeps its present blocked wording and shows no invented or empty reason line.
- **AC-3** — Given a card blocked by an infrastructure failure, when the list renders, then its one line says so (infrastructure failed; the factory retries once) rather than asking for a decision.
- **AC-4** — Given any view of the dashboard (Factory, Feed, Settings), when the owner looks at the page, then one link labelled as the documentation is visible in the same place and opens the docs in a new tab.
- **AC-5** — Given the dashboard with the machine offline, when the page loads, then it renders complete as before; the docs link is the only thing that may need the network, and only when clicked.
- **AC-6** — Given the Factory view with "Today" closed, when the owner reads what is above the panels, then pool in use, runs today and spend today each appear exactly once, and spend keeps its "est." label.
- **AC-7** — Given a duration above 48 h (96 h 08 min), when the dashboard shows it, then it reads in days and hours ("4d 0h"); a duration of 48 h or less reads as it does today.
- **AC-8** — Given the dashboard in pt-BR, when the new texts (reason line wording, docs link, day unit) appear, then they are shown translated, while the reason taken from the factory's comment is shown as written.
**Out of scope:** Changing what the factory writes in its block comment; an in-page help or glossary for columns and gates (the docs link covers it); new header figures; changing the drawer's block note or "Full report"; rewriting the docs themselves; durations of 48 h or less.
**Product fit:** Serves principle 4 (the owner acts only where the factory waits for the owner: the reason is where the action is offered) and principle 3 (numbers exact and sourced: each figure once, the estimate still labelled, the reason taken from the factory's comment and never inferred). Consistent with principle 1: nothing new is stored by the dashboard. The docs link must not break the "self-contained, local, no network asset" constraint: a link, never an embedded resource.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Reason line, place (AC-1).** In a blocked pass of "Yours" (`passHtml`), one `<p class="pwhy">` inside `.seg`, under the title and directly above the `.stub` row that holds "Unblock & retry"; outside the `.ptitle` button. The caption stays `Blocked · waits for your call`. No new component: the line reuses the one-line recipe of `.did li` (`white-space: nowrap; overflow: hidden; text-overflow: ellipsis`) at 13px in `--soft`, `margin: 4px 0 0`; `--bad` stays on the number and the caption only.
- **Reason line, text.** The same lead the drawer's `blockNote` shows (markdown marks stripped, first letter in capitals), as plain escaped text, never rewritten by the catalog (it joins the `RAW` selector, AC-8). Truncation is by CSS at the width of the pass, never by cutting the string; the whole text is in `title`. The line is not a button: "Details" already opens the card.
- **States of the line.** (a) Lead found: the lead. (b) No lead but the comment names a failed gate: `Failed gate: <gate>` (label already in the catalog, gate name as written). (c) Neither: no element at all, the pass is as today (AC-2). (d) Cost limit: caption `Blocked · cost limit` and the existing sentence `Spent $X est. since it was last unblocked; the limit for a card is $Y.` (or its `since Inbox` form), both already in the catalog; when the overview does not carry the amounts, state (c).
- **Infrastructure (AC-3).** An infra-blocked card does not enter "Yours" (the owner has nothing to decide, principle 4); its one line is the `.why` of its waiting tile in "In progress", which now reads `Infrastructure failed; the factory retries once` (pt-BR: `A infraestrutura falhou; a fábrica tenta mais uma vez`), replacing `Blocked by infrastructure; the factory retries it`. Same wording as the drawer's block note; no factory text is appended to it.
- **Loading and error.** The line has no state of its own: it comes in the overview read, so it appears with the pass and stays through a failed read ("Not updating" is unchanged). A reason that changes rewrites only that pass, as today.
- **Docs link (AC-4, AC-5).** One `<a class="cap">` written in the static `<header>` markup (not by `renderStrip`, so it is there before the first read, when a read fails and when the machine is offline), as the first child of `.stats`, before `#scope`: `Docs` + the `EXT` glyph, `target="_blank" rel="noopener"`, `href="https://github.com/kennedykjj/shipfloor#learn-more"` (the README's table of the four docs pages). pt-BR: `Documentação`. Same look and hover as "Board on GitHub"; nothing is fetched until it is clicked.
- **Figures once (AC-6).** The header keeps Pool, Stacks, Runs today and Spent est., since it shows on every view. The sentence in `#sum` is removed with `renderSum` and its CSS; the first row of the Factory view is the two fold buttons, "Lifecycle" and "Today", and nothing else. The per-project day stays in the headings of "Today" when it is open. No string replaces the sentence.
- **Header titles.** With more than one project the header figures are for the machine, so their `title` says it: Runs today gets `Runs of every project today` (pt-BR: `Execuções de todos os projetos hoje`); the Spent est. title gains a first line `Every project, today.` (pt-BR: `Todos os projetos, hoje.`). With one project, no change.
- **Durations (AC-7).** `dur(a, b)` above 48 h (strictly more than 172 800 s) prints `<days>d <hours>h`: whole days, then whole hours rounded down, minutes dropped, a space between, the zero hour kept (`4d 0h`, `2d 1h`, `12d 23h`). 48 h or less is as today (`42m`, `47h59`, `48h00`). Every caller takes it from `dur`, so `blocked 4d 0h ago`, the list's wait, the drawer's "first to last run", the sessions and the Feed all agree. `d` is the unit in pt-BR too (`4d 0h`): no catalog entry, but the `rx` entries that capture a duration with `(\S+)` must accept the space.
- **Small screens.** The reason line truncates at whatever width the pass has; it never wraps and adds one line of 13px to a blocked pass only. Under 1180px the header already wraps: `Docs` wraps with the stats group, staying first in it. Under 1180px the first row no longer wraps, since only the two buttons are left.
- **DESIGN.md.** Update "Layout" (the summary sentence is gone), "Header" (the Docs link), "Your" (the reason line and its three states) and "In Progress" (the infra wording) in the same change.

## Architecture
_Tech Lead_

One layer (`factory`), four files changed, no new endpoint, nothing stored, no migration.

**Contracts touched**
- `GET /api/overview` → each entry of `projects[].cards[]` gains two fields, both additive:
  - `block_line` (string): `""` for a card that is not blocked, for one blocked by infrastructure, for a cost block, and for a blocked card whose note holds no reason;
  - `block_cost` (`null`, or `{"total", "limit", "baseline"}` in dollars): set only for a block by the cost limit whose marker `cost/<n>.json` is readable — the same three figures `block()` returns for `kind: "cost"`.
- `GET /api/card/<project>/<n>` and `GET /api/decide/<project>/<n>`: unchanged (`block_reason`, `block` stay as they are; the drawer's block note is out of scope).

**`scripts/dashboard.py`**
- New `Factory.block_line(p, n)`: one plain-text line taken from `block_reason(p, n)` (same note, same one-minute cache, same trusted-commenter filter), first match of:
  1. the line that states the owner's call (`must decide | owner must | needs? you to`), without its label up to the colon, first letter in capitals — the rule `blockNote` applies in the page today;
  2. `Failed gate: <name>` when the note has `failed gates?:`;
  3. else `""` (also for a note that opens with `COST_BLOCK`: that state is told by `block_cost`).
  Markdown marks (`**`, `` ` ``, a leading `-`/`*`) are stripped and whitespace collapsed; the payload is bounded at 500 characters, the visible cut is the page's. The line is never composed from anything but the note.
- `overview()`: on each card, `block_line` as above when `blocked.get(n) == "owner"`, else `""`; `block_cost` from the cost marker (the read `block()` does, moved to one helper both use), else `None`.

**`scripts/dashboard.html`**
- `passHtml(c)`: the `<p class="pwhy">` of `## UX` for a card with `c.blocked === "owner"`: `c.block_cost` → caption `Blocked · cost limit` and the existing spend sentence built from its figures; else a non-empty `c.block_line` → that text through `esc`, whole text in `title`; else no element. `.pwhy` joins the `RAW` selector so the catalog never rewrites it.
- `whyWaits(p, c)`: the `blocked === "infra"` sentence becomes `Infrastructure failed; the factory retries once`.
- The docs link: static markup in `<header>`, first child of `.stats` before `#scope`, `href="https://github.com/kennedykjj/shipfloor#learn-more"`, `target="_blank" rel="noopener"`. No fetch, no preload, no asset.
- Figures once: `renderSum`, `#sum`, its CSS and its call in `renderBoard` are removed; `#sumline` keeps the two fold buttons. `renderStrip` gains the two `title` texts of `## UX` when `o.projects.length > 1`.
- `dur(a, b)`: when `s > 172800` returns `` `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h` ``; otherwise unchanged. No call site changes.

**`scripts/lang/dashboard.pt-BR.json`**
- Add `Docs`, the infrastructure sentence, the two header titles. Remove the three `rx` entries of the summary sentence (`\bin use\b`, `est\. spent today`, `(\d+) runs? today`) and the old infrastructure sentence. The two `rx` entries that capture a duration with `(\S+)` (`Running · last cycle (\S+) ago`, `board read (\S+) ago`) capture `(\d+d \d+h|\S+)` instead.

**`DESIGN.md`** — "Layout", "Header", "Your" and "In Progress" follow the change, as `## UX` lists.

**Existing tests that describe what this card removes** (QA updates them with the acceptance tests): `scripts/test/dashboard-first-screen.test.sh` asserts `renderSum`, `span#sum` and the three pt-BR `rx` entries of the sentence.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-block-line.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-block-line.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-block-line.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-glance.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-glance.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-glance.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-glance.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-glance.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The header keeps pool, runs and spend and the summary sentence goes: the header is on every view, the sentence only on Factory with "Today" closed.
- With several projects the header figures are the machine's and say so in their `title`; the per-project day stays in "Today". No per-project figure is added to the first row: it would be the repetition the issue removes.
- A card blocked by infrastructure stays out of "what waits for you": the owner has nothing to decide there (principle 4). AC-3's "list" is its tile in "In progress".
- The reason line is extracted on the server (`block_line` in `/api/overview`), not in the page: the list has only the overview, and one rule in Python is testable against the fake `gh`. The drawer's `blockNote` is left as it is (out of scope).
- The overview reads each blocked card's note through `block_reason`'s existing one-minute cache: one `gh` call per blocked card per minute at most, and blocked cards are few.
- No fallback to "the first prose line" of the note: a line that is not the owner's call or the failed gate would be a guess; such a card keeps today's wording (AC-2).
- A cost block shows the spend sentence the page already has, from the marker's figures, rather than the note's first line: exact numbers, already translated.
- `block_line` is bounded at 500 characters in the payload; what the owner sees is cut by CSS at the width of the row.
- The docs link is a constant to Shipfloor's own README (`#learn-more`, the table of the four docs pages), not to the project on screen: the docs are the tool's, the same for every project.
- Days and hours apply to every duration through `dur`, not only "first to last run": one function, one reading everywhere.
- `d` and `h` are the units in pt-BR too; the catalog gains no unit entry, and its two duration captures accept the space.
- Two new test files instead of growing `dashboard.test.sh`: one needs the server and the fake `gh` (AC-1 to AC-3), the other reads the page and the catalog (AC-4 to AC-8).
- Limit of 0 for specs in refinement means no limit (the dashboard's own wording), so the card was taken with one spec already in Spec Review.

## Open questions
- none
