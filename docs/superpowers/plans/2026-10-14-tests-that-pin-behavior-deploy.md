# Tests that pin behavior: deploy — plan

**Issue:** #159 · **Spec:** `docs/superpowers/specs/2026-10-14-tests-that-pin-behavior-deploy-design.md`
**Branch:** `feat/159-tests-that-pin-behavior-deploy`

`deploy.sh` is not edited. The acceptance tests are the deliverable: they pin today's behavior.
They are red at first only where they rely on a fake-gh / deploy-lib switch that does not exist yet;
task 1 adds those switches and turns them green.

## Acceptance tests (QA, before task 1)

| AC | File |
|---|---|
| AC-1, AC-8 | `scripts/test/deploy-start.test.sh` |
| AC-2 | `scripts/test/deploy-approval-limits.test.sh` |
| AC-3 | `scripts/test/deploy-merge-fail.test.sh` |
| AC-4 | `scripts/test/deploy-continue-checks.test.sh` |
| AC-5, AC-10 | `scripts/test/deploy-push-ci.test.sh` |
| AC-6, AC-9 | `scripts/test/deploy-production.test.sh` |
| AC-7 | `scripts/test/deploy-other.test.sh` |

Each file sources `scripts/test/deploy-lib.sh`, reuses `scene` snapshots, runs with `FACTORY_POLL=0`,
has no sleeps, and asserts both the exit code and what the fake gh recorded (comments, labels, moves).
New switches a test needs are driven by state files in `$FG`, and are named in QA's RESULT so task 1
can add exactly those.

## Tasks

### Task 1 — factory: additive switches in the deploy test helpers
- **Layer:** factory · **Agent:** engineer · **Depends on:** acceptance tests
- **Files:** `scripts/test/fake-gh-deploy`, `scripts/test/deploy-lib.sh`
- Add only the switches the new acceptance tests use (e.g. failing `pr merge` / `pr create` / push,
  `pr merge` failing with state `MERGED`, failed-run logs, `deploy.environment` deployments,
  empty or changing check rollups, several open PRs, fork PRs, a login with odd characters).
- Every switch is off by default: the existing `deploy-*.test.sh` output stays unchanged.
- Must not edit `factory/deploy.sh` or any acceptance test.
- Done when every new acceptance test passes and the existing deploy tests still pass.

## Bugs found
A test that exposes a bug pins today's behavior; the Tech Lead opens a follow-up issue under #153.
