# Shipfloor

**A software factory for Claude Code.** Turns GitHub issues into shipped PRs: agents refine, build and validate; deterministic gates they can't edit decide what passes. It works in any repository that declares a `.shipfloor/factory.yml`.

> The shop floor is where a factory's work gets done. This one ships software: the agents build; the gates hold.

## How it works

The board (a GitHub Project v2) has fixed columns. The owner moves cards between the 👤 columns; the factory works the 🤖 ones:

| Pipeline | Takes from | Leaves in | What it does |
|---|---|---|---|
| `/sf:refine` | Ready for Refinement | Spec Review | PO, UX/UI and Cybersec write the spec; the Tech Lead writes architecture and test plan |
| `/sf:develop` | Ready for Dev | Validation | plan, failing acceptance tests (QA), implementation per layer |
| `/sf:validate` | Validation | Staged | gates, review (code, UX, security), PR with green CI |
| `/sf:deploy` | Ready for Prod | Done | up to date with `main` (resolving conflicts, fixing what breaks), merge tested on the current `main`, waits for CI and deploy; on failure opens a revert PR |

The gates (`scripts/gate.sh`) do not depend on the model: file scope per role, forbidden paths, untouched acceptance tests, immutable, unique and ordered migrations, build per layer, red by assertion (not by a compile error) and green with at least one test run.

A dispatcher (a scheduled task, every 3 minutes by default) goes through every registered project and starts pipelines with `claude -p`, within the machine's agent pool, each stage's slots and the project's WIP.

## Agent pool

Each pipeline run is one agent. `~/.shipfloor/config.yml` sets how many run at once on the machine, across all projects, and how many each stage may take (absolute numbers):

```yaml
pool: 4
stages: {refine: 2, develop: 2, validate: 2, deploy: 1}
```

`shipfloor pool` shows it and the runs in progress; `shipfloor pool set 6` and `shipfloor pool stage validate 3` change it. A project runs one deploy at a time (merges into main are serial); its `limits.<stage>.wip` in `factory.yml` caps the cards waiting in Spec Review (refine, default 2) and in Coding + Validation (develop, default 4).

## Working hours

`hours` in `~/.shipfloor/config.yml` lists the windows (local time, 24-hour `HH:MM-HH:MM`, start included, end excluded) in which the dispatcher starts runs. Outside them it does everything else (board snapshot, reaping, retries) but starts nothing; runs in progress finish. A window whose end is before its start crosses midnight. Unset or `[]` means all hours; a malformed value is reported by `machine validate` and ignored.

```yaml
hours: ["08:00-23:00"]
```

## Parallel work

Cards built at the same time do not break `main`:
- the `migration` gate refuses a version used twice and a migration older than the base's or `main`'s;
- only `deploy` merges `origin/main`, once, on the head the owner approved (`validate` does it only when the PR conflicts with main, so CI can run); the PR's CI already tests the branch merged with main;
- `deploy` merges only a head that contains the current `main` and passed CI; with `deploy.refresh_staged: true` the dispatcher also keeps Staged PRs on top of `main` (faster approvals, but every refresh reruns CI: leave it off when Actions minutes are tight);
- to close the race with merges made by hand, enable branch protection on the main branch with "Require branches to be up to date before merging" and required CI; `/sf:deploy` reports when it is missing.

On deploy, what breaks on top of `main` is repaired in place. Conflicts are resolved by an agent, which may touch only the conflicted files. A migration whose version `main` took is renumbered above main's newest. A gate or CI that goes red after the merge gets up to two agent rounds: a fix within `deploy.fix_max_files` / `fix_max_lines` (3 files, 40 lines) that touches no acceptance test ships with the approved head, recorded on the issue as `deploy-fix`; a larger one goes back to Staged for a new approval. A CI run on `main` that fails has its failed jobs run once more before the revert. The card goes back to Coding only when a migration file itself conflicts, when the conflict is large (`deploy.conflict_max_files` / `conflict_max_hunks`), or when the two rounds do not turn it green.

## Requirements

`git`, an authenticated `gh`, `claude`, Python 3.11+ with PyYAML (`pip install pyyaml`), and Git Bash on Windows.

## Install

```bash
claude plugin marketplace add <path or URL of this repo>
claude plugin install sf@shipfloor
bash <plugin>/scripts/shipfloor install     # copies scripts and templates to ~/.shipfloor/factory
alias shipfloor='bash ~/.shipfloor/factory/shipfloor'
shipfloor doctor
```

For each repository:

1. Copy `examples/factory.yml` to `.shipfloor/factory.yml`, set project, board and layers, and commit it to the main branch.
2. `shipfloor add <local clone> [--worktrees DIR]` reads the config from `origin/main`, validates it and registers the project.
3. `shipfloor setup-board <project>` creates the columns and the `ui`, `cybersec` and `blocked` labels.
4. Optionally add `.shipfloor/review-criteria.md` and project agents in `.claude/agents/<name>.md`, referenced by `agent:` in a layer.
5. Permissions for the headless pipelines in the project's `.claude/settings.json`: `Bash(bash ~/.shipfloor/factory/gate.sh:*)`, `Bash(bash ~/.shipfloor/factory/board.sh:*)`, `Bash(bash ~/.shipfloor/factory/shipfloor-config.sh:*)`, `Bash(bash ~/.shipfloor/factory/report.sh:*)`, `Bash(bash ~/.shipfloor/factory/review-page.sh:*)`, plus `git` and `gh`.

Dispatcher on Windows: `powershell -File <plugin>/installer/install-dispatcher.ps1` registers the `ShipfloorDispatcher` task. It runs every 3 minutes unless you choose 1, 5 or 10: pick it in Settings in the dashboard ("Looks for work every"), or pass `-EveryMin` to `installer/install-dispatcher.ps1`. The value lives in `~/.shipfloor/config.yml` as `dispatcher.every_min`.

## Upgrading from Aghanim's Anvil <!-- legacy aghanim -->

The factory was called Aghanim's Anvil (`aghanim`) before 0.7.0. To move a machine and its repositories: <!-- legacy aghanim -->

1. `aghanim pause` and wait until `aghanim pool` shows no runs. <!-- legacy aghanim -->
2. Install the new plugin (`claude plugin install sf@shipfloor`), then `bash <plugin>/scripts/shipfloor migrate-home` (moves `~/.aghanim` to `~/.shipfloor`) and `shipfloor install`. <!-- legacy aghanim -->
3. Run `installer/install-dispatcher.ps1` again: it replaces the `AghanimDispatcher` task with `ShipfloorDispatcher`. <!-- legacy aghanim -->
4. In each repository, move `.aghanim/` to `.shipfloor/` and update anything that calls `~/.aghanim/factory/` or `/aghanim:*` (project agents, `.claude/settings.json`, `factory-guard.yml`). There is no fallback: a repository is not read until it has `.shipfloor/factory.yml`. <!-- legacy aghanim -->
5. `shipfloor resume`.

## Operation

`shipfloor dashboard` · `shipfloor list` · `shipfloor pool` · `shipfloor pause [project]` · `shipfloor resume [project]` · `shipfloor remove <project>` · `shipfloor metrics <project>` · `shipfloor clean <project>` · `shipfloor accept <project> <n> <reason>` (owner only: after reviewing how a card's acceptance test files changed since the QA commit, for example a merge from main resolved by hand, take them as they stand; `acceptance-intact` then passes those exact contents, recorded in `~/.shipfloor/projects/<project>/accepted.tsv`, and blocks again on any later edit). Before it comes to that, a card's own QA gets the first word: an engineer who finds an acceptance test wrong reports it instead of editing it, and when `acceptance-intact` fails on the card's own edit the Tech Lead sends the test back to QA, who either corrects it or puts it back and says what the code must do. QA's correction is a new QA commit, which becomes what the gate protects, and `gate.sh qa-amend <n>` keeps it honest without anyone reviewing it first: it touches only test files, loses no assertion line, switches no test off, and a card is amended at most twice. The amendment is commented on the issue and listed in the report.
`shipfloor dashboard` (or `/sf:dashboard` inside Claude Code) opens a local page with the pool, live runs, logs (per card, and a Feed view with every run, what it left behind and the dispatcher's log in one timeline), the estimated cost of each card and the review pages, where Spec Review and Staged cards are approved or sent back. Its address carries a random token; `--token <text>` fixes it instead. The In progress panel lists every card in the factory's hands: the sessions at work and, marked as waiting with the reason (a busy stage slot, a pause), the cards that wait for a run. Every panel, and every running session, has a maximize button in its corner that opens it over 90% of the screen: the lifecycle line becomes a board with each card by name in two lanes (upstream, to an approved spec; downstream, to production), and Today lists the day's runs one by one. What waits for you, maximized, is a decision inbox: the queue with the oldest wait first, what to read to decide the card in focus (the spec's problem, acceptance criteria and open questions from its review page; a pull request's size and checks; a block told in order: the step it stopped at, why, how the acceptance tests changed since QA wrote them, what the factory tried) and the decision as options that each say when to choose them and where the card goes next. A blocked card can be retried, sent back to Coding with a note, or, when `acceptance-intact` stopped it, have its tests taken as they stand (`shipfloor accept`). A decision waits five seconds so it can be undone. The Settings view changes this machine's limits (the pool, each stage's slots, the stacks; saved to `~/.shipfloor/config.yml` and read on the next cycle) and pauses the factory or one project at once; For a project it also sets how the factory operates on it on this machine (cards in progress and specs in refinement at once, how long the deploy waits, the largest conflict an agent may resolve): these are kept in `~/.shipfloor/projects/<project>/overrides.yml`, which every config reader lays over the project's `factory.yml`, and nothing else can be overridden there. What a project is (its files, layers and commands) is shown as the dispatcher last read it, with the file to edit in its repository. A card's Live tab shows its latest session as it happens (what the run and its subagents say and do) and, while a run works on the card, takes a message for it: the run and each of its subagents read the message after the tool call they are in (a hook the plugin ships, `hooks/hooks.json`), and no run ever waits for one.
Logs in `~/.shipfloor/logs/dispatcher.log` and `~/.shipfloor/projects/<project>/logs/`. A layer may set `install` (for example `pnpm install --frozen-lockfile`): the gates run it in the layer's directory before its build or tests, once per content of that directory, so no agent has to install a worktree's dependencies; a failing install is exit 3 (infrastructure). A project the dispatcher cannot use in a cycle (its control checkout does not reach `origin/<main>`, or the config there is missing or invalid) is skipped: the reason and the time of the first failed cycle go to `~/.shipfloor/projects/<project>/SKIPPED`, the dashboard shows a "skipped since" flag and `shipfloor doctor` warns; the first good cycle clears it. An `index.lock` older than 10 minutes in the control checkout (`SHIPFLOOR_STALE_LOCK_MIN`) is treated as left by a dead git and removed. Reports on each repository's orphan `factory-reports` branch. At the end of every cycle the dispatcher empties what cards left under the project's `tmp/`: the `tmp/<n>/` of a card that is Done or off the board, and stray files or folders beside them once nobody touched them for 3 days, unless their name carries the number of a card still in progress (`shipfloor clean <project>` does the same on demand).

Every dispatcher cycle appends one line to `~/.shipfloor/logs/health-<YYYY-MM>.jsonl`: each project's cards per column and blocked cards, runs against the pool and the stage slots, busy stacks, the machine's CPU, free memory and free disk, and how the cycle went (seconds, exit code, whether another cycle was still running). The dashboard and `shipfloor doctor` raise what the last three cycles show: a stage with a free slot and cards waiting through all three, more runs than a limit, two cycles at once.

The demo: `bash scripts/test/demo-stack.sh up` serves this checkout's dashboard on sample data (two projects, every kind of card and run) and prints its address, `http://127.0.0.1:<port>/?t=<token>`; `down` stops it and removes its files.
It reads only `SHIPFLOOR_STACK` (default `shipfloor-demo`), `SHIPFLOOR_PORT_WEB` (7727) and `SHIPFLOOR_DEMO_TOKEN` (`demo`), never touches `~/.shipfloor` and never calls the real `gh`, so a card that changes the page can be looked at without a factory home.

## Language

The factory speaks English unless told otherwise. Two keys change that, each `en` (default) or `pt-BR`:

- `language` in a project's `.shipfloor/factory.yml`: what people read about that project. The agents write specs, comments, reports and review pages in it; the gates' messages and what the deploy logs and posts on the card come out in it.
- `language` in `~/.shipfloor/config.yml`: this machine. The dashboard and the dispatcher's own log lines.

What other code reads stays in English whatever the language: commit messages, the spec's `##` headings, the markers on a card (`staged-head:`, `deploy-merge:`, `deploy-fix:`, "Factory report"), labels, and the board's column names on GitHub (the dashboard shows them translated). The scripts and the page are written in English and translated where their text leaves them, by the catalogs in `scripts/lang/` (`<code>.sed` for the scripts, `dashboard.<code>.json` for the page): a phrase with no entry there comes out in English, and a new language is a new pair of files plus its code in `LANGS` (`scripts/shipfloor_config.py`).

## Security

- Scripts run from the installed copy in `~/.shipfloor/factory`, outside every worktree.
- The gates read a snapshot of the committed config (`origin/main`), outside the pipelines' reach; `.shipfloor/` is forbidden to agents, so a factory PR cannot change the gates that judge it.
- `templates/factory-guard.yml` repeats the forbidden-path check in GitHub Actions.

## Development

`bash scripts/test/run.sh` runs the suite; `bash scripts/test/run.sh --changed` runs only the tests tied to what changed against `origin/main` (use it while editing, and the whole suite before a push). Designs in `docs/superpowers/specs/`.
