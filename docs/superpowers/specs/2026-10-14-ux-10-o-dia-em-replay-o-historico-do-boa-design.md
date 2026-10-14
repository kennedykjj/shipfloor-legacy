# #31/37 [UX-10] O dia em replay: o histórico do board e o diário preso à esteira — spec

**Issue:** #184 · **Branch:** `feat/184-ux-10-o-dia-em-replay-o-historico-do-boa` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** "What happened while I was away?" means reading the Feed run by run and rebuilding card positions in your head, because `board.tsv` is overwritten every cycle and nothing records where cards were.
**Audience:** The factory's owner, on a quick check after time away.
**Acceptance criteria**
- **AC-1** — Given two dispatcher cycles with an identical board and then one with a change, when they run, then `<project home>/logs/board-<YYYY-MM>.jsonl` gains exactly one line `{"t": "<ISO>", "cards": {"<n>": "<column>", …}}`, for the change only.
- **AC-2** — Given board history files of past months, when `shipfloor clean` runs (or a cycle sweeps `tmp/`), then they stay, as the health logs do (neither has a retention today).
- **AC-3** — Given today's runs and owner decisions, when the dashboard shows the line under the belt, then it has an `ok` tick per finished run, a `bad` tick per block and an accent diamond per owner decision, each titled (`13:05 · #121 you approved the PR`), mono hours and the future hatched; every mark comes from existing run logs or owner moves, none inferred.
- **AC-4** — Given history lines for today, when the owner drags the needle to 09:40, then the belt shows each card in its column from the last line at or before 09:40, the status sentence reads `Replay at 09:40. The belt is as it was.` with a Back to live control, the belt does not advance and every decide action is disabled.
- **AC-5** — Given the needle before today's first history line, when replay renders, then the belt says there is no history for that hour instead of showing cards.
- **AC-6** — Given replay is on, when the owner chooses Back to live, then the belt returns to the current snapshot and decide actions are enabled again.
- **AC-7** — Given reduced motion is set, when the needle moves, then cards swap positions without travelling.
- **AC-8** — Given the dashboard, when the owner opens the former Feed, then it is named **Logbook** and holds the period totals and charts that were in History, and History no longer exists as a separate view; `docs/contracts.md` documents the file format and `docs/operation.md` explains replay.

**Out of scope:** Rewriting the Feed's content beyond its name and absorbing History; replay of past days beyond what the current day's line shows; any owner action from a replayed state; marks inferred from anything other than run logs and owner moves; a new retention setting.
**Product fit:** Serves principle 1 (the board is the source of truth): the history is a record the dispatcher writes from the board snapshot, the dashboard only reads it and replay never acts, so no card state lives in the dashboard. Serves principle 3: marks are sourced, never inferred. Serves principle 4: decide is off while looking at the past. No conflict with positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

Source: `docs/design/floor-v4.md` (The logbook scrubber, Status line, Address, Data → Board history). Builds on the belt (#181): its panel, tokens, travel, status sentence and ghost button are reused; the only new piece is the scrubber lane.

- **Scrubber.** Inside the belt panel, under the rail, 38px, outside the belt's horizontal scroller (always the panel's width). A 1px `edge` lane spans today 00:00–24:00 local; hour labels in Plex Mono 12px `faint` tabular every 3 h (every 6 h under 600px). The time after now is hatched (45° `track` stripes at 2px/6px). Minimized belt or maximized lifecycle: no scrubber.
- **Marks.** Run ended: 2px × 10px `ok` tick. Block: 2px × 18px `bad` tick. Owner decision: 8px `accent` diamond (rotated square, no radius). Each mark carries `title` and an off-screen label: `13:05 · #121 Validate ended`, `13:05 · #121 Validate blocked`, `13:05 · #121 you approved the PR` / `you approved the spec` / `you requested changes` / `you moved it to <column>`. Marks are not focusable; they refresh with the Feed's 5 s read, also in replay.
- **Playhead.** 2px `text` line with a 10px `text` dot on top, at now while live. `role="slider"`, label `Time shown`, `aria-valuetext` `Now` or `09:40`; hit area 24px wide (44px under `hover: none`). Drag, or click on the lane, sets the time (1-minute steps); Left/Right ±5 min, PageUp/PageDown ±1 h, Home = today's first history line, End = live. Releasing in the hatched future is Back to live. The time is in the address as `#@0940`; browser Back leaves the replay.
- **Replay on.** Status sentence: dot becomes an 8px `accent` square, text `Replay at 09:40. The belt is as it was.` then ghost **Back to live** (also `Esc` when focus is in the belt panel). Rail paused at `track`. The belt draws the history line's columns only: gate tokens in the waiting look, Done tokens in the done look, all others in the queued look; no progress bars, no `free` ghosts; segment meta is the count only (`3` / `empty`). Token names end with `, as at 09:40`.
- **Decide off.** While replaying, every decide control (Approve, Request changes, quick approve, moves, drag, keys A/R/1–9, the maximize button that opens moves) is `aria-disabled`, faint, `not-allowed`, still focusable, titled `Back to live to decide.` A token still opens its drawer on today's state, read-only for the same reason.
- **Back to live.** Belt returns to the current snapshot (tokens travel to their live places), playhead jumps to now, controls re-enable, focus goes to the playhead. A decision arriving while in replay does not exit replay; the sentence keeps the replay text and the tab title counts as usual.
- **States.** First replay: belt shows `Reading the board history…` (12px `faint`, centred) until read. Needle before today's first line: no tokens, one line across the belt `No history for 07:10. The first record today is at 08:02.`; no line today at all: `No board history for today yet.` Read failed: stay live, panel note line in `bad` `Could not read the board history.`, playhead returns to now.
- **Motion.** On release (or a key step) tokens travel to the replayed places (950ms FLIP, backwards included); during a drag they swap instantly, re-drawn at most every 100ms. Reduced motion: always swap, no travel, no hatching movement.
- **Logbook.** The Feed view is renamed **Logbook** (nav and heading). The History panel leaves the Factory view and opens the Logbook, above the filters, unchanged inside (period control, totals, charts, maximize), heading `Totals` + the period in `muted`. Its minimized state and `shipfloor.history` key are kept.
- **Narrow.** Under 600px the replay sentence wraps under the brand; `Back to live` stays on it and is at least 44px high under `hover: none`.
- **Copy** (en / pt-BR; the other 10 catalogs get the entries, English until filled): `Logbook`/`Diário` · `Totals`/`Totais` · `Time shown`/`Hora mostrada` · `Now`/`Agora` · `Replay at 09:40. The belt is as it was.`/`Replay às 09:40. A esteira como estava.` · `Back to live`/`Voltar ao vivo` · `Back to live to decide.`/`Volte ao vivo para decidir.` · `, as at 09:40`/`, como às 09:40` · `Validate ended`/`Validate terminou` · `Validate blocked`/`Validate bloqueou` · `you approved the PR`/`você aprovou o PR` · `you approved the spec`/`você aprovou a spec` · `you requested changes`/`você pediu mudanças` · `you moved it to Ready for Dev`/`você moveu para Ready for Dev` · `Reading the board history…`/`Lendo o histórico do board…` · `No history for 07:10. The first record today is at 08:02.`/`Sem histórico às 07:10. O primeiro registro de hoje é às 08:02.` · `No board history for today yet.`/`Ainda não há histórico do board hoje.` · `Could not read the board history.`/`Não foi possível ler o histórico do board.`

## Architecture
_Tech Lead_

One layer: `factory`. Builds on #181 (the belt), which must be on main before develop starts.

**Data — board history (new contract).** `<project home>/logs/board-<YYYY-MM>.jsonl`, one line per change: `{"t": "<ISO local time with offset>", "cards": {"<n>": "<column>", …}}`. `cards` holds every card of `board.tsv` (the whole board, not a diff), keys as strings, sorted.
- New `scripts/shipfloor_core/board_history.py`:
  - `record(home, rows, now=None) -> bool`: builds `cards` from the snapshot rows and compares it with the `cards` of the last line of the newest `board-*.jsonl`. It appends a line only when they differ, or when there is no file yet. An empty read writes nothing (it proves nothing, as `board_read` says). An `OSError` returns False and never fails the cycle.
  - `day(home, date) -> list[{"t", "cards"}]`: the lines whose `t` falls on that local date, in file order. Bad lines are skipped.
- `scripts/shipfloor_core/dispatch.py` `read_board`: after `os.replace`, calls `board_history.record(self.home, self.snapshot_rows())`. The project home is where `board.tsv` lives, so no new path is needed.
- Retention: `project.sweep_tmp` touches only `tmp/`, so `shipfloor clean` and the cycle sweep leave `logs/` alone. Nothing changes there; the test pins it.

**Dashboard API (new, read-only).** `GET /api/day/<project>` in `scripts/dashboard.py`, under the same token and known-project checks as `/api/history`. It returns `{"date", "now", "board": [{"t", "cards"}], "marks": [{"t", "kind": "ok"|"bad"|"decision", "n", "stage"?, "what"}], "error"?}`.
- `ok` / `bad`: from `runs(p, day=today)` with an `end`. A run is `bad` when its report's `outcome` (the `reports()` pairing `feed_runs` already uses) is `blocked` or `infra`, or when it exited non-zero. Otherwise it is `ok`.
- `decision`: from consecutive board-history lines, a card that leaves `Spec Review` or `Staged` for a target in `OWNER_MOVES[<that column>]`. Only the owner makes those moves (`board.sh move` refuses them), so this records a move and does not guess one. `what` is `approved-spec` (Spec Review → Ready for Dev), `approved-pr` (Staged → Ready for Prod), `requested-changes` (the moves that need a note), or `moved:<column>`.
- The page turns `what` into the catalog text. The server sends keys, never English.

**Page (`scripts/dashboard.html`).** Everything in `## UX`:
- the scrubber lane inside the belt panel; the playhead slider and `#@HHMM` in the address;
- replay state `R = {at, lines}`. The belt is drawn from the last line with `t <= at` and paused while `R.at` is set. With no such line it shows the empty states;
- every decide control is gated on `!R.at`, through one `deciding()` check that the existing approve, request, move, drag and key handlers call;
- the status sentence's replay mode;
- FLIP travel, skipped under `prefers-reduced-motion` (the existing `still` media query);
- the Feed renamed Logbook, with the `#history` section moved into it. `/api/history` is unchanged.

The day is read once on entering replay and then with the 5 s Feed poll.

**Catalogs:** the new keys go in `scripts/lang/dashboard.en.json` and `scripts/lang/dashboard.pt-BR.json` with real text, and in the other 10 `scripts/lang/dashboard.*.json` in English (as #181 did).

**Docs:** `docs/contracts.md` gets the file in "Files under ~/.shipfloor" (writer `dispatch.sh` via `board_history.record`, reader `dashboard.py`) and `/api/day` next to the dashboard's readers. `docs/operation.md` gets one paragraph on the scrubber and replay.

**Files:**
- new: `scripts/shipfloor_core/board_history.py`
- changed: `scripts/shipfloor_core/dispatch.py`, `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.*.json` (12), `docs/contracts.md`, `docs/operation.md`
- tests: `scripts/test/board-history.test.sh`, `scripts/test/dashboard-day.test.sh`, `scripts/test/dashboard-replay.test.sh`

**Migration:** none. It is a new append-only file, and a project with no history simply shows `No board history for today yet.`

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/board-history.test.sh` |
| AC-2 | factory | `scripts/test/board-history.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-day.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-replay.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-replay.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-replay.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-replay.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-replay.test.sh` |

The page tests read `dashboard.html` as text, as `dashboard-page.test.sh` does. Validation checks the running screen with verify-ui.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Retention: the issue asks for "the same retention as the health logs". Health logs have none, and neither `shipfloor clean` nor the cycle sweep touches `logs/`, so board history is kept the same way. A month is small (one line per change), and a retention setting is out of scope.
- Change detection compares against the last history line, not the previous `board.tsv`: a failed read or a restart cannot cause a duplicate line or a missed one.
- Each line holds the whole board, not a diff: the replay at any time reads one line, as the design reference says.
- Owner decision marks come from board-history moves out of Spec Review/Staged to an `OWNER_MOVES` target. Those moves are made only by the owner, so the mark is sourced and not guessed. Its time is the cycle that saw the move.
- `bad` = the report's `outcome` is blocked/infra or the run exited non-zero: both are recorded facts in sources the Feed already reads.
- The feed's new English name is Logbook, matching "The logbook scrubber" in floor-v4.md; pt-BR is Diário, as the issue names it.
- Develop waits for #181 (the belt is not on main yet): the issue already orders it after #28/37, and #169 is closed.
- Weight is heavy: 8 acceptance criteria and more than 8 files.

## Open questions
- none
