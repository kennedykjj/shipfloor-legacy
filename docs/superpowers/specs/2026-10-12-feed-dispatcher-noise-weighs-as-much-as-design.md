# Feed: dispatcher noise weighs as much as outcomes, and a failed run shows "ok" — spec

**Issue:** #114 · **Branch:** `feat/114-feed-dispatcher-noise-weighs-as-much-as` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The Feed gives raw dispatcher and stacks log lines the same weight as a run that ended (10 of 22 lines on the demo stack), a failed run shows its last log line ("ok · now in Validation") under its title, and dates follow the browser's locale instead of the dashboard's language.
**Audience:** The factory's owner, in a quick check of the dashboard: what happened to my cards, and did anything fail.
**Acceptance criteria**
- **AC-1** — Given a feed with run lines and dispatcher/stacks log lines, when the owner opens the Feed with no filter chosen, then only run lines show.
- **AC-2** — Given the same feed, when the owner picks the "Dispatcher" filter, then the dispatcher and stacks lines show, with the same text as before.
- **AC-3** — Given a run that failed on a gate, when its line shows in the Feed, then its second line names that gate.
- **AC-4** — Given a run that failed with no gate recorded, when its line shows, then its second line gives the exit reason (at least the exit code), and in no failed run does it read "ok" or repeat a success log line.
- **AC-5** — Given a run that ended well, when its line shows, then its second line is what it is today.
- **AC-6** — Given the dashboard in English and a browser in another locale, when the Feed shows, then the day header's weekday and month are in English.
- **AC-7** — Given the dashboard in pt-BR and a browser in another locale, when the Feed shows, then the day header's weekday and month are in Portuguese.
- **AC-8** — Given either dashboard language, when a date or time is shown by `when()` or `hhmm()` anywhere on the page, then its format follows the dashboard's language, not the browser's locale.
**Out of scope:** Rewording or grouping dispatcher lines; new filters, counters or badges; changing what the dispatcher logs; the remaining direct `toLocale*` calls outside the day header, `when()` and `hhmm()` (tooltips, numbers); time zones; a third language.
**Product fit:** Serves principle 2 (a gate's outcome outranks any other claim: a failed run must never read "ok") and principle 3 (what the page shows is exact and sourced: the failed gate or exit code comes from the run's record, not from the last log line). Fits the quick-check use in Users. No conflict with the positioning or the constraints.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Filter row:** `Runs` · `Waits for you` · `Failures` · `Running` · `Dispatcher`, each with its count as today. `Runs` takes the place of `All`, is the pressed filter when the Feed opens and shows every run line (ended, running, no end logged) and no dispatcher or stacks line. Its count is the run lines only; the middle three are subsets of it and `Dispatcher` is the rest. Still five filters, same `.ftools` buttons and `aria-pressed`; no "All" stays.
- **Dispatcher filter:** unchanged rows (`f-sys`, dash mark, `37× since 00:09`), unchanged count.
- **Failed run, a gate failed** (the report's `failed_gates`): the second line opens with the existing `gates failed: build, lint` (gate names stay raw, `fraw`). The last log line is no longer shown on any row; the row still opens that run's log.
- **Failed run, no gate on record:** the second line opens with `ended with exit 3 · no failed gate recorded`. A failed run always has a second line, so the "ok" case cannot happen.
- **Order of the second line:** reason first, then `PR #n`, then `now in <column>`, joined by ` · ` as today: `gates failed: build · PR #64 · now in Validation`. Runs that ended well and running runs are untouched. The right column keeps `· exit 3` (it is the column the eye scans; the second line is where the reason is read).
- **Styling:** nothing new. `.fleft` in `--text` on a failed row (existing `.f-bad .fleft`), the diamond mark and the `--bad` stage name carry the state; the reason gets no color of its own.
- **Dates follow the page's language** (`document.documentElement.lang`, never the browser): `en` formats as `en-US`, `pt-BR` as `pt-BR`, anything else as `en-US`.
  - Day header (`.fday.cap`, uppercase by CSS): `Monday, October 12` / `segunda-feira, 12 de outubro`. No year, no "Today".
  - `hhmm()`: 24-hour `08:29` in both languages (the time column is `5ch` mono and the logs are 24-hour); never `AM`/`PM`.
  - `when()`: today `08:29`; another day `Oct 12 08:29` in English, `12/10 08:29` in pt-BR.
- **States:** empty, loading and error are unchanged (`Nothing here.` when the pressed filter has no row, `Nothing logged yet.` for an empty feed); with no run yet, `Runs` shows `Nothing here.` and the `Dispatcher` count shows where the lines are. No new string.
- **Small screens:** no layout change. The filter row already wraps; at 1180px and below the second line stays under the title with `overflow-wrap: anywhere` and the duration, exit and cost drop under it.
- **Copy, new or changed** (en → pt-BR, in `scripts/lang/dashboard.pt-BR.json`): `Runs` → `Execuções` (exact); `ended with exit 3` → `terminou com exit 3` (rx, placed after the existing ` and ended with exit` entry so that one still matches first); `no failed gate recorded` → `nenhum gate que falhou foi registrado` (exact, so it needs its own element). `Dispatcher` and the gate names stay as they are in both languages.
- **For `## Decisions`** (calls made here):
  - No "All" filter: the mixed view is the noise the issue reports, and the Product section rules out a new filter; every line stays reachable through `Runs` plus `Dispatcher`.
  - The last log line leaves the Feed's second line altogether instead of being filtered for "ok": a log line is not an outcome, and the reason now comes from the report or the exit code (principle 3).
  - English shows the month as a word in `when()` (`Oct 12`), because `10/12` reads as two different days to English readers outside the US; pt-BR keeps `12/10`, which has one reading there.
  - 24-hour time in English too, so the time column keeps its width and matches the log lines.
  - `DESIGN.md`, Feed paragraph, has to follow in the same change: the filter list and "the last line of a run that failed (the log)".

## Architecture
_Tech Lead_

One layer, `factory`. No migration, no new endpoint, no new dependency.

**Contracts touched**
- `GET /api/feed` (`Factory.feed_runs` in `scripts/dashboard.py`): a run event loses `last` (the last log line of a failed run); `last_line()` goes with it. Every other field stays: `failed` (the report's `failed_gates`), `exit`, `end`, `pr`, `column`, `you`, `step`, `lost`, `cost`. Dispatcher and stacks events are unchanged.
- `GET /api/lang`: unchanged. The page's language is still `document.documentElement.lang` (`en` in the markup, set by `loadLang()` otherwise).

**Page (`scripts/dashboard.html`)**
- `FEED_IS` / `FEED_NAMES`: the key `all` gives way to `runs: (e) => e.issue`, named `Runs`, first in the row; `S.feedFilter` defaults to it. `sys` (`Dispatcher`) is unchanged, so are `you`, `bad` and `run`.
- `feedLeft(e)`: no `e.last`. Order: reason, `PR #n`, `now in <column>`, step. Reason = `gates failed: <names>` when `e.failed`; else, for an ended run with `e.exit !== 0`, `ended with exit <n>` · `<span>no failed gate recorded</span>` (its own element, for the exact catalog entry). A run that ended with exit 0 and a running run build the same line as today.
- Dates: one helper, `dateLocale()`, returns `pt-BR` when `document.documentElement.lang` is `pt-BR` and `en-US` otherwise. `when()`, `hhmm()` and the day header in `renderFeed()` pass it instead of `undefined`; both times use `hourCycle: "h23"`. `when()` on another day: `{ month: "short", day: "numeric" }` in English, `{ day: "2-digit", month: "2-digit" }` in pt-BR. The day header keeps its shape (`head = d === day ? "" : \`<li class="fday cap">…\``), which `scripts/test/dashboard-page.test.sh` reads.

**Files**
- `scripts/dashboard.py`: `feed_runs` without `last`.
- `scripts/dashboard.html`: the three points above.
- `scripts/lang/dashboard.pt-BR.json`: `Runs` (exact), `no failed gate recorded` (exact), `ended with exit (\d+)` (rx, after ` and ended with exit (\d+)`); `All` stays only if the page still uses it elsewhere.
- `DESIGN.md`, Feed paragraph: the filter list and the second line's sources (no last log line; the exit code when no gate is on record).
- `scripts/test/dashboard.test.sh`: the existing feed check that reads `r["last"]` follows the contract (it asserts the title and that `last` is gone).
- `scripts/test/dashboard-feed.test.sh`: new, the acceptance tests.

**How the ACs are tested:** as the other dashboard tests, with no browser. The API part starts `dashboard.py` on a temp home with a dispatcher log, a failed run with a report naming a gate, a failed run with no report and a run that ended well, and reads `/api/feed`. The page part reads `scripts/dashboard.html` and the pt-BR catalog as text (`FEED_IS`, `feedLeft`, `dateLocale`, no `toLocale*(undefined` left in `when()`, `hhmm()` or `renderFeed()`).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-feed.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-feed.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-feed.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-feed.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-feed.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-feed.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-feed.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-feed.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- No "All" filter; `Runs` is the default: the mixed view is the noise the issue reports, and every line stays reachable through `Runs` plus `Dispatcher`.
- The last log line leaves the feed (page and `/api/feed`) instead of being filtered for "ok": a log line is not an outcome, and nothing else reads `last`.
- A failed run with no gate on record says `ended with exit <n> · no failed gate recorded`: the exit code is the agent process's, the factory has no table of reasons for it, and nothing is inferred (principle 3).
- The page composes the reason from `failed` and `exit`; the server sends no ready-made sentence, so the text goes through the catalog like every other string.
- Dates take the page's language from `document.documentElement.lang`, `en-US` for anything that is not `pt-BR`: the two languages the factory ships.
- `when()` in English shows the month as a word (`Oct 12`): `10/12` reads as two different days outside the US; pt-BR keeps `12/10`.
- 24-hour time in both languages: the time column keeps its width and matches the log lines.
- `when()` and `hhmm()` change for the whole page (AC-8); the other direct `toLocale*` calls (tooltips, numbers) stay, as the Product section rules.
- `DESIGN.md`'s Feed paragraph changes in the same card: it names the filter list and the last log line.
- Tests read the page as text and the API over HTTP, with no browser: that is how every dashboard test in the layer runs.

## Open questions
- none
