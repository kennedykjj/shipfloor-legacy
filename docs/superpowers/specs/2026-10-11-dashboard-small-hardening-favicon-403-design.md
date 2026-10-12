# Dashboard: small hardening (favicon 403, Unicode digits, --faint contrast) — spec

**Issue:** #7 · **Branch:** `feat/7-dashboard-small-hardening-favicon-403` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** Every dashboard load logs a 403 for `/favicon.ico` in the browser console; card-number route segments accept non-ASCII digits, so a crafted URL serves the wrong card or crashes the request (500 on GET, dropped connection on POST); and the text contrast that was fixed on main (4.5:1 in all 12 themes, tightest 4.55) has nothing holding it there.
**Audience:** The factory's owner and other developers who install the plugin, using the dashboard in quick checks.
**Acceptance criteria**
- **AC-1** — Given the dashboard is running, when a browser requests `GET /favicon.ico` without a token, then it answers 204 with an empty body.
- **AC-2** — Given the owner opens the dashboard with a valid token, when the page finishes loading, then the browser console shows no failed request for the favicon.
- **AC-3** — Given a valid token and an existing card 12, when `GET /api/card/<project>/١٢` (percent-encoded Arabic-Indic digits) is requested, then it answers 404 and no card data is returned.
- **AC-4** — Given a valid token, when any GET route that takes a card number (`/api/card`, `/api/decide`, `/api/live`, `/review/<project>/<n>`) receives a segment that passes `isdigit()` but is not `[0-9]+` (e.g. `²`), then it answers 404, never 500.
- **AC-5** — Given a valid token, when `/api/log` is requested with a `from` value that is not `[0-9]+` (e.g. `²` or `١٢`), then it answers exactly as it does today for a non-numeric `from` (e.g. `abc`), never 500.
- **AC-6** — Given a valid token, when `POST /api/card/<project>/<n>/<action>` is sent with a card number that is not `[0-9]+`, then it gets a 404 response (the connection is not dropped) and no card moves on the board.
- **AC-7** — Given a valid token, when the same routes receive plain ASCII card numbers, then they behave as before (card 12 is served for `12`).
- **AC-8** — Given the theme tokens in `scripts/dashboard.html`, when the test suite runs, then it fails if `--soft`, `--muted` or `--faint` falls below 4.5:1 on `--panel` or `--ground` in any theme, and passes on today's values.
**Out of scope:** Any CSS or color change (contrast already meets AA on main); a real favicon image or `<link rel="icon">` artwork; contrast of non-text tokens (accents, borders, status colors); changing the token check for any other path; hardening of non-numeric segments (project names, actions).
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): the contrast fix stops being a claim in an issue comment and becomes a check, with only 0.05 of margin on the tightest theme. Also principle 1: a URL must name exactly the card the board names, so `١٢` must not resolve to card 12. Stays within local-only; no contradiction with the positioning. Unlike the rest of the dashboard, `/favicon.ico` answers without a token; that is acceptable because the answer carries no data.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. Files: `scripts/dashboard.py` (change), `scripts/test/dashboard.test.sh` (change). No new file, no migration, no change to `scripts/dashboard.html`.

**Contracts touched** (all in `Handler`, `scripts/dashboard.py`)
- `GET /favicon.ico` — new: answered before the token check, `204`, no body, `Content-Length: 0`, `Cache-Control: no-store`. Every other path keeps the token check.
- `GET /api/card/<project>/<n>`, `/api/decide/<project>/<n>`, `/api/live/<project>/<n>`, `/review/<project>/<n>` — `<n>` must match `[0-9]+`; anything else is `404 {"error": "not found"}`. Response fields unchanged.
- `GET /api/log/<project>/<name>?from=<start>` — `from` is used only when it matches `-?[0-9]+`; anything else means `-1` (the last 64 KiB), as `abc` does today.
- `POST /api/card/<project>/<n>/<action>` — `<n>` must match `[0-9]+`; anything else is `404 {"error": "not found"}` before the body is read and before any board call.

**Shape**
- One module-level helper, `number(s)`: true when `re.fullmatch(r"[0-9]+", s)`. It replaces every `.isdigit()` in `do_GET` and `do_POST`; the `from` query uses `re.fullmatch(r"-?[0-9]+", start)`.
- The three `.isdigit()` calls that parse files the factory writes (`cache`, `stack status`: lines 205, 281, 282) move to the same helper, so one stray character in a file is skipped instead of raising.
- The favicon branch sits beside the `url.path == "/"` branch in `do_GET`; `send()` is reused with empty bytes.
- Contrast check: a Python block in `scripts/test/dashboard.test.sh` reads `scripts/dashboard.html`, takes every rule that declares `--ground` (the default and each `[data-theme]`), resolves `--soft`, `--muted`, `--faint`, `--panel`, `--ground` (a theme inherits what it does not redeclare), computes the WCAG 2 contrast ratio and prints one `ok` / `FAIL` line naming theme, token and background. It also asserts that it found 12 themes, so a parsing miss cannot pass silently.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard.test.sh` |
| AC-2 | manual | load the dashboard in review with the console open: no failed favicon request |
| AC-3 | factory | `scripts/test/dashboard.test.sh` |
| AC-4 | factory | `scripts/test/dashboard.test.sh` |
| AC-5 | factory | `scripts/test/dashboard.test.sh` |
| AC-6 | factory | `scripts/test/dashboard.test.sh` |
| AC-7 | factory | `scripts/test/dashboard.test.sh` |
| AC-8 | factory | `scripts/test/dashboard.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Contrast gets a regression check and no CSS change: the owner measured it as resolved on main (2026-10-11), and the tightest theme has 0.05 of margin.
- The contrast check covers `--soft`, `--muted` and `--faint` on `--panel` and `--ground`: the set the owner measured; accent and status colors are not body text.
- `/favicon.ico` answers 204 without a token rather than shipping an icon: the answer carries no data, and artwork is a design task of its own.
- A wrong card number is 404, not 400: the route does not exist for that segment, which is what every other unknown path answers.
- `from` keeps accepting a negative number (`-?[0-9]+`): `-1` is the page's own "tail" request today.
- The file-parsing `isdigit()` calls in `scripts/dashboard.py` change too; `scripts/shipfloor_config.py` stays as it is: the issue is about the dashboard.
- POST tests send the Unicode segment both percent-encoded and as raw Latin-1 bytes (`²` is 0xB2): POST does not unquote, so only the raw byte reaches `isdigit()` today.
- AC-2 is checked by hand in review: the test suite has no browser, and AC-1 covers the request behind it.
- Tests go in the existing `scripts/test/dashboard.test.sh`: it already starts the server and holds the `code` and `post` helpers.

## Open questions
- none
