# [UX-03] Incremental re-review: when a card comes back, the owner reads only what changed — spec

**Issue:** #177 · **Branch:** `feat/177-incremental-re-review` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** when the owner requests changes and the card comes back to Spec Review, the second read costs as much as the first, because the review page does not say what changed since the owner's last decision.
**Audience:** the factory's owner, approving or sending back Spec Review cards from the dashboard.
**Acceptance criteria**
- **AC-1** — Given a card on its first Spec Review, when its review page is built, then no statement carries a mark and no "changed since" summary appears.
- **AC-2** — Given a card back in Spec Review whose spec differs from the version the owner read, when the page is built, then every statement is marked new, changed or untouched against that version, and statements that were removed are listed as removed.
- **AC-3** — Given a card back in Spec Review, when the page is shown, then the top reads "N statements changed since your request" (N counts new, changed and removed) and quotes the owner's request; with no request available it shows only the count.
- **AC-4** — Given a card back in Spec Review, when the page is shown, then untouched statements remain visible but visually demoted relative to marked ones.
- **AC-5** — Given a card back in Spec Review with a spec identical to the version the owner read, when the page is built, then every statement is untouched and the summary says 0 statements changed.
- **AC-6** — Given the dashboard in light or dark theme and in en or pt-BR, when a returned card's page renders, then marks and summary follow that theme and language, and other languages show the English labels.
- **AC-7** — Given two spec files, when a script runs `review-page.sh --diff <old.md> <new.md>` (or calls `statement_diff`), then it gets JSON entries `{section, status, old, new}` with status `new` | `changed` | `untouched` | `removed`, and no page is written.
**Out of scope:** the Staged page highlighting commits and files changed since the owner's last review (no PR review page exists to extend; follow-up card); the `since_request` field of `<n>.brief.json` (#178 consumes AC-7); marks for cards already in flight before this ships (they count as a first review).
**Product fit:** serves principle 4 (the owner acts only where the factory waits for the owner) by cutting the owner's second read to the delta. Dropping the Staged half narrows the issue's proposal but contradicts no principle or positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Flow:** the owner opens a returned card on Review, reads the summary at the top, then the marked statements, and skims the demoted ones. The Keep / Change buttons, the reviewed count and Copy review work as they do today on every row except removed ones.
- **Summary:** the first `section.sheet` of `main`, not `header.top`, because the embed hides the header. Its `h2` holds the count, then the request comes in a `.res` block (left rule in `--muted`, `white-space:pre-wrap`, `max-width:72ch`) under a 12px uppercase `--muted` caption. With no request there is no caption and no block, only the `h2`.
- **Marks:** a tag at the start of the statement's `<p>` (12px, 600, uppercase, `--surface` fill, 1px `--rule` border, 4px radius, `--ink` text), reading New or Changed. It uses only the variables the dashboard themes (`page`, `sheet`, `surface`, `ink`, `muted`, `rule`), so it follows all 12 themes. Do not use `--gold`, `--chg` or `--ok`: those colors already mean the owner's Keep / Change and the accent. The word carries the state, not a color.
- **Changed:** under the text, the previous version sits in the existing `details.ro` fold, closed by default.
- **Untouched (demoted):** `.item.same p{color:var(--muted)}`, with no tag and the buttons unchanged. Demote by color, never by opacity, so the text keeps 4.5:1 in every theme.
- **Removed:** after the section's current statements, a row with a Removed tag and its text in `--muted` with `line-through`. It has no buttons and does not count toward "N of M reviewed".
- **Index (nav):** unchanged. The marks live in the sheets only.
- **Small screen (<520px):** `.item` already stacks to one column. The tag wraps inline with the text, and the summary sheet and quote take the full width. Nothing scrolls sideways at 360px.
- **States:** a first review shows no summary and no tags (AC-1). An identical spec shows the summary with 0 and every row demoted (AC-5). There is no loading or error state: the page is static.
- **Copy, en:** `N statements changed since your request` · `1 statement changed since your request` · caption `Your request` · tags `New`, `Changed`, `Removed` · fold `Before`.
- **Copy, pt-BR:** `N afirmações mudaram desde o seu pedido` · `1 afirmação mudou desde o seu pedido` · caption `Seu pedido` · tags `Nova`, `Alterada`, `Removida` · fold `Antes`. Other languages show the English (AC-6).

## Architecture
_Tech Lead_

- **Contract:** `review_page.statement_diff(old_text, new_text) -> list[{section, status, old, new}]`. Statements are the ones `build` already extracts, keyed by section id. Matching per section: identical text = `untouched`; otherwise the i-th unmatched old statement in the same section pairs with the i-th unmatched new one = `changed`; leftover new = `new`; leftover old = `removed`. The section's statements are first parsed by extracting `build`'s parsing into `parse_statements(text)` (same output as today, so the page is unchanged for a first review).
- **Baseline ("the version the owner read"):** each build writes `<reviews>/<n>.published.md` (a copy of the spec). If it exists and differs from the spec being built, it is first rotated to `<reviews>/<n>.read.md`; the diff is against `<n>.read.md`. Building the same spec twice changes nothing; a first review has no `.read.md`, so no marks.
- **Owner's request:** the page quotes the latest "Spec review" comment from the issue, passed by the caller as optional `--request-file <path>` to `review-page.sh` (refine writes it to `<tmp>`); absent means the summary shows only the count.
- **CLI:** `review-page.sh <spec> <issue> <branch> <out.html> [--request-file F]` and `review-page.sh --diff <old.md> <new.md>` (JSON on stdout). `sf.py` dispatch unchanged apart from passing arguments through.
- **Page:** `scripts/review-template.html` receives the marks in `__DATA__` (a `mark` per item) and a `__SINCE__` summary; untouched rows get a demoted class using existing theme variables. Labels use `rv.*`-style keys added to `scripts/lang/dashboard.en.json` and `dashboard.pt-BR.json` (other catalogs fall back to English); the page receives them by the same path the dashboard uses to give it its theme (`scripts/dashboard.py`).
- **Files:** `scripts/shipfloor_core/review_page.py`, `scripts/review-page.sh`, `scripts/review-template.html`, `scripts/dashboard.py`, `scripts/lang/dashboard.en.json`, `scripts/lang/dashboard.pt-BR.json`, `skills/refine/SKILL.md` (pass the request file and describe the baseline), `scripts/test/review-diff.test.sh`.
- **Migration:** none; no baseline files exist yet, so every card currently in flight is treated as a first review.

## Test plan
_Tech Lead_

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/review-diff.test.sh` |
| AC-2 | factory | `scripts/test/review-diff.test.sh` |
| AC-3 | factory | `scripts/test/review-diff.test.sh` |
| AC-4 | factory | `scripts/test/review-diff.test.sh` |
| AC-5 | factory | `scripts/test/review-diff.test.sh` |
| AC-6 | factory | `scripts/test/review-diff.test.sh` |
| AC-7 | factory | `scripts/test/review-diff.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
- Baseline is a spec copy under `<reviews>` rotated on build, because the owner's decision happens in the dashboard and the builder is the one place that sees every published version.
- A statement is "changed" by position within its section when its text differs, because statements have no stable ids and positional pairing keeps the diff deterministic.
- Staged page is out of scope: the repo has no PR review page to extend; recorded as a follow-up.
- Labels ship in the en and pt-BR catalogs only, others fall back to English, to keep the change small.
- The quoted request is passed in by the caller, so `review_page.py` stays offline (no `gh` calls).

## Open questions
- **Staged scope:** A (recommended) ship Spec Review now and open a follow-up card for the Staged page, or B keep Staged in this card — B needs a new PR review page first and roughly doubles the size.
