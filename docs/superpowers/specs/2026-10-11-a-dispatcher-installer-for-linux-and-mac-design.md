# A dispatcher installer for Linux and macOS — spec

**Issue:** #76 · **Branch:** `feat/76-a-dispatcher-installer-for-linux-and-mac` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** The plugin registers the dispatcher only on Windows (`installer/install-dispatcher.ps1`). On Linux, macOS and WSL the owner must write a timer by hand and the README does not say how, so the factory does not start work there.
**Audience:** The factory's owner and other developers who install the plugin, on a Linux, macOS or WSL machine.
**Acceptance criteria**
- **AC-1** — Given a Linux machine with a working systemd user session, when the install command runs, then a user timer and service (no root) start `~/.shipfloor/factory/run-dispatcher.sh` at the machine's pace (`dispatcher.every_min`, else 3 minutes), and the output says whether lingering is on and, when it is off, that the dispatcher stops at logout and how to turn it on.
- **AC-2** — Given a Linux machine without a usable systemd user session, when the install command runs, then the user's crontab has exactly one dispatcher line at that pace and every other line is unchanged.
- **AC-3** — Given a macOS machine, when the install command runs, then a launchd user agent is loaded that starts `run-dispatcher.sh` at that pace.
- **AC-4** — Given the dispatcher is already registered, when the install command runs again, then exactly one timer, crontab line or agent exists and the command exits 0.
- **AC-5** — Given a cycle is still running, when the next one is due, then no second cycle starts, on systemd, cron and launchd alike.
- **AC-6** — Given a timer starts a cycle with a near-empty environment, when the cycle runs, then `claude`, `gh`, `git` and Python resolve as they do in the owner's login shell.
- **AC-7** — Given a registered dispatcher, when the uninstall command runs, then no dispatcher timer, service, plist or crontab line is left and the crontab's other lines are unchanged; with nothing registered it exits 0 and changes nothing.
- **AC-8** — Given a Linux or macOS machine, when `shipfloor doctor` runs, then it says whether a dispatcher is registered and by which mechanism, and when none is, names the command that registers one; the README names the install and uninstall command for each system next to the Windows one.
**Out of scope:** Moving a factory home from Windows to WSL. New pace values or a new way to choose the pace (#32; the installer only reads the existing setting). System-wide (root) units. Any change to the Windows installer or to the dashboard. Starting the dashboard server on a timer.
**Product fit:** Serves the Operating Context promise that the owner works on Windows, macOS or Linux, which today holds only on Windows. Supports principle 2 (deterministic gates outrank any agent's claim): `doctor` reports the registration it finds on the machine, not an assumption. No conflict with the positioning or what is out of scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

One layer (`factory`). No endpoint, event or data migration.

**Command (new): `installer/install-dispatcher.sh`**, next to the Windows one, run as `bash <plugin>/installer/install-dispatcher.sh [option]`.

| Call | Does | Exit |
|---|---|---|
| (no option) | registers the dispatcher with the mechanism it detects | 0; 1 when it cannot register, with the reason |
| `--every-min <1\|3\|5\|10>` | registers at that pace instead of `dispatcher.every_min` | 2 on any other value |
| `--kind <systemd\|cron\|launchd>` | forces the mechanism (also `SHIPFLOOR_SCHEDULER_KIND`) | 2 on any other value |
| `--uninstall` | removes every registration of every mechanism | 0, also with nothing registered |
| `--status` | prints `registered: <kind>`, or `not registered` and the command that registers | 0 registered, 1 not, 2 on Windows (prints nothing) |
| `--dry-run` | prints the mechanism and pace, changes nothing | 0 |

- **Detection:** `uname -s` is `Darwin` → launchd; else `systemctl --user show-environment` exits 0 → systemd; else `crontab` exists → cron; else exit 1 naming what is missing. On Git Bash it refuses and names `install-dispatcher.ps1`.
- **Pace:** `--every-min`, else `shipfloor-config.sh machine values dispatcher.every_min`, else 3 (the same order as the `.ps1`).
- **Requires** `<home>/factory/run-dispatcher.sh` (else "run 'shipfloor install' first") and a `bash` 4.4 or newer on `PATH` (the factory scripts use `mapfile -d`; macOS ships 3.2). The absolute path of that `bash` is what every mechanism starts.
- **What each mechanism starts:** `<bash> -l <home>/factory/run-dispatcher.sh`, with `SHIPFLOOR_HOME=<home>` set when the installing shell had it set.

| Mechanism | Files and names | How |
|---|---|---|
| systemd | `${XDG_CONFIG_HOME:-~/.config}/systemd/user/shipfloor-dispatcher.service` and `.timer` | service `Type=oneshot`, `KillMode=process`; timer `OnCalendar=*:0/<n>`; `systemctl --user daemon-reload`, then `enable --now shipfloor-dispatcher.timer`; `loginctl show-user` reads `Linger` |
| cron | one crontab line ending in `# shipfloor-dispatcher` | `*/<n> * * * *`; `crontab -l`, drop the marked lines, add one, `crontab -` |
| launchd | `~/Library/LaunchAgents/com.shipfloor.dispatcher.plist` | `StartInterval` `<n>*60`, `AbandonProcessGroup` true; `launchctl bootstrap gui/<uid> <plist>` |

- **Runs outlive the cycle:** `dispatch.sh` starts pipelines in the background and exits. `KillMode=process` and `AbandonProcessGroup` keep systemd and launchd from killing them when the cycle's process ends.
- **Idempotent:** when the files or the line it would write equal what is there and the mechanism is active, it changes nothing and says "already registered". Otherwise it first removes the registration of the other mechanisms, so a machine never has two.
- **Uninstall:** systemd `disable --now` the timer, delete both unit files, `daemon-reload`; cron writes the crontab back without the marked lines; launchd `bootout`, delete the plist; delete `<home>/dispatcher.path`. A cycle that is running is not stopped.
- **Environment (AC-6):** the installer writes its own `PATH` to `<home>/dispatcher.path` (one line). `scripts/run-dispatcher.sh` puts that in front of `PATH` when the file exists. Windows never has the file, so nothing changes there.
- **No second cycle (AC-5):** `scripts/shipfloor-dispatch.sh` already detects a running cycle (`dispatch.pid`) and only records it. It now also exits 0 without dispatching, after recording `--overlap` in health. A `dispatch.pid` older than `SHIPFLOOR_CYCLE_STALE_MIN` (default 30) is treated as left behind and taken over, so a reused pid cannot stop the dispatcher for good. This holds on every system, Windows included.
- **Doctor (AC-8):** `cmd_doctor` in `scripts/shipfloor` calls `<source>/installer/install-dispatcher.sh --status`: `ok   dispatcher registered (<kind>)`, or `WARN no dispatcher registered; run: bash <source>/installer/install-dispatcher.sh`. A warning does not change doctor's exit code. `cmd_install`'s "next:" line names the command of the system it runs on.
- **README:** the "Dispatcher on Windows" paragraph gains the Linux and macOS install and uninstall commands, lingering, and "run it again after your `PATH` changes".

**Files**

| File | Change | Owner |
|---|---|---|
| `installer/install-dispatcher.sh` | new | factory |
| `scripts/run-dispatcher.sh` | reads `dispatcher.path` | factory |
| `scripts/shipfloor-dispatch.sh` | an overlapping cycle exits; stale `dispatch.pid` | factory |
| `scripts/shipfloor` | doctor line, "next:" line | factory |
| `README.md` | commands per system | factory |
| `scripts/test/install-dispatcher.test.sh` | new | factory |
| `scripts/test/shipfloor-dispatch.test.sh`, `scripts/test/shipfloor-cli.test.sh` | new cases | factory |

**Tests never touch the real timers:** each test uses a temp `HOME` and `SHIPFLOOR_HOME`, forces the mechanism with `--kind`, and puts stand-ins for `systemctl`, `loginctl`, `crontab`, `launchctl` and `uname` first on `PATH`. The stand-ins record their arguments, and the `crontab` one keeps its table in a file. The same tests run on Git Bash and on Linux.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-2 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-3 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-4 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-5 | factory | `scripts/test/shipfloor-dispatch.test.sh` |
| AC-6 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-7 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-8 | factory | `scripts/test/shipfloor-cli.test.sh` |

- AC-5: a live `dispatch.pid` and a stub `SHIPFLOOR_DISPATCH` that must not be called; a stale one that must be taken over. The install test also checks the unit is `oneshot` and the plist is one job.
- AC-6: the test runs the command the cron line holds under `env -i`, with a stub `run-dispatcher.sh` that records what `claude` resolves to.

## Security
_Cybersec_ — n/a

## Rollback
No data changes. To undo on a machine: `bash <plugin>/installer/install-dispatcher.sh --uninstall`.

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- One script with `--uninstall` and `--status`, in `installer/`: it sits next to the Windows installer, and doctor finds it through the recorded plugin source.
- `PATH` is recorded at install time and put in front by `run-dispatcher.sh`, on top of a login shell: Debian's `/etc/profile` replaces `PATH` and `.bashrc` stops early when not interactive, so `bash -l` alone loses `claude` installed through nvm or `~/.local/bin`.
- Only `PATH` is recorded, never other variables: a token exported in the shell must not land in a file.
- The no-overlap guard lives in `shipfloor-dispatch.sh`, not in each timer: cron has no guard of its own, and one rule is testable on every system. Windows gets it too (its `IgnoreNew` never worked behind mintty).
- A stale `dispatch.pid` is taken over after 30 minutes: once the pid check blocks a cycle, a reused pid would otherwise block it forever.
- The installer does not turn lingering on: it changes the machine beyond the user's timers. It prints `loginctl enable-linger <user>`.
- The installer refuses a `bash` older than 4.4 instead of registering a timer that fails every cycle.
- Installing one mechanism removes the others: two timers would double the pace.
- Reinstalling with nothing to change touches nothing: `launchctl bootout` would end a cycle that is running.
- Doctor warns, it does not fail: a machine without a dispatcher still runs pipelines by hand.
- Doctor on Windows stays as it is: the PO kept the Windows side out of scope.
- The dashboard still says the pace control is "Windows only" on Linux and macOS (dashboard is out of scope); there the pace changes by running the installer again. A follow-up card can wire it.
- The launchd path is tested only against stand-ins: CI has no macOS runner.

## Open questions
- none
