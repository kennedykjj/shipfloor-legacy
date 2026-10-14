# [UX-05] The decision brief on today's screen — spec

**Issue:** #179 · **Branch:** `feat/179-ux-05-o-resumo-da-decisao-na-tela-de-hoj` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** To approve or send back a Spec Review or Staged card, the owner has to read the tabs and reconstruct what matters. The decision brief (`brief.json`, produced by #178) already says it: the verdict, what is being approved, what needs a look, what changed since the last request, what the gates proved. Today's dashboard does not show it. Most of the speed gain is in that content, so it should not wait for the redesign (#27–#31).

**Audience:** The factory's owner, during a quick check of the cards waiting for them.

**Acceptance criteria**
- AC-1: Given a Spec Review or Staged card that has a `brief.json`, when the owner opens its drawer, then the brief appears above the tabs, starting with the verdict pill (`ok` color for routine, accent for look / since_request).
- AC-2: Given a Spec Review or Staged card without a `brief.json` (or one that cannot be read), when the owner opens its drawer, then the drawer looks and works exactly as it does today.
- AC-3: Given a brief, when it is rendered, then each block (what you approve, needs your eyes, since your request, what the gates proved, the rest (N)) appears only if it has content, and "the rest" starts folded.
- AC-4: Given a `routine` brief, when the drawer opens, then it shows the verdict, what you approve, the gates proved and the folded rest, and no "needs your eyes" or "since your request" block.
- AC-5: Given any brief block with text written by an agent or computed by the factory, when it is rendered, then its origin chip (written by the product owner / review agent, flagged by the gates, diff computed, computed not claimed) is always shown with it.
- AC-6: Given a brief with flags, when the owner clicks a flag's suggestion button next to "Use the review's N changes", then the request-changes note is filled with that suggestion and nothing is sent.
- AC-7: Given a card in "Yours" with a brief, when the owner looks at the list, then the card's row shows a one-word verdict (`routine` / `1 point`); without a brief the row is unchanged.
- AC-8: Given the dashboard in a language other than English, when the brief's labels render, then they come from new keys in `scripts/lang/dashboard.<code>.json` with English text, and missing translations fall back to English.

**Out of scope:** producing or changing `brief.json` (#178); the new visual system and workspace layout (#27–#31), which will reuse the isolated brief renderer; translating the new keys into languages other than English; any new owner action beyond filling the note.

**Product fit:** Serves principle 4 (the owner acts only where the factory waits for them, and faster there) and principle 2: gate facts are labeled "computed, not claimed" and agent text never appears without its origin, which is the positioning (gates hold, not the agents' word). Read-only: the dashboard keeps no card state (principle 1).

**Touches UI:** yes

## UX
_UX/UI Designer_

- **Flow:** the owner opens a Spec Review or Staged card (Review tab, wide drawer) → reads the brief in `#d-decide`, inside the decision group, above the "Your decision" row → approves, or clicks a flag's suggestion, edits the note and clicks Request changes. The brief is in place whatever tab is open, like the decision.
- **Order inside the brief:** verdict row (pill + one muted line) → What you approve → Needs your eyes → Since your request → What the gates proved → `<details>` The rest (N), closed. A block with no content is left out entirely, caption included (AC-3/AC-4).
- **Verdict pill:** the existing `.tag`, recolored by token only: `routine` with `ok` text and border; `look` / `since_request` with `sand` (owner-waits accent, per the Accent Rule). Its text carries the meaning, so color is never the only cue.
- **Blocks:** caption = the existing `.isec h3` caption style (12px, uppercase, tracked, `muted`); body = Body 14px in `soft`; items as a plain `ul`. Separated by a `--hair` hairline and `spacing.sm` (10px). Gates proved reuses the Gates tab's outcome mapping (`ok` / `bad` / `muted`), with the label in words beside each color.
- **Origin chip:** a plain `.tag` (muted, never colored) right after each block's caption, always rendered with the block (AC-5). Agent and factory text inside a block uses the `RAW` selector so the catalog never rewrites it.
- **Flag suggestion:** a `.btn.ghost` per flag in the Needs your eyes block, the same as `#fill`. On click it fills `#changes`, unfolds it in a narrow drawer, focuses it with the cursor at the end, and writes the notice (polite). Nothing is sent and Approve stays as it is (AC-6).
- **Yours row (AC-7):** inside the row's `.cap` meta, after the age: `· routine` in `ok`, or `· 1 point` / `· N points` in `sand`. No new element. With no brief, the row is unchanged.
- **States:** no brief, or an unreadable one → nothing is rendered: no placeholder and no error (AC-2). Loading → the brief appears when the card is read (the 5s card poll), with no skeleton. The `<details>` open state is kept in `S`, per card, so a refresh does not fold it again. Success after a fill → the notice line.
- **Small screen:** the drawer is full width under 860px. Under the 540px container size, the verdict row wraps (pill, then line), chips wrap under their caption, and suggestion buttons take the full width (24px minimum target). The rest stays folded.
- **Copy (en; new keys in `scripts/lang/dashboard.<code>.json`; other languages fall back to English):** captions `What you approve`, `Needs your eyes`, `Since your request`, `What the gates proved`, `The rest ({n})`. Pill: `routine`, `1 point`, `{n} points`. Chips: `written by the product owner`, `written by the review agent`, `flagged by the gates`, `diff computed`, `computed, not claimed`. Button: `Use this point`, with title `Fills the note. Nothing is sent.` Notice: `Note filled from #{n}'s brief. Nothing was sent.` Group label for screen readers: `Decision brief`.

## Architecture
_Tech Lead_

**Contract read (owned by #178, not changed here):** `<reviews>/<n>.brief.json` with `verdict` (`routine`|`look`), `what` (+ origin), `flags[]` (`id`, `title`, `detail`, `diff?`, `suggestion?`), `since_request[]` (old/new statements, `new` marker), `proven[]` (gate names), `facts`, `rest[]`. The format is not in the repo yet; the reader is defensive: any missing or mistyped field drops that block, an unparseable file counts as no brief.

**Layer `factory` only.** Files:
- `scripts/dashboard.py`: `card()` adds `brief` (the parsed file, or `null` when missing, unreadable or not an object); the overview's per-card dict adds `verdict` (`routine`/`look`/`null`) and `flags` (count) for cards in `AWAITING`. A small `brief(p, n)` helper reads and validates the shape; a read failure never raises.
- `scripts/dashboard.html`: isolated pure function `briefHTML(brief)` (returns `""` for no brief; no globals except `t`/`esc`), called from `renderDecide` inside `.decide`, above the decision row, only when `S.card.brief` is set; `<details>` open state kept in `S` per card; a `data-suggest` click handler fills `#changes` (unfolds, focuses, no send) and sets the notice; `passHtml` appends the one-word verdict to the row's `.cap`. New CSS reuses today's tokens.
- `scripts/lang/dashboard.en.json` and the 11 other `dashboard.<code>.json`: new `brief.*` and `pass.verdict.*` keys. `dashboard-catalog.test.sh` requires every catalog to carry every English key, so the other 11 get the English text now (they read as English until translated).
- `scripts/test/dashboard-brief.test.sh`: new test.

No migration, no new endpoint, no change to the producer.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-brief.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-brief.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-brief.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-brief.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-brief.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-brief.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-brief.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-catalog.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- **Weight heavy:** one layer, but more than 8 files (the 12 catalogs).
- **Brief format:** #178 is still open, so the reader follows the issue text and ignores anything it does not recognise; if #178 lands with other field names, the reader adjusts in develop.
- **Catalogs:** the issue says other languages fall back to English; the catalog test demands the same keys everywhere, so the English text is copied into each catalog (same visible result, no test change).
- **Brief placement:** above the decision row inside `#d-decide` (UX); Approve moves down a little once the card loads, accepted over a placeholder.
- **Yours verdict:** the server adds `verdict`/`flags` to the overview so the list needs no per-card fetch.
- **Tests:** new `dashboard-brief.test.sh` covers AC-1 to AC-7 (server cases by fixture, `briefHTML` run in node when present, as `dashboard-glance`); AC-8 stays in the existing catalog test.

## Open questions
- none
