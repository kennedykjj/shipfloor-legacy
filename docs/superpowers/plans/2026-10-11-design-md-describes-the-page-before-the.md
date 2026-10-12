# DESIGN.md describes the page before the rename; regenerate it from the shipped dashboard — plan

**Issue:** #54 · **Spec:** `docs/superpowers/specs/2026-10-11-design-md-describes-the-page-before-the-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/design-doc.test.sh`), red.
2. Task 1 (factory), one task: `DESIGN.md` and `.impeccable/design.json` are written together, because AC-6 compares one with the other.

## Before the plan

`origin/main` was merged into the branch before anything else. Since the spec was written, main changed `scripts/dashboard.html` (the Feed: new `font-size` and `border-radius` values) and two lines of `DESIGN.md`. A document derived from the branch's older page would describe a page that no longer ships and its test would fail on top of main. Every gate of this card uses the merge commit as its base.

## Acceptance tests — QA

- **File:** `scripts/test/design-doc.test.sh` (new), AC-1 to AC-6, in the shape of `scripts/test/theme.test.sh` (`FACTORY_PYTHON`, `ok` / `FAIL` lines).
- Reads three files of the repository and nothing else: `scripts/dashboard.html`, `DESIGN.md`, `.impeccable/design.json`. No server, no network.
- From the page's CSS: the `--sans`, `--cond` and `--mono` stacks; every `font-size`, including the size inside a `font:` shorthand; every `border-radius`; the hex tokens of the `:root, [data-theme="charcoal"]` block; the ids of the `[data-theme]` blocks.
- From `DESIGN.md`: the front matter with PyYAML (`colors`, `typography`, `rounded`) and the body (`## Known deviations`, one bullet per value as `` `<value>` — `<selector>` ``).
- AC-2: `0`, `50%` and `inherit` are not checked. A failure names the missing value and the selector that uses it.
- AC-3: the `colors` keys are exactly the page's base hex tokens, same values; `gold` and `azure` are not keys.
- AC-4: the retired terms and values of the spec, searched in both documents, case as written in the spec.
- AC-6: every color and typography entry of the sidecar exists in the front matter with the same value; `generatedAt` is on or after 2026-10-11.
- Before the implementation the tests fail on their assertions (the old document is parsed and found wrong), not on a crash or a missing file.
- AC-7 and AC-8 are manual checks in review: no test.

## Task 1 — factory: the document and its sidecar describe the shipped page

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `DESIGN.md` (rewrite)
- `.impeccable/design.json` (rewrite)

`scripts/dashboard.html` and `scripts/dashboard.py` are read, never written (AC-7). `.impeccable/surfaces/scripts-dashboard-html.md` stays as it is.

**`DESIGN.md` front matter** (the contract in the spec's Architecture section)
- `name`, `description`: Shipfloor, with no item-shop wording.
- `colors`: the 19 hex tokens of the `:root, [data-theme="charcoal"]` block, the name without `--`, the same value. Nothing else.
- `typography`: named roles; `fontFamily` is one of the page's three stacks, written as the page writes it; the `fontSize` values are the type ramp.
- `rounded`: the radius scale.
- `spacing`, `components`: the shipped values; they reference only declared tokens.

**Ramp and scale**
- Count the rules that use each `font-size` (and `font:` shorthand size) and each `border-radius` in the page as it is on this branch.
- Three or more rules, or a named role (a caption, a stat, a card): the value joins the ramp or scale.
- Once or twice with no role: a bullet under `## Known deviations`, `` `<value>` — `<selector>` ``. The page is not changed to remove it.

**`DESIGN.md` body**
- Keep the subsections that already describe the shipped page, with main's latest wording: How a Card Opens, Line Peek, Feed, Language, Themes, Embedded Review Pages, Keyboard and Live Updates.
- Rewrite the rest from the page: Overview, Colors, Typography (Barlow and Barlow Condensed embedded in the file, the mono stack, uppercase captions), Layout (the lifecycle band; the three views Factory, Feed, Settings), Elevation, Shapes, Components, Do's and Don'ts.
- Themes: the 12 ids of the page's `[data-theme]` blocks, by id.
- `--gold` and `--azure` only in prose, as the aliases of `sand` and `text` that the page defines.
- New `## Known deviations`.
- None of the retired terms or values of AC-4.

**`.impeccable/design.json`**
- `schemaVersion` stays 2; `generatedAt` is the day of the change.
- Every color and typography entry it names exists in the `DESIGN.md` front matter with the same value.
- None of the retired terms or values of AC-4.

**Done when:** `scripts/test/design-doc.test.sh` passes, `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green, and `git diff --stat origin/main -- scripts/dashboard.html scripts/dashboard.py` prints nothing.
