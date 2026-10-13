# Dashboard: the Today panel becomes the factory's history, with a period to choose — spec

**Issue:** #130 · **Branch:** `feat/130-dashboard-the-today-panel-becomes-the-fa` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The "Today" panel empties at midnight. The owner cannot see what shipped, what it cost, how often runs failed or whether the factory got faster over a day past, a week or a month, although the run logs, transcripts and reports already hold it.
**Audience:** The factory's owner, in a quick check of the dashboard (and any developer who installs the plugin and runs their own factory).

**Terms:** a day is a calendar day in the machine's time zone; "7 days" and "30 days" end today and include it; a custom range includes both dates; the "previous period" is the one of the same length that ends the day before the shown one starts; a run belongs to the period it ended in.

**Acceptance criteria**
- **AC-1** — Given runs that ended on three different days of the last seven, when the owner picks "7 days" in the panel's heading, then both charts (runs clean and failed, est. spend) show one slot per day, seven in all, three with bars of the right counts and spend and four empty in place; "30 days" does the same by day, and "Today" shows by hour what the panel shows now.
- **AC-2** — Given any period, when the owner uses the two arrows, then the panel steps to the previous or next period of the same length (Today to yesterday and back), the next arrow is unavailable at the present, and a custom range of two dates shows exactly those days and refuses a future date or an end before its start.
- **AC-3** — Given a period of several days, when the owner clicks a day in a chart, then that day opens by hour; and given any period that is not the current one, a "Back to now" link is shown and returns to the current period (to today from a single day), and is absent at the present.
- **AC-4** — Given a period with runs, when the panel shows it, then four totals sit above the charts (cards that reached Done, runs clean and failed, est. spend, median time of a card from Inbox to Done), each with its change from the previous period in words ("3 more than the 7 days before", "the same as…", "nothing in the 7 days before"), never as a bare arrow or a color alone; a median with no card done shows a dash, not zero; and "A stage usually takes" is computed over the same period.
- **AC-5** — Given the panel maximized on a period, when the owner reads it, then the totals are a strip of four columns (label, figure, comparison), the table of runs that ended covers the whole period newest first and loads further pages on demand, the run and spend totals equal the sum of that table's rows once all pages are loaded, and a second table lists the cards with a run in the period by est. cost from Inbox to now, costliest first, a row opening the card.
- **AC-6** — Given a period in which no run ended, when the panel shows it, then it shows a message saying so with a link to the previous period, and no empty chart or table; a period with runs but a missing price shows `$ ?`, and every cost in the panel carries "est.".
- **AC-7** — Given the owner chose a period, when the page reloads or refreshes itself, then the same period is shown (Today, 7 days and 30 days stay relative to now; a stepped or custom period keeps its dates), while the summary line above the panels (pool, spend, runs) keeps today's figures whatever the period.
- **AC-8** — Given the dashboard in English or in pt-BR, when the panel is open, then its toggle reads "History" and its heading carries the period ("History · last 7 days", "History · today", a date or a date range), nothing in it is still called "Today" as the panel's name, and every new string, the comparisons and their plurals included, is shown in that language.

**Out of scope:** exporting; charts per project side by side; anything that needs data the factory does not record today (no new logging, no backfill; days before the oldest record simply show as empty); changes to the Feed, the summary line's content, the lifecycle band or the card drawer; a server-side or cross-browser memory of the chosen period; a comparison against any period other than the previous one of the same length.
**Product fit:** Serves principle 3 (numbers are exact and sourced; estimates say so): the totals must agree with the rows they summarize, come from the run logs and transcripts, and keep "est." on every cost. Keeps principle 1 (the panel reads history and holds no card state; the period is a view preference in the browser, like the theme) and principle 4 (nothing new to act on). It fits the "quick check" use as long as the panel stays closed at load and Today stays the first view; no contradiction with the positioning or with what PRODUCT.md rules out, since everything stays local.
**Touches UI:** yes

## UX
_UX/UI Designer_

No new component: the Feed's filter buttons (`.ftools`), `.max`, `.lnk`, `.nf`, `.empty`, `.chart`, `.key`, `.usual`, `table.ended`, the ghost button and the drawer's `dt`/`dd` stats. pt-BR copy follows each English string after `/`; dates come from `Intl.DateTimeFormat` in the page's language (`formatRange` for a range, the year only when it is not this one), not from the catalog.

- **Naming (AC-8).** Toggle `History` / `Histórico`. One `h1.g`: `History` in `text`, then the period in `muted`, wrapping under it when it does not fit: `· today` / `· hoje`, `· yesterday` / `· ontem`, `· last 7 days` / `· últimos 7 dias`, `· last 30 days` / `· últimos 30 dias`, else a date (`Thu 8 Oct`) or a range (`3 – 9 Oct`). The period span is `aria-live="polite"`. Maximize button: `Maximize the history` / `Maximizar o histórico`, `Restore the history` / `Restaurar o histórico`.
- **Period control, under the heading.** A `role="group"` labelled `Period` / `Período` of four `.ftools` buttons with `aria-pressed`: `Today` / `Hoje`, `7 days` / `7 dias`, `30 days` / `30 dias`, `Custom` / `Personalizado`; then two `.max`-sized buttons with the fold chevron turned left and right, `aria-label` `Previous period` / `Período anterior` and `Next period` / `Próximo período`; then `.lnk` `Back to now` / `Voltar para agora`. A preset is pressed only while its current period shows; in a stepped period or an opened day none is pressed; `Custom` is pressed for a range.
- **States of the control.** At the present, Next has `aria-disabled="true"` (faint, not-allowed cursor, still focusable, `title` `This is the current period` / `Este é o período atual`) and `Back to now` is absent. `Custom` opens a second row with two `input[type=date].nf`, `From` / `De` and `To` / `Até`, both with `max` = today, prefilled with the period shown; the panel changes when both hold a valid range. Invalid: `aria-invalid="true"` on the offending field, one `bad` line (12px, `role="status"`) under the row, and the panel keeps the last valid period: `The end date is before the start date.` / `A data final é anterior à inicial.`, `That date is in the future.` / `Essa data está no futuro.`, `Pick 92 days at most.` / `Escolha no máximo 92 dias.`
- **Totals (AC-4).** A `dl` of four, two by two in the column: caption label, figure at Heading size (20px condensed), comparison at Meta (12px, `muted`, never an outcome color or an arrow). Labels: `Cards done` / `Cards concluídos`, `Runs` / `Execuções` (figure `12 clean · 2 failed`, the failed part `bad` and left out at zero; the comparison counts all runs), `Spent est.` (figure in `sand`), `Inbox to Done, median` / `Inbox a Concluído, mediana`. Maximized: one strip of four columns divided by hairlines (label, figure, comparison); two by two under 860px.
- **Comparison wording.** `{P}` is `the day before` / `no dia anterior` for one day and `the N days before` / `nos N dias anteriores` otherwise. Counts: `3 more than {P}` / `3 a mais que {P}`, `2 fewer than {P}` / `2 a menos que {P}`, `the same as {P}` / `o mesmo que {P}`, `nothing in {P}` / `nada {P}` (`nothing the day before` for one day). Spend: `est. $1.20 more than {P}` / `est. $1,20 a mais que {P}`, `less` / `a menos`. Median: `12 min faster than {P}` / `12 min mais rápido que {P}`, `slower` / `mais lento`; with no card done the figure is `–` and the line reads `no card reached Done` / `nenhum card chegou a Concluído`. A missing price in either period: figure `$ ?` with its existing explanation, line `not comparable: a price is missing` / `sem comparação: falta um preço`.
- **Charts (AC-1, AC-3).** Same marks, key and hatch as today. Headings by slot: `Runs that ended, by day` / `Execuções encerradas, por dia`, `Spend by day` / `Gasto por dia`. Day labels: `Mon 6` for up to 7 slots, else the first, the last and every seventh as `6 Oct`. By hour, the chart stays `role="img"` with its totals in the label and a `title` per bar. By day, each slot is a real `button` over the chart (the whole slot, a 6% `--ov` wash on hover and focus), named with its values: `Mon 6 Oct: 3 clean, 1 failed. Open the day` / `seg., 6 de out.: 3 limpas, 1 falharam. Abrir o dia`, and `Mon 6 Oct: $1.20 est. Open the day` / `…: $1,20 est. Abrir o dia`; an empty day is `no run` / `nenhuma execução` and still opens.
- **Keyboard and focus.** Tab order: maximize, the four period buttons, Previous, Next, Back to now, From, To, runs chart, spend chart, table rows, `Show more runs`. Each by-day chart is one tab stop (roving tabindex; Left, Right, Home and End move between days, Enter or Space opens the day). Focus stays on the control just used; opening a day moves it to `Back to now`; `Back to now` moves it to the period button that becomes pressed. The control row is not rewritten by the refreshes. Esc keeps its order (maximized panel first).
- **Loading, empty, error (AC-6).** A period with no data read yet: `Reading the history…` / `Lendo o histórico…` in place of the content, the control usable; on a refresh the old content stays until the new one arrives. No run in the period: only the heading, the control and `.empty`: `No run ended in this period.` / `Nenhuma execução terminou neste período.` followed by `.lnk` `See the day before` / `Ver o dia anterior` or `See the N days before` / `Ver os N dias anteriores` (replaces "No run has ended today."); no totals, chart, "A stage usually takes" or table. A failed read uses the existing "Not updating" alert and keeps what was shown.
- **Maximized tables (AC-5).** `Runs that ended` / `Execuções encerradas` (the existing table; `ended` shows the date too when the period is longer than a day), then a muted count `50 of 213 runs` / `50 de 213 execuções` and a ghost button `Show more runs` / `Mostrar mais execuções`: while it reads, disabled with the progress cursor and `Loading…`; then focus goes to the first new row's card button; with everything loaded the button leaves and the count reads `213 runs`. A failed page keeps the rows and says, in `bad`, `The next runs could not be read.` / `Não foi possível ler as próximas execuções.` Loaded pages survive the refreshes. Second table `Cards of the period, by est. cost` / `Cards do período, por custo est.`: `card` (number as the `.lnk` button, title), `column` / `coluna`, `runs` / `execuções`, `Inbox to now est.` / `Inbox até agora est.` in `gold`; `$ ?` rows last; the row's button opens the card as the runs table does, on Sessions.
- **Summary sentence (AC-7): decided.** It hides only while History is open on the current `Today` (the totals carry the same figures); on any other period it shows, so today's pool, spend and runs stay in sight. Its copy does not change.
- **Sizes and narrow widths.** In the column the panel keeps `max-height: 60%` and scrolls inside; at 1440x900 the control, the four totals and the runs chart are whole at scroll 0 (the spend chart and the stages are reached by scrolling: this replaces "both charts whole"). At 1180px and below the control wraps (period buttons, then arrows and `Back to now`), the date fields share one row and stack under 600px, and each table scrolls sideways inside itself. A day slot narrower than 24px (30 days in the column, long custom ranges) stays reachable by the arrow keys and is 24px or wider when maximized up to 45 slots.
- **DESIGN.md, in the same change.** Typography: "such as Lifecycle or History". Layout: the fold buttons are "Lifecycle" and "History", the hide rule and the "both charts whole" clause as decided above. `### Today` becomes `### History` (period control, totals, comparisons in words, by-day buttons, the two tables). Keyboard: the arrow keys in a by-day chart. `docs/operation.md` names the panel too.

## Architecture
_Tech Lead_

One layer, `factory`. The server computes the period, its neighbours and every figure; the page only draws what it is given and words the comparisons (the tests have no JavaScript runtime, so what must be exact lives where a test can call it).

**New contract — `GET /api/history/<project>`** (token as every `/api/*`; read-only)
- Query: `days=N` (the N days that end today, 1 to 92; default 1), or `from=YYYY-MM-DD&to=YYYY-MM-DD` (both included). `page=N` (default 1) for the runs table. `400 {"error"}` for a malformed date, `to` before `from`, `to` after today, or more than 92 days; `404` for an unknown project.
- Response:
  - `from`, `to`, `days`, `unit` (`"hour"` when one day, else `"day"`), `present` (true when `to` is today).
  - `prev: {from, to}` (same length, ends the day before `from`), `next: {from, to}` or `null` when present (clamped so it never passes today), `now: {from, to}` or `null` when present (the same length, ending today).
  - `buckets`: one per slot, none skipped: `{h, ok, failed, cost, unpriced}` for hours 0 to 23 (today: 0 to the current hour), or `{day, ok, failed, cost, unpriced}` for each day of the range.
  - `totals` and `previous` (the same shape, for `prev`): `{done, ok, failed, cost, unpriced, median_s, median_of}`; `median_s` is `null` when no card with a known start reached Done.
  - `typical_s`: `{stage: median seconds of the clean runs that ended in the period}`.
  - `runs`: one page (50) of the runs that ended in the period, newest first: `{issue, title, stage, start, end, exit, log, cost}` (`cost` `null` when a session of the run has no price); `runs_total`, `page`, `pages`.
  - `cards`: every card with a run that ended in the period: `{issue, title, column, cost}` (`cost` is the card's estimate from Inbox to now, `null` when unpriced), costliest first, unpriced last.
  - `empty`: true when no run ended in the period (the lists are then empty).
- Rules: a run belongs to the slot its `== end` line falls in, in the machine's time zone (not to the day in its log's name). A session's cost goes to the run it belongs to (the rule `card()` and `overview()` already use) and is counted where that run ended, so `totals.cost` is the sum of `runs[].cost` over all pages and `totals.ok + totals.failed == runs_total`. A session of a run still in progress is not in the history yet. `done` counts the cards whose `deploy` run ended with exit 0 in the period (`deploy.sh` moves the card to Done as its last step). `median_s` is the median of (that deploy's end − the issue's `createdAt`).

**Changed**
- `scripts/dashboard.py`: `Factory.history(p, start, end, page)` and the route; the period arithmetic in a small pure function so it is tested without a server clock trick (`today` injectable). `Factory.titles` also asks GitHub for `createdAt` in the query it already makes and keeps it in memory (it never changes). `overview()` drops `projects[].hours` and `projects[].ended` (the page no longer reads them); `today`, `typical_s` and everything else stay, so the summary line, the lifecycle band and Settings are untouched.
- `scripts/dashboard.html`: `#today` → `#history`, `S.show.today` → `S.show.history`, `data-show="history"`; `renderTelem` draws from the `/api/history` answer (period switch, arrows from `prev`/`next`, "Back to now" from `now`, totals, charts by `unit`, a day bar asking for `from=to=<day>`, the maximized strip and the two tables, "more" asking for `page+1`). The chosen period is kept in `localStorage` as `shipfloor.history`: `{"days": N}` for Today, 7 days and 30 days (relative to now) or `{"from", "to"}` for a stepped, custom or opened day. The history is fetched when the panel opens, when the period changes, and on the page's refresh while the panel is open; never while it is closed. The panel still opens closed at every load.
- `scripts/lang/dashboard.pt-BR.json`: an entry for every new string; `rx` rules for the comparisons and their plurals.
- `DESIGN.md` (section "Today", the heading example, the summary sentence rule) and `docs/operation.md`: the panel's new name and behaviour, as the UX section states.
- Tests that name the old panel (`scripts/test/dashboard-first-screen.test.sh`, `scripts/test/dashboard-narrow.test.sh`, `scripts/test/dashboard.test.sh` where it reads `hours`/`ended`) are brought to the new names by QA with the acceptance tests.

**Migration:** none; nothing is stored on disk, no log or report format changes. Every file above belongs to the `factory` layer.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-history.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-history.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-history.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-history.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-history.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-history.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-history.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-history.test.sh` |

The file starts a dashboard on a temporary home with logs and transcripts on three days and asks `/api/history` (buckets, neighbours, totals against the sum of all pages, empty period, refused ranges); for what happens in the browser (AC-3, AC-7, AC-8) it reads the page as text, as the other dashboard tests do (the day bar asks for one day, `shipfloor.history` is read at load and written on change, the summary line still reads `o.today`, no "Today" left as the panel's name) and checks the pt-BR catalog carries each new string. The screen itself is checked by UX/UI in validation.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- A day is a calendar day in the machine's time zone, and a run belongs to the period it ended in: the logs carry local times and the charts already count runs where they ended.
- "7 days" and "30 days" end today and include it; the previous period is the same length and ends the day before: the only reading under which "the 7 days before" never overlaps.
- The next arrow is unavailable at the present and a custom range refuses a future date, an end before its start or more than 92 days ("Pick 92 days at most."): there is nothing to show there, and beyond a quarter the bars in the column are too thin to read or click; the server refuses the same ranges.
- "Back to now" returns to the current period of the length shown (to today from a single day): it undoes the stepping, not the choice of length.
- Today, 7 days and 30 days are stored as relative, a stepped or custom period with its dates, in `localStorage` only: a reload tomorrow should still say "today"; the server keeps no view preference (principle 1).
- A session's cost is counted with the run it belongs to, where that run ended: the issue requires the totals to equal the table's rows, and the rows are runs. So while a run is in progress the summary line's spend for today (by session start, as the cost limits count it) can be ahead of "History · today"; the summary sentence still hides there, since the gap closes when the run ends.
- The summary sentence hides only while History shows the current Today and shows on any other period: elsewhere the panel no longer carries today's figures.
- In the column the panel keeps its height and the spend chart may scroll (control, totals and runs chart whole at 1440x900); DESIGN.md's "both charts whole" is rewritten with it: four totals were asked for above the charts.
- A by-day chart's slots are buttons (one tab stop, arrow keys); by hour it stays an image with a title per bar: only days open something.
- The mockup is not on the factory's machine: the UX section follows the issue text and DESIGN.md.
- "Reached Done" is a `deploy` run that ended clean in the period: it is what the factory records, and `deploy.sh` moves the card to Done as its last step. A card moved to Done by hand is not counted.
- "From Inbox" is the issue's creation time on GitHub, read in the title query the dashboard already makes: the factory logs no entry into Inbox, and the first run's start would hide the wait before refinement. A card whose date cannot be read is left out of the median.
- The cards table lists the cards with a run that ended in the period, at their cost from Inbox to now, and is not part of the "totals equal the rows" check: its cost can include spend outside the period.
- A median with no card done shows a dash; a missing price shows `$ ?` (Estimate Rule); an empty previous period is said in words.
- The history is its own request (`/api/history`), per project like the panel today, fetched only while the panel is open: a month of logs has no place in the overview every poll makes.
- `overview()` loses `hours` and `ended`: one source for each figure; only the page read them.
- The period arithmetic and every figure are computed on the server: the tests cannot run JavaScript, so the exact part lives where a test can call it.
- "A stage usually takes" in the panel follows the period; the lifecycle band and Settings keep the all-time figure: they answer "is this run slow", not "how was that week".
- No backfill, no new logging: days before the oldest log show as empty.

## Open questions
- none
