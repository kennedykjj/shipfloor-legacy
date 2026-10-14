# Plan — Tests that pin behavior (#161)

Spec: `docs/superpowers/specs/2026-10-14-py-08-tests-that-pin-behavior-board-design.md`

Most of this issue is acceptance tests that pin today's behavior. QA writes them in step 3. They run green against today's scripts, except the setup-board test, which needs `FACTORY_GH`. The only code change is that one.

## Tasks

### T1 — setup-board honors `FACTORY_GH` (layer: factory, agent: engineer)
- **Files:** `scripts/setup-board.sh`
- **What:** every `gh` call goes through `"${FACTORY_GH:-gh}"` (the same form `board.sh` uses), so the fake gh in `scripts/test/setup-board.test.sh` replaces it. No other behavior changes: options, labels, the restore, `board-ids` removal, counts and `SNAPSHOT` stay as they are.
- **Depends on:** the QA commit (acceptance tests for #161).
- **Done when:** `scripts/test/setup-board.test.sh` passes and every other acceptance test file still passes.

## Acceptance test files (QA, step 3)
| AC | File |
|---|---|
| AC-1 | `scripts/test/board.test.sh` (extend) |
| AC-2 | `scripts/test/setup-board.test.sh` (new) |
| AC-3 | `scripts/test/report.test.sh` (extend) |
| AC-4 | `scripts/test/metrics.test.sh` (new) |
| AC-5 | `scripts/test/review-page.test.sh` (extend) |
| AC-6 | `scripts/test/shipfloor-config.test.sh` (new) |
| AC-7 | `scripts/test/inbox-hook.test.sh` (new) |
| AC-8 | `scripts/test/shipfloor-cli.test.sh` (extend) |

Pinning rule: a test records what the script does today, odd results included. A test is never "fixed" by changing a script, except T1.
