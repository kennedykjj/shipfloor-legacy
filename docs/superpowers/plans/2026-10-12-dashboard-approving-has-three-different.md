# Dashboard: approving has three different names — plan

**Issue:** #113 · **Spec:** `docs/superpowers/specs/2026-10-12-dashboard-approving-has-three-different-design.md` · **Date:** 2026-10-12

Copy only, in the page and its catalog. One layer, one task; no server code, no contract, no migration.

## Acceptance tests (QA, before the task)

- **Owner:** `qa-engineer`
- **File:** `scripts/test/dashboard-names.test.sh` (new). It reads `scripts/dashboard.html` and `scripts/lang/dashboard.pt-BR.json` as text, as `scripts/test/dashboard-page.test.sh` does, and covers AC-1 to AC-8.

## Task 1 — one name per decision on the three surfaces

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** the acceptance tests
- **Files:** `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`

In `scripts/dashboard.html`:

1. `optionsFor(c, d)`: in the Spec Review and the Staged branches, `t` and `verb` become "Approve" (id `approve`) and "Request changes" (id `request-changes`). `when`, `then`, `note`, `need`, `done` and the whole blocked branch keep their text (AC-1, AC-2, AC-3).
2. The option renderer that fills `#io` (the `.iopt` template): the heading text goes in its own span with an id, apart from the `<kbd>`; the button gets `aria-labelledby` that span and `aria-describedby` the ids of its when and then lines. Blocked options get the same wiring, text unchanged (AC-1 to AC-4).
3. `passHtml(c)`: "Review spec" becomes "Review" (still `data-open` and `data-go="review"`, no `data-q`); the `data-q="send"` pill reads "Request changes", followed by a `.hint` span with `→ <column>` before Cancel, tied to the pill with `aria-describedby` (AC-3, AC-4, AC-5).
4. `renderDecide`: `#approve` text and `data-label` become "Approve", `#request` becomes "Request changes"; each gets a `.hint` span with `→ <column>` (beside `#approve` and before `#approve-hint`; under `#request`), listed in the button's `aria-describedby` (`#approve`: destination span, then `approve-hint`). `syncDecide()` keeps "Approve with <doubt>" and restores `data-label` (AC-1, AC-2, AC-3, AC-4, AC-7).
5. CSS: `.decide-a .hint` widens to `.decide .hint, .edit .hint`; `.edit div` gets `flex-wrap: wrap`.
6. Untouched: `data-act`, `data-q`, `data-io`, the option ids, the `OWNER` column map, the POST actions and the keys A, R and 1 to 9 (AC-8).

In `scripts/lang/dashboard.pt-BR.json`:

7. Remove the exact entries "Review spec", "Approve and ship", "Approve the spec", "Build it", "Rewrite it", "Not yet" and the rx entries `^Approve → ` and `^Request changes → `.
8. Keep "Approve", "Request changes", "Review", "Send back to Coding" and rx `^Approve with (.*)$`. The secondary text `→ <column>` must show the column in pt-BR as the catalog already names it; add an rx only if the existing entries do not cover it (AC-6).

## Gates

After the task: `scope factory`, `acceptance-intact`, `migration`, `build`; then `green factory scripts/test/dashboard-names.test.sh`. Other tests that read the old names (for instance `scripts/test/dashboard-page.test.sh`) are updated in this task if the build shows them red.
