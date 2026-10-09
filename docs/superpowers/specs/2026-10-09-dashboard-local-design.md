# Local dashboard — design

**Date:** 2026-10-09 · **Status:** approved in conversation, pending review of this document

## Problem

Watching the factory means opening the GitHub board, `aghanim pool`, log files and report JSONs by hand. There is no view of what a card cost: the reports' `agents[].tokens` are written by the agent itself and are often empty (`"agents": []`). Approving a spec or a staged card means reading a local review page, then moving the card on GitHub by hand.

## Goal

One local page for the owner (a developer) that shows the pool and slots, live runs, each run's log, metrics, the cost of each card from Inbox to Done, and the review pages with approve / request changes. It replaces neither the GitHub Project board nor the issues; the board stays the source of truth.

Success: the owner can follow and approve the factory's work without opening GitHub or a terminal, and can see what each card cost, session by session.

## Decisions

1. **On demand.** `aghanim dashboard [--port N] [--no-open]` starts the server and opens the browser; it stops when the owner ends it. Nothing resident.
2. **Python stdlib server + one HTML page with plain JS.** No pip, npm or build: Python is already a factory dependency. The page polls every 5 s.
3. **Read-only, except two owner actions:** approve and request changes.
4. **Cost comes from Claude Code transcripts, not from reports.** US$ is an estimate: tokens × a price table per model, labeled as such.
5. **Layout "control room":** everything on one screen; card detail in a drawer; the review opens inside the drawer, which widens to ~70% of the screen.
6. **The UI is designed with the `/impeccable` skill.** Audience: developers. Dense, exact numbers, monospace for data, dark and light themes, every item links to its source (issue, PR, log, commit), nothing decorative.

## Files

- `scripts/dashboard.py`: HTTP server (`http.server`, `ThreadingHTTPServer`) and the data readers.
- `scripts/dashboard.html`: the page.
- `scripts/aghanim`: new `dashboard` command, a thin wrapper that runs `python -I dashboard.py`.
- `templates/prices.yml`: default price table, copied to `~/.aghanim/prices.yml` by `aghanim install` when missing (the owner's edits are kept).

## Code organization

The plugin stays small and readable; the dashboard follows the patterns already in `scripts/`, without AI slop:

- Same shape as `review-page.sh` / `review_page.py` / `review-template.html`: Python logic, a thin bash entry point, one HTML file. No new directories, frameworks or dependencies.
- `dashboard.py` holds readers as plain functions (one per source above) and a small request handler that maps routes to them. If it grows past ~400 lines, the cost reader moves to `dashboard_cost.py`; no other split up front.
- No speculative options, abstraction layers, plugin hooks or config keys beyond `--port`, `--no-open` and `prices.yml`.
- Comments only where the code cannot say it (the transcript format, the owner-action guardrail). No narrating comments, no dead code, no commented-out code, no emoji in code or UI copy.
- The page uses the factory's names (columns, stages, `aghanim`) verbatim; no invented terms.
- `hygiene.test.sh` keeps passing; README gets one short `aghanim dashboard` entry under Operation.

## Data sources (read-only)

| Data | Source |
|---|---|
| Projects | `~/.aghanim/registry.tsv` |
| Pool and slots | machine config, read through `aghanim-config.sh machine` (what `aghanim pool` shows) |
| Live runs | `projects/<p>/locks/<stage>-<n>.lock` whose pid is alive; a lock whose pid is gone is shown as orphaned |
| Card column | `projects/<p>/board.tsv`, the snapshot the dispatcher writes each cycle (no extra GraphQL); the page shows its age |
| Logs | `projects/<p>/logs/<date>-<n>-<stage>.log` |
| Gates, rounds, outcome | `projects/<p>/reports-wt/reports/<n>-*/<stage>-<ts>.json` |
| Cost | `~/.claude/projects/<encoded control path>/<session>.jsonl` and `<session>/subagents/*.jsonl` |
| Prices | `~/.aghanim/prices.yml` |
| Reviews | `projects/<p>/reviews/<n>.html` |
| Factory state | `~/.aghanim/PAUSE`, `projects/<p>/PAUSE`, a recent usage-limit hit in the logs |

### Cost

- The factory launches every run in the project's `control` checkout, so all its sessions live in one transcript directory. A session belongs to a card when its first user message is `/aghanim:<stage> <n>` (or the legacy `/mylos:<stage> <n>`). Other sessions (the owner's manual work in `control`) are ignored.
- Each assistant message carries `model` and `usage` (`input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`). A session's cost is the sum over its messages and its subagents' messages, each priced by its own model.
- A card's cost is the sum of all its sessions: refine, develop, validate, deploy, refresh and every resume.
- A model missing from `prices.yml` shows its tokens, `$ ?` and a hint to add it.
- Parsed transcripts are cached in memory by path, size and mtime, so the 5 s polling does not reread them.

## Endpoints

- `GET /` — the page.
- `GET /api/overview` — pool and slots in use, live runs, factory state, cards by column with their cost, cards awaiting the owner, today's runs (count, outcomes, cost).
- `GET /api/card/<p>/<n>` — sessions (start, stage, model, the four token kinds, duration, result, cost, subagents), reports, gates, links.
- `GET /api/log/<p>/<file>?from=<byte>` — incremental tail.
- `GET /review/<p>/<n>` — the existing review page.
- `POST /api/card/<p>/<n>/approve`
- `POST /api/card/<p>/<n>/request-changes` with `{"text": "..."}`

## Owner actions

| Current column | Approve → | Request changes → |
|---|---|---|
| Spec Review | Ready for Dev | Ready for Refinement |
| Staged | Ready for Prod | Coding |

- Any other column: `409`, nothing changes.
- Before acting, the server reads the card's current column live (one board read). If the column changed since the page loaded, it answers `409`.
- Request changes posts the text as an issue comment (`gh issue comment`) first, then moves the card. If the comment fails, nothing moves. If the comment succeeds and the move fails, the answer says so and the page offers to retry the move only.
- **The dashboard moves the card itself** (`gh project item-edit`, with the project and field ids from the existing `board-ids` cache). `board.sh move` keeps refusing owner-only transitions: it is the agents' guardrail, and an owner path in it would be open to agents too.
- After an action the card shows "moving…" until the next snapshot confirms it.

## Security

- Binds to `127.0.0.1` only.
- Each run creates a random token that goes in the opened URL; POSTs without it get `403`. A website open in the owner's browser cannot approve a card through `localhost`.
- Files are served only from registered projects' `logs` and `reviews` directories; any other path is `404`.

## Behavior

- Several projects: the top strip adds them up; the board has a project selector, hidden when there is only one.
- Default port taken: tries the next one.
- Server gone: the page shows "offline" and retries.

## Layout

- **Top strip:** pool usage and slots per stage; today's runs, outcomes and cost; cards awaiting the owner; factory state (paused, usage limit, orphaned locks); board snapshot age.
- **Board:** compact columns; each card shows its number, title, a live-run marker, an awaiting-owner marker and its cost.
- **Drawer** (click a card): header with issue and PR links, total cost, sessions, run time and lead time; tabs **Sessions** (one row per session, subagents expandable, a row opens that session's log), **Log** (live tail), **Gates**, **Review** (widens the drawer; approve and request-changes with a text box at the top).

Mockups from the brainstorm: `.superpowers/brainstorm/` (not committed).

## Tests

Only what protects a decision; no UI unit tests. One file, `scripts/test/dashboard.test.sh`, with a fake home and small fixtures (no git repositories):

- Cost: a card's total and per-session cost from fixture transcripts, including a subagent, a legacy `/mylos:` session, and an ignored manual session.
- Owner actions: POST without token → `403`; approve from a non-owner column → `409`; approve from Spec Review moves to Ready for Dev; request changes comments, then moves; a log path outside `logs` → `404`. `gh` is the existing `fake-gh`, which records its calls.

At the end of the implementation, a manual smoke check with `playwright-cli` against the fake home: open, click a card, see the sessions table.

## Out of scope

- Replacing the GitHub Project board or keeping board state locally.
- Real US$ from the API (the estimate uses the price table).
- Starting, stopping or retrying runs from the dashboard.
- Access from other machines or a phone.
