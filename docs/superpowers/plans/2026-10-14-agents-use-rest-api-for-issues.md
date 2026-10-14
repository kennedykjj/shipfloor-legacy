# Agents use the REST API for issues — plan (#189)

Spec: `docs/superpowers/specs/2026-10-14-agents-use-rest-api-for-issues-design.md`
Layer: `factory` (every file; `shipfloor-config.sh layer-of` → factory).

## Tasks

1. **Acceptance tests (qa-engineer)** — `scripts/test/hygiene.test.sh`: add one check per AC.
   - AC-1/AC-3: scan `skills/**/*.md` and `agents/*.md` for `gh +(issue|pr (view|checks|comment))`; fail and name file and line on any hit.
   - AC-2: each operation named in the spec (issue comment, add label, PR read, PR checks, PR comment) appears in its skill with the REST form (`gh api repos/`) or the factory script (`board.sh issue`).

2. **Implementation (engineer)** — `skills/refine/SKILL.md`, depends on nothing:
   - Step 6: `gh issue comment` → `gh api repos/<repo>/issues/<n>/comments -F body=@<file in tmp>`.
   - Step 7: `gh issue edit <n> --add-label blocked` → `gh api repos/<repo>/issues/<n>/labels -f 'labels[]=blocked'`.

3. **Implementation (engineer)** — `skills/validate/SKILL.md`, depends on nothing (separate file):
   - Step 4: PR create stays (`gh pr create`, out of scope). Replace the "comment on it what changed" for an existing PR with the REST comment on the PR number.
   - Mergeable read → `gh api repos/<repo>/pulls/<pr> --jq .mergeable` (`null` = retry, `false` = conflicting).
   - Head and checks → `gh api repos/<repo>/pulls/<pr> --jq .head.sha`, then `gh api repos/<repo>/commits/<sha>/check-runs --jq '.check_runs[]|[.name,.status,.conclusion]|@tsv'`, polled every 30 s until all are `completed`; any conclusion other than success/skipped/neutral is red.
   - Issue comments in step 4 → REST comments endpoint.

Tasks 2 and 3 touch different files, so they may run one after the other in the same worktree; task 1 comes first so the tests are red before the edits.

## Files

- `scripts/test/hygiene.test.sh` (task 1)
- `skills/refine/SKILL.md` (task 2)
- `skills/validate/SKILL.md` (task 3)

## Order

1 → 2 → 3, then the last gates (forbidden, migration, build, green).
