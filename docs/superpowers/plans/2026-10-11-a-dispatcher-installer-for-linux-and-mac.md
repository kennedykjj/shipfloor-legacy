# A dispatcher installer for Linux and macOS — plan for #76

**Goal:** `bash <plugin>/installer/install-dispatcher.sh` registers the dispatcher on Linux (systemd user timer, else crontab) and macOS (launchd user agent), removes it with `--uninstall`, reports it with `--status`; a cycle that finds another one running exits without dispatching; `shipfloor doctor` says whether a dispatcher is registered.

**Spec:** `docs/superpowers/specs/2026-10-11-a-dispatcher-installer-for-linux-and-mac-design.md`

**Layers:** `factory` only (path `./`, agent `engineer`, Bash and Python 3).

## Constraints

- The spec's `## Architecture` is the contract: option names, exit codes, file names, unit and plist keys, the crontab marker `# shipfloor-dispatcher`, the `--status` lines, the doctor lines.
- No test and no implementation step touches the real user's timers: temp `HOME` and `SHIPFLOOR_HOME`, `--kind` forced, stand-ins for `systemctl`, `loginctl`, `crontab`, `launchctl` and `uname` first on `PATH`.
- The same tests run on Git Bash and on Linux: no call that only one of them has.
- Nothing changes in `installer/install-dispatcher.ps1` or in the dashboard.
- Only `PATH` is written to `<home>/dispatcher.path`, never another variable.
- Existing cases in `scripts/test/shipfloor-dispatch.test.sh` and `scripts/test/shipfloor-cli.test.sh` keep passing; a case that asserted "an overlapping cycle still dispatches" is QA's to change, since the spec reverses that behavior.
- Minimal change: no new config key, no dead code, no narrating comments.

## Tasks

### Task 0 — Acceptance tests (QA, before any implementation)

- **Owner:** `qa-engineer`
- **Files:** creates `scripts/test/install-dispatcher.test.sh`; adds cases to `scripts/test/shipfloor-dispatch.test.sh` and `scripts/test/shipfloor-cli.test.sh`
- AC-1 to AC-4, AC-6, AC-7 in `install-dispatcher.test.sh`; AC-5 in `shipfloor-dispatch.test.sh`; AC-8 in `shipfloor-cli.test.sh`, following the spec's test notes.
- AC-5: a live `dispatch.pid` with a stub `SHIPFLOOR_DISPATCH` that must not be called, and a `dispatch.pid` older than `SHIPFLOOR_CYCLE_STALE_MIN` that is taken over; the install test also checks the unit is `Type=oneshot` and the plist is one job.
- AC-6: run the command the cron line holds under `env -i`, with a stub `run-dispatcher.sh` that records what `claude` resolves to.
- AC-8's README part is checked by reading `README.md` for the install and uninstall command of each system.
- Must fail on the current code with a message that names the missing behavior.

### Task 1 — No second cycle, and the recorded `PATH`

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 0
- **Files:** changes `scripts/shipfloor-dispatch.sh`, `scripts/run-dispatcher.sh`

`scripts/shipfloor-dispatch.sh`:
- A `dispatch.pid` whose process is alive and that is not older than `SHIPFLOOR_CYCLE_STALE_MIN` minutes (default 30) is another cycle: record `--overlap` in health as today, then exit 0 before any project is dispatched.
- An older `dispatch.pid` is left behind: take it over (write this cycle's pid) and run.
- The `health` trap still removes `dispatch.pid` only when this cycle owns it.
- The header comment on that line says what the code now does.

`scripts/run-dispatcher.sh`:
- When `<home>/dispatcher.path` exists and is not empty, its one line goes in front of `PATH` before the dispatch script starts. Without the file nothing changes.

**Done when:** the AC-5 cases pass and the rest of `scripts/test/shipfloor-dispatch.test.sh` is green.

### Task 2 — `installer/install-dispatcher.sh`

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 1 (`dispatcher.path`)
- **Files:** creates `installer/install-dispatcher.sh`

- Options, exits, detection, pace, requirements and what each mechanism starts: the spec's command table and the bullets under it.
- systemd: the two unit files under `${XDG_CONFIG_HOME:-~/.config}/systemd/user/`, `daemon-reload`, `enable --now` the timer, then the lingering line from `loginctl show-user`.
- cron: `crontab -l`, drop the marked lines, add one, `crontab -`; the other lines byte for byte as they were.
- launchd: the plist in `~/Library/LaunchAgents/`, `launchctl bootstrap gui/<uid>`.
- Idempotent: equal files or line and an active mechanism → "already registered", nothing written, nothing reloaded. Otherwise the other mechanisms' registrations are removed first.
- `--uninstall` removes every mechanism's registration and `<home>/dispatcher.path`, exit 0 also with nothing registered; a running cycle is not stopped.
- `--status` and `--dry-run` change nothing.
- Writes its own `PATH` to `<home>/dispatcher.path` on install.

**Done when:** every case in `scripts/test/install-dispatcher.test.sh` passes.

### Task 3 — Doctor, the "next:" line and the README

- **Layer:** `factory` · **Owner:** `engineer` · **Depends on:** Task 2 (`--status`)
- **Files:** changes `scripts/shipfloor`, `README.md`

- `cmd_doctor`: on a system that is not Windows, call `<source>/installer/install-dispatcher.sh --status` and print `ok   dispatcher registered (<kind>)` or `WARN no dispatcher registered; run: bash <source>/installer/install-dispatcher.sh`. The warning does not change doctor's exit code; on Windows (status exit 2) doctor prints what it prints today.
- `cmd_install`: the "next:" line names the command of the system it runs on.
- `README.md`: the "Dispatcher on Windows" paragraph gains the Linux and macOS install and uninstall commands, lingering, and "run it again after your `PATH` changes".

**Done when:** the AC-8 cases pass and the whole of `scripts/test/shipfloor-cli.test.sh` is green.

## Review focus

- A crontab with no dispatcher line and an empty crontab (`crontab -l` exits 1) both install cleanly, and uninstall never writes an empty table over lines it failed to read.
- Reinstalling with nothing to change runs no `bootout`, `disable` or `daemon-reload`.
- A stale `dispatch.pid` is judged by the file's age, not the process's.
- `dispatcher.path` holds `PATH` and nothing else.
