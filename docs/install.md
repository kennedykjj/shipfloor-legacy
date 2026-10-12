# Installing Shipfloor

What the machine needs, how a repository joins the factory, and the dispatcher on each system. Back to the [README](../README.md).

## Requirements

`git`, an authenticated `gh`, `claude`, Python 3.11+ with PyYAML (`pip install pyyaml`), and Git Bash on Windows.

## Install

```bash
claude plugin marketplace add <path or URL of this repo>
claude plugin install sf@shipfloor
bash <plugin>/scripts/shipfloor install     # copies scripts and templates to ~/.shipfloor/factory, each file by rename (safe while runs are in progress) and says how many it replaced, added and removed; refuses a clone that is not a clean, up-to-date main (--force installs anyway and says so)
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

Dispatcher on Linux and macOS: `bash <plugin>/installer/install-dispatcher.sh` registers it. On Linux it is a systemd user timer when there is a systemd user session, else a crontab line. On macOS it is a launchd user agent. To remove it, run `bash <plugin>/installer/install-dispatcher.sh --uninstall`.
- On systemd the dispatcher stops at logout unless lingering is on (`loginctl enable-linger <user>`); the installer says which.
- The pace comes from `--every-min` or `dispatcher.every_min`. To change it, run the installer again. The dashboard's pace control is Windows only.
- The installer records your shell's `PATH` for the timer. Run it again after PATH changes.

## Upgrading from Aghanim's Anvil <!-- legacy aghanim -->

The factory was called Aghanim's Anvil (`aghanim`) before 0.7.0. To move a machine and its repositories: <!-- legacy aghanim -->

1. `aghanim pause` and wait until `aghanim pool` shows no runs. <!-- legacy aghanim -->
2. Install the new plugin (`claude plugin install sf@shipfloor`), then `bash <plugin>/scripts/shipfloor migrate-home` (moves `~/.aghanim` to `~/.shipfloor`) and `shipfloor install`. <!-- legacy aghanim -->
3. Run `installer/install-dispatcher.ps1` again: it replaces the `AghanimDispatcher` task with `ShipfloorDispatcher`. <!-- legacy aghanim -->
4. In each repository, move `.aghanim/` to `.shipfloor/` and update anything that calls `~/.aghanim/factory/` or `/aghanim:*` (project agents, `.claude/settings.json`, `factory-guard.yml`). There is no fallback: a repository is not read until it has `.shipfloor/factory.yml`. <!-- legacy aghanim -->
5. `shipfloor resume`.
