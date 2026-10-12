# Feed: dispatcher noise weighs as much as outcomes, and a failed run shows "ok" — plan

**Issue:** #114 · **Branch:** `feat/114-feed-dispatcher-noise-weighs-as-much-as`
**Spec:** `docs/superpowers/specs/2026-10-12-feed-dispatcher-noise-weighs-as-much-as-design.md`

One layer (`factory`), one task: the API field, the page and the catalog change together, and the page must not read a field the server stopped sending.

## Acceptance tests (QA, before the task)

- `scripts/test/dashboard-feed.test.sh` (new), AC-1 to AC-8, as the spec's "How the ACs are tested": the API part starts `dashboard.py` on a temp home and reads `/api/feed`; the page part reads `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json` as text.

## Task 1 — the feed opens on runs, a failed run names its reason, dates follow the page's language

**Layer:** factory · **Owner:** engineer · **Depends on:** the acceptance tests

**Files**
- `scripts/dashboard.py` — `Factory.feed_runs`: a run event no longer carries `last`; `last_line()` is removed (nothing else reads it). Every other field stays.
- `scripts/dashboard.html`
  - `FEED_IS` / `FEED_NAMES`: the key `all` gives way to `runs: (e) => e.issue`, named `Runs`, first in the row; `renderFeed()` defaults `S.feedFilter` to `runs`. `you`, `bad`, `run` and `sys` are unchanged.
  - `feedLeft(e)`: no `e.last`. Order: reason, `PR #n`, `now in <column>`, step. Reason = `gates failed: <names>` when `e.failed`; else, for an ended run with `e.exit !== 0`, `ended with exit <n>` and `<span>no failed gate recorded</span>` (its own element, so the exact catalog entry matches), joined by ` · `. A run that ended with exit 0 and a running run build the line they build today.
  - `dateLocale()`: `pt-BR` when `document.documentElement.lang` is `pt-BR`, `en-US` otherwise. `when()`, `hhmm()` and the day header in `renderFeed()` pass it instead of `undefined`; both times use `hourCycle: "h23"`. `when()` on another day: `{ month: "short", day: "numeric" }` in English, `{ day: "2-digit", month: "2-digit" }` in pt-BR. The day header keeps its shape (`head = d === day ? "" : \`<li class="fday cap">…\``), which `scripts/test/dashboard-page.test.sh` reads.
- `scripts/lang/dashboard.pt-BR.json` — `Runs` → `Execuções` (exact); `no failed gate recorded` → `nenhum gate que falhou foi registrado` (exact); `ended with exit (\d+)` → `terminou com exit $1` (rx, placed after ` and ended with exit (\d+)`, so that one still matches first). `All` → `Tudo` goes only if the page no longer uses `All` anywhere.
- `scripts/test/dashboard.test.sh` — the feed check on line 56 that reads `r["last"]` follows the contract: it keeps the title assertion and asserts that `last` is gone.
- `DESIGN.md`, Feed section — the filter list (`Runs` in place of `All`) and the second line's sources (no last log line; the exit code when no gate is on record).

**Done when:** `scripts/test/dashboard-feed.test.sh` passes, and the layer's build (`bash scripts/test/run.sh --changed origin/main`) passes, the language tests included (every string the page shows has its catalog entry).
