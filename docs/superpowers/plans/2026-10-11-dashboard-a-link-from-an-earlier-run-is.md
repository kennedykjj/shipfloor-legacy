# Dashboard: a link from an earlier run is a dead end and keeps polling — plan

**Issue:** #52 · **Spec:** `docs/superpowers/specs/2026-10-11-dashboard-a-link-from-an-earlier-run-is-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-link.test.sh`), red.
2. Task 1 (factory): the server keeps the link's secret across runs.
3. Task 2 (factory): the page stops at the first 403 and shows the refused-link state. Independent of Task 1 in code; second because they share the worktree.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-link.test.sh` (new), AC-1 to AC-7.
- Starts the dashboard as `dashboard.test.sh` does: a temp `SHIPFLOOR_HOME`, the fake `gh`, `--port 0 --no-open`, the URL read from the printed line. The second start of AC-1 and AC-2 asks for the port the first one got (`--port <that port>`).
- AC-1: start, read the URL, stop, start again on the same home and port: the two URLs are equal.
- AC-2: the token of the first run gets 200 from `/api/overview` of the second run.
- AC-5: with `<home>/dashboard.token` deleted, and again with it damaged (empty, wrong length, other characters), the start prints a URL with a new token, the old token gets 403 and the file is back with the token and a newline; where the system has file modes (not on Windows), the file is `600`.
- AC-6: no token and a wrong token get 403 on a GET and on a POST; the token in the URL of a POST (not in the header) still gets 403.
- AC-3, AC-4, AC-7: read from the source of `scripts/dashboard.html` with Python, as `theme.test.sh` does:
  - the page has exactly one `fetch(`, inside `api()`;
  - the `S.refused` guard comes before it and answers without a request;
  - a 403 response sets `S.refused` and calls `refuse()`; the `catch` branch does not;
  - the refused state holds the spec's English copy ("This link is no longer valid", the command `shipfloor dashboard` in a `<code>` of its own) and the old sentence ("belongs to an earlier run") is gone;
  - `scripts/lang/dashboard.pt-BR.json` has the three `exact` entries of `## UX`.
- AC-6 and AC-7 hold today: their assertions pass before the implementation. The red is on AC-1 to AC-5, on assertions, not on a crash.

## Task 1 — factory: the link's secret is kept in the home

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.py` (change)
- `README.md` (change)
- `skills/dashboard/SKILL.md` (change)

**`scripts/dashboard.py`**
- New `link_token(home) -> str`: reads `<home>/dashboard.token`; a value matching `[A-Za-z0-9_-]{22}` (after the trailing newline is stripped) is returned as is; anything else (missing, empty, damaged) is replaced by a fresh `secrets.token_urlsafe(16)`.
- The write: a sibling temp file created with `os.open(..., os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)`, the token and a newline, then `os.replace` onto `dashboard.token`. A leftover temp file of a crashed start must not block the next one.
- A home that cannot be written (`OSError`) does not stop the start: the token lives in memory for that run and one line on stderr says the link will not survive a restart. That line does not hold the token.
- `main()`: `Handler.token = link_token(args.home)` replaces the `secrets.token_urlsafe(16)` call. The printed line and `Handler.allowed()` stay as they are.
- The token is never logged, never sent in a response body and never served by a route.

**`skills/dashboard/SKILL.md`**: "The URL holds this run's token" becomes "this machine's token".
**`README.md`**: one line under the dashboard: the link's secret is kept in `~/.shipfloor/dashboard.token`; deleting it and restarting makes a new link.

**Done when:** the AC-1, AC-2, AC-5 and AC-6 assertions of `scripts/test/dashboard-link.test.sh` pass and the build is green (`dashboard.test.sh` and the other dashboard tests included).

## Task 2 — factory: the page stops at the first 403

**Owner:** `engineer` · **Depends on:** Task 1 (worktree order only)

**Files**
- `scripts/dashboard.html` (change)
- `scripts/lang/dashboard.pt-BR.json` (change)
- another `scripts/test/*.test.sh` only where it asserts the old sentence or markup (not an acceptance test of this card)

**`scripts/dashboard.html`**
- `S.refused`, false at load.
- `api()` stays the page's only `fetch`: with `S.refused` set it returns `{ status: 403, body: {} }` without a request; a 403 response sets `S.refused` and calls `refuse()` once. The `catch` (network failure) leaves `S.refused` alone: Offline and its retries stay as today.
- `refuse()` draws the refused-link state of the spec's `## UX`; the 403 branch of `loadOverview` moves into it:
  - stays: the header with the brand, and `#msg` as the whole page;
  - hidden or emptied: `.views`, `.stats` (`#scope`, `#stats`), `#alerts`, `#band`, `#cols`, `#feed`, `#settings`, `#peek`; `#drawer` closed and `inert`, the maximized scrim included; the review iframe removed from the document;
  - `#msg`: a `<strong>` first line, a muted sentence, the command in a `<code>` on its own line (`user-select: all`, tokens `--text`, `--panel-hi`, `--edge-hi` only), a closing muted sentence; each its own text node, with the copy of `## UX`;
  - `#msg` gets `role="alert"` and `tabindex="-1"` and takes focus;
  - the keys n, a, r, l and Esc do nothing while `S.refused`.
- The seven `setInterval` timers stay; they stop at the guard in `api()`. Nothing that draws after a refused answer may bring factory data or a flag back (the callers of `api()` return on a 403 or on `S.refused`).

**`scripts/lang/dashboard.pt-BR.json`**: the three `exact` entries of `## UX`.

**Done when:** every assertion of `scripts/test/dashboard-link.test.sh` passes and the build is green (`theme.test.sh`, `dashboard-lang` and the other tests that read the page included).
