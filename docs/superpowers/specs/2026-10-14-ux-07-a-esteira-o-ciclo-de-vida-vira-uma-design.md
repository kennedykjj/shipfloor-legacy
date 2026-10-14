# [UX-07] The belt: the lifecycle becomes a line of tokens that moves only while the dispatcher is alive — spec

**Issue:** #181 · **Branch:** `feat/181-ux-07-a-esteira-o-ciclo-de-vida-vira-uma` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The lifecycle band, "Yours" and "In progress" show the same card three times; no single place answers "where is everything", and nothing says at a glance whether the factory is moving.
**Audience:** The factory's owner, in a quick check of the dashboard.
**Acceptance criteria**

- **AC-1** — Given a board snapshot (`fake-gh` and `demo-gh`), when the dashboard renders, then the belt shows each card exactly once, as a token in its board column's segment, with segments in board order and each segment's meta (count/`empty`, `1 of 2` slots, `2 for you`, `2 today`).
- **AC-2** — Given cards queued, running, waiting for the owner, blocked by infrastructure and done today, plus a stage with free slots, when the belt renders, then each token has the look of its state from the design's token table and each free slot is a dashed `free` token.
- **AC-3** — Given a card that changes column between two reads, when the second read renders, then its token travels from the old place to the new one and a gate it arrives at rings once.
- **AC-4** — Given `prefers-reduced-motion: reduce`, when a card changes column or the dispatcher is alive, then nothing animates: no travel, no moving rail, no gate ring.
- **AC-5** — Given #176's overview reports `silent` (last cycle stale), when the dashboard renders, then the rail stops and turns `bad`, and the header's status line reads `The belt stopped. Last cycle <age> ago.` with Restart; otherwise it reads `Running · <n> decisions wait for you · <a> of <b> sessions · $<cost> today`.
- **AC-6** — Given the belt, when the owner tabs through it, then every token is reachable with a visible focus, announces `#<n> <title>, <column>, <state>` (e.g. `#120 <title>, Staged, waits for you`), and Enter or a click selects the card (today: opens the today drawer).
- **AC-7** — Given a viewport under 1020px, when the belt renders, then it scrolls horizontally inside its own container and the page never scrolls sideways.
- **AC-8** — Given the change, when `DESIGN.md` is read, then the Lifecycle Band section is replaced by The Belt and the belt is recorded as the third continuous motion, allowed only because it carries state and stopped under reduced motion.

**Out of scope:** the work area (#29/37) and removing "Yours"/"In progress" with it; the logbook scrubber and replay (UX-10); the design tokens themselves (#27/37); computing the dispatcher's staleness (#176); new owner actions from the belt beyond selecting a card.
**Product fit:** Serves principle 1 (the belt only draws the board's columns from the snapshot, keeps no card state) and principle 4 (waiting-for-you tokens and gate meta point the owner to the only places they act); the moving rail is motion that carries state, consistent with a calm control room.
**Touches UI:** yes

## UX
_UX/UI Designer_

Source: `docs/design/floor-v4.md` (The belt, Tokens, Motion, Status line). Uses the v4 tokens from #27 (UX-06); no new component beyond the belt itself: the panel shell, maximize button, ghost button, `.lnk`, drawer and maximized lanes are reused.

- **Segments.** The belt replaces the lifecycle band in the same panel (title, minimize and maximize buttons kept). One row, 11 segments in board order (Inbox … Done). Stages (Refine, Develop, Validate, Deploy, Done) 13px 600 `text`; gates (Spec Review, Staged) 13px 600 `accent`; queues 13px 500 `muted`. Under the name, 12px `faint` meta: queue `3` or `empty`; stage `1 of 2`; gate `2 for you` (`accent`) or `nothing for you`; Done `2 today` (`ok`) or `nothing today`. Tokens sit under the meta, wrapping inside the segment, oldest first.
- **Gates.** Spec Review and Staged are a platform: `accent` at 6% fill, 1px inset `accent` hairline at 18%, 8px radius. A card arriving at a gate (absent from it in the previous snapshot) plays one 1.1s ease-out ring (box-shadow from 0 to 8px `accent` at 30% to 0), never on first load.
- **Tokens** (`button`, 30px high, min 54px wide, 8px radius, `#120` in Plex Mono 13px 500 tabular, `title="#120 <title> · step 4 of 7"`):

  | State | Look |
  |---|---|
  | queued | transparent, 1px dashed `edge-hi`, number `muted` |
  | running | `raise` fill, 1px `edge`, 2px bar at the bottom in `text`, width = step / steps |
  | waits for you (gate or blocked waiting for your call) | `accent` 14% fill, `accent` 45% border, number `accent` |
  | blocked by infrastructure | `warn` diagonal stripes at 14% over `panel`, `warn` border and number |
  | done today | `ok` 8% fill, `ok` 40% border, number `ok` |
  | selected (its drawer is open) | 2px `text` outline, 2px offset; a waiting one turns solid `accent` with `accent-ink` |
  | focus | the same 2px outline in `accent` (`:focus-visible` only) |

- **Ghost tokens.** Each free slot of a stage is a token with a 1px dashed `edge` border reading `free` in 12px `faint`; not focusable, `aria-hidden` (the meta `1 of 2` says it).
- **Rail.** An 8px rail spans all segments under the tokens, 2px `track` ticks every 22px, sliding right one tick per 1.8s (`background-position`, linear, infinite) while #176's last-cycle age is fresh. Stopped: animation paused where it is, fill `bad` at 12%, ticks `bad` at 40%. Decorative (`aria-hidden`); its state is said by the status sentence.
- **Travel.** A card whose column changed between two reads travels from its old box to the new one (FLIP, 950ms, `cubic-bezier(.4,0,.2,1)`, 14px upward arc at mid-path); other tokens re-flow instantly. A card new to the snapshot fades in (200ms); one that left fades out. Focus stays on a token that travels.
- **Status sentence** (header, replaces the loose stats, `role="status"` polite, 13px 500 `soft`, 8px dot before it): live `● Running · 3 decisions wait for you · 2 of 6 sessions · $1.36 today` (dot `ok`; the decisions part in `accent`, left out at zero). Stopped: dot `bad`, `The belt stopped. Last cycle 14 min ago.` (hours as `2 h 5 min`; no cycle ever: `No cycle on record.`) then a ghost **Restart** button. Loading keeps today's `Reading the factory…`; a failed read keeps the `Not updating` alert and the sentence keeps its last text.
- **Restart** never runs anything. It expands, under the sentence, one row: `Run this on this machine to restart the dispatcher:`, #176's `silent.reinstall` command in a mono code box, and a ghost `Copy` (turns `Copied` for 2s; focus moves to Copy on open, Esc or Restart again closes and returns focus). With no `silent.reinstall`: `The reinstall command is not known. See docs/install.md.` as a `.lnk`. The row closes by itself when cycles arrive again.
- **Click and maximize.** A token click (or Enter/Space) opens today's drawer for that card, by today's routing (waiting card: wide drawer on Review; running: maximized on Live). The line peek is removed. The panel's maximize button opens today's maximized lifecycle unchanged (lanes, moves, drag, keys); minimized, the belt is its heading.
- **Narrow.** Under 1020px the belt scrolls horizontally inside its panel (`overflow-x: auto`, segments min 96px, gates min 132px), the page never does; the focused token is scrolled into view (`inline: nearest`). Under 600px the meta stays, the status sentence wraps under the brand and drops the sessions and cost parts (they stay in the title attribute).
- **Keyboard and screen reader.** The belt is a `role="group"` labelled `The belt`, one tab stop (roving tabindex like the History charts): Left/Right go to the previous/next token across segments, Home/End to the first/last, Enter/Space open. Each segment is a `role="list"` labelled by its name and meta. A token's name: `#120 <title>, Staged, waits for you`; others `, Develop, running, step 4 of 7` / `, Inbox, queued` / `, blocked by infrastructure` / `, blocked` / `, done today`. Tokens travelling or rings are not announced; the name updates.
- **Reduced motion** (`prefers-reduced-motion: reduce`): rail static, no travel (tokens jump), no gate ring, no fade; the running/stopped state is still in the sentence, rail color and dot. Copy (en / pt-BR; the other 10 catalogs get the same entries, English until filled): `empty`/`vazio` · `1 of 2`/`1 de 2` · `2 for you`/`2 para você` · `nothing for you`/`nada para você` · `2 today`/`2 hoje` · `nothing today`/`nada hoje` · `free`/`livre` · `Running`/`Andando` · `3 decisions wait for you`/`3 decisões esperam você` (`1 decision waits for you`/`1 decisão espera você`) · `2 of 6 sessions`/`2 de 6 sessões` · `$1.36 today`/`$1.36 hoje` · `The belt stopped. Last cycle 14 min ago.`/`A esteira parou. Último ciclo há 14 min.` · `No cycle on record.`/`Nenhum ciclo registrado.` · `Restart`/`Religar` · `Run this on this machine to restart the dispatcher:`/`Rode isto nesta máquina para religar o dispatcher:` · `Copy`/`Copiar` · `Copied`/`Copiado` · `The reinstall command is not known. See docs/install.md.`/`O comando de reinstalação não é conhecido. Veja docs/install.md.` · `The belt`/`A esteira` · `waits for you`/`espera você` · `running, step 4 of 7`/`rodando, passo 4 de 7` · `queued`/`na fila` · `blocked by infrastructure`/`bloqueado pela infraestrutura` · `blocked`/`bloqueado` · `done today`/`saiu hoje`.

## Architecture
_Tech Lead_

All in the `factory` layer; no server contract changes beyond reading what #176 adds.

- **Contracts read:** the overview's `silent` (`{min, every, check, reinstall}` or null, from #176) for the rail, the status sentence and Restart; today's `pool.stages[stage]` (`slots`, `running`) for the slot meta and ghost tokens; per-card `column`, `running`, `blocked`, `awaiting`, cost, `S.seen` (column-change detector) and `runOf()/progress()/STEP_COUNT` for token state and bar. "Done today" and "decisions waiting" come from the data `renderYours`/the header stats already compute; if a figure is missing in the overview, `scripts/dashboard.py` adds it to the project payload (one integer, `done_today`).
- **`scripts/dashboard.html`:** `renderBand` becomes `renderBelt` (same `#band` panel, `#cells` becomes the belt container; maximize, minimize and the maximized lanes untouched); new `renderStatus` replaces the header stats; the line peek (`renderPeek`, `peek()`, `#peek`) is removed and a token click goes to the existing open-drawer routing; FLIP travel keyed by `data-key` (replaces the dot slide, 950ms, arc), gate ring on arrival (never on the first read), CSS rail animation, roving-tabindex keyboard, `@media (prefers-reduced-motion: reduce)` and `(max-width: 1019px)` rules, Restart row with Copy.
- **i18n:** new `belt.*` and `status.*` keys in all 12 `scripts/lang/dashboard.*.json` (en and pt-BR as the UX section gives; the other 10 carry the English text, because the catalog test requires every key in every language). Keys of the removed peek and band dots are deleted from all 12.
- **`DESIGN.md`:** Lifecycle Band and Line Peek sections replaced by The Belt; overview, Motion and Do's/Don'ts say three continuous motions (dial, dot pulse, belt) and the belt's rule; front matter description updated.
- **Files:** `scripts/dashboard.html`, `scripts/dashboard.py` (only if `done_today` is missing), 12 `scripts/lang/dashboard.*.json`, `DESIGN.md`, new `scripts/test/py/dashboard_belt.py` and `belt_page.py` (run by `dashboard-views.test.sh`), `scripts/test/py/dashboard_v4.py`, and the existing tests that name the band or peek: `dashboard-first-screen`, `dashboard-short`, `dashboard`, `dashboard-accent`, `dashboard-targets`, `dashboard-move`, `design-doc` (`.test.sh`).
- **Order:** develop only after #180 (UX-06 tokens: `raise`, `accent-ink`, `accent-soft`, `accent-line`) and #176 (`silent`) are merged.
- **Migration:** none. **Rollback:** revert the commit.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-8 | factory | `scripts/test/theme.test.sh` |

The belt's cases live in `scripts/test/py/dashboard_belt.py` (with `belt_page.py`), run by `dashboard-views.test.sh`; AC-8's DESIGN.md checks join `scripts/test/py/dashboard_v4.py`, run by `theme.test.sh`. No new `*.test.sh`: `hygiene.test.sh` caps the suite count and is never raised to fit a new file.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The maximized lifecycle (lanes, moves, drag) stays behind the belt's maximize button: the issue replaces the band, not the owner's move tools.
- The line peek is removed; a token click opens today's drawer, as the issue says, until the work area (#29/37) exists.
- Restart shows and copies #176's reinstall command and runs nothing: the dashboard stays read-only toward the machine's scheduler (local-only, no privileged action from a web page).
- The 10 non-en/pt-BR catalogs get the English text for the new keys: the catalog test needs every key everywhere, and translations are a follow-up.
- Develop waits for #180 and #176; both are open today and the belt builds on their tokens and `silent` field.
- In develop, the test plan moved from three new suites to `dashboard-views.test.sh` and `theme.test.sh`: main's test diet set a ceiling on `*.test.sh` files that a card may not raise.
- Weight heavy: more than 6 acceptance criteria and more than 8 files.

## Open questions
- none
