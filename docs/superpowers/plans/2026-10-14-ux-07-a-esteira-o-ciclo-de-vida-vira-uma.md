# [UX-07] The belt — plan

**Issue:** #181 · **Spec:** `docs/superpowers/specs/2026-10-14-ux-07-a-esteira-o-ciclo-de-vida-vira-uma-design.md` · **Date:** 2026-10-14

The branch was cut before #176 (`silent`, merged as #231) and #180 (v4 tokens, merged as #240); `origin/main` was merged into it before this plan so the belt builds on both. Every task is in the one layer, `factory` (path `./`, agent `engineer`). The tasks share the worktree and run one after the other.

## Acceptance tests (QA, before any task)

- `scripts/test/py/dashboard_belt.py` + `belt_page.py`, run by the existing `scripts/test/dashboard-views.test.sh` — AC-1 to AC-7.
- `scripts/test/py/dashboard_v4.py`, run by the existing `scripts/test/theme.test.sh` — AC-8.
- No new `*.test.sh`: `hygiene.test.sh` caps their count and the cap is never raised to fit a new file.
- Reuse `scripts/test/py/dashboard_support.py`, `fake-gh` and `demo-gh` as the existing dashboard suites do; prefer in-process checks (docs: the factory tests behavior, prefers in-process tests).

## Tasks

### T1 — The belt, its tokens and the status sentence
- **Layer:** factory · **Agent:** engineer · **Depends on:** acceptance tests.
- **Covers:** AC-1, AC-2, AC-5, AC-6.
- **Files:** `scripts/dashboard.html` (`renderBand` → `renderBelt` in the `#band` panel, `#cells` as the belt container; segments in board order with meta; token states; ghost `free` tokens from `pool.stages[stage]`; roving-tabindex keyboard and accessible names; token click / Enter / Space to today's drawer routing; `renderPeek`, `peek()` and `#peek` removed; `renderStatus` in the header in place of the loose stats; Restart row with #176's `silent.reinstall` and Copy), `scripts/dashboard.py` (only if `done_today` is missing from the project payload), `scripts/lang/dashboard.*.json` (all 12: `belt.*` and `status.*` keys, en and pt-BR from the spec, English elsewhere; removed peek/band-dot keys deleted from all 12).

### T2 — Motion, reduced motion and narrow layout
- **Layer:** factory · **Agent:** engineer · **Depends on:** T1.
- **Covers:** AC-3, AC-4, AC-7.
- **Files:** `scripts/dashboard.html` (FLIP travel keyed by `data-key`, 950ms with a 14px arc, replacing the dot slide; gate ring on arrival, never on the first read; fade in/out; CSS rail ticks animating only while `silent` is null, paused and `bad` when it is set; `@media (prefers-reduced-motion: reduce)` stops travel, rail, ring and fade; `@media (max-width: 1019px)` belt `overflow-x: auto` with segment minimums, page never scrolls sideways; focused token scrolled into view).

### T3 — DESIGN.md and the existing suites that name the band or peek
- **Layer:** factory · **Agent:** engineer · **Depends on:** T1, T2.
- **Covers:** AC-8, and keeps the rest of the suite green.
- **Files:** `DESIGN.md` (Lifecycle Band and Line Peek replaced by The Belt; overview, Motion and Do's/Don'ts say three continuous motions — dial, dot pulse, belt — with the belt's rule; front matter description), `.impeccable/design.json` if it names the band or peek, and any existing test under `scripts/test/` that asserts the removed band dots, peek or header stats (outside the QA commit).

## Gates after each task
`scope factory <start>`, `acceptance-intact <qa>`, `migration <base> <spec>`, `build <base>`; after T3, `green factory <selector>` for each acceptance test.
