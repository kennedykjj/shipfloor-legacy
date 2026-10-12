# Cost limits: flag and block a card, stop starting runs for the day — plan

**Issue:** #36 · **Spec:** `docs/superpowers/specs/2026-10-11-cost-limits-flag-and-block-a-card-stop-s-design.md`
**Branch:** `feat/36-cost-limits-flag-and-block-a-card-stop-s`

One layer, `factory` (path `./`, agent `engineer`). No migration. The tasks run in order and share the worktree; each one leaves the suite of the files it touched passing.

## Acceptance tests (QA, before any task)

- `scripts/test/dispatch-cost.test.sh` (new): AC-2, AC-3, AC-4, AC-5, AC-6, AC-7.
- `scripts/test/dashboard.test.sh`: AC-1, AC-8, and the dashboard halves of AC-3 (the cost "why"), AC-4 (the alert) and AC-6 ("price missing").
- `scripts/test/machine.test.sh`: the `costs` validation of AC-8.

## Tasks

### T1 — machine config and the shared estimate
- **Layer:** factory · **Owner:** engineer · **Depends on:** nothing
- **Files:** `scripts/shipfloor_config.py`, `scripts/dashboard_cost.py`
- `machine_problems(raw)` validates the optional `costs` mapping: keys `card_warn`, `card_block`, `day_stop` only; each a number above 0 (int or float, not a bool); `card_warn` ≤ `card_block` when both are set; an unknown key is an error. No defaults.
- `machine values costs.<key>` prints an empty value for an absent key.
- `dashboard_cost.py`:
  - `spend(sessions, prices, today)` → `{"cards": {issue: {"total", "stages"}}, "today"}`; an unpriced session makes its card's `total` `None` and adds nothing to `today`.
  - `over(spend, costs, baselines)` → `{"day_stop", "warn", "block"}`; the card's figure is `total - baseline`; a limit acts at `>=`; `total: None` is in neither list.
  - the parse cache `<SHIPFLOOR_HOME>/cost-cache.json`, keyed by path, size and mtime.
  - CLI `limits --home --project [--claude-dir]`: `day_stop<TAB><today><TAB><limit>` when the day is stopped, then one `block<TAB><issue>` per card of the project at or over `card_block`.
  - CLI `block --home --project --issue --out`: writes the comment body (first line `Cost limit: blocked.`, the estimated total, the limit, one line per stage, the word "estimate") and the marker `<project home>/cost/<n>.json` (`at`, `limit`, `total`, `baseline`, `stages`).
- **AC:** AC-2, AC-3, AC-6, AC-7 (their computation), AC-8 (validation).

### T2 — the dispatcher and the health record
- **Layer:** factory · **Owner:** engineer · **Depends on:** T1
- **Files:** `scripts/dispatch.sh`, `scripts/shipfloor_health.py`
- With no `costs` in the machine config, no new process starts and the cycle is as today.
- Right after `usage_limited`: on a `day_stop` line, log `dispatch: today's estimate US$ <x> reached costs.day_stop (US$ <y>); no new run until tomorrow` and exit 0. Running sessions are untouched.
- In `start_run`, before `launch`: a card in the `block` list is not launched; run the `block` CLI, post the comment (`gh issue comment --body-file`, through `FACTORY_GH`), then `board.sh label <n> add blocked`. A failed comment or label fails the cycle's status; the card is still not launched.
- The marker of a card that left the board snapshot is removed.
- `shipfloor_health.py`: `snapshot()` records `cost_stop` and counts it as stopped, so the "free slot and cards waiting" alert stays quiet.
- **AC:** AC-2, AC-3, AC-4, AC-5, AC-6, AC-7.

### T3 — the dashboard's API
- **Layer:** factory · **Owner:** engineer · **Depends on:** T1
- **Files:** `scripts/dashboard.py`
- `Factory.overview()` and `Factory.card()` use `spend()` instead of their own sums.
- `GET /api/overview`: `costs: {card_warn, card_block, day_stop, day_stopped}`; each card gains `over: "warn" | null` and `spent`; `cost: null` stays "price missing".
- `GET /api/settings`: `machine.costs` (three keys, `null` when absent) and `unpriced`.
- `POST /api/settings/machine`: accepts `costs: {key: number | null}`; `null` removes the key, an empty `costs` is dropped from the file; 400 with `machine_problems`' messages.
- `Factory.block()` / `decide`: with the marker and a newest block note opening with `Cost limit: blocked.`, the block is `{"kind": "cost", "limit", "total", "stages"}`.
- **AC:** AC-1, AC-3, AC-4, AC-6, AC-8.

### T4 — the dashboard's screen, its strings and the README
- **Layer:** factory · **Owner:** engineer · **Depends on:** T3
- **Files:** `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `README.md`
- As the spec's `## UX` says: the over-warning flag (In progress tiles, the lifecycle dot, the peek, the lanes), the cost block in the inbox with its "why" table and the unblock hint, the "Runs stopped for today" alert and the waiting tiles' reason, the `$ ?` marker on waiting tiles with its new title and the `.note.warn`, the Limits group in Settings, Costs with its typed fields and validation.
- Every new string has its pt-BR entry.
- `README.md`: the `costs` keys beside the other machine settings.
- **AC:** AC-1, AC-3, AC-4, AC-5, AC-6, AC-8.
