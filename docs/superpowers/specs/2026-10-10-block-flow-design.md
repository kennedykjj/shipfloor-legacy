# Block and unblock flow

Date: 2026-10-10. Status: approved by the owner in conversation (sections 1 to 4), spec review waived.

## Why

On the night of 2026-10-09 seven Pickio cards were blocked. One label (`blocked`) covered four different things: a bug in a gate (#83), a decision only the owner can take (#100, #39, #86), an outside cause that fixed itself (#80) and forgotten state (#40, a label on a Done card). The owner's words: too many blocks reach me, I cannot see the specific reason easily, most reasons are easy to resolve, and I do not find out a card is blocked.

Today a block is a label plus a long agent comment; an unblock removes the label and the factory repeats the same stage, knowing nothing new.

## Goals

1. Fewer blocks reach the owner: the factory resolves the known kinds itself.
2. Every block states its specific cause in one sentence, on the issue and on the dashboard.
3. The owner is told, on the issue (with an @ mention only when their action is needed) and on the dashboard.
4. Every resolution is recorded, and what the factory resolved on its own is shown when the owner approves the card in Staged.
5. Gates stay scripts. No agent overrides a gate.

Out of scope: push or system notifications, semantic search over history, the factory rewriting its own rules.

## 1. The block record

`scripts/block.sh` is the only way to block a card. Skills and scripts call it; none adds the `blocked` label directly.

    block.sh <n> <kind> --stage <stage> --cause "<one sentence>" [--needs "<what unblocks>"]
             [--gate <gate>] [--file <path>]... [--commit <sha>]... [--url <url>]... [--report <file>]

It writes `<project home>/blocks/<n>.json`, adds the label (`blocked:infra` for kind `infra`, `blocked` otherwise) and posts an issue comment whose first line is the cause.

Record fields: `issue`, `kind`, `stage`, `cause`, `needs`, `evidence` (`gate`, `files`, `commits`, `urls`), `since` (ISO time), `attempts` (resolution attempts so far, objects with `by`, `action`, `at`, `note`), `handler` (`script`, `unblocker` or `owner`), and for an owner question `question` and `options`.

Kinds (closed list): `acceptance-changed`, `external`, `gate-failed`, `infra`, `needs-owner`, `unknown`.

`scripts/unblock.sh <n> --by <script|unblocker|owner> --action <action> --reason "<one sentence>"` removes both labels, appends the closed record to the history (section 3), deletes `blocks/<n>.json` and posts a short comment saying what was done. The dashboard's Unblock button and `aghanim accept` go through it.

Reconciliation, every dispatcher cycle (`resolve.sh`, section 2): a label without a record gets an `unknown` record built from the last issue comment that mentions the block; a record without a label gets the label back; a card in Done with a block is unblocked (`by script`, action `cleanup`).

The label stays the thing that makes the dispatcher skip a card, so nothing that works today changes.

If GitHub is unreachable, the local record is still written; label and comment are retried on the next cycle (the record carries `synced: false`).

## 2. Who resolves

Both layers run at the start of each dispatcher cycle, before the stages are launched.

### Layer 1: script resolvers (`scripts/resolve.sh`)

No agent, no tokens. For each record:

| Kind | Rule | Gives up |
|---|---|---|
| `infra` | clean up and retry the stage once (today's `retry_infra`) | on the second failure: kind becomes `gate-failed`, handler `unblocker` |
| `external` | when `origin/<main>` moved since the block, or the PR's failing check is now green: unblock (action `retry`) | after 3 attempts or 24 hours: handler `unblocker` |
| `acceptance-changed` | passes when every commit that touched the listed files after the QA commit is either a commit by the QA role or a merge whose result is what a clean merge gives (`only_main_changed`); then record the acceptance (`accepted.tsv`) and unblock (action `accept`) | another role edited the file, or a merge needed a hand resolution: handler `unblocker` |
| any, card in Done | unblock (action `cleanup`) | never |

A commit's role is read from a trailer the skills add to every agent commit: `Factory-Role: <agent>` (for example `qa-engineer`, `backend-engineer`, `tech-lead`). The gate `acceptance-intact` also uses it: the baseline is the last commit with `Factory-Role: qa-engineer` that touched the file, falling back to the commit whose message says "acceptance tests for #<n>" when no trailer exists.

A record a resolver gives up on keeps its attempts and moves to layer 2.

### Layer 2: the `unblocker` agent

A new stage, `unblock`, with its own pool limit (`stages.unblock`, default 1). The dispatcher launches it only when a record has `handler: unblocker`, one card at a time, at most 2 attempts per block. It does not run while the Claude usage limit pauses the factory; layer 1 still does.

Input: the record, the report of the stage that blocked, the relevant diff, and similar closed cases from the history.

It acts only through `scripts/unblock-action.sh <n> <action> ...`:

1. `retry --note "<what changed>"`: unblock; the note is handed to the stage's next run.
2. `wait --cause "<...>"`: reclassify as `external`, handler `script`.
3. `to-qa --file <path> --note "<...>"`: unblock with a note that the QA agent must re-commit the acceptance file (a new baseline).
4. `accept --reason "<...>" --evidence <file>`: record the acceptance of the files as they stand (the existing `aghanim accept`), attach the test-by-test comparison, unblock.
5. `ask-owner --question "<one sentence>" --option "<...>" --option "<...>" [--option "<...>"]`: handler `owner`; the issue comment starts with the question and mentions the owner with @.

It cannot edit code or tests, change gate configuration, move a card into an owner column, or approve. After it acts the card goes back to its stage and the gates run again. A second block with the same kind and gate counts as an attempt; on the second attempt the only action left is `ask-owner`.

`accept` is the one action that changes what a gate accepts. Its guards: it holds only for the exact file content; the reason and comparison go to the history; and every `accept` by the agent is highlighted on the owner's Staged decision (section 4).

## 3. History

`<project home>/blocks/history.jsonl`, one line per closed block: the original record plus `resolved_by` (`script`, `unblocker`, `owner`), `action`, `reason`, `closed` (ISO time), `duration_s`, and `worked` (set later: `true` when the card left the stage, `false` when it blocked again with the same kind and gate, or when the owner used Request changes on a card whose block the agent resolved).

The agent receives the closed cases with the same kind and gate, newest first (a script filter, no semantic search).

When the same kind and gate was resolved by the same action 3 times in a row, `aghanim doctor` suggests turning it into a layer 1 rule. The factory never rewrites its own rules.

`aghanim metrics` gains: blocks per week, resolved by script, by the agent, by the owner, and mean time blocked.

Seed: the seven blocks of 2026-10-09/10 are written as the first lines of Pickio's history from their issue comments.

## 4. What the owner sees

Issue: a short comment when a block starts (cause first, then kind and who handles it), another when it is resolved; an @ mention only for `ask-owner`.

Dashboard header: a "blocked" count beside "awaiting you", opening the block list. "awaiting you" counts approvals plus blocks whose handler is the owner. The tab title carries the awaiting count: "(3) Aghanim's Anvil".

Block list (in the drawer): one row per block, owner's first: card number and title, the cause, how long it has been blocked, and the handler ("script: waiting for main", "unblocker: attempt 1", "you").

Card: the small flag keeps the color on the word only: "blocked · needs you" (needs you in azure), "blocked · factory is on it", "infra · retrying".

Drawer: the block note shows the record (cause, evidence as links, attempts); the full report stays folded. For `ask-owner` the "Your decision" block shows the question and its options as buttons; choosing one records the answer, unblocks the card and hands the decision to the stage's next run.

Staged decision: a line "The factory resolved N blocks on this card", expanding to each resolution; an `accept` by the agent is highlighted with the test diff, and Approve asks twice while one is unopened.

## Errors and edge cases

- Corrupt record or unknown kind: treated as `unknown`, handler `unblocker`; if the agent fails too, `ask-owner` with the raw report.
- GitHub unreachable: local record kept, label and comment retried next cycle.
- Usage limit: the agent waits; script resolvers run.
- Old blocks without a record: reconciliation builds an `unknown` record.

## Testing

- `block.sh` / `unblock.sh`: record, label, comment, history, with the fake `gh`.
- `resolve.sh`: one case per rule, the attempt and time limits, and `acceptance-changed` with commits carrying QA and engineer roles.
- Dispatcher: the `unblock` stage respects the pool, does not run without a pending record, stops at 2 attempts.
- `unblock-action.sh`: each action; anything outside the list is refused; the second attempt allows only `ask-owner`.
- Dashboard: the overview returns blocks with cause and handler; answering an `ask-owner` records the answer and unblocks.
- Skills: a test asserts none of them adds the `blocked` label directly.

## Delivery order

Each step is useful on its own.

1. Record, `block.sh`, `unblock.sh`, reconciliation, and the cause on the dashboard and the issue.
2. Script resolvers and the `Factory-Role` trailer.
3. History and metrics.
4. The `unblocker` agent and `ask-owner` with buttons.
5. The resolutions line on the Staged decision.
