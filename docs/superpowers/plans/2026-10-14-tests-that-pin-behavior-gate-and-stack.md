# Tests that pin behavior: gate and stack — plan

**Issue:** #158 · **Spec:** `docs/superpowers/specs/2026-10-14-tests-that-pin-behavior-gate-and-stack-design.md`

This card adds characterization tests only. `gate.sh` and `lib/stack.sh` do not change, so the acceptance tests pass against today's code from the start: the `red` gate does not apply, and the tests are proven with `green`.

## Tasks

| # | Layer | Owner | Files | Depends on |
|---|---|---|---|---|
| 1 | factory (tests) | qa-engineer | `scripts/test/gate-pin-verdict.test.sh` (AC-1) | — |
| 2 | factory (tests) | qa-engineer | `scripts/test/gate-pin-static.test.sh` (AC-2, AC-3) | — |
| 3 | factory (tests) | qa-engineer | `scripts/test/gate-pin-cache.test.sh` (AC-4) | — |
| 4 | factory (tests) | qa-engineer | `scripts/test/stack-pin-slots.test.sh` (AC-5) | — |
| 5 | factory (tests) | qa-engineer | `scripts/test/stack-pin-queue.test.sh` (AC-6) | — |

There are no engineer tasks. Tasks 1–5 make up the single QA commit (`test(tests-that-pin-behavior-gate-and-stack): acceptance tests for #158`).

## Checks

- AC-7: every new file name contains `gate` or `stack`; `build` (`run.sh --changed origin/main`) selects and runs them; `green factory <file>` passes for each; `git diff <base> -- scripts/gate.sh scripts/lib/stack.sh` is empty.
- A case that exposes a bug is left out and noted for PY-03 or a new issue under #153.

## Pinned behavior (AC-8)

`docs/contracts.md` landed on main (a57f0cf) after this branch was cut, and the branch is not merged with main before deploy. As the spec's decision says, the pinned behaviors go in a `## Pinned behavior` section of the PR description rather than in `docs/`, so this card and PY-02 do not conflict. The list is the set of bullets in the issue, as covered by the five files above.
