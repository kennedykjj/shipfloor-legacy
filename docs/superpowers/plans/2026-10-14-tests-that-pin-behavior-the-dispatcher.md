# Plan — #160 Tests that pin behavior: the dispatcher

Spec: `docs/superpowers/specs/2026-10-14-tests-that-pin-behavior-the-dispatcher-design.md`

This card is tests only. The deliverable is the acceptance tests themselves: they pin today's behavior of
`scripts/dispatch.sh`, `scripts/shipfloor-dispatch.sh` and `scripts/run-dispatcher.sh`, which are not edited.
The tests are therefore expected to pass as soon as QA writes them (no "red" phase: there is no missing
behavior). A test that exposes a bug pins today's behavior and the bug is reported for a follow-up under #153.

## Tasks

| # | Layer | Owner | Files | Depends on |
|---|---|---|---|---|
| 1 | factory | qa-engineer | `scripts/test/dispatch-process.test.sh` (AC-1, AC-7) | — |
| 2 | factory | qa-engineer | `scripts/test/dispatch-launch-flags.test.sh` (AC-2) | — |
| 3 | factory | qa-engineer | `scripts/test/dispatch-cost-cleanup.test.sh` (AC-3, AC-8) | — |
| 4 | factory | qa-engineer | `scripts/test/dispatch-lang-files.test.sh` (AC-4) | — |
| 5 | factory | qa-engineer | `scripts/test/shipfloor-dispatch-cycle.test.sh` (AC-5) | — |
| 6 | factory | qa-engineer | `scripts/test/run-dispatcher.test.sh` (AC-6) | — |
| 7 | factory | engineer | `scripts/test/lib.sh` only if a shared helper is needed; otherwise none. Never `scripts/dispatch.sh`, `scripts/shipfloor-dispatch.sh`, `scripts/run-dispatcher.sh` | 1–6 |

## Notes for every test file

- Source `scripts/test/lib.sh`; reuse its helpers (`wait_for`, fake board, stubs) as the existing
  `dispatch-*.test.sh` files do. Keep helpers local to the file unless task 7 moves them to `lib.sh`.
- `mktemp -d` homes; a `trap` that kills every sleeping child the test started; no fixed sleeps (use `wait_for`).
  The files must be safe under `TEST_JOBS=4`.
- AC-7: in the process-model tests the launch is real; `FACTORY_CLAUDE` is a script that sleeps and writes.
- AC-2: the `--model` / `weight=` regex is read out of `scripts/dashboard.py`, not copied.
- AC-8: every bullet of issue #160 has an assertion somewhere in the six files.
