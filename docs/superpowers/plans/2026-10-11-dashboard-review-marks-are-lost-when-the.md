# Dashboard: review marks are lost when the review iframe reloads — plan

**Issue:** #11 · **Spec:** `docs/superpowers/specs/2026-10-11-dashboard-review-marks-are-lost-when-the-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Acceptance tests (QA, before any task)

- `scripts/test/dashboard-marks.test.sh` (new): AC-2, AC-3, AC-5, AC-6, AC-7 against a running dashboard with `curl`, plus the endpoint's refusals (`400`, `404`, `409`, `403` without the token).
- `scripts/test/review-page.test.sh`: AC-8, the page served without `embed=1` carries no `__shipfloorMarks`.
- AC-1 and AC-4 are manual (in the browser); no test file.

## Tasks

### T1 — Server: marks store, endpoint, injection and embed script
- **Layer:** factory · **Owner:** engineer · **Depends on:** acceptance tests
- **Files:** `scripts/dashboard.py`
- **What:**
  - `rev` of a card's review page: first 16 hex of the SHA-256 of `reviews/<n>.html` as read from disk.
  - Store `reviews/<n>.marks.json` = `{"rev", "marks"}`, written to a temp file in the same folder and renamed; empty `marks` deletes the file.
  - `POST /api/card/<project>/<n>/marks` behind the same token check as the other card actions: `200 {"ok": true}`, `409` on another `rev`, `400` on the limits of the spec (500 ids, id `^[a-z0-9-]{1,80}$`, `s` in `ok`/`chg`, `n` a string up to 2000 characters, body up to 256 KB, body not JSON or not the expected shape), `404` for an unknown project or a card with no review page. The body size is checked from `Content-Length` before reading.
  - `GET /review/<project>/<n>?embed=1`: add `<script>window.__shipfloorMarks={"rev":...,"marks":{...}}</script>` before the embed block; `marks` is `{}` when the file is missing, unreadable or of another `rev`; `<`, `>` and `&` in the JSON are written as `<`, `>`, `&`. The page without `embed=1` is served as today; the sandbox header stays.
  - Embed script in `EMBED_CSS`: on load, when `__shipfloorMarks.marks` has entries, set the page's `st` to them and call `render()` before the first `review-progress`; after every change also post `{shipfloor: "review-marks", rev, marks: st}` to the parent.

### T2 — Drawer relay and DESIGN.md
- **Layer:** factory · **Owner:** engineer · **Depends on:** T1
- **Files:** `scripts/dashboard.html`, `DESIGN.md`
- **What:**
  - The `message` listener takes `review-marks` only from the open card's iframe (same source check as `review-progress`) and remembers the card key (`project/n`) it arrived for.
  - The save is a `POST` to T1's endpoint with the token header, debounced (at most 500 ms); a waiting save is sent at once when the iframe is replaced (tab switch, another card, drawer closed) or the dashboard page is hidden, with `fetch(..., {keepalive: true})`. A failed save changes nothing on screen.
  - `DESIGN.md`: the drawer's review paragraph says the marks are kept by the dashboard server per card and review page, and the iframe stays sandboxed.

## Not touched
`scripts/review-template.html`, `scripts/review_page.py`.

## Checks by hand in review
AC-1 and AC-4, in the browser, as the spec's test plan says.
