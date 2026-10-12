# Dashboard: say why a card is blocked, link the docs, and stop repeating the header — plan

**Issue:** #119 · **Spec:** `docs/superpowers/specs/2026-10-12-dashboard-say-why-a-card-is-blocked-link-design.md`
**Layers:** `factory` (path `./`, agent `engineer`). No migration, no new dependency, no new endpoint, nothing stored.

Acceptance tests (written by QA before any task): `scripts/test/dashboard-block-line.test.sh` (new; AC-1, 2, 3: the server against the fake `gh`, as `dashboard.test.sh` starts it, plus the page's `passHtml` and `whyWaits` read as text), `scripts/test/dashboard-glance.test.sh` (new; AC-4 to AC-8: `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json` read with Python, `dur` run from the page's own source; no browser). QA also updates `scripts/test/dashboard-first-screen.test.sh`, which asserts what this card removes (`renderSum`, `span#sum`, the three `rx` entries of the summary sentence).

Task 2 reads the two fields Task 1 adds to the overview; they run one after the other, Task 1 first.

## Task 1 — the server: `block_line` and `block_cost` in the overview

- **Layer:** factory · **Owner:** engineer · **Depends on:** nothing
- **Files:** `scripts/dashboard.py`
- **ACs:** AC-1, AC-2, AC-3 (the server half)
- New `Factory.block_line(p, n)`: one plain-text line from `block_reason(p, n)` (same note, same one-minute cache, same trusted-commenter filter), first match of:
  1. the line that states the owner's call (`must decide | owner must | needs? you to`), without its label up to the colon, first letter in capitals: the rule `blockNote` applies in the page today;
  2. `Failed gate: <name>` when the note has `failed gates?:`;
  3. else `""`, also for a note that opens with `COST_BLOCK`.
  Markdown marks (`**`, `` ` ``, a leading `-` or `*`) stripped, whitespace collapsed, bounded at 500 characters. Never composed from anything but the note.
- The cost marker read (`cost/<n>.json`) moves out of `block()` into one helper both `block()` and the overview use; `block()` returns what it returns today.
- `overview()`: each entry of `projects[].cards[]` gains `block_line` (the line above when `blocked.get(n) == "owner"`, else `""`) and `block_cost` (`{"total", "limit", "baseline"}` in dollars, the three figures `block()` gives for `kind: "cost"`, only for an owner block whose note opens with `COST_BLOCK` and whose marker is readable; else `None`).
- `/api/card/<project>/<n>` and `/api/decide/<project>/<n>` do not change.

## Task 2 — the page: reason line, docs link, figures once, days and hours

- **Layer:** factory · **Owner:** engineer · **Depends on:** Task 1 (`block_line`, `block_cost`)
- **Files:** `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `DESIGN.md`
- **ACs:** AC-1, AC-2, AC-3 (the page half), AC-4, AC-5, AC-6, AC-7, AC-8
- `passHtml(c)`, for `c.blocked === "owner"`: one `<p class="pwhy">` inside `.seg`, under the title and directly above the `.stub` row, outside the `.ptitle` button. `c.block_cost` → caption `Blocked · cost limit` and the existing spend sentence from its figures (`Spent $X est. since it was last unblocked; the limit for a card is $Y.` or its `since Inbox` form); else a non-empty `c.block_line` → that text through `esc`, the whole text in `title`; else no element, the pass as today.
- CSS `.pwhy`: the one-line recipe of `.did li` (`white-space: nowrap; overflow: hidden; text-overflow: ellipsis`), 13px, `--soft`, `margin: 4px 0 0`. `.pwhy` joins the `RAW` selector; the cost sentence must still be translated, so it is written where the catalog reaches it (not under `RAW`) or carries its own class.
- `whyWaits(p, c)`: the `blocked === "infra"` sentence becomes `Infrastructure failed; the factory retries once`.
- Docs link: static markup in `<header>`, first child of `.stats` before `#scope`: `<a class="cap" href="https://github.com/kennedykjj/shipfloor#learn-more" target="_blank" rel="noopener">Docs` + the `EXT` glyph. Not written by `renderStrip`; no fetch, no preload, no asset.
- Figures once: `renderSum`, `span#sum`, its CSS (`#sum …`, `#sum[hidden]`) and its calls (`renderBoard`, `show`) are removed; `#sumline` keeps the two fold buttons. `renderStrip`: when `o.projects.length > 1`, the Runs today `title` is `Runs of every project today` and the Spent est. `title` gains a first line `Every project, today.`; with one project, no change.
- `dur(a, b)`: when `s > 172800` returns `` `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h` ``; otherwise unchanged. No call site changes.
- `dashboard.pt-BR.json`: add `Docs` → `Documentação`, `Infrastructure failed; the factory retries once` → `A infraestrutura falhou; a fábrica tenta mais uma vez`, `Runs of every project today` → `Execuções de todos os projetos hoje`, `Every project, today.` → `Todos os projetos, hoje.`. Remove the three `rx` entries of the summary sentence (`\bin use\b`, `est\. spent today`, `(\d+) runs? today`) and the old infrastructure sentence. The two `rx` entries that capture a duration (`Running · last cycle (\S+) ago`, `board read (\S+) ago`) capture `(\d+d \d+h|\S+)`.
- `DESIGN.md`: "Layout" (the summary sentence is gone), "Header" (the Docs link), "Your" (the reason line and its states), "In Progress" (the infrastructure wording).
