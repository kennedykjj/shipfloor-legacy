# Installing Shipfloor

What the machine needs, how a repository joins the factory, and the dispatcher on each system. Back to the [README](../README.md).

## Requirements

Python 3.11+ with PyYAML (`pip install pyyaml`), Git, an authenticated gh, Claude Code (`claude`) and, only for a config that uses `runtime: codex`, the Codex CLI (`codex`, 0.50 or newer), only for `runtime: opencode`, opencode 2.x (`opencode`), and Git Bash on Windows for the wrappers and the scheduler. Any bash runs the wrappers: there is no minimum version.

## The short path

Once the plugin is installed (the first two commands below), `shipfloor init [<repo>] [--yes]` does the rest in one guided run. It checks the prerequisites first (fatal, nothing changes), then runs install, `.shipfloor/factory.yml` (committed to main after a confirmation), `shipfloor add`, `shipfloor setup-board`, the dispatcher and `shipfloor doctor`. Each step is idempotent and prints the `$ <command>` it equals. `--yes` answers the confirmations; without a terminal and without it, init prints the command that needs you and exits 1. The sections below are the same steps by hand.

## Install

To see the factory work before you trust it with a repository, run `bash <plugin>/scripts/shipfloor demo`: it needs only `git` and Python 3.11+ with PyYAML, and touches nothing of yours.

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

To run stages on Codex (see [Runtime: Codex](configuration.md#runtime-codex)): set `runtime: codex` in `~/.shipfloor/config.yml` or a project's `factory.yml`, run `shipfloor install` again (it generates the factory's `CODEX_HOME`, `SHIPFLOOR_CODEX_HOME` or `~/.shipfloor/runtimes/codex`, and leaves `auth.json` alone), then log in to that home, not to your personal `~/.codex`:

```bash
CODEX_HOME=~/.shipfloor/runtimes/codex codex login    # or export CODEX_API_KEY
shipfloor doctor                                      # ok/FAIL for codex, its login and the generated CODEX_HOME
```

To run stages on opencode (see [Runtime: opencode](configuration.md#runtime-opencode)): install opencode 2.x (opencode 1.x is not supported; `shipfloor doctor` says `FAIL` and how to move), set `runtime: opencode` and the models as `provider/model` under `runtime.models`, run `shipfloor install` again (it generates the factory's `OPENCODE_CONFIG_DIR`, `SHIPFLOOR_OPENCODE_HOME` or `~/.shipfloor/runtimes/opencode`), then pick where the model comes from: log in to a provider with `opencode auth login`, or set `runtime.provider` to your own endpoint (chat completions is enough) and export its `api_key_env` variable. Use `codex` for OpenAI's models and Responses API endpoints, `opencode` for the rest.

```bash
opencode auth login      # a provider's credential, when there is no runtime.provider
shipfloor doctor         # ok/FAIL for opencode 2.x, the generated config and the credential or the endpoint
```

Dispatcher on Windows: `powershell -File <plugin>/installer/install-dispatcher.ps1` registers the `ShipfloorDispatcher` task. It runs every 3 minutes unless you choose 1, 5 or 10: pick it in Settings in the dashboard ("Looks for work every"), or pass `-EveryMin` to `installer/install-dispatcher.ps1`. The value lives in `~/.shipfloor/config.yml` as `dispatcher.every_min`.

Dispatcher on Linux and macOS: `bash <plugin>/installer/install-dispatcher.sh` registers it. On Linux it is a systemd user timer when there is a systemd user session, else a crontab line. On macOS it is a launchd user agent. To remove it, run `bash <plugin>/installer/install-dispatcher.sh --uninstall`.
- On systemd the dispatcher stops at logout unless lingering is on (`loginctl enable-linger <user>`); the installer says which.
- The pace comes from `--every-min` or `dispatcher.every_min`. To change it, run the installer again. The dashboard's pace control is Windows only.
- `0.5` (`dispatcher.every_min: 0.5`, or `--every-min 0.5`) runs a cycle every 30 seconds on systemd and launchd. cron and Windows Task Scheduler cannot go below one minute: their installers refuse 0.5 (exit 2) instead of rounding it. `shipfloor doctor` prints the pace the registration runs at.
- On systemd and launchd a run that ends also asks for a cycle at once, so a freed slot does not wait for the next tick; the pace is the net for the rest (a card moved by hand on the board). cron and Windows keep the pace alone. An install from before this needs the installer run again.
- The installer records your shell's `PATH` for the timer. Run it again after PATH changes.
