# Plan — incremental re-review (#177)

Spec: `docs/superpowers/specs/2026-10-14-incremental-re-review-design.md`. Single layer: `factory`. The Staged half is out of scope (spec's open question, option A).

## Tasks

1. **factory / engineer — statement diff, baseline and the marked page.** Depends on: QA's acceptance test (red first).
   - `scripts/shipfloor_core/review_page.py`: extract the parsing in `build` into `parse_statements(text)` (same sections and items as today, so a first review renders exactly as before); add `statement_diff(old_text, new_text)` returning `[{section, status, old, new}]` with per-section, positional pairing (identical = `untouched`, i-th unmatched old with i-th unmatched new = `changed`, leftovers `new` / `removed`).
   - Baseline: each build keeps `<out dir>/<n>.published.md`; when it exists and differs from the spec being built, rotate it to `<n>.read.md` first; diff against `<n>.read.md` when present. Building the same spec twice changes nothing.
   - CLI: `review-page.sh <spec> <issue> <branch> <out.html> [--request-file F]` and `review-page.sh --diff <old.md> <new.md>` (JSON on stdout, no page written). `scripts/review-page.sh` stays a thin shim.
   - `scripts/review-template.html`: a `mark` per item in `__DATA__` and a `__SINCE__` summary sheet (first `section.sheet` of `main`: count `h2`, then `Your request` caption + `.res` quote when a request exists); `New` / `Changed` tags, `Before` fold for the previous text, `.item.same` demoted by color, removed rows struck through with no buttons and outside the reviewed count. Theme variables only (`page`, `sheet`, `surface`, `ink`, `muted`, `rule`).
   - Labels: `rv.*` keys in `scripts/lang/dashboard.en.json` and `scripts/lang/dashboard.pt-BR.json` (other languages fall back to English); `scripts/dashboard.py` hands them to the embedded page alongside its theme.
   - `skills/refine/SKILL.md`: on a rework, write the latest "Spec review" comment to `<tmp>` and pass it as `--request-file`; describe the baseline files under `<reviews>`.
   - Files: `scripts/shipfloor_core/review_page.py`, `scripts/review-page.sh`, `scripts/review-template.html`, `scripts/dashboard.py`, `scripts/lang/dashboard.en.json`, `scripts/lang/dashboard.pt-BR.json`, `skills/refine/SKILL.md`.

QA writes `scripts/test/review-diff.test.sh` (AC-1 to AC-7) before task 1; the engineer does not edit it.
