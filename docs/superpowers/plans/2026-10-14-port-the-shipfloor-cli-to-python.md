# Port the shipfloor CLI to Python — plan

**Issue:** #170 · **Spec:** `docs/superpowers/specs/2026-10-14-port-the-shipfloor-cli-to-python-design.md`
**Branch:** `feat/170-port-the-shipfloor-cli-to-python`

No behavior change: the existing CLI tests stay the gate, unedited except `install-atomic.test.sh` (amended as the
spec says). Every script the Bash CLI ran (gate.sh, board.sh, setup-board.sh, metrics.sh, install-dispatcher.sh,
dashboard.py, shipfloor_health.py, git, gh) still runs as a process with the same argv, so the CLI does not depend on
the gate port (#165) or any other port's Python code.

## Acceptance tests (QA, before task 1)

| AC | File | What is new |
|---|---|---|
| AC-1 | `scripts/test/shipfloor-cli.test.sh` | `help` prints the usage on stderr, exit 2; the wrapper's shape; `sf.py cli` |
| AC-2, AC-3 | `scripts/test/install-source.test.sh` | nothing: already pinned |
| AC-4, AC-5 | `scripts/test/install-atomic.test.sh` | faults injected in the Python install (wrapped `os.replace`) instead of stand-in `cp`/`mv`/`rm`; same checks |
| AC-6 | `scripts/test/shipfloor-cli.test.sh` | doctor exits 0 when it only warns |
| AC-7 | `scripts/test/shipfloor-cli.test.sh` | the exact lines of add, list, remove, clean; registry.tsv; accepted.tsv records |
| AC-8 | the existing suites | nothing new |

## Tasks

### Task 1 — factory: `shipfloor_core/cli.py`, the wrapper, `sf.py cli`
- **Layer:** factory · **Agent:** engineer · **Depends on:** acceptance tests
- `cli.py` exposes `main(argv) -> int`, one function per Bash command, the same messages and exit codes
  (including today's quirks: `pool` exits as its pipeline did, `add` on a non-repo names an empty path).
- `install`: copy to `.<name>.install-tmp` with mode and times kept, `os.replace` over the target, unchanged files
  skipped by byte compare, stale files and empty folders removed, `.origin` then `.source` (by rename) only when
  nothing failed; `__pycache__`, `*.pyc` and `test/` never copied or counted.
- `doctor`: the same lines in the same order; the Python and PyYAML checks run in the CLI's own interpreter (the
  factory's Python); the copy comparison is a tree compare that skips what `diff -x` skipped.
- `scripts/shipfloor` keeps its header (lines 2-10 are still the usage the CLI prints) and becomes
  `set -- cli "$@"` + the `lib/py.sh` lines; the usage strings stay in its comments for `contracts-doc.test.sh`.
- `proc.alive` and `text.read_tab` move out of `deploy.py` so the CLI reuses them.
- **Done when:** the acceptance tests and the full suite (`bash scripts/test/run.sh`) pass.
