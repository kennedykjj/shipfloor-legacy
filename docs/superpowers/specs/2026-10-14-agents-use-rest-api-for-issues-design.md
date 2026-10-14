# Agents talk to issues through the REST API, outside the GraphQL quota — spec

**Issue:** #189 · **Branch:** `feat/189-agents-use-rest-api-for-issues` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** light

## Product
_Product Owner_

**Problem:** Skills and agents tell agents to run `gh issue …` and `gh pr view/checks/comment`, which spend the GraphQL quota (5,000 points/h) shared by every run, the dispatcher and the owner. On 2026-10-14 GraphQL was rate-limited for about 20 minutes with REST intact, and the #164 and #165 refinements died on their first calls, repeatedly.
**Audience:** the factory's owner (and developers who install the plugin), whose runs and board reads must survive a GraphQL quota outage.
**Acceptance criteria**
- **AC-1** — Given the plugin's `skills/*/SKILL.md` and `agents/*.md`, when they are scanned, then none tells the agent to run `gh issue …`, `gh pr view`, `gh pr checks` or `gh pr comment`.
- **AC-2** — Given each operation that used one of those commands (issue read, issue comment, add label, PR read, PR checks, PR comment), when the skill or agent is read, then it names the factory script where one exists (`board.sh issue`, `report.sh`) and otherwise spells out the REST `gh api repos/...` command.
- **AC-3** — Given a `gh issue …`, `gh pr view`, `gh pr checks` or `gh pr comment` instruction is added to a skill or agent, when the test suite runs, then the hygiene test fails and names the file and line.
**Out of scope:** `board.sh` itself and the dispatcher's own GitHub calls (#163); `gh pr create` and `gh pr merge` (no REST equivalent in `gh`, few calls per card); factory scripts that already use `gh api`; retry/backoff on rate limits.
**Product fit:** serves principle 1 (the board is the source of truth): runs keep reading and writing cards through a GraphQL outage. Consistent with the positioning; no conflict with what is out of scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Contracts: none (docs for agents plus one test). Layer: `factory` for all files (`shipfloor-config.sh layer-of` → factory).

Files:
- `skills/refine/SKILL.md` — step 6 comment and step 7 label.
- `skills/validate/SKILL.md` — step 4: PR read, checks wait, PR comment, issue comment.
- `scripts/test/hygiene.test.sh` — new scan over `skills` and `agents` for the forbidden commands.

REST replacements (written in the skills):
- Issue/PR comment: `gh api repos/<repo>/issues/<n>/comments -F body=@<file in tmp>` (a PR is an issue, so PR comments use the PR number).
- Add label: `gh api repos/<repo>/issues/<n>/labels -f 'labels[]=blocked'`.
- PR mergeable: `gh api repos/<repo>/pulls/<pr> --jq .mergeable` (`null` = still computing, retry; `false` = conflicting).
- Head and checks: `gh api repos/<repo>/pulls/<pr> --jq .head.sha`, then `gh api repos/<repo>/commits/<sha>/check-runs --jq '.check_runs[]|[.name,.status,.conclusion]|@tsv'`; poll every 30 s until all are `completed`; any conclusion other than success/skipped/neutral is red.
- Issue read: already `board.sh issue <n>`.

Scan: grep with `gh +(issue|pr (view|checks|comment))` over `skills/**/*.md` and `agents/*.md`; the skills must not name the forbidden commands even in prose ("instead of `gh issue comment`" would fail), so they just state the REST form.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/hygiene.test.sh` |
| AC-2 | factory | `scripts/test/hygiene.test.sh` |
| AC-3 | factory | `scripts/test/hygiene.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- `gh pr checks --watch` becomes a 30 s poll of the REST check-runs endpoint: `--watch` is GraphQL and has no REST form.
- PR comments go through the issues comments endpoint: a PR is an issue to REST, and it avoids `gh pr comment`.
- The `blocked` label uses `POST .../labels` (adds) rather than `PATCH` on the issue (which replaces all labels and could drop others).
- Comment bodies use `-F body=@<file>`, keeping the "text from a file in tmp" rule of the skills.
- Issue reads stay on `board.sh issue`; `board.sh` internals are #163's.

## Open questions
- none
