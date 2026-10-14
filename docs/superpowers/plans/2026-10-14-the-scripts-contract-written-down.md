# Plan — the scripts' contract, written down (#155)

Spec: `docs/superpowers/specs/2026-10-14-the-scripts-contract-written-down-design.md`. Single layer: `factory`. No behavior changes.

## Tasks

1. **factory / engineer — `docs/contracts.md` and the link.** Depends on: QA's acceptance test (red first).
   - Write `docs/contracts.md` from the code as it is today: top note (describes behavior; when doc and code disagree, the code is the bug and the fix is a card); one `## <name>` section per `scripts/*.sh` (including `lib/project.sh`, `lib/stack.sh`) and `shipfloor` (the CLI), each with an `Interface` line listing subcommands as backticked words, exit codes, stdout vs stderr, verdict and log lines; then the cross-cutting sections: GitHub markers, files under `~/.shipfloor` and who reads them, environment variables and test seams, the `claude -p` launch, security invariants, known quirks kept on purpose.
   - `docs/how-it-works.md`: one link to `contracts.md`.
   - Files: `docs/contracts.md`, `docs/how-it-works.md`.

QA writes `scripts/test/contracts-doc.test.sh` (AC-1 to AC-5) before task 1; the engineer does not edit it.
