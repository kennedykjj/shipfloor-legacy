# Dashboard: the first screen shows more than a quick check needs — plan

**Issue:** #53 · **Spec:** `docs/superpowers/specs/2026-10-11-dashboard-the-first-screen-shows-more-th-design.md`
**Layers:** `factory` (path `./`, agent `engineer`). No migration, no new dependency, no server change (`scripts/dashboard.py` is not touched).

Acceptance tests (written by QA before any task): `scripts/test/dashboard-first-screen.test.sh` (new; AC-2, 3, 7, 8), `scripts/test/theme.test.sh` (changed; AC-5, 6). Both read `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json` as text with Python, as `theme.test.sh` does today; no browser. AC-1 and AC-4 are pixel measures: UX/UI checks them in validation with verify-ui, so the tasks below must meet the UX section's numbers without a test asking for them.

Both tasks edit `scripts/dashboard.html`; they run one after the other, Task 1 first.

## Task 1 — the first screen: summary line, panels on demand, "Yours"

- **Layer:** factory · **Owner:** engineer · **Depends on:** nothing
- **Files:** `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `DESIGN.md` (the Factory view's first screen)
- **ACs:** AC-2, AC-3, AC-7, AC-8 (tested); AC-1, AC-4 (measured in validation)
- Markup: `#board` gains a first row `div.sumline#sumline`, hidden with `#cols` until the first read: `button[data-show="band"][aria-controls="band"][aria-expanded="false"]` ("Lifecycle"), `button[data-show="today"][aria-controls="today"][aria-expanded="false"]` ("Today"), each with the existing fold chevron, then `span#sum`. `section.telem` gets `id="today"`; it and `nav#band` are `hidden` in the static markup.
- State: `S.show = { band: false, today: false }`, in memory only, never `localStorage`. `show(which, on)` sets the panel's `hidden` and the button's `aria-expanded`, restores the panel first if it is maximized, closes an open peek when the band closes, and re-renders `#sum`. Focus stays on the button.
- `renderBoard`: `$("band").hidden` and `$("today").hidden` come from `S.show` (and from "no project"), no longer from the data alone; `#sumline` follows `#cols`. A refresh never rewrites the two buttons.
- `renderSum(p)`: writes `#sum` through `setHTML`: `Pool 2 / 4 in use · $3.41 est. spent today · 12 runs today · 1 failed`. Pool from `S.overview.pool`; spent and runs from the same sums of `p.hours` that `renderTelem` uses; the failed part in `--bad`, left out at zero; the cost keeps the strip's `title`. `#sum` is hidden while `S.show.today`.
- `renderTelem(p)`: returns early while "Today" is closed; content order is runs chart, spend chart, then "A stage usually takes"; the maximized chart height is `min(170px, 20vh)` computed from `innerHeight`.
- `waiting()`: sorted the oldest wait first (`since`, cards without it last), the comparison `inboxCards` uses today; `inboxCards` keeps only its `gone` filter.
- `renderYours`: with nothing waiting in the page, the panel is its heading only: `#list` empty and `.foot` hidden; the maximized inbox keeps its paragraph.
- Click handler: one new branch for `[data-show]`. The maximize buttons are unchanged (a closed panel is `hidden`, so its button is too).
- CSS: `.board` rows `auto auto minmax(0, 1fr)`; `.yours` loses `max-height: 62%`; `.telem` becomes `flex: 0 0 auto; max-height: 60%` with a `min-height` of its heading plus both charts; `.sumline` (36px row, 13px `--muted`, figures in `<b>` `--text` tabular, wraps at 1180px and below); focus ring is the existing 2px `--sand` outline. If 5 cards do not fit at 1440x900, tighten `.pass` padding.
- `dashboard.pt-BR.json` (`rx`): `\bin use\b` → `em uso`; `est\. spent today` → `est. gastos hoje`; `(\d+) runs? today` → `$1 execuções hoje`.
- `DESIGN.md`: the Factory view's first screen (summary line, "Yours", "In progress"; the band and "Today" on demand).

## Task 2 — Themes: four first, the rest under "More themes"

- **Layer:** factory · **Owner:** engineer · **Depends on:** Task 1 (same file)
- **Files:** `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `DESIGN.md` (the Themes paragraph)
- **ACs:** AC-5, AC-6
- `THEMES` gains `first: [["auto", …], ["tape", …], ["kraft", …], ["contrast", …]]`; `dark` and `light` keep the other eight. Every theme id stays exactly once in the first 900 characters after `const THEMES` (`theme.test.sh` reads them there).
- `renderSettings`, Themes: one `.sgroup` without a heading holds exactly four `button.thm` in the order Auto, Floor tape, Kraft, High contrast; under it the fold row (`h2.ptitle2` with a `data-fold="themes"` button, `aria-expanded`, `aria-controls`) labelled "More themes"; open, it shows the "Dark" (7) and "Light" (2) groups.
- `SET.moreThemes`: false whenever Settings opens; the `data-fold="themes"` branch toggles it and does not write `shipfloor.shut`. Picking a theme inside the fold keeps it open and keeps focus on that swatch.
- The fold row's right-hand `span` reads `In use: <b>name</b>` only when `THEME` is none of the four; then none of the four is `aria-pressed="true"` and the swatch inside the fold is.
- `dashboard.pt-BR.json`: `^In use: ` → `Em uso: ` (`rx`); exact `More themes` → `Mais temas`.
- `DESIGN.md`: the Themes paragraph (four first, the rest under "More themes").
