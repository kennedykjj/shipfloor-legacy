# Fast and safe deploy — plan

Spec: `docs/superpowers/specs/2026-10-09-fast-safe-deploy-design.md`. Executor: superpowers:executing-plans.

- [ ] Task 1 — `scripts/deploy.sh` + `scripts/test/deploy.test.sh` (fake gh, local bare remote): up-to-date → Done; behind → merge/push/deploy-merge; migration conflict → Coding; small conflict → exit 3 then `--continue`; unknown head → blocked; red CI after merge → Coding; failed health check → revert + blocked. Config: `deploy.healthcheck` (list of URLs) validated. Commit `feat(deploy): deterministic deploy script`.
- [ ] Task 2 — refresh: `deploy.sh --refresh` (tests: behind → pushed + recorded; conflict → untouched; up to date → no-op) and dispatcher launching refreshes for Staged/Ready for Prod cards (lock `refresh-<n>`, outside the pool). Commit `feat(dispatch): keep staged cards up to date`.
- [ ] Task 3 — skills: thin `/mylos:deploy`; English-output line in all four skills; `mylos doctor` reports branch protection (`strict`). Hygiene/doctor tests. Commit `feat: thin deploy skill, English output, protection check`.
- [ ] Task 4 — Shop PR: CI path filters on pull requests, migration upgrade job, `deploy.healthcheck`.
