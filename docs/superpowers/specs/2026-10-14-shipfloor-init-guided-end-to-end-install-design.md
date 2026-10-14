# shipfloor init: guided end-to-end install — spec

**Issue:** #174 · **Branch:** `feat/174-shipfloor-init-guided-end-to-end-install` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The quick start is about 7 manual steps across three tools (`claude plugin` ×2, `shipfloor install`, the alias, copying `examples/factory.yml` and committing it to main, `shipfloor add`, `shipfloor setup-board`, the dispatcher installer). That is the whole barrier for the second user in PRODUCT.md, the dev who installs the plugin. `shipfloor doctor` diagnoses nearly everything but fixes nothing: each FAIL/WARN prints a command the newcomer still has to understand.
**Audience:** a developer installing the plugin for the first time, and an owner adding one more repository to a machine that already has the factory.
**Acceptance criteria**
- **AC-1** — Given a clean machine (stubbed `git`, `gh`, `claude`, installer and board), when the owner runs `shipfloor init <repo>` and confirms, then it installs, writes and commits `.shipfloor/factory.yml`, adds the project, sets up the board, registers the dispatcher, ends with `shipfloor doctor` and exits 0 with no FAIL line.
- **AC-2** — Given `init <repo>` already ran to the end, when it runs again, then it changes nothing, prints what was already done for each step and exits 0.
- **AC-3** — Given the repo already has `.shipfloor/factory.yml`, when `init <repo>` runs, then it keeps the file, skips the generation and the commit, and overwrites only after an explicit confirmation.
- **AC-4** — Given `gh` is not authenticated (or `git`, `claude`, Python 3.11+ or PyYAML is missing), when `init` runs, then it stops before changing anything, names the missing prerequisite with the command that fixes it, and exits non-zero.
- **AC-5** — Given `init` with no `<repo>`, when it runs, then it only does the machine part (prerequisites, install, dispatcher, doctor) and touches no repository.
- **AC-6** — Given any step runs, when it prints, then it shows the equivalent manual command, and nothing destructive (the commit in the owner's repo, overwriting a `factory.yml`, replacing a registered dispatcher) happens without a confirmation; without a terminal and without `--yes`, it stops there and prints the exact command for the owner to run.
- **AC-7** — Given the README, when read, then the quick start is `init` plus what remains, and the manual steps live in `docs/install.md`.
**Out of scope:** per-runtime doctor (#149; init uses today's doctor); installing `claude`, `gh` or Python for the user; creating the GitHub repository or the Project board itself beyond what `setup-board` does today; Windows dispatcher installer changes.
**Product fit:** it removes the main adoption barrier for outside devs and teaches the manual path by printing each equivalent command.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

- **Command:** `shipfloor init [<repo>] [--yes]`, new `cmd_init` in `scripts/shipfloor_core/cli.py`, registered in `COMMANDS` and in the usage header of `scripts/shipfloor`. The step logic lives in a new `scripts/shipfloor_core/init.py` (cli.py is already 1000+ lines); it reuses `cmd_install`, `cmd_add`, `cmd_setup_board`, `cmd_doctor`, `_have`, `source_dir` and the dispatcher script's `--status`, so no behavior is duplicated.
- **Steps, each idempotent:** (1) prerequisites, the same checks as `cmd_doctor` (git, gh auth, claude, Python ≥ 3.11, PyYAML), run first and fatal; (2) `install` unless the installed copy matches the source (`_same_tree`); (3) with `<repo>`: if `origin/<main>:.shipfloor/factory.yml` is missing, render `examples/factory.yml` with the answers (project name defaulting to the repo directory slug, `board.owner/number`, layers: one layer from path/build/test/tests prompts, or keep the example's), show it, and on confirmation commit and push it to main; (4) `add` unless the project is already registered for this repo, then `setup-board <project>` (itself safe to repeat); (5) `install-dispatcher.sh --status`: exit 0 → say it is registered, exit 1 → run the installer (`install-dispatcher.ps1` on Windows), a different mechanism or `--every-min` already registered is replaced only after confirmation; (6) `doctor`, then the next steps.
- **Transparency:** every step prints `$ <equivalent command>` before acting (a small `_step(title, cmd)` helper).
- **Confirmation:** `_confirm(question)` reads stdin when it is a TTY; `--yes` answers yes; otherwise it returns no and the step prints the exact manual command and the run exits 1 ("pending"). The commit uses `git -C <repo>`, only on `<main>`, only when the tree has no unrelated staged changes (else print the command and stop).
- **Contracts touched:** new CLI subcommand only; the registry format, `factory.yml` schema and the dispatcher installers are unchanged.
- **Files:** `scripts/shipfloor_core/init.py` (new), `scripts/shipfloor_core/cli.py`, `scripts/shipfloor`, `scripts/test/init.test.sh` (new), `README.md`, `docs/install.md`.
- **Layers:** all files belong to layer `factory`.
- **Migration:** none (additive). `## Rollback` is n/a.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/init.test.sh` |
| AC-2 | factory | `scripts/test/init.test.sh` |
| AC-3 | factory | `scripts/test/init.test.sh` |
| AC-4 | factory | `scripts/test/init.test.sh` |
| AC-5 | factory | `scripts/test/init.test.sh` |
| AC-6 | factory | `scripts/test/init.test.sh` |
| AC-7 | factory | `scripts/test/init.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- #170 (Python CLI) already landed, so init goes in the Python package; #149 has not, so init uses today's doctor.
- Step logic in `init.py`, only the wiring in `cli.py`: cli.py is large and the issue's "in cli.py" is satisfied by the registered command.
- `--yes` is the non-interactive consent; without a TTY and without it, init never commits or replaces anything and exits 1 with the exact command, so the safe default is "owner decides".
- The `factory.yml` is generated from `examples/factory.yml` with few questions (project, board, layers) and the rest stays commented as in the example, so the owner can edit it later.
- The plugin install (`claude plugin` ×2) is not part of init: init runs from the installed plugin, so it is already there.
- `init.test.sh` also asserts AC-7 by checking the README quick start mentions `shipfloor init` and `docs/install.md` still lists the manual steps.
- Weight is `heavy`: one layer, but more than 6 acceptance criteria (7).

## Open questions
- none
