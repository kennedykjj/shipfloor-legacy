# Fast and safe deploy — design

**Date:** 2026-10-09 · **Status:** approved in conversation (items 1–4, 6, 7; item 5 limited by the GitHub plan)

## Problem

The first deploys on the generic factory took ~10 minutes of which ~5 were a local rerun of the build and acceptance tests that CI repeats on the same head. Every step was carried out by the model from prose, so a skipped or reinterpreted step was possible. A deploy that the platform reports as successful but that serves errors is not detected. A migration's upgrade path is only tested from an empty database.

## Decisions

1. **Deterministic deploy.** `scripts/deploy.sh <n>` runs the whole deploy and is launched by the dispatcher directly (no agent, no tool timeout). Only when it exits 3 (conflicts) does the dispatcher call the `/mylos:deploy` agent to resolve them, then runs `deploy.sh <n> --continue`, which verifies the resolution (merge of the approved head and main, only conflicted files changed).
2. **No duplicate tests in the deploy.** The script runs the fast deterministic gates (`forbidden`, `migration`, `acceptance-intact`); build and tests are CI's job on the exact head that will be merged.
3. **Staged cards stay up to date.** Each dispatcher cycle refreshes cards in Staged and Ready for Prod whose PR is behind main: `deploy.sh <n> --refresh` merges main (only when it merges cleanly), runs the fast gates, pushes and records `deploy-merge`. When the owner approves, the head is usually ready and the deploy is only CI + merge + production.
4. **Faster CI (Pickio):** pull requests run only the jobs of the layers they change; pushes to main run all.
5. **Up-to-date enforcement on GitHub:** branch protection and merge queues need GitHub Pro on private repositories (`403`). The factory enforces "head contains current main" itself; `mylos doctor` reports whether `strict` protection is on. Remaining risk: a hand merge between the deploy's last check and its merge (caught by main CI + automatic revert).
6. **Health check after deploy.** `deploy.healthcheck: [url, …]` in `factory.yml`; after the platform reports success, each URL must answer 2xx (5 tries, 15 s apart). Failure triggers the existing revert flow.
7. **Migration upgrade check (Pickio CI):** on pull requests, a job applies main's migrations to a fresh PostgreSQL, then the PR's; Flyway's validation fails on duplicate versions, out-of-order versions and edited applied migrations — the upgrade path production takes.
8. **English output.** Every skill states that comments, reports, PR texts and specs are written in English.

## `deploy.sh`

```
deploy.sh <n> [--refresh | --continue]
exit 0 done (deploy: card in Done; refresh: up to date or nothing to do)
     3 conflicts to resolve: prints "CONFLICT <file>" lines, the worktree is left mid-merge (deploy only)
     4 sent back to Coding (comment with the reason)
     5 blocked before merge (label + comment)
     6 failed after merge: revert PR opened, issue reopened and blocked
     2 usage or configuration error
```

Steps:
1. Card status must be `Ready for Prod` (refresh: `Staged` or `Ready for Prod`). Exactly one open PR whose head is `feat/<n>-…` or `revert/<n>`.
2. Accepted heads: the last `staged-head: <sha>` comment by the factory's own GitHub user, and every `deploy-merge: <sha> <main>` it wrote after it whose first parent is an accepted head and whose second parent is on main. Fork PRs are refused. The worktree must hold exactly the head GitHub reports. The PR head must be one of them; otherwise blocked ("PR changed after it was staged").
3. Worktree `<worktrees>/<n>` reset to the PR head (not with `--continue`).
4. If the head does not contain `origin/<main>`: merge it with a factory commit message and trailer.
   - Conflicts: a migration file among them, or more than `conflict_max_files`/`conflict_max_hunks` → abort, back to Coding (exit 4). Otherwise deploy exits 3 for the skill to resolve and rerun with `--continue`; refresh aborts and leaves it to the deploy.
5. Fast gates against `mb = merge-base(HEAD, origin/<main>)`: `forbidden mb`, `migration mb <spec>`, `acceptance-intact <qa>` (when a QA commit exists). Failure after a merge → back to Coding.
6. Push and comment `deploy-merge: <head> <main sha>`. Refresh ends here.
7. Wait for the head's checks (`statusCheckRollup`, up to 30 min). Red after a merge → back to Coding; red otherwise → blocked.
8. Fetch; if main moved and is no longer contained, go back to 4 (at most 3 times).
9. `gh pr merge --squash --match-head-commit <head>`.
10. Wait for main CI (`ci_workflow`), the deployment (`environment`, `timeout_min`) and the health checks. Failure → revert PR (`revert/<n>`), issue reopened, `blocked`, exit 6.
11. Done: card to Done, success comment (merge sha, minutes, deployment URL), worktree removed, report published.

The dispatcher launches refreshes as background jobs with a `refresh-<n>` lock; they are not agents and do not use the pool.

## Tests

Fake `gh`/board/git remote fixtures cover: up-to-date head → merged and Done; behind main → merge, push, `deploy-merge` comment; migration conflict → Coding; small conflict → exit 3, then `--continue` completes; unknown head → blocked; red CI after merge → Coding; failed health check → revert PR and blocked; refresh behind main → pushed and recorded, refresh with conflict → untouched.
