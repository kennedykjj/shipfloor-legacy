# Installing Shipfloor

What the machine needs, how a repository joins the factory, and the dispatcher on each system. Back to the [README](../README.md).

## Requirements

Python 3.11+ with PyYAML (`pip install pyyaml`), Git, an authenticated gh, Claude Code (`claude`), and Git Bash on Windows for the wrappers and the scheduler. Any bash runs the wrappers: there is no minimum version.

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
