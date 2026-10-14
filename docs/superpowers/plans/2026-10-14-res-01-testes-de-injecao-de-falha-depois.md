# [RES-01] Fault-injection tests — plan

**Issue:** #173 · **Spec:** `docs/superpowers/specs/2026-10-14-res-01-testes-de-injecao-de-falha-depois-design.md`
**Layers:** factory (only layer; agent `engineer`)

## Area split

QA's scope is `scripts/test/*.test.sh` and `scripts/test/py/*.py`. A `scripts/test/chaos-lib.sh` (named in the spec)
is outside it, so the shared harness lives in QA's area instead: `scripts/test/py/chaos_invariant.py` (the four
checkable invariant conditions on a `~/.shipfloor` home, exit 0/1 with one line per violation) and, if needed,
helper functions defined inside each `chaos-*.test.sh`. Same contract as the spec's `chaos_invariant <home>`;
only the file moves. The fakes (`fake-gh`, `fake-gh-deploy`) are helpers, not tests: the engineer changes them.

## Tasks

### T0 — acceptance tests (qa-engineer)
- Files (new): `scripts/test/chaos-board.test.sh` (AC-1, AC-2), `scripts/test/chaos-dispatch.test.sh` (AC-3, AC-4,
  AC-5), `scripts/test/chaos-fs.test.sh` + `scripts/test/py/chaos_fs.py` (AC-6), `scripts/test/py/chaos_invariant.py`.
- No existing test file is edited (AC-7).
- Red reason expected: AC-1 fails because the fakes ignore `FAKE_GH_FAIL_AT` / `FAKE_GH_FAIL_CMD`; AC-6 fails on the
  report half-copy; other scenarios may already hold (they then pin the behavior; QA states which).

### T1 — `FAKE_GH_*` failure mode in the fakes (engineer, layer factory) — depends on T0
- Files: `scripts/test/fake-gh`, `scripts/test/fake-gh-deploy`.
- `FAKE_GH_FAIL_AT=<n>`: count calls in `$FAKE_GH_DIR/fail-count`; the n-th call exits 1 with
  `gh: injected failure` on stderr. `FAKE_GH_FAIL_CMD=<ERE>`: every call whose argv line matches `grep -E` exits 1
  the same way. Checked before any other branch; both unset = today's behavior byte for byte. Portable tools only.

### T2 — small fixes the chaos tests expose (engineer, layer factory) — depends on T1
- Files: `scripts/shipfloor_core/report.py` (copy into `reports-wt` through `fs.write_atomic`, no half report, no
  temp left) and, only if a chaos test fails on them, `scripts/shipfloor_core/{dispatch,cycle,deploy,board,cli}.py`.
- Each fix stays inside its module and keeps its contract. A failure that needs more than a small fix is reported
  back (it becomes its own bug issue and the scenario leaves this PR, decided by the Tech Lead with QA).

### T3 — the failure invariant in the contract (engineer, layer factory) — depends on T2
- File: `docs/contracts.md`: new `## Failure invariant` section after `## Security invariants`, worded as in the
  spec's Architecture; the env-var table (`## Environment variables and test seams`) gains `FAKE_GH_FAIL_AT` and
  `FAKE_GH_FAIL_CMD`. Must keep `scripts/test/contracts-doc.test.sh` green.

## Gates
After each task: `scope factory`, `acceptance-intact <qa>`, `migration <base>` (no migration), `build <base>`.
Then `green factory <selector>` for each `chaos-*.test.sh`.
