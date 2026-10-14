# Plan — #179 [UX-05] The decision brief on today's screen

Spec: `docs/superpowers/specs/2026-10-14-ux-05-o-resumo-da-decisao-na-tela-de-hoj-design.md`

## Brief format read (from #178's spec, not on main yet)

`<home>/reviews/<n>.brief.json` = `{card, column, built, verdict, what:{text,by}, flags:[{id,kind,title,detail,hunk,source,suggestion}], since_request:[{old,new}], proven:[gate names], facts:{pr,files,added,removed,statements}, rest:[text]}`. The reader is defensive: a missing or mistyped field drops its block; an unparseable file or a non-object counts as no brief.

## Tasks

All files belong to the single layer `factory` (path `./`), agent `engineer`.

### T1 — layer `factory` (engineer): server, renderer, catalogs

Depends on: QA's acceptance tests (`scripts/test/dashboard-brief.test.sh`, the AC-8 cases in `scripts/test/dashboard-catalog.test.sh`).

Files:
- `scripts/dashboard.py`
  - helper `brief(p, n)`: reads `self.pdir(p) / "reviews" / f"{n}.brief.json"`; returns the parsed dict, or `None` when missing, unreadable, unparseable or not an object. Never raises.
  - `card()`: adds `"brief"` (the helper's result).
  - overview per-card dict (around the `"awaiting": col in AWAITING` entry): adds `verdict` (`"routine"` / `"look"` / `None`) and `flags` (count of list entries, 0 when absent) for cards in `AWAITING` with a brief; `None`/0 otherwise.
- `scripts/dashboard.html`
  - pure `briefHTML(brief)` (only `t`/`esc` as globals; `""` for no brief): verdict row (pill `.tag` with `ok` for `routine`, `sand` for `look`/`since_request`; text `routine` / `1 point` / `{n} points`), then What you approve, Needs your eyes (one `.btn.ghost` `data-suggest` per flag with a suggestion), Since your request, What the gates proved, `<details>` The rest ({n}) closed by default. Each block only with content, each with its muted origin chip; agent/factory text under the `RAW` selector.
  - `renderDecide`: inserts `briefHTML(S.card.brief)` above the decision row inside `.decide`, group labelled `Decision brief`; `<details>` open state kept in `S` per card.
  - click handler for `data-suggest`: fills `#changes`, unfolds it, focuses it with the cursor at the end, writes the polite notice; sends nothing.
  - `passHtml`: appends `· routine` (ok) or `· 1 point` / `· N points` (sand) to the row's `.cap` when the card has a verdict.
  - CSS reusing current tokens; narrow (<540px container) wrapping per spec UX.
- `scripts/lang/dashboard.en.json` + the 11 other `dashboard.<code>.json`: new `brief.*` and `pass.verdict.*` keys, English text in all of them.

Acceptance: every selector in the QA commit green; `build` gate green.
