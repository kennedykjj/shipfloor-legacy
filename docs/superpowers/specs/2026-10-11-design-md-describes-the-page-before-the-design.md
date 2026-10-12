# DESIGN.md describes the page before the rename; regenerate it from the shipped dashboard — spec

**Issue:** #54 · **Branch:** `feat/54-design-md-describes-the-page-before-the` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** `DESIGN.md` and its sidecar `.impeccable/design.json` describe the page before the rename (deep-slate "item shop", parchment/gold/azure hexes, system fonts, no uppercase, ten-column board), not the shipped `scripts/dashboard.html`. Every design-system finding of the detector comes from that gap, so it gives no signal, and the agents that read `DESIGN.md` as context design against a page that no longer exists.
**Audience:** the factory's owner (and, through the context files, the agents that design and review for the owner).
**Acceptance criteria**
- **AC-1** — Given the `--sans`, `--cond` and `--mono` stacks of `scripts/dashboard.html`, when `DESIGN.md` is read, then its typography declares Barlow, Barlow Condensed and the mono stack, says the two Barlow faces are embedded in the file, and no longer says "no webfonts".
- **AC-2** — Given every `font-size` and `border-radius` value in the page's CSS, when `DESIGN.md` is read, then each value is in its type ramp or radius scale, or is listed by value under a "Known deviations" heading with the selector that uses it.
- **AC-3** — Given the color tokens of the page's base (`:root`) block, when the `colors` front matter of `DESIGN.md` is read, then each token is declared with the same value, no declared color is missing from the page, and `--gold`/`--azure` appear only as the aliases of `sand` and `text` that the page defines.
- **AC-4** — Given `DESIGN.md` and `.impeccable/design.json`, when they are searched, then none of these retired terms or values remain: "item shop", "Item Tooltip", "parchment", "stone-", "Deep Slate", "never uppercase", "ten columns", `#e2b356`, `#63b2ff`, `#ebe5d5`, `#0d1014`.
- **AC-5** — Given the shipped page, when `DESIGN.md` is read, then it describes the lifecycle band, the three views by their names (Factory, Feed, Settings), the uppercase captions, and the same 12 theme ids as the page's `[data-theme]` blocks.
- **AC-6** — Given the regenerated `DESIGN.md`, when `.impeccable/design.json` is read, then every color and typography entry it names exists in the `DESIGN.md` front matter with the same value, and its `generatedAt` is the date of this change.
- **AC-7** — Given the branch, when it is compared with `main`, then `scripts/dashboard.html` and `scripts/dashboard.py` are unchanged.
- **AC-8** — Given a machine with the `impeccable` tool, when `impeccable detect scripts/dashboard.html` runs, then it reports no finding that is only a missing declaration, and each finding left matches an entry under "Known deviations" (manual check).
**Out of scope:** any change to the dashboard's pixels, CSS or tokens; fixing the real deviations the detector still reports (each goes to a follow-up issue); renaming the `--gold`/`--azure` aliases in the page; `PRODUCT.md`, `README.md` and the review template; redesign or new themes.
**Product fit:** serves principle 2 (deterministic gates outrank any agent's claim: a detector that only reports the stale document is a gate with no signal) and principle 3 (what is written is exact and sourced: the document is derived from the shipped file, not from memory). No conflict with positioning or scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

A documentation change plus one test that keeps the document tied to the page. No endpoint, event, public function or migration is touched; `scripts/dashboard.html` is read, never written.

**Files (all owned by layer `factory`)**
- `DESIGN.md` — rewritten from `scripts/dashboard.html`. The body keeps the sections that already describe the shipped page (Line Peek, Feed, Language, Themes, How a Card Opens, Keyboard and Live Updates) and rewrites the rest.
- `.impeccable/design.json` — rewritten to match; `schemaVersion` stays 2, `generatedAt` is the day of the change.
- `scripts/test/design-doc.test.sh` — new; reads the three files with `FACTORY_PYTHON`, in the shape of `scripts/test/theme.test.sh`.

**Front matter contract of `DESIGN.md`** (what the test reads)
- `colors`: one key per hex token of the page's `:root, [data-theme="charcoal"]` block, same name without `--`, same value: `ground`, `panel`, `panel-hi`, `edge`, `edge-hi`, `text`, `soft`, `muted`, `faint`, `sand`, `glow1a`, `glow1b`, `glow2`, `track`, `track-on`, `refine`, `ok`, `warn`, `bad`. Nothing else: the other 11 themes are documented in the body by id, and `gold`/`azure` only in prose as aliases of `sand`/`text`.
- `typography`: named roles whose `fontFamily` is one of the page's three stacks (`--sans` Barlow, `--cond` Barlow Condensed, `--mono`) and whose `fontSize` values form the type ramp.
- `rounded`: the radius scale. `spacing` and `components` are refreshed to the shipped values and reference only declared tokens.
- Body heading `## Known deviations`: one bullet per value left out of the ramp or scale, as `` `<value>` — `<selector>` ``.

**Ramp and scale rule** (so the document is not widened until the detector goes silent)
- A `font-size` or `border-radius` value joins the ramp or scale when the page uses it in three or more rules or it belongs to a named role (a caption, a stat, a card); a value used once or twice with no role goes under `## Known deviations`.
- `0`, `50%` and `inherit` are not scale values and are not checked.

**What the test checks**
- Parses the page's CSS for the three font stacks, every `font-size` (including the size inside a `font:` shorthand) and every `border-radius`; parses the `DESIGN.md` front matter with PyYAML and the sidecar with `json`.
- Fails with the missing value and its selector, so a later card that adds a size or a radius is told to declare it or list it.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/design-doc.test.sh` |
| AC-2 | factory | `scripts/test/design-doc.test.sh` |
| AC-3 | factory | `scripts/test/design-doc.test.sh` |
| AC-4 | factory | `scripts/test/design-doc.test.sh` |
| AC-5 | factory | `scripts/test/design-doc.test.sh` |
| AC-6 | factory | `scripts/test/design-doc.test.sh` |
| AC-7 | manual | `git diff --stat origin/main -- scripts/dashboard.html scripts/dashboard.py` prints nothing |
| AC-8 | manual | `impeccable detect scripts/dashboard.html`, each finding matched to `## Known deviations` |

## Security
_Cybersec_ — n/a

## Rollback
n/a — two documents and a test; reverting the commit restores them.

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Real deviations are listed under `## Known deviations`, not declared into the ramp or scale: the issue asks that what the detector still reports be a real deviation, and widening the document would silence it.
- A value joins the ramp or scale at three or more uses or with a named role: a rule the test and a reviewer can apply the same way, instead of a judgment per value.
- The document is written by hand from the CSS, not with `/impeccable document`: the factory's engineer cannot run that skill; the sidecar keeps its current schema (version 2) and AC-8 checks the result with the tool.
- AC-8 is a manual check: `impeccable` is not in the repository or in CI, so no test of the layer can run it.
- AC-7 is a manual check: a test that compares the branch with `main` proves nothing once merged and breaks in a checkout without `origin/main`.
- AC-6's test asserts `generatedAt` is on or after 2026-10-11, not one fixed day: the build day is not known when the test is written.
- `colors` in the front matter holds the base theme (Charcoal) only: the 11 other themes set the same tokens and `scripts/test/theme.test.sh` already checks them; AC-5 ties their ids to the document.
- `.impeccable/surfaces/scripts-dashboard-html.md` stays as it is: it is the dated record of the direction chosen on 2026-10-09, not the sidecar, and AC-4 names the two files it covers.
- No follow-up issue is opened by this card: `## Known deviations` is the list, and the owner decides which ones are worth a card.
- The sidecar is `.impeccable/design.json`: the only file `.gitignore` keeps from `.impeccable/` besides `surfaces/`.
- The WIP limit for refinement reads 0, which is no limit, so the card was taken with 7 cards in Spec Review.

## Open questions
- none
