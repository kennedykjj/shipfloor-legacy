# Explicit dependencies: the dispatcher does not start a card with an open dependency, and the card shows each one with its status — spec

**Issue:** #202 · **Branch:** `feat/202-explicit-dependencies-dispatcher` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** Dependencies live as free text in the issue body, read only by an agent after it starts, so the dispatcher starts cards whose base is not on `main` and each one burns a session to end `blocked` (#163–#166, #171 on 2026-10-14); the owner has no single place to see what a card waits on.
**Audience:** The factory's owner (and developers who install the plugin) running the dispatcher and checking the dashboard.
**Acceptance criteria**
- **AC-1** — Given a Ready for Dev card with an open "Blocked by" issue, when the dispatcher runs a cycle, then that card is not started, gets no `blocked` label, stays in the queue, and the next eligible card is started.
- **AC-2** — Given that card's last open dependency is closed, when the next cycle runs, then the card is started without any owner action.
- **AC-3** — Given a dependency closed as "not planned", when the dispatcher evaluates the card, then it is treated as having no open dependency and the dashboard shows that dependency as closed.
- **AC-4** — Given a card with dependencies, when the owner opens the dashboard, then the card shows "Depends on" with each dependency's number, short title, current board column or "closed", and a link to the issue.
- **AC-5** — Given a queued card waiting only on dependencies, when the health record is written, then that slot is not counted as `idle` and the card appears as "waiting on #N, #M".
- **AC-6** — Given a candidate card, when the dispatcher checks its dependencies, then it uses the GitHub REST API with at most one call per candidate per cycle, and an API error leaves the card not started (and not `blocked`).
- **AC-7** — Given a card with open dependencies in Ready for Refinement, when the dispatcher runs, then refinement starts normally; only develop, validate and deploy wait on dependencies.
- **AC-8** — Given `fake-gh` scenarios for an open dependency, a closed dependency and an API error, when the test suite runs, then each scenario's dispatch outcome above is asserted.
**Out of scope:** Migrating the text dependencies of the open PY-series issues (#153) to "Blocked by" relations (a one-off board operation done by the owner, not code in this PR); parsing text dependencies as a fallback; editing dependencies from the dashboard; the refine agent auto-creating "Blocked by" relations (follow-up issue).
**Product fit:** Serves principle 1 (the board, via GitHub's native dependencies, is the source of truth; the dashboard keeps no dependency state of its own) and principle 2 (a deterministic dispatcher check replaces an agent discovering the gap after starting); also principle 4, since a waiting card needs no owner unblock. No conflict with the positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Where (AC-4):** the card drawer's head (`tipHead` in `scripts/dashboard.html`) gets a "Depends on" block between the `.meta` line and `.tip-stats`. It appears only when the card has at least one dependency. There is no empty state: a card with no dependency looks exactly as it does today.
- **The block:** a caption label (`.cap`, `muted`) over a `<ul aria-label="Depends on">`, one row per dependency, open ones first, then by number. Each row has three parts. First the number `#N`, a link to the issue (`target="_blank" rel="noopener"`, `title` from the existing `gh.title`, tabular). Then the short title, which is GitHub data so it is RAW and never translated, set in `soft`, one line with an ellipsis and the full title in `title`. A missing title uses the existing `UNTITLED`. Last the state: the board column through `colName()` in `soft` for an open dependency, or "closed" in `faint`. A dependency closed as "not planned" also reads "closed" (AC-3). No outcome color and no accent here: state is carried by the words.
- **Waiting tile (AC-5):** in `whyWaits()`, a queued card whose dispatcher record says it waits only on dependencies shows "Waiting on #12, #14" in the existing `.why` line. It lists open dependencies only, joined with the existing `hold.sep`. This check comes after infra/paused/day_stop/usage/skipped and before slot/pool, because a free slot would not start it. The tile keeps the plain queued look (dashed, hollow `muted` ring), never `warn` or `bad`, and has no nested links because the tile itself opens the card. The line peek's meta line uses the same string in place of the queued state.
- **Error (AC-6):** when the dispatcher could not read a card's dependencies on its last cycle, the tile's `.why` and the drawer block (in place of the rows) both say `dep.unread` in `muted`. The card is only queued, so there is no alert and no `warn`.
- **Loading:** the dashboard keeps no dependency state of its own. It shows what the latest dispatcher record holds, and on a refresh the block is rewritten only when its markup changed (existing `setHTML`). Before the first record there is no block.
- **Small screens:** under 860px the drawer is full width already. Each row is a grid of `auto 1fr auto`: the number and the state never truncate and the title takes the ellipsis. Under 540px (drawer container) the title drops to its own line under the number and state. Each link keeps a hit box of at least 24×24px and the `sand` focus ring.
- **Tokens and components:** existing `.cap`, the `.meta` 12.5px type, `--soft`/`--muted`/`--faint`, `colName()`, `hold.sep`, `gh.title`. No new component and no new token.
- **Copy:** new keys go in all 12 `scripts/lang/dashboard.*.json` catalogs. Column names use the existing `col.*` keys. `{list}` is issue numbers such as `#12, #14`.

| key | en | pt-BR | es | fr | de | it |
|---|---|---|---|---|---|---|
| `dep.h` | Depends on | Depende de | Depende de | Dépend de | Hängt ab von | Dipende da |
| `dep.closed` | closed | fechada | cerrada | fermée | geschlossen | chiusa |
| `why.deps` | Waiting on {list} | Aguardando {list} | Esperando a {list} | En attente de {list} | Wartet auf {list} | In attesa di {list} |
| `dep.unread` | Dependencies not read; it starts once GitHub answers | Dependências não lidas; começa quando o GitHub responder | Dependencias sin leer; empieza cuando GitHub responda | Dépendances non lues ; démarre quand GitHub répond | Abhängigkeiten nicht gelesen; startet, sobald GitHub antwortet | Dipendenze non lette; parte quando GitHub risponde |

| key | ja | ko | ru | tr | zh-CN | zh-TW |
|---|---|---|---|---|---|---|
| `dep.h` | 依存先 | 의존 대상 | Зависит от | Bağımlı olduğu | 依赖于 | 依賴於 |
| `dep.closed` | クローズ | 닫힘 | закрыта | kapalı | 已关闭 | 已關閉 |
| `why.deps` | {list} を待っています | {list} 대기 중 | Ждёт {list} | {list} bekleniyor | 等待 {list} | 等待 {list} |
| `dep.unread` | 依存関係を読み込めません。GitHub が応答すると開始します | 의존성을 읽지 못함. GitHub가 응답하면 시작합니다 | Зависимости не прочитаны; запуск, когда GitHub ответит | Bağımlılıklar okunamadı; GitHub yanıt verince başlar | 未能读取依赖；GitHub 响应后开始 | 未能讀取依賴；GitHub 回應後開始 |

## Architecture
_Tech Lead_

**Contract touched.** One new read, `gh api repos/<repo>/issues/<n>/dependencies/blocked_by` (REST, core quota): a JSON array of issues, each with `number`, `title`, `state` (`open`/`closed`). Only `state == "open"` blocks; a closed issue (merged or "not planned") never does. A non-zero exit or a body that is not a JSON array is an error. New dispatcher record `<project home>/deps.json`, written atomically (temp + `os.replace`) at the end of every cycle: `{"<card n>": {"read": true|false, "deps": [{"n": 162, "title": "…", "state": "open"|"closed"}]}}`. Entries of cards not examined this cycle are carried over while the card is still on the board and not Done. Board, GraphQL, `board.sh` and the `factory.yml` schema do not change.

**Layer:** `factory` only. Files:
- `scripts/shipfloor_core/deps.py` (new): `blocked_by(repo, n)` returns the dependency list or `None` on error (one `gh api` call, `?per_page=100`); `open_numbers(deps)`; `load(home)` / `save(home, record)` for `deps.json`.
- `scripts/shipfloor_core/dispatch.py`: in `run_pipeline`'s `start_run` (orphan resumes and queue starts, stages develop, validate and deploy; never refine), call `deps.blocked_by` before `block_card` and the launch. Open dependency or `None` → record it, `self.started = 0`, return `True` (no label, no slot taken, the loop moves to the next card). `run()` saves `deps.json` at the end of the cycle.
- `scripts/shipfloor_health.py`: `waiting(col)` skips a card whose record has an open dependency or `read: false`, so `idle` does not count it.
- `scripts/dashboard.py`: loads `deps.json` per project; the card payload gets `deps` (each dependency's state resolved to the board column from the board snapshot, `closed` when closed, `open` when open but off the board) and `deps_unread`; `whyWaits` data gets the open numbers.
- `scripts/dashboard.html`: the drawer "Depends on" block, the `why.deps` tile line and the `dep.unread` line, as in `## UX`.
- `scripts/lang/dashboard.*.json` (12 catalogs): keys `dep.h`, `dep.closed`, `dep.open`, `why.deps`, `dep.unread`.
- `scripts/test/fake-gh`: answer `api repos/acme/shop/issues/<n>/dependencies/blocked_by` (before the generic `issues/<n>` case, in both case blocks) from `$d/blocked-by-<n>` (a JSON array, default `[]`), exit 1 when `$d/fail-deps` exists; log each call to `$d/dep-calls`.
- `docs/operation.md`, `docs/contracts.md`: describe the check, `deps.json` and how to declare a dependency (GitHub's "Blocked by").

**Migration:** none; no schema or stored data changes. A card with no relation behaves as today.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dispatch-deps.test.sh` |
| AC-2 | factory | `scripts/test/dispatch-deps.test.sh` |
| AC-3 | factory | `scripts/test/dispatch-deps.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-deps.test.sh` |
| AC-5 | factory | `scripts/test/health-deps.test.sh` |
| AC-6 | factory | `scripts/test/dispatch-deps.test.sh` |
| AC-7 | factory | `scripts/test/dispatch-deps.test.sh` |
| AC-8 | factory | `scripts/test/dispatch-deps.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The dispatcher is the only reader of the dependency API and publishes `deps.json`; the dashboard and health read that file, so no extra API calls and the "one call per candidate per cycle" bound holds.
- The check sits in `start_run`, so it covers orphan resumes as well as new starts, and never refine (AC-7).
- A closed dependency never blocks, whether merged or "not planned" (the API `state` is all that matters).
- An open dependency that is not on the board shows as "open" (new key `dep.open`, translated in all 12 catalogs), since it has no column.
- Cards not examined this cycle keep their previous `deps.json` entry so the dashboard list does not flicker.
- Weight `heavy`: more than 6 acceptance criteria and more than 8 files.
- Migrating the PY-series text dependencies (#153) is a one-off board change by the owner, outside this PR.

## Open questions
- **Refine writes the relations:** B, a follow-up issue (recommended), or A, include now — the issue also asks refinement to record dependencies in the spec and create "Blocked by"; A adds an agent-prompt and `gh` write path to this PR.
