# Dashboard: the accent marks a queue and an infrastructure block, and two stages share a blue — spec

**Issue:** #115 · **Branch:** `feat/115-dashboard-the-accent-marks-a-queue-and-a` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** In "In progress", a waiting tile writes its reason and draws its ring in the accent even when the card only queues or infrastructure failed, so the owner reads "this waits for you" where nothing does; the same infrastructure-blocked card is `warn` in the Lifecycle band. In Settings > Sessions, the pool bar draws Refine and Validate in two near-identical blues on Kraft, so the owner cannot read how the stages share the pool.
**Audience:** The factory's owner, in a quick check of the dashboard.
**Acceptance criteria**
- **AC-1** — Given a card queued for a stage or waiting for the pool, when its waiting tile is shown, then its reason, ring and every other mark are neutral (no accent, no outcome color).
- **AC-2** — Given a card blocked by infrastructure, when its waiting tile is shown, then its reason and ring are `warn`.
- **AC-3** — Given a card blocked by infrastructure, when the Lifecycle band is open, then the card's dot and number in the band and the marks of its tile are the same color.
- **AC-4** — Given any waiting tile in "In progress", when it is shown, then its marks use the accent only if its card waits for the owner (the cost aside, which is money).
- **AC-5** — Given the Kraft theme, when Settings > Sessions is open, then the Refine and Validate segments of the pool bar are told apart at a glance, and each matches its key.
- **AC-6** — Given any of the twelve themes (Floor tape included), when the pool bar is shown, then the four stage colors of the pool bar are four different colors, and none is the accent.
- **AC-7** — Given the change is shipped, when DESIGN.md is read, then the "In Progress" and Settings paragraphs describe the waiting tile and the pool bar as the page draws them (no "says why in the accent").
**Out of scope:** The wording of the waiting reasons; the tile's layout and dashed shape; the Lifecycle band's own colors; running tiles and the cost figure (money stays in the accent); the stage meters elsewhere, unless they share the pool bar's hues; a hue of its own for Deploy (it keeps `ok`); new themes.
**Product fit:** Serves principle 4, "The owner acts only where the factory waits for the owner": the accent is the page's one signal for that, and it must not fire on a queue or a retry. It restores DESIGN.md's Accent Rule and the "infrastructure trouble is `warn`" line; no conflict with the positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Flow:** nothing new to click. A waiting tile takes the kind the Lifecycle band already gives its card (`kindOf`, line 820): `tile wait` (queued, pool, paused, limits), `tile wait infra`, `tile wait you`. No new component, no new copy in either language (English, pt-BR), no layout change at any width; empty, loading and error states stay as they are.
- **Queued tile (AC-1):** ring hollow, `2px solid var(--muted)` (the band's `.dot.wait`); number and title stay `--muted`; the reason `.why` is `--soft`, one step above them so it still reads as the tile's statement. The dashed `--edge-hi` border and the cost in `--sand` (money) stay.
- **Infrastructure tile (AC-2, AC-3):** ring filled, background and border `--warn` (the band's `.dot.infra`: the state is carried by the fill too); number `.tnum` `--warn`; reason `--warn`; title stays `--muted`; border unchanged.
- **Owner tile (AC-4):** `.tile.wait.you` has the ring filled `--sand` and the number and reason in `--sand`. No card reaches it today (`renderWork` leaves the owner's cards to "Yours"); the list's filter does not change.
- **Just-changed waiting tile:** `.tile.wait.ch` takes a `--text` border instead of the accent's (`.tile.ch`, line 255), so no mark of a queued tile is `--sand`. Running tiles keep theirs.
- **Pool bar (AC-5, AC-6):** `STAGE_HUE.validate` becomes `var(--validate)`; Refine keeps `--refine`, Develop `--text`, Deploy `--ok` (the bar's one hue borrowed from the outcome trio, named as such in DESIGN.md; no `--deploy` token in this card). The key reads the same map, so each segment matches its key.
- **`--validate`, a violet-to-magenta in every theme** (never a blue, never the accent or an outcome hue): charcoal `#c896ec`, tape `#c896ec`, dock `#c896ec`, machine `#c896ec`, foundry `#c896ec`, terminal `#c896ec`, blueprint `#f06fe0`, night `#d98af5`, contrast `#e29bff`, kraft `#86389a`, steel `#9c2f8c`, paper `#a3277f`. Blueprint, steel and paper are magenta because their `--refine` is already violet; night sits halfway between its periwinkle `--refine` and its pink `--bad`.
- **Contrast of `--validate`:** at least 3:1 on `--edge` (lowest: contrast 3.3, kraft 3.9) and at least 4.5:1 on ground, panel and panel-hi (lowest: kraft 4.9 on ground). `scripts/test/theme.test.sh` adds `validate` to its 4.5:1 list and a 3:1 check of `refine`, `validate`, `text` and `ok` against `edge`.
- **DESIGN.md, Colors:** front matter gains `validate: "#c896ec"` after `refine`; "The 19 front matter entries" becomes 20; line 176 reads "**Refine** (`colors.refine`) and **Validate** (`colors.validate`): the hues of those two stages in the Settings pool bar, where Develop is `text` and Deploy is `ok`. Neither is the accent." The Themes token list (line 286) ends "`refine`, `validate`".
- **DESIGN.md, In Progress (line 253, AC-7):** the last sentence becomes "A waiting tile is dashed, with no fill, its number and title in `muted`, and says why in plain words ("Waiting for the pool · 4 of 4 busy"). Its ring and reason follow the Lifecycle band: hollow `muted` and `soft` when the card only queues, filled `warn` with the number and reason in `warn` when infrastructure failed, and the accent only on a tile that waits for the owner. The cost stays in the accent, as money."
- **DESIGN.md, Settings (line 280, AC-7):** "A pool bar shows how the stages share the sessions, one hue per stage with a key under it (Refine `refine`, Develop `text`, Validate `validate`, Deploy `ok`; the share no stage uses is the hairline), and warns when they ask for more than the pool allows."

## Architecture
_Tech Lead_

- **Contracts:** none touched. No endpoint, event, config key or copy changes; `/api/overview` already carries `blocked`, `awaiting` and `running`, which is all `kindOf` reads.
- **Layer:** `factory` only. No migration.
- **`scripts/dashboard.html`, CSS:**
  - New color token `--validate`, set in the base block (`:root, [data-theme="charcoal"]`) and in each of the other eleven theme blocks, with the values of `## UX`.
  - `.ring`: `border: 2px solid var(--muted)`; `.why`: `color: var(--soft)`.
  - `.tile.wait.infra`: `.ring` filled and bordered `--warn`; `.tnum` and `.why` in `--warn`.
  - `.tile.wait.you`: `.ring` filled and bordered `--sand`; `.tnum` and `.why` in `--sand`.
  - `.tile.wait.ch`: `border-color: var(--text)`, after `.tile.ch` so it wins.
- **`scripts/dashboard.html`, JS:**
  - `renderWork`: the waiting tile's class is `tile wait` plus `infra` or `you` when `kindOf(key(c), c)` returns that kind; every other kind adds nothing. The `waits` filter does not change.
  - `STAGE_HUE.validate` becomes `"var(--validate)"`. The bar and its key already read the same map.
- **`DESIGN.md`:** front matter `colors.validate: "#c896ec"`; the count of front matter entries; the Refine line, the "In Progress" sentence, the Settings pool bar sentence and the Themes token list, as worded in `## UX`.
- **`.impeccable/design.json`:** `colorMeta.validate` (`role: secondary`, `displayName: Validate Stage`, `canonical: #c896ec`) and `generatedAt` set to the day of the change.
- **Tests (existing files extended, one new):**
  - `scripts/test/dashboard-accent.test.sh` (new, static, reads the page as text like `dashboard-narrow.test.sh`): which token each mark of `.tile.wait`, `.tile.wait.infra`, `.tile.wait.you` and `.tile.wait.ch` resolves to; that the infra tile's ring, number and reason use the token of `.dot.infra`; that `renderWork` takes the class from `kindOf`.
  - `scripts/test/theme.test.sh`: `validate` joins the 4.5:1 list; `refine`, `text`, `validate` and `ok` are held to 3:1 on `edge`; per theme, the four `STAGE_HUE` tokens resolve to four colors at least 20 apart (CIE76 ΔE, stdlib only) and none equals `sand`.
  - `scripts/test/design-doc.test.sh`: the retired sentence "says why in the accent" is gone and the pool bar sentence names `validate`; its existing AC-3 already fails until `colors.validate` matches the page.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-accent.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-accent.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-accent.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-accent.test.sh` |
| AC-5 | factory | `scripts/test/theme.test.sh` |
| AC-6 | factory | `scripts/test/theme.test.sh` |
| AC-7 | factory | `scripts/test/design-doc.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Deploy keeps `ok` in the pool bar: the issue asks only to tell Refine and Validate apart, and a `--deploy` token would need a free hue in twelve themes.
- Validate gets its own token `--validate` instead of a new Refine value: Validate was drawn in the accent, which the Accent Rule forbids for a stage; Refine stays as it is.
- The pool bar is held to all twelve themes, not only Kraft and Floor tape: one token per theme is the same change, and a fix for two themes leaves the collision in the others.
- "Waiting for a slot", "Waiting for the pool", "Paused" and the limit reasons are neutral like "Queued": none of them waits for the owner on this card.
- The waiting tile takes its kind from `kindOf`, the band's own source: one rule for both places, so the band and the tile cannot drift apart again.
- The infrastructure tile's number is `warn`, like the band's label; its title stays `muted` like every waiting tile.
- A just-changed waiting tile gets a `text` border instead of the accent's: the accent border is a mark of the tile, and AC-1 allows none.
- The `.tile.wait.you` style is written though no card reaches it today: AC-4 stays true if the list's filter ever changes.
- "Told apart" is measured as CIE76 ΔE ≥ 20 between any two stage hues of a theme: a static test needs a number, and Kraft's old pair (accent and Refine, two blues) falls well under it.
- The `--validate` values were computed by hand (the refinement session could not run Python): the extended `theme.test.sh` is their first tool check, and a value that fails it is moved in lightness, keeping its hue.
- No screenshot test: the layer has no browser; the colors are checked as tokens, and the look on Kraft and Floor tape in validation's UX review on the demo stack.
- DESIGN.md and `.impeccable/design.json` change in the same card: `design-doc.test.sh` fails when the page has a color the front matter lacks.

## Open questions
- none
