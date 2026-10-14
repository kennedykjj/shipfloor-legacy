# Plan — browser tests for the dashboard JavaScript (#234)

Spec: `docs/superpowers/specs/2026-10-14-testes-de-navegador-para-o-javascript-do-design.md`

## Tasks

### T1 — layer `factory`, owner: engineer
Make the acceptance tests in `scripts/test/py/dashboard_browser.py` (written by QA) pass:
- add `scripts/test/dashboard-browser.test.sh`, the thin driver (like `dashboard-views.test.sh`), running the module with `BROWSER_PYTHON` (default `FACTORY_PYTHON`);
- add `scripts/test/requirements-browser.txt` with the pinned `playwright==<current>`, the only place Playwright is named;
- touch `scripts/test/py/run.py` only if the "skipped" line needs it.
- No change to `scripts/dashboard.py` or `scripts/dashboard.html`.

Dependencies: QA's tests first. Files: `scripts/test/dashboard-browser.test.sh`, `scripts/test/requirements-browser.txt`.

AC-6 (CI job in `.github/workflows/ci.yml`) is the owner's, by hand; the pipeline cannot edit `.github/`.
