# Dashboard: small fixes from the critique (pause without undo, drawer focus, shortcut legend, Feed) — plan

**Issue:** #55 · **Spec:** `docs/superpowers/specs/2026-10-11-dashboard-small-fixes-from-the-critique-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-page.test.sh`), red.
2. Task 1 (factory): the styles and the static markup (AC-5, AC-6, AC-8).
3. Task 2 (factory): the behavior in the page's script and the catalog (AC-1, AC-2, AC-3, AC-4, AC-7). Depends on Task 1 only because both change `scripts/dashboard.html`: they run one after the other.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-page.test.sh` (new), AC-1 to AC-8.
- Reads `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json` as text with the factory's Python, as `scripts/test/theme.test.sh` does; no browser and no server.
- One named check per criterion, so a red run says which criterion is missing. Each check asserts on what the spec's UX and Architecture sections name: markup, CSS rules, handlers, strings.
  - **AC-1** — `renderFlags()` writes a `.btn.ghost` with `data-resume` in each paused alert, with the two `aria-label`s; a `resume(` function posts to `/api/settings/pause` with `paused: false`; `S.resuming` and `S.resumeErr` exist; the error sentence is in the page; the CLI hint is no longer in the alert text.
  - **AC-2, AC-3** — `renderDrawer()` sets `aria-modal` from `S.open && S.full`; the document `keydown` listener has a Tab branch guarded by `S.open && S.full`; the static markup of `#drawer` keeps `aria-modal="false"`.
  - **AC-4** — the 403 branch sets `role="alert"` on `#msg` before it writes the text; the attribute is removed where `#msg` is written otherwise; the static `#msg` has no `role`.
  - **AC-5** — the `.foot` paragraph holds the list keys (`N A R L`) and the inbox keys (`1–9` choose, `Esc` close) as two groups; `.yours.maxed .foot` is no longer in a `display: none` rule; CSS shows one group by `.yours.maxed`.
  - **AC-6** — `.foot` and `.iopt kbd` are at least 12px.
  - **AC-7** — `renderFeed()` emits `<h2 class="ev-day">`; a `day(` helper returns `Today`, `Yesterday` or a weekday and date; the day row is not matched by `.ev > span`.
  - **AC-8** — the `.lane` rule's color is `var(--soft)`, not `var(--sand)`; `.lane small` stays `var(--muted)`.
  - **Catalog** — every new string listed under "Copy, pt-BR" in the spec has its entry in `scripts/lang/dashboard.pt-BR.json`, with the spec's translation (checked under the criterion the string belongs to: AC-1, AC-5, AC-7).
- Before the implementation every check fails on its assertion (the page lacks the rule or the handler), not on a missing file or a crash.

## Task 1 — factory: legend, sizes and lane headings (AC-5, AC-6, AC-8)

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.html` (change): CSS and the `<p class="foot cap">` markup only.

**What changes**
- **AC-5** — the `.foot` paragraph holds two groups: list keys (`N next · A approve · R review · L log`) and inbox keys (`<kbd>1–9</kbd>choose`, `<kbd>Esc</kbd>close`). `.yours.maxed .foot` leaves the `display: none` rule; CSS shows the inbox group only under `.yours.maxed` and the list group only outside it.
- **AC-6** — `.foot` is 12px (the `.cap` default of 11px stays elsewhere; its `kbd` inherits); `.iopt kbd` goes from 11px to 12px. Colors unchanged.
- **AC-8** — `.lane { color: var(--soft) }`; `.lane small` and the rule stay.

**Done when:** the AC-5, AC-6 and AC-8 checks of `scripts/test/dashboard-page.test.sh` pass (the "choose" and "close" catalog entries come with Task 2) and the build gate is green.

## Task 2 — factory: Resume, modal drawer, stale-link alert, day rows, catalog (AC-1, AC-2, AC-3, AC-4, AC-7)

**Owner:** `engineer` · **Depends on:** Task 1

**Files**
- `scripts/dashboard.html` (change)
- `scripts/lang/dashboard.pt-BR.json` (change)

**What changes**
- **AC-1** — `renderFlags()`: each paused alert ends with `<button class="btn ghost" data-resume="<slug or empty>">Resume</button>` with its `aria-label` ("Resume the factory" / "Resume <slug>"); the alert text is the spec's copy, without the CLI hint; label in `--text` (one CSS rule, as `.notice .btn`). The document click handler routes `[data-resume]` to a new `resume(target)`: posts `{project: <slug> | null, paused: false}` to `/api/settings/pause`, reads the overview again (`loadOverview()`), refreshes `SET.data` when Settings is loaded, moves focus to `[data-view][aria-pressed="true"]` on success. `S.resuming` (target in flight) keeps the button disabled across the 5s re-render; `S.resumeErr` keeps "Still paused: the resume did not go through." and the button enabled again.
- **AC-2, AC-3** — `renderDrawer()` sets `aria-modal` to `String(!!(S.open && S.full))` beside `d.inert`. The document `keydown` listener gains a Tab branch that runs only when `S.open && S.full`: first and last focusable inside `#drawer` wrap to each other; focus outside the drawer is pulled to the first. The static `aria-modal="false"` stays.
- **AC-4** — in the 403 branch of the overview read, `#msg` gets `role="alert"` before `setHTML`; every other writer of `#msg` removes the attribute.
- **AC-7** — `renderFeed()` tracks the local calendar day of the last timed event and emits `<h2 class="ev-day">` when it changes (also for a one-day Feed); a new `day(iso)` helper returns `Today`, `Yesterday` or weekday and date; rows under a day row print the time only; an event with no time stays under the day above. CSS for `.ev-day` as the spec's UX section says; it must not be matched by `.ev > span`. `evId`, `S.feedOpen`, focus restore and follow-the-end are untouched.
- **Catalog** — the entries listed under "Copy, pt-BR" in the spec, including the `^Resume (\S+)$` pattern in the form the catalog already uses for patterns.

**Done when:** `scripts/test/dashboard-page.test.sh` passes whole and the build gate is green.
