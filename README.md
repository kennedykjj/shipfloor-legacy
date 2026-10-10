# Aghanim's Anvil

**A software factory for Claude Code.** Turns GitHub issues into shipped PRs: agents refine, build and validate; deterministic gates they can't edit decide what passes. It works in any repository that declares a `.aghanim/factory.yml`.

> Aghanim's Scepter upgrades a hero. The Anvil is what everything is shaped against: it doesn't move. The agents strike; the gates hold.

## How it works

The board (a GitHub Project v2) has fixed columns. The owner moves cards between the 👤 columns; the factory works the 🤖 ones:

| Pipeline | Takes from | Leaves in | What it does |
|---|---|---|---|
| `/aghanim:refine` | Ready for Refinement | Spec Review | PO, UX/UI and Cybersec write the spec; the Tech Lead writes architecture and test plan |
| `/aghanim:develop` | Ready for Dev | Validation | plan, failing acceptance tests (QA), implementation per layer, up to date with `main` |
| `/aghanim:validate` | Validation | Staged | up to date with `main`, gates, review (code, UX, security), PR with green CI |
| `/aghanim:deploy` | Ready for Prod | Done | up to date with `main` (resolving conflicts), merge tested on the current `main`, waits for CI and deploy; on failure opens a revert PR |

The gates (`scripts/gate.sh`) do not depend on the model: file scope per role, forbidden paths, untouched acceptance tests, immutable, unique and ordered migrations, build per layer, red by assertion (not by a compile error) and green with at least one test run.

A dispatcher (a scheduled task every 3 minutes) goes through every registered project and starts pipelines with `claude -p`, within the machine's agent pool, each stage's slots, the project's limits and the WIP.

## Agent pool

Each pipeline run is one agent. `~/.aghanim/config.yml` sets how many run at once on the machine, across all projects, and how many each stage may take (absolute numbers):

```yaml
pool: 4
stages: {refine: 2, develop: 2, validate: 2, deploy: 1}
```

`aghanim pool` shows it and the runs in progress; `aghanim pool set 6` and `aghanim pool stage validate 3` change it. A project's `limits` in `factory.yml` can ask for less.

## Parallel work

Cards built at the same time do not break `main`:
- the `migration` gate refuses a version used twice and a migration older than the base's or `main`'s;
- `develop`, `validate` and `deploy` merge `origin/main` before the gates;
- `deploy` merges only a head that contains the current `main` and passed CI; with `deploy.refresh_staged: true` the dispatcher also keeps Staged PRs on top of `main` (faster approvals, but every refresh reruns CI: leave it off when Actions minutes are tight);
- to close the race with merges made by hand, enable branch protection on the main branch with "Require branches to be up to date before merging" and required CI; `/aghanim:deploy` reports when it is missing.

On deploy, conflicts are resolved by the pipeline itself. The card goes back to Coding only when a migration conflicts, when the conflict is large (`deploy.conflict_max_files` / `conflict_max_hunks`), or when gates or CI fail after resolving.

## Requirements

`git`, an authenticated `gh`, `claude`, Python 3.11+ with PyYAML (`pip install pyyaml`), and Git Bash on Windows.

## Install

```bash
claude plugin marketplace add <path or URL of this repo>
claude plugin install aghanim@aghanim
bash <plugin>/scripts/aghanim install     # copies scripts and templates to ~/.aghanim/factory
alias aghanim='bash ~/.aghanim/factory/aghanim'
aghanim doctor
```

For each repository:

1. Copy `examples/factory.yml` to `.aghanim/factory.yml`, set project, board and layers, and commit it to the main branch.
2. `aghanim add <local clone> [--worktrees DIR]` reads the config from `origin/main`, validates it and registers the project.
3. `aghanim setup-board <project>` creates the columns and the `ui`, `cybersec` and `blocked` labels.
4. Optionally add `.aghanim/review-criteria.md` and project agents in `.claude/agents/<name>.md`, referenced by `agent:` in a layer.
5. Permissions for the headless pipelines in the project's `.claude/settings.json`: `Bash(bash ~/.aghanim/factory/gate.sh:*)`, `Bash(bash ~/.aghanim/factory/board.sh:*)`, `Bash(bash ~/.aghanim/factory/aghanim-config.sh:*)`, `Bash(bash ~/.aghanim/factory/report.sh:*)`, `Bash(bash ~/.aghanim/factory/review-page.sh:*)`, plus `git` and `gh`.

Dispatcher on Windows: `powershell -File <plugin>/installer/install-dispatcher.ps1` registers the `AghanimDispatcher` task.

## Upgrading from mylos <!-- legacy mylos -->

The factory was called mylos before 0.6.0. To move a machine and its repositories: <!-- legacy mylos -->

1. `mylos pause` and wait until `mylos pool` shows no runs. <!-- legacy mylos -->
2. Install the new plugin (`claude plugin install aghanim@aghanim`), then `bash <plugin>/scripts/aghanim migrate-home` (moves `~/.mylos` to `~/.aghanim`) and `aghanim install`. <!-- legacy mylos -->
3. Run `installer/install-dispatcher.ps1` again: it replaces the `MylosDispatcher` task with `AghanimDispatcher`. <!-- legacy mylos -->
4. In each repository, move `.mylos/` to `.aghanim/` and update anything that calls `~/.mylos/factory/` (project agents, `.claude/settings.json`, `factory-guard.yml`). Until then the factory still reads `.mylos/factory.yml`, with a warning. <!-- legacy mylos -->
5. `aghanim resume`.

## Operation

`aghanim dashboard` · `aghanim list` · `aghanim pool` · `aghanim pause [project]` · `aghanim resume [project]` · `aghanim remove <project>` · `aghanim metrics <project>` · `aghanim clean <project>` · `aghanim accept <project> <n> <reason>` (owner only: after reviewing how a card's acceptance test files changed since the QA commit, for example a merge from main resolved by hand, take them as they stand; `acceptance-intact` then passes those exact contents, recorded in `~/.aghanim/projects/<project>/accepted.tsv`, and blocks again on any later edit).
`aghanim dashboard` opens a local page with the pool, live runs, logs, the estimated cost of each card and the review pages, where Spec Review and Staged cards are approved or sent back.
Logs in `~/.aghanim/logs/dispatcher.log` and `~/.aghanim/projects/<project>/logs/`. A layer may set `install` (for example `pnpm install --frozen-lockfile`): the gates run it in the layer's directory before its build or tests, once per content of that directory, so no agent has to install a worktree's dependencies; a failing install is exit 3 (infrastructure). A project the dispatcher cannot use in a cycle (its control checkout does not reach `origin/<main>`, or the config there is missing or invalid) is skipped: the reason and the time of the first failed cycle go to `~/.aghanim/projects/<project>/SKIPPED`, the dashboard shows a "skipped since" flag and `aghanim doctor` warns; the first good cycle clears it. An `index.lock` older than 10 minutes in the control checkout (`AGHANIM_STALE_LOCK_MIN`) is treated as left by a dead git and removed. Reports on each repository's orphan `factory-reports` branch.

## Security

- Scripts run from the installed copy in `~/.aghanim/factory`, outside every worktree.
- The gates read a snapshot of the committed config (`origin/main`), outside the pipelines' reach; `.aghanim/` is forbidden to agents, so a factory PR cannot change the gates that judge it.
- `templates/factory-guard.yml` repeats the forbidden-path check in GitHub Actions.

## Development

`bash scripts/test/run.sh` runs the suite. Designs in `docs/superpowers/specs/`.
