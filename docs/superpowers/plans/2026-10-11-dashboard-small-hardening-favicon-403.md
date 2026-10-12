# Dashboard: small hardening (favicon 403, Unicode digits, --faint contrast) — plan

**Issue:** #7 · **Branch:** `feat/7-dashboard-small-hardening-favicon-403`
**Spec:** `docs/superpowers/specs/2026-10-11-dashboard-small-hardening-favicon-403-design.md`

One layer (`factory`), one implementation task. The acceptance tests come first, from QA, in
`scripts/test/dashboard.test.sh`; the engineer then changes `scripts/dashboard.py` only.

## Tasks

### T0 — Acceptance tests (QA)
- **Owner:** `qa-engineer` · **Layer:** `factory` · **Depends on:** nothing
- **File:** `scripts/test/dashboard.test.sh` (change; reuse its server start and its `code` and `post` helpers)
- AC-1: `GET /favicon.ico` without a token answers 204 with an empty body.
- AC-3: `GET /api/card/<project>/%D9%A1%D9%A2` answers 404 and returns no card data.
- AC-4: `/api/card`, `/api/decide`, `/api/live` and `/review/<project>/<n>` answer 404, never 500, for a segment
  that passes `isdigit()` but is not `[0-9]+` (`²` as `%C2%B2`, and `١٢`).
- AC-5: `/api/log/<project>/<name>?from=²` and `?from=١٢` answer as `?from=abc` does (same status and body), never 500.
- AC-6: `POST /api/card/<project>/<n>/<action>` with a card number that is not `[0-9]+`, sent percent-encoded and as
  the raw Latin-1 byte `0xB2`, gets a 404 response (the connection is not dropped) and no board call is made.
- AC-7: the same routes still serve card 12 for `12`.
- AC-8: a Python block reads `scripts/dashboard.html`, resolves `--soft`, `--muted`, `--faint`, `--panel`, `--ground`
  for the default rule and each `[data-theme]` (a theme inherits what it does not redeclare), prints one `ok` / `FAIL`
  line per theme, token and background at 4.5:1, and asserts it found 12 themes.
- AC-8 holds on today's values, so it cannot be red before the implementation: QA proves it by showing the check
  fails when a token is lowered (in a temporary copy of the HTML, not in the repository) and passes on the real file.
- AC-2 is manual (review, console open): no test.

### T1 — Route hardening in the dashboard server
- **Owner:** `engineer` · **Layer:** `factory` · **Depends on:** T0
- **File:** `scripts/dashboard.py` (change). No change to `scripts/dashboard.html`, no new file.
- Add the module-level helper `number(s)`: true when `re.fullmatch(r"[0-9]+", s)`.
- `do_GET`: answer `/favicon.ico` before the token check, beside the `url.path == "/"` branch, with
  `self.send(204, b"")` (`Content-Length: 0` and `Cache-Control: no-store` come from `send()`; a 204 carries no body).
- `do_GET`: replace `.isdigit()` with `number()` on the card-number segment of `/api/card`, `/api/decide`, `/api/live`
  and `/review/<project>/<n>`.
- `do_GET`, `/api/log`: use `from` only when `re.fullmatch(r"-?[0-9]+", start)`; anything else is `-1`.
- `do_POST`: replace `.isdigit()` with `number()` in the route check, so a wrong number is 404 before the body is
  read and before any board call.
- File parsing (`cache`, `stack status`: the three `.isdigit()` calls near lines 205, 281, 282): use `number()` too.
- Done when: no `.isdigit()` is left in `scripts/dashboard.py`, the acceptance tests pass and
  `TEST_JOBS=4 bash scripts/test/run.sh` passes.

## Order
T0 → T1.

## Risks
- `send()` always writes a `Content-Type` header; on a 204 that is harmless, and the spec asks for no other header.
- The branch is behind `main`; `main` touched `scripts/dashboard.py` and `scripts/test/dashboard.test.sh` since
  (#57, #59). The deploy merges once, on the approved head; keep the change small and local to the lines above.
