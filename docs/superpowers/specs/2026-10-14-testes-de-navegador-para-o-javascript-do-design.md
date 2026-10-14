# Browser tests for the dashboard JavaScript (Playwright), replacing the text searches — spec

**Issue:** #234 · **Branch:** `feat/234-testes-de-navegador-para-o-javascript-do` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** standard

## Product
_Product Owner_

**Problem:** The dashboard's ~2,500 lines of JS have no behavior tests; the ~500 text-search assertions that stood in for them are being removed (test diet pass 2), so a broken owner flow would ship unnoticed.
**Audience:** The factory's owner (and developers who install the plugin), who rely on the dashboard to approve and move their cards.
**Acceptance criteria**
- **AC-1** — Given a real `dashboard.py` serving a fixture home, when the browser suite opens the token link, then the dashboard loads; with an invalid token, then the expired-link screen shows.
- **AC-2** — Given fixture cards waiting for the owner, when the suite opens the dashboard, then the waiting list shows them in the expected order and opening one shows the Review / Gates / Sessions / Log tabs.
- **AC-3** — Given an owner-movable card, when the suite moves it by drag and by keyboard, then the move commits after the 5 s delay, undo within the delay cancels it, and a refused move shows its reason.
- **AC-4** — Given Spec Review cards, when the suite requests changes with a note and approves a spec, then each action reaches the dashboard API with its note/target.
- **AC-5** — Given the dashboard, when the suite switches language and theme and reloads, then the choices persist: the theme in localStorage, the language in the factory's `config.yml` (shown as `<html lang>`); at a phone-width viewport the page has no horizontal scroll.
- **AC-6** — Given CI, when it runs, then the browser suite runs headless Chromium as a shard or separate job in under 1 minute, and Playwright is absent from the factory's runtime dependencies.
**Out of scope:** Screenshot/visual tests; per-string catalog tests (the catalog consistency test covers them); any change to dashboard behavior or UI.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): owner flows are proven by an executable check, not by text matching. Keeps the stack promise (no build, no framework at runtime) since Playwright is test-only.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Contracts touched:** none. `scripts/dashboard.py` and `scripts/dashboard.html` are not changed; the suite drives the existing page and API (`GET /?t=`, `/api/overview`, `/api/card/<p>/<n>`, `POST /api/card/<p>/<n>/{move,approve,request-changes}`).

**Layer:** `factory` only (all files under `scripts/test/`).

**Files**
- `scripts/test/py/dashboard_browser.py` (new): unittest suite on Playwright's sync API, headless Chromium. One `setUpClass` builds the fixture home with `demo_home.py` (busy project `atlas`: cards waiting for the owner, Spec Review, blocked, logs, reports) and serves it with one in-process `dashboard.Server` in a thread (as `dashboard_support.server()` does), `gh` pointed at `scripts/test/demo-gh`, a fixed token. One browser for the class, a fresh context per test. About 6 flow tests, one per AC-1..AC-5 (AC-3 drag + keyboard + refused move may be 2).
- `scripts/test/dashboard-browser.test.sh` (new): thin driver like `dashboard-views.test.sh`; runs the module with `BROWSER_PYTHON` (default `$FACTORY_PYTHON`) so Playwright can live in a test-only venv.
- `scripts/test/requirements-browser.txt` (new): pinned `playwright==<current>`; the only place Playwright is named. Install: `pip install -r scripts/test/requirements-browser.txt && python -m playwright install --with-deps chromium`.
- `scripts/test/py/run.py` (change only if needed): the existing "skipped" line is reused; no new runner.

**Behavior**
- Playwright not importable → every test is skipped with the reason "playwright not installed", unless `BROWSER_TESTS=required` → one `FAIL` line. The CI job sets `required`; the other shards skip.
- The 5 s move delay and undo use Playwright's clock (`page.clock.install` / `fast_forward`), never a real 5 s wait, to keep the suite under 1 minute.
- Each action is asserted on observable results: the gh stand-in's recorded calls / the board state after reload, the rendered tabs, the `localStorage` theme key, the language in `config.yml` and `<html lang>`, `document.documentElement.scrollWidth <= innerWidth` at 375 px.
- No assertion on catalog text beyond locating elements; locators prefer roles, `data-*` and ids already in the page.

**CI:** a `browser` job in `.github/workflows/ci.yml` (Python 3.11, install from `requirements-browser.txt`, `BROWSER_TESTS=required bash scripts/test/run.sh dashboard-browser.test.sh`, `timeout-minutes: 5`) and listed in the `test` job's `needs`. `.github/` is out of the pipeline's reach: done by the owner by hand (see Open questions).

**Migration:** none.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-2 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-3 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-4 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-5 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-6 | manual | the PR's CI run: `browser` job green in under 1 min; Playwright named only in `scripts/test/requirements-browser.txt` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Python Playwright, not Node: the stack is Python, and the suite reuses the in-process server pattern of `dashboard_support.py`; no `package.json` in the repo.
- New suite file `dashboard_browser.py`: no existing suite drives a browser, and the Playwright import and skip rule must stay out of the API suites.
- Fixture from `demo_home.py` + `demo-gh`: it already draws every card kind the owner flows need; no second fixture to maintain.
- Skip when Playwright is absent, required in CI: keeps `run.sh` green on machines and shards without a browser while the CI job proves the flows.
- Fake clock for the 5 s delay: real waits would break the 1-minute budget.
- owner: language lives in config.yml, not localStorage — it is a factory setting, shared by the dashboard and the agents' output; AC-5 tests the theme in localStorage and the language in `config.yml` / `<html lang>`.
- One test file slot for `dashboard-browser.test.sh` under the hygiene ceiling: `dashboard-settings.test.sh` folded into `dashboard-views.test.sh` (both thin `py_suite` drivers of the dashboard API).
- AC-6 checked by hand in review: CI wall time and the job definition are not observable from inside the suite.

## Open questions
- **CI job:** owner adds the `browser` job to `.github/workflows/ci.yml` by hand (recommended) or leaves the suite local-only — the pipeline cannot edit `.github/`; without it CI never runs these tests.
- **Playwright on the factory machine:** owner installs `requirements-browser.txt` + Chromium here before Ready for Dev (recommended) or not — without it the suite only skips, and develop cannot prove the acceptance tests red then green.
