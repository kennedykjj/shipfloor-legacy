# The Floor, v4: a calm belt, one thing at a time, decisions in seconds

Status: proposal, approved by the owner on 2026-10-13 for implementation. The interactive mockup is
[`floor-v4.html`](floor-v4.html) (open it in a browser; it runs a simulated day from 14:20 with example cards).
Every card, title, brief, cost and time in the mockup is an example.

This document is the source for the issues that build it (UX-03 to UX-10). When a piece ships, its rules move into
`DESIGN.md` and this document keeps only what is still to come.

## Why

The owner keeps the dashboard in a pinned desktop tab and names two pains:

1. **Deciding takes long.** Approving a spec or a PR means opening the review, reading all of it, comparing, coming back.
2. **The page is dense.** The lifecycle band, "Yours", "In progress" and "History" all compete; every card carries its
   step, tool, clock and cost; uppercase condensed type everywhere flattens the hierarchy.

Three things the owner wants kept from the earlier proposals: the belt (the pipeline drawn as a production line that
moves only while the dispatcher is alive), the day's replay, and the tab title plus a command palette.

## Principles

- **A card is its number until you select it.** Detail lives in one place, for one card at a time.
- **One accent, one meaning.** The accent marks what waits for the owner, nothing else. Money, headings and outlines
  are ordinary text.
- **The owner reads what needs their eyes first.** Every decision opens with a verdict and only the flagged parts;
  the rest is folded. What the gates computed is labeled as computed; what an agent wrote is labeled as the agent's.
- **Motion means something.** The belt moves only while dispatcher cycles arrive on time. A card that changes stage
  travels to its new place. Under `prefers-reduced-motion` nothing animates and every state is still said in words.
- The existing principles hold: the board is the source of truth, gates outrank any agent's claim, numbers are exact
  and sourced, the owner acts only where the factory waits for the owner.

## Layout

From top to bottom, in the Floor view (today's Factory view):

1. **Header**: the brand, the views (Floor, Diário/Feed, Settings), the status line, the command palette button.
2. **The belt** (replaces the lifecycle band): one straight line, left to right, with every column as a segment.
3. **The logbook scrubber**, thin, attached under the belt (UX-10).
4. **The work area**: a single panel that shows one thing: the next decision, a live run, a selected card, or a calm
   summary. It replaces the "Yours" and "In progress" panels. "History" moves to the logbook (the Feed view).

There is no separate inspection mode: deciding happens in the work area.

### Status line

One sentence in the header, never a panel: a dot (ok while cycles arrive, bad when the dispatcher stopped, a square in
the accent during a replay), then `Running · 3 decisions wait for you · 2 of 6 sessions · $1.36 today`.
Stopped: `The belt stopped. Last cycle 14 min ago.` with **Restart**. Replay: `Replay at 09:40. The belt is as it was.`
with **Back to live**. It is a polite live region.

### The belt

- Segments in board order: Inbox, Ready for Refinement, **Refine**, *Spec Review*, Ready for Dev, **Develop**,
  **Validate**, *Staged*, Ready for Prod, **Deploy**, Done. Stages (bold) and gates (accent) name themselves in 13px
  600; queues in 13px 500 `muted`. Under each name, 12px `faint` meta: a queue's count or `empty`, a stage's
  `1 of 2` slots, a gate's `2 for you` (accent) or `nothing for you`, Done's `2 today` (ok).
- A gate segment is a raised platform: the accent at 6% with a 1px inset accent hairline at 18%. When a card arrives
  at a gate, the platform rings once (one 1.1s ease-out ring, not continuous).
- The belt itself is an 8px rail under all segments, a 2px tick every 22px in `track`, moving right at one cycle per
  1.8s. It pauses during a replay and turns `bad` at 12% when the dispatcher stopped (the staleness signal is #176's).
- Free slots of a stage show as dashed ghost tokens reading `free`.
- The line scrolls horizontally inside its own container under 1020px; the page never does.

### Tokens

A card on the belt is a token: 30px high, 8px radius, at least 54px wide, the number in Plex Mono 13px 500, tabular.

| State | Look |
|---|---|
| queued in a stage (no run) | transparent, dashed `edge-hi`, number `muted` |
| running | `raise` fill, a 2px progress bar at the bottom in `text`, width = step / steps |
| waits for the owner | accent at 14% fill, accent at 45% border, number in the accent |
| selected | 2px `text` outline, 2px offset; a waiting card turns solid accent with `accent-ink` |
| blocked by infrastructure | diagonal stripes of `warn` at 14% over the panel, `warn` border and number |
| done today | `ok` at 8% fill, `ok` at 40% border, number in `ok` |

A token's title attribute is `#<n> <title> · step <s> of <steps>`. Clicking it selects the card (the work area shows
it). When a card changes column, its token travels from the old place to the new one (FLIP, 950ms, a 14px arc), so a
move is seen, not inferred.

### The work area

One panel, 16px radius, 28px vertical and up to 36px side padding. Its content swaps with a 260ms slide out and a
400ms slide in (none under reduced motion). What it shows:

- **Decide** (a waiting card is selected, the default whenever one waits, oldest first):
  - Head: the number as a mono chip in the accent, the column, `waiting 3 h 50 min`; at the right
    `1 of 3 decisions`, progress dashes (done `ok`, current accent) and `next: #129`.
  - Title at 24px 500, at most 40ch.
  - Left, the **brief** (see below). Right, sticky, **Your decision**: Approve (solid `text`, `ground` ink, its
    destination in a second line, `A`), Request changes (its destination, `R`), Skip for now (`N`), and a link to the
    full review page (today's Review tab). Request changes opens the suggestions (one per flag, accent-tinted buttons
    that fill the note), the note and Send (`Enter`).
  - After a decision the token travels on the belt and the next waiting card slides in. With none left, Calm.
- **Run** (a running card is selected): the stage's steps as a stepper (done `muted`, current `text` 600), the last
  five tool calls as a mono stream (time, tool, target), the field to say a word to the run (today's Live), and at the
  right the step, the clock and the cost estimate, Log and GitHub.
- **Card** (any other card): its state in words and its cost estimate.
- **Calm** (nothing waits, nothing selected): `Nothing waits for you` at 34px 600, then three columns: the next
  decisions (runs nearest a gate, with what comes after), what runs now, and what shipped today (PR, time, cost from
  Inbox to Done).

Keyboard: `A`, `R`, `N` in Decide (not while typing); `Esc` closes the suggestions, then the palette.

### The decision brief

Built for the gate the card sits at; shown top to bottom, each block titled in 14px 600 with a source chip:

1. **Verdict** pill: `Routine: nothing flagged` (`ok`) or `1 point needs your eyes` / `Came back: 3 statements changed
   since your request` (accent).
2. **What you approve**, 16px/1.6, at most two sentences. Source chip: `written by the product owner` (Spec Review)
   or `written by the review agent` (Staged).
3. **Needs your eyes**, only when flags exist: one card per flag on `paper`, a 2px accent left edge, the title in 15px
   600, one or two lines of detail, and an optional diff hunk in mono. Source chip: `flagged by the gates`.
4. **Since your request** (a card that came back): each changed statement with the old text struck and the new below;
   a new statement is labeled `new`. Source chip: `computed diff`. This is #177's data.
5. **What the gates proved**: check-marked short names of the gates that passed, then the facts in mono
   (`PR #66 · 6 files · +142 −38`). Source chip: `computed, not declared`.
6. **The rest, which needed no attention (N)**: folded; optional review notes, untouched statements.

The brief's data contract is in [Data](#data). An agent never writes a verdict, a flag or a proven gate: those come from
scripts. An agent writes only `what` and one suggestion per flag.

### Address, tab and palette

- **Address**: the hash carries the selected card (`#card/120`) and a replay time (`#@0940`). Back closes what was
  opened. A notification link (`Click` header of ntfy) can open a decision directly when read on this machine.
- **Tab**: the title is `(3) Shipfloor · ATLAS` while 3 decisions wait, `Shipfloor · ATLAS · stopped` when the
  dispatcher stopped. The favicon is a 14px square: neutral, the accent while something waits, `bad` when stopped.
- **Command palette**: `Ctrl K` / `Cmd K` and the header button. One field, up to nine results: actions (Next decision,
  Back to live, Show the belt at a time), then cards by number or title with their column. Arrows, Enter, Esc.

### The logbook scrubber

Under the belt, 38px: a 1px lane with marks at the time they happened: a 2px `ok` tick when a run ended, a taller
`bad` tick for a block, an 8px accent diamond for each owner decision (title: `13:05 · #121 you approved the PR`).
Hours in mono 11.5px. The future is hatched. A playhead (2px `text` line with a 10px dot) sits at the time shown;
dragging it replays the belt as it was (tokens travel backwards), with the status line in replay. `Back to live`
returns. The day's runs and decisions come from the logs the dashboard already reads; card positions come from the
board history (UX-10).

## Visual system

### Type

IBM Plex Sans (400, 500, 600, 400 italic) for everything read; IBM Plex Mono (400, 500) for card numbers, times,
figures and code. Both under the SIL Open Font License; both embedded as `@font-face` data URIs, latin and
latin-ext subsets, woff2, the way Barlow is today. No uppercase transforms anywhere; hierarchy is weight and size.

| Role | Size / weight / line |
|---|---|
| Calm headline | 34px 600, -0.02em |
| Card title | 24px 500 / 1.3, -0.012em |
| Panel title, view name | 17px 600 |
| Body, brief prose | 16px 400 / 1.6 (brief), 15px / 1.55 (UI) |
| Block title, segment name | 14px 600 / 13px 600 |
| Meta, captions | 13px 500 `muted`, 12px 400 `faint` |
| Mono figures | 13px 500, tabular |

Nothing under 12px. Running text at most 64ch.

### Color

Two new themes, the new defaults under Auto: **Graphite** (dark) and **Paper** (light). The other themes stay and
follow the same token rules; each needs a value for the new tokens.

| Token | Graphite | Paper | Use |
|---|---|---|---|
| `ground` | `#141412` | `#f4f2ec` | page |
| `panel` | `#1b1b19` | `#faf9f5` | belt, work area |
| `panel-hi` | `#23231f` | `#ffffff` | decision panel, palette |
| `raise` | `#2a2925` | `#ffffff` | running tokens |
| `edge` / `edge-hi` | `#2e2d29` / `#44423c` | `#e2ddd2` / `#cdc6b8` | hairlines, outlines |
| `text` / `soft` | `#ecebe6` / `#cbc8bf` | `#1f1d19` / `#3e3a33` | reading |
| `muted` / `faint` | `#a29f95` / `#8b887f` | `#5f5a51` / `#6f6a60` | labels, meta |
| `accent` / `accent-ink` | `#e9b44c` / `#1d1606` | `#8f5b00` / `#ffffff` | what waits for the owner |
| `ok` / `warn` / `bad` | `#86c29c` / `#e59a62` / `#e8806f` | `#2f7a4b` / `#a2531a` / `#b4372a` | outcomes |
| `track` | `#3b3a35` | `#d9d3c6` | the belt's ticks |
| `paper` | `#1f1e1b` | `#fffdf8` | flag cards |

Derived: `accent-soft` = accent at 14%, `accent-line` = accent at 45%, `hair` = ink at 8%.
`scripts/test/theme.test.sh` keeps refusing text under 4.5:1 on ground and panels; `faint` and the Paper accent were
chosen to pass it.

**Rule change**: today the accent (`sand`) marks money and what waits for the owner. In v4 it marks only what waits for
the owner. Costs are `text` with `est`.

### Space and shape

Spacing on a 4/8 grid. Panels 16px radius; the decision panel 14px; tokens 8px; chips and pills fully rounded.
Panels are flat at rest with a hairline; the decision panel and the palette are the only raised surfaces.

### Motion

| Motion | Rule |
|---|---|
| Belt | continuous while cycles arrive on time; paused in a replay; stopped when the dispatcher stopped |
| Token travel | on a column change, 950ms |
| Gate ring | once, when a card arrives at a gate |
| Work area swap | 260ms out, 400ms in |
| Run stream | the newest line fades in |

The belt is a third continuous motion, beyond the dial and the dot's pulse that `DESIGN.md` allows today. It earns
its place because it carries state. Everything above stops under `prefers-reduced-motion: reduce`.

## Data

### The brief: `<reviews>/<n>.brief.json`

Written next to the review page (`<reviews>/<n>.html`) by a script, when the card reaches Spec Review (refine,
step 6) and Staged (validate, step 4). The dashboard serves it with the card.

```json
{
  "card": 120,
  "column": "Staged",
  "built": "2026-10-13T10:30:00Z",
  "verdict": "look",
  "what": { "text": "Replaces the sync worker's polling loop with a queue consumer. The retry policy does not change.", "by": "review" },
  "flags": [
    { "id": "migration-0042", "kind": "migration", "title": "A new migration runs before the deploy",
      "detail": "0042_sync_queue creates the queue table. It is the only file outside app/sync/.",
      "hunk": "+ CREATE TABLE sync_queue (...)", "source": "gate:migration",
      "suggestion": "Move the migration to its own card, shipped first" }
  ],
  "since_request": [ { "old": "The order page shows the delivery window.", "new": "The order page and the confirmation e-mail show the same delivery window." } ],
  "proven": [ "red", "green", "acceptance-intact", "scope", "build", "migration" ],
  "facts": { "pr": 66, "files": 6, "added": 142, "removed": 38, "statements": null },
  "rest": [ "Review: consumer.py could be named queue_consumer.py (optional)" ]
}
```

- `verdict` is `look` when `flags` or `since_request` is not empty, else `routine`. Computed, never written by an agent.
- `flags` come from scripts only. First kinds: `migration` (a new or changed migration, from `gate migration`),
  `outside-architecture` (a changed file the spec's `## Architecture` does not name), `qa-amended` (an acceptance test
  QA amended, from the report's `amendments`), `open-question` (the spec's `## Open questions` is not empty),
  `security` (a filled `## Security` section or a 🔴 cybersec finding), `infra-retry` (the card was blocked by
  infrastructure and retried).
- `since_request` is #177's statement diff against the version of the spec the owner last decided on.
- `proven` lists only gates whose recorded verdict for this head is a pass.
- `what` and each flag's `suggestion` are the only agent-written fields. The agent hands them in a notes file
  (`<tmp>/brief-notes.json`: `{"what": "...", "suggestions": {"<flag id>": "..."}}`); the script validates their
  length (what: at most 280 characters; a suggestion: at most 120) and drops unknown flag ids.
- A card with no brief file shows the review page as today; the brief is an addition, never a requirement to decide.

### Board history (for the replay): `<project home>/logs/board-<YYYY-MM>.jsonl`

One line per dispatcher cycle in which `board.tsv` changed: `{"t": "<ISO time>", "cards": {"120": "Staged", ...}}`.
The dashboard rebuilds the belt at a time from the last line at or before it. A month of lines is small (a line per
change, not per cycle). Runs and decisions for the scrubber marks come from the run logs and the board moves the
dashboard already reads.

## What changes in DESIGN.md

- Typography: Plex Sans and Plex Mono replace Barlow and Barlow Condensed; no uppercase transforms; the scale above.
- Colors: Graphite and Paper become the Auto pair; the accent marks only what waits for the owner.
- Layout: the belt replaces the lifecycle band; the work area replaces "Yours" and "In progress"; History moves to the
  Feed (logbook).
- Motion: the belt is the third continuous motion, under the rule above.
- Components: Line Peek and the Tooltip Drawer give way to the work area's modes; the Review tab stays as "the full
  review page".
