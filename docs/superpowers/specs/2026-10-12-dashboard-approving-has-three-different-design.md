# Dashboard: approving has three different names in the list, the decision box and the drawer — spec

**Issue:** #113 · **Branch:** `feat/113-dashboard-approving-has-three-different` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The owner's two decisions on a waiting card change name with the surface. Approving a Staged card is "Approve" (list), "Ship it" then "Approve and ship" (maximized decision box) and "Approve → Ready for Prod" (drawer); approving a spec is "Build it" then "Approve the spec" (box) and "Approve → Ready for Dev" (drawer); requesting changes is "Request changes", "Not yet"/"Rewrite it", "Send back to Coding" and "Request changes → Coding". It is the page's one irreversible decision and the owner has to reread the button each time.
**Audience:** The factory's owner, in a quick check of the dashboard (open, approve what waits, close).

**The names.** The decision is named **Approve** and **Request changes** (pt-BR: **Aprovar** and **Pedir mudanças**), for Spec Review and Staged cards alike, as the product context already names the owner's actions. The destination column is secondary text, never part of the name.

**Acceptance criteria**
- **AC-1** — Given a Staged card that waits for the owner, when the owner sees its approval in the list, in the maximized decision box (option heading and confirming button) and in the drawer, then each control's name is exactly "Approve".
- **AC-2** — Given a Spec Review card that waits for the owner, when the owner sees its approval in the maximized decision box (option heading and confirming button) and in the drawer, then each control's name is exactly "Approve".
- **AC-3** — Given a Staged or a Spec Review card, when the owner sees the request for changes in the list (the row's button and the button that sends the note), in the maximized decision box (option heading and confirming button) and in the drawer, then each control's name is exactly "Request changes".
- **AC-4** — Given any of those controls, when the destination column is shown, then it appears as secondary text beside or under the name (e.g. "→ Ready for Prod", "Goes to Ready for Prod."), outside the control's name, and the same column is shown on every surface that shows one.
- **AC-5** — Given a waiting card in the list, when the owner sees the button that opens its review, then it reads "Review" for a Staged and for a Spec Review card alike, and clicking it opens the review and approves nothing.
- **AC-6** — Given the dashboard in pt-BR, when the owner sees the controls of AC-1 to AC-5, then they read "Aprovar", "Pedir mudanças" and "Revisão" on every surface, with no English left and no second pt-BR name for the same decision.
- **AC-7** — Given a review with doubt (items not reviewed or changes asked), when the drawer's Approve is armed, then it still reads "Approve with <doubt>" ("Aprovar com <doubt>"), starting with the decision's name, and returns to "Approve" after the wait.
- **AC-8** — Given a card that the owner approves or sends back from any of the three surfaces, when the action is sent, then the card moves to the same column as before this change (Ready for Dev, Ready for Prod, Ready for Refinement or Coding) and the keys A and R do what they did.

**Out of scope:** The options of a blocked card ("The edits are right", "It needs rework", "Just try again" and their buttons), which are other decisions. The questions that head the box ("Build this spec?", "Ship it to production?") and the when/then sentences under an option. Adding an Approve button to a Spec Review row of the list. Layout, colors and the Approve pill's styling. The review page inside the iframe. Any language but English and pt-BR.
**Product fit:** Serves principle 4, "The owner acts only where the factory waits for the owner": the one place the owner acts must be recognizable at a glance. It also brings the page back to the product context, which names the owner-only actions "approve and request changes", and to DESIGN.md ("Approve with its destination"; "keep factory stage and column names verbatim"). No contradiction with the positioning or with what is out of scope.
**Touches UI:** yes

## UX
_UX/UI Designer_

The label is the control's whole text and its accessible name; the destination is a separate element tied to the control with `aria-describedby`, never inside it and never in an `aria-label`.

| Surface | Control | Label (en / pt-BR) | Secondary text (destination) |
|---|---|---|---|
| List, Staged row | Approve pill (`data-q="approve"`) | Approve / Aprovar | none (as today; the row then says "Moving to Ready for Prod") |
| List, Staged and Spec Review row | opener (`data-go="review"`) | Review / Revisão | none; it stays the pill in a Spec Review row |
| List, both rows | `data-q="changes"` | Request changes / Pedir mudanças | none |
| List, note editor | `data-q="send"` pill | Request changes / Pedir mudanças | `→ Coding` or `→ Ready for Refinement`, a span right after the pill, before Cancel |
| Maximized box, option heading (`.iopt .t`) | approve / request-changes option | Approve / Aprovar · Request changes / Pedir mudanças | the option's existing `.then` line ("Goes to Ready for Prod." / "Goes back to Coding with your note, …"), unchanged |
| Maximized box, confirm (`#igo`) | same two | Approve / Aprovar · Request changes / Pedir mudanças | none; the pressed option above it carries the line |
| Drawer (`#approve`) | approve | Approve / Aprovar | `→ Ready for Prod` or `→ Ready for Dev`, a span beside the button, before `#approve-hint` |
| Drawer (`#request`) | request changes | Request changes / Pedir mudanças | `→ Coding` or `→ Ready for Refinement`, a span under the button (beside it under 540px) |

- **Destination style:** the existing hint style (12.5px, `--muted`; widen `.decide-a .hint` to `.decide .hint, .edit .hint`), text `→ <column>` with the column name verbatim. No new component, no new token, no color on the arrow.
- **Accessible names:** list and drawer buttons take their name from their text. `#approve` gets `aria-describedby="<destination span> approve-hint"`; `#request` and the list's send pill point at their destination span. In the box, an option is one button that holds heading, key, when and then: wrap the heading text in its own span and set `aria-labelledby` to it and `aria-describedby` to the when/then lines, so its name is exactly "Approve" or "Request changes" (the blocked card's options get the same wiring with their own headings, text unchanged).
- **Armed approval (drawer):** `data-label` becomes "Approve"; armed, the button reads "Approve with <doubt>" / "Aprovar com <doubt>" for 4s, then "Approve" again. The destination span and the hint ("Click again to move it anyway.") stay where they are; soft styling, focus and timing unchanged.
- **Other states:** disabled, busy, the 5s Undo, notices and the keys A, R and 1 to 9 are unchanged; no new empty, loading or error state.
- **pt-BR, "Review":** the opener stays the noun **"Revisão"**, no verb form. It opens the drawer's tab of the same name ("Revisão") and sits beside "Log" and "Details", which also name the place they open; on a waiting card only the two decisions are verbs, which is what tells the owner this button decides nothing (AC-5). The catalog is keyed by the English text, so a verb would also need a second English string for the same word.
- **Catalog (`scripts/lang/dashboard.pt-BR.json`):** no new entry; "Approve", "Request changes", "Review", `^Approve with (.*)$` and the column names already cover every string above (`→ Ready for Prod` shows as `→ Pronto para produção`; Coding keeps its name, as in "Volta para Coding"). Remove the entries the page no longer writes: "Review spec", "Approve and ship", "Approve the spec", "Build it", "Rewrite it", "Not yet", `^Approve → ` and `^Request changes → `. Keep "Send back to Coding" (a blocked card's option).
- **Small screens:** under 540px the drawer's destination span wraps to its own line under the button (`.decide-a` and `.acts` already wrap); in the list, add `flex-wrap: wrap` to `.edit div` so the span drops under the pill instead of pushing Cancel out.

## Architecture
_Tech Lead_

Copy only, in the page and its catalog. No endpoint, event, server code or data changes; no migration.

**Contracts touched:** none. `POST` actions (`approve`, `request-changes`), the `OWNER` column map, `data-act`, `data-q`, `data-io` and the option `id`s keep their values; so do the A and R keys.

**Layer `factory`, files changed**
- `scripts/dashboard.html`
  - `optionsFor(c, d)` (decision box): in the Spec Review and Staged branches, `t` and `verb` become "Approve" and "Request changes". `when`, `then` ("Goes to <column>." stays the secondary text), `note`, `done` and the whole blocked branch are untouched.
  - The box's option renderer (the `.iopt` template that fills `#io`): the heading text gets its own span with an id, the button `aria-labelledby` it and `aria-describedby` the when/then lines; blocked options share the wiring, text unchanged.
  - CSS: the hint style widens to `.decide .hint, .edit .hint`; `.edit div` gets `flex-wrap: wrap` (see UX).
  - `passHtml(c)` (list): "Review spec" becomes "Review" (still `data-open` + `data-go="review"`, no `data-q`); the `data-q="send"` button reads "Request changes", with `→ <column>` in a secondary element outside the button's name.
  - `renderDecide` (drawer): `#approve` text and `data-label` become "Approve", `#request` becomes "Request changes"; `→ <column>` moves to a secondary element beside each, tied by `aria-describedby`. `syncDecide()` keeps "Approve with <doubt>" and restores `data-label`.
- `scripts/lang/dashboard.pt-BR.json`
  - Remove the entries no string of the page uses any more: exact "Review spec", "Approve and ship", "Approve the spec", "Build it", "Rewrite it", "Not yet"; rx "^Approve → ", "^Request changes → ".
  - Keep "Approve", "Request changes", "Review", "Send back to Coding" (a blocked card still uses it) and rx "^Approve with (.*)$". Add an rx for the secondary text only if its English wording needs one ("→ <column>" keeps the column name verbatim, so it needs none).
- `scripts/test/dashboard-names.test.sh` (new): reads the page and the catalog as text, as `scripts/test/dashboard-page.test.sh` does.

**Migration plan:** none; one commit, reverted by `git revert`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-names.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-names.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-names.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-names.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-names.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-names.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-names.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-names.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The names are "Approve" and "Request changes" (pt-BR "Aprovar", "Pedir mudanças"): PRODUCT.md and DESIGN.md already name the owner's actions this way, and both are in the catalog.
- In the decision box the option heading and the confirming button both take the name: two more names for one decision is the problem the issue reports.
- The destination column stays, as secondary text outside the control's name: the issue allows it and DESIGN.md asks for "Approve with its destination".
- The list's "Review spec" becomes "Review", as on a Staged row; no Approve button is added to a Spec Review row: a spec is read before it is approved, and that is a product change the issue does not ask for.
- "Approve with <doubt>" stays: it starts with the decision's name and is a state, not another name.
- A blocked card's options keep their names, "Send back to Coding" included: they are other decisions.
- Catalog entries that no string uses any more are removed, not left behind: a dead entry is a second pt-BR name waiting to come back.
- All ACs are checked by one static test that reads the page and the catalog as text: the page has no build and no browser runs in the pipeline; the server side of the moves is unchanged and already covered by `scripts/test/dashboard-quick.test.sh`.

## Open questions
- none
