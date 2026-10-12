# Validate does not rerun a gate that already passed on the same commit — plan for #75

**Goal:** `gate.sh build <base>` and `gate.sh green <layer> <selector>` answer from a pass the factory recorded under the project's home when nothing they read changed, say so, and run as today in every other case.

**Spec:** `docs/superpowers/specs/2026-10-11-validate-does-not-rerun-a-gate-that-alre-design.md`

**Layers:** `factory` only (path `./`, agent `engineer`, Bash and Python 3).

## Constraints

- Arguments, exit codes and verdict lines of every gate stay as they are. Only `build` and `green` read or write a record; `fast`, `forbidden`, `migration`, `acceptance-intact`, `scope`, `red`, `test-plan`, `qa-commit`, `qa-amend` and `stack` do not.
- A record lives only in `$FACTORY_HOME/gate-passes/<key>`. Nothing inside the worktree or the branch is ever read as a pass.
- Only exit 0 records. A failure (1), bad usage (2) and infrastructure (3) record nothing, and a `flaky:` pass still records (it passed).
- A reuse runs no layer command, installs no dependency (`ensure_deps`) and starts no stack (`stack_around`).
- `scripts/deploy.sh` is not changed.
- The existing tests in `scripts/test/` keep passing unchanged, through `SHIPFLOOR_GATE_FRESH=1` exported by `scripts/test/lib.sh`.
- Minimal change: no new config key, no new dependency, no dead code, comments in the file's own style (one `#` note after the function header).

## Tasks

### Task 0 — Acceptance tests (QA, before any implementation)

- **Owner:** `qa-engineer`
- **Files:** creates `scripts/test/gate-reuse.test.sh`
- AC-1 to AC-8 from the spec. Setup as in `scripts/test/gate-build.test.sh` and `scripts/test/gate-retry.test.sh`: a repo from `new_repo`, a config whose layer's `build` and `test` commands leave a mark each time they run (a line appended to a file outside the repo), so "the command ran" and "the command did not run" are counted, not inferred.
- The file unsets `SHIPFLOOR_GATE_FRESH` after sourcing `lib.sh` (the spec's contract: `lib.sh` will export it).
- What each AC needs to show:
  - AC-1: second `build` on the same commit ends `gate build: pass` and the build mark count did not grow.
  - AC-2: the reuse says `build: reused the pass on <12 chars of HEAD> recorded <ISO time>; nothing ran` on stderr, before the verdict.
  - AC-3: the build command runs again on another commit, with another `<base>`, after `origin/main` moved, and after the config file changed.
  - AC-4: a failed `build` is run again on the same commit.
  - AC-5: a file shaped like a record, committed in the repo or left in the worktree under `gate-passes/`, is not read; with `FACTORY_HOME` pointing inside the worktree nothing is reused and nothing is written there; after a pass the record is under `$FACTORY_HOME/gate-passes/`.
  - AC-6: `green` reuses per selector: the same selector does not run its tests again, another selector does.
  - AC-7: with a tracked change or an untracked file in the worktree the gate runs and `gate-passes` gains no file.
  - AC-8: `fast` and `forbidden` (what `scripts/deploy.sh` calls) run every time on a commit and write no record; `build` on a commit with no record runs.
- Must fail on the current code for the reuse ACs (AC-1, AC-2, AC-6 at least) with a message that names the missing behavior (the command ran a second time; no reuse line).

### Task 1 — Recorded passes in `scripts/gate.sh`

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 0
- **Files:** changes `scripts/gate.sh`, `scripts/test/lib.sh`, `scripts/lang/pt-BR.sed`, `scripts/report.sh`, `skills/validate/SKILL.md`, `skills/develop/SKILL.md`, `README.md`

`scripts/gate.sh`:
- `pass_key <gate> <arguments...>`: sets the key, or returns 1 when no record may be read or written: `SHIPFLOOR_GATE_FRESH` is `1`; `FACTORY_HOME` is empty; `git status --porcelain` prints anything; `$FACTORY_HOME/gate-passes` resolves to a path inside the worktree's top-level directory (compare resolved paths, so a symlink or a `..` does not get around it). The key is `git hash-object --stdin` of one value per line:
  - `build`: HEAD sha, `build`, `<base>` resolved to a sha, the sha of `origin/<main>` (empty when there is none; `<main>` from the config), the blob hash of `$FACTORY_CONFIG`, the blob hash of `gate.sh` itself.
  - `green`: HEAD sha, `green`, layer, selector, the blob hash of `$FACTORY_CONFIG`, the blob hash of `gate.sh` itself.
- `pass_reused <gate>`: when the key's file exists, prints `<gate>: reused the pass on <HEAD sha, 12 chars> recorded <ISO time>; nothing ran` on stderr (the time is the record's first field) and returns 0.
- `pass_record <gate> <arguments...>`: writes `<ISO time>\t<HEAD sha>\t<gate>\t<arguments>` to a temp name in `gate-passes` and renames it to the key; then deletes records older than 14 days.
- `gate_build`: the key is computed after `require_rev` and before any layer runs; a reuse returns 0 there; a pass records at the end. The key is the one computed before the command ran: a build that dirties the worktree must not move it.
- `gate_green`: the same, after the selector and layer checks and before `ensure_deps` and `stack_around` (today `load_layer` installs: the reuse check goes ahead of the install).
- `usage`: the `build` and `green` lines say a pass on the same commit is reused.

Other files:
- `scripts/test/lib.sh`: `export SHIPFLOOR_GATE_FRESH=1` after the unset loop, with the reason in the comment's style.
- `scripts/lang/pt-BR.sed`: the reuse line, in the gates block.
- `scripts/report.sh`: the schema comment gains `"gates_reused":["build","green <layer> <selector>"]` beside `flaky`.
- `skills/validate/SKILL.md`, `skills/develop/SKILL.md`: where `flaky` lines are copied into the report, a gate that says "reused the pass" goes into the report's `gates_reused` and is never counted as run.
- `README.md`: one sentence where the gates are described.

**Done when:** every acceptance test in `scripts/test/gate-reuse.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh --changed origin/main` is green.

## Review focus

- The clean-worktree check happens before the command runs, and the record written is for the HEAD read then.
- No path from an argument or the environment lets a record be read from, or written into, the worktree.
- `green` on a reuse neither installs nor leases a stack slot.
- Exit 3 and the retried-then-failed build record nothing.
