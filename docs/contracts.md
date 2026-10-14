# The scripts' contract

This document describes behavior: what each script under `scripts/` promises to the code, the skills, the dashboard and the people that call it. It was written from the code as it is, not from what anyone remembers of it. When this document and the code disagree, the code is the bug, and the fix is a card: do not edit a script to match a sentence here, and do not edit a sentence here to excuse a script; open a card, and change both there.

Who uses it: the owner who maintains and ports the scripts (the Python port, #153, checks each of its steps against this), and the developers who install the plugin and extend it. `scripts/test/contracts-doc.test.sh` enforces one thing only: every script has a `## <name>` section below, and that section lists, as backticked words, every subcommand the script's usage text names. Everything else here is kept true by review.

Conventions used below:
- stdout is data that callers read; stderr is messages for people. A gate's stderr is translated to the project's language (see `gate.sh`); its stdout never is.
- "the project" is the one `shipfloor_resolve` finds (see `lib/project.sh`). `~/.shipfloor` is `$SHIPFLOOR_HOME`; a project's home `~/.shipfloor/projects/<slug>` is `$FACTORY_HOME`.
- Markers the factory reads stay in English in every language: the catalog `scripts/lang/<language>.sed` has no rule for them on purpose.

## gate.sh

The deterministic gates. Run as `gate.sh [-C <worktree>] <gate> ...`; `-C` enters the worktree first (pipelines never `cd`); a worktree that cannot be entered is `gate: cannot enter '<dir>'` and exit 2.

**Interface:** the gate is the first word after the options. Each subcommand, with its arguments after it:
- `test-plan` `<spec>`: every AC of the spec has a test its layer's runner can run.
- `weight` `<spec>`: the spec's header names exactly one weight: light, standard or heavy.
- `scope` `<role> <base>`: only that role's files changed since `<base>`; the role is `po`, `ux`, `techlead`, `qa` or a layer name.
- `qa-commit` `<n> [--head]`: prints card `<n>`'s QA commit.
- `qa-amend` `<n>`: QA's amendment of its own acceptance tests is honest.
- `acceptance-intact` `<qa>`: the acceptance tests are as QA committed them.
- `forbidden` `<base>`: no forbidden file changed since `<base>`.
- `migration` `<base> <spec>`: applied migrations untouched, destructive ones have a rollback.
- `build` `<base>`: each layer changed since `<base>` builds.
- `red` `<layer> <selector>`: the tests fail on an assertion.
- `green` `<layer> <selector>`: the tests ran and pass.
- `stack` with its three words `up` `<owner>`, `down` `<owner>` and `status`.

Two more words exist that the usage text does not print: `fast` `<base> <spec> [qa]` (forbidden, migration and acceptance-intact in one process; used by `deploy.sh`) and `acceptance-own` `<qa> <file>` (the key `shipfloor accept` records; prints it on stdout). `help`, `-h` and `--help` print the usage on stdout and exit 0; no argument or an unknown one prints it on stderr and exits 2.

**Exit codes:** 0 pass; 1 blocked (details on stderr); 2 bad usage, bad revision, unknown layer or role, a failed config query, an invalid grep -E pattern: never a pass; 3 infrastructure (the run's stack did not come up, no stack slot in time, or a layer's install command failed).

**Verdict line.** Every gate except `stack` and `acceptance-own` ends by writing its verdict as the last line on stderr, in English in every language (it is written by an EXIT trap, after the translation pipe has closed):
- `gate <name>: pass`
- `gate <name>: FAIL (exit N)` for every other exit but 3
- `gate <name>: INFRA (exit 3)`

`<name>` is the word given (`build`, `green`, `qa-commit`...). When `SHIPFLOOR_RUN_LOCK` names an existing directory, the verdict is also written to `<lock>/last-gate` as `<name><TAB><pass|FAIL|INFRA>`; the dispatcher reads how a run ended from there, never from the agent's report.

**Other lines callers read:**
- `flaky: <layer> build` (stdout) when a layer with `retry: 1` passes its build on the second try; `flaky: <layer> <selector>` (stdout) for `green`. The skills copy these into the report's `flaky` list.
- `<gate>: reused the pass on <12 hex> recorded <ISO>; nothing ran` (stderr) when `build` or `green` is answered by a recorded pass (`build: ...`, `green: ...`). The skills copy these into `gates_reused`.
- `red` prints, on stdout, up to 20 lines of the runner's output that match an assertion pattern; `qa-commit` prints the full sha of card `<n>`'s newest commit whose message matches `acceptance tests for #<n>` (the number not followed by another digit); `--head` also requires it to be the last commit.
- Failure messages start with the gate's own word: `forbidden:`, `scope:`, `migration:`, `acceptance-intact:`, `qa-amend:`, `qa-commit:`, `test-plan:`, `weight:`, `red:`, `green:`, `build:`, `gate:`, `stack:`.

**Behavior worth keeping:**
- `build` and `green` record a pass per clean worktree: a file `gate-passes/<sha1>` under the project's home holding `<ISO UTC><TAB><head sha><TAB><gate><TAB><arguments>`, keyed by the head, the gate, its arguments, the config file's hash and `gate.sh`'s own hash. Not used when the worktree is dirty, when `SHIPFLOOR_GATE_FRESH=1`, or when the store would be inside the worktree. Records older than 14 days are deleted at each record.
- The selector reaches the layer's test command as `"$1"` of `bash -c`, never as shell code. `NO_COLOR=1` and `FORCE_COLOR=0` are exported for the runner. A layer with `needs_stack` runs on its own stack slot (`lib/stack.sh`, owner `gate-<pid>`); if the slot does not come up the gate exits 3.
- `red` is never retried; `green` and `build` run once more for a layer with `retry: 1`.
- A layer's `install` command runs once per content of the layer's directory (marker in the git dir), by the gate, not by an agent.
- `qa-amend` allows at most `FACTORY_QA_AMEND_MAX` (default 2) amendments, refuses a commit touching files outside the QA scope, a switched-off test, or fewer assertion lines than before.
- The language of the stderr comes from `FACTORY_LANGUAGE` (set at launch), else the machine's `overrides.yml`, else the project's `factory.yml`.

## board.sh

Reads and moves cards on the project's GitHub Project v2 (config: `board.owner`, `board.number`, `project.repo`). Statuses are the column names without their owner mark ("👤 Spec Review" is `Spec Review`).

**Interface:** `items`; `status` `<n>`; `count` `<status>...`; `first` `<status>`; `eligible` `<status>`; `move` `<n> <status>`; `infra`; `label` `<n>` then `add` or `remove` and `<name>`; `issue` `<n>`; and `snapshot`. The usage line printed on a bad command lists `items`, `status`, `count`, `first`, `move`, `infra`, `label`, `issue`, `add` and `remove`; `eligible` and `snapshot` work but are not in it. A bad command prints the usage on stderr and exits 2.

**Output (stdout):**
- `items`: `<issue><TAB><status>` per card, in the project's own order (the position the owner sets by dragging).
- `snapshot`: `<issue><TAB><status><TAB><item id>` per card, always read from GitHub (this is what the dispatcher saves as `board.tsv`).
- `status <n>`: the status; empty when the card is not on the board. `count`: one number, the cards in any of the given statuses. `first <status>`: the first eligible card, or nothing. `eligible <status>`: one issue number per line, board order, skipping cards labeled `blocked` or `blocked:infra`. `infra`: open issues labeled `blocked:infra`, one number per line.
- `issue <n>`: `#<n> <title>`, a blank line, the body, then each comment as `--- comment by <login>, <ISO>` and its body, for the comments of the factory's own GitHub user and of `trusted_commenters` only (`*` is anyone). When others commented, the last line is `(<k> comment[s] by other people not shown)`.

**Reads from the environment:** `FACTORY_BOARD_SNAPSHOT`: when it names a non-empty file, `items`, `status`, `count`, `first` and `eligible` read it instead of GitHub (the GraphQL quota is shared with the pipelines). `FACTORY_GH` replaces `gh`.

**Exit codes:** 0 ok; 1 a lookup failed, the card is not on the board or the status is unknown (`eligible` and `first` fail closed: any failed lookup is exit 1, never an empty list that looks like "nothing eligible"); 2 bad usage, a status that is not a board column, or no readable board config; 3 `move` refused because only the owner moves cards **to** `Ready for Refinement`, `Ready for Dev` or `Ready for Prod`, or **out of** `Spec Review` or `Staged`.

**Behavior worth keeping:** `label <n> remove` of an absent label is not an error; `board-ids` (project id and Status field id) is cached under the project's home.

## deploy.sh

The deterministic deploy of one card: `deploy.sh <n> [--refresh | --continue]`. Run from the control checkout by the dispatcher (stage `deploy`) and, with `--refresh`, by the dispatcher's refresh of Staged cards.

**Interface:** `<n>` is the issue number; the modes are `--refresh` (bring a Staged card's PR up to date with main, clean merges only, never merges to main) and `--continue` (resume after what a previous run handed over was fixed and committed); no flag is a full deploy. There are no subcommand words.

**Exit codes:** 0 done (and every "nothing to do" of `--refresh`); 2 usage, configuration, a transient API error, or the card is busy or not in `Ready for Prod` (safe to retry); 3 handed over to an agent (conflicts listed in `<tmp>/resolve.files` and printed as `CONFLICT <path>` lines, or a fix round with the findings in `<tmp>/fix.findings`); 4 sent back (to Coding, or to Staged with a fix the owner must see); 5 blocked before merging (label `blocked`); 6 failed after the merge and reverted.

**Log lines:** every line it says is `deploy #<n>: <text>` on stdout, translated by the project's `language`. Lines the dispatcher or the dashboard do not read by pattern.

**Markers it writes on the issue** (always English): see "GitHub markers". It posts the record comment (`deploy-merge:` or `deploy-fix:` lines) **before** it pushes the commits they name; an unpushed record is harmless, an unrecorded push wedges the card.

**Behavior worth keeping:**
- One `deploy.sh` per card at a time: lock `locks/deploysh-<n>.lock/info` holding `<pid> <epoch>`; a stale one (pid dead) is taken over.
- Approval is the newest `staged-head: <40 hex>` comment written by the factory's own GitHub user; `HEAD_SHA` of the PR must be that commit or a chain (at most 10) of recorded `deploy-merge`/`deploy-fix` commits on top of it, each merge's second parent an ancestor of `origin/<main>`.
- A fork PR, zero or several open PRs for the card, a PR changed after staging, red gates or red CI before merge are `block`: exit 5.
- Merge is `gh pr merge --squash --match-head-commit <sha>`. After merge it checks `deploy.ci_workflow` on `origin/<main>` (a failed run reruns its failed jobs once), then `deploy.environment`, then each `deploy.healthcheck` url (5 tries); any failure opens `revert/<n>` and a revert PR, comments with a closing `staged-head: <sha of the revert branch>`, reopens the issue, labels `blocked` and exits 6.
- `deploy.local_ci`, when set, replaces waiting for GitHub's checks.
- A fix of at most `deploy.fix_max_files` files and `fix_max_lines` lines that touches no acceptance test ships with the approved head; a larger one goes back to Staged with a new `staged-head:`.
- At most two fix rounds (`<tmp>/fix.round`), after which the card goes back to Coding.

## dispatch.sh

One dispatcher cycle for one project: starts pipelines for cards waiting in the owner's queues. Run by `shipfloor-dispatch.sh` once per registered project with `FACTORY_CONTROL_REFRESH=0`.

**Interface:** none: it takes no arguments and has no subcommands. It exits 0 with nothing to do when `PAUSE` exists in the project's home; 2 for an invalid config, unreadable limits, pool or stage models; 1 when the board read fails; otherwise the number of failing steps (0 or 1).

**What it does, in order:** reads the board once into `board.tsv` (a temp file per process, then renamed) and exports `FACTORY_BOARD_SNAPSHOT=<home>/board.tsv`; stops when a log under the home's `logs/` was written in the last 30 min and holds `hit your session limit` after its last `== start`; removes `cost/<n>.json` and `stepup/<n>` markers of cards that left the board or Coding; applies the machine's `costs` limits through `dashboard_cost.py`; retries `blocked:infra` cards once; unless outside the working hours, runs the pipelines `refine`, `develop`, `validate` and `deploy` in that order; optionally refreshes Staged cards when `deploy.refresh_staged` is true; sweeps stale `tmp/` folders.

**Log lines, on stdout** (the dispatcher's own, `dispatch: ...` or `<ISO> dispatch: ...`, translated by the machine's `language`): e.g. `dispatch: outside working hours; runs start again at <hh:mm>`, `dispatch: #<n> reached costs.card_block; blocked`, `<ISO> dispatch: #<n> failed gate <gate> on <from>; the next run is on <to>`. They are free text, read by people only.

**The run's own log** is `logs/<YYYY-MM-DD>-<n>-<stage>.log` of the project's home, with these lines written by the dispatcher (the dashboard reads them with regular expressions in `dashboard.py`: `RUN_LINE` and `STEPUP_LINE`):
- `== start /sf:<stage> <n> <ISO> pid=<pid>[ model=<m>] weight=<w>`
- `== end /sf:<stage> <n> exit=<rc> <ISO>`
- `== step-up /sf:develop <n> <from> -> <to>: gate <gate> failed <ISO>`

`<ISO>` is `date -Is`. The pid is the subshell that owns the lock. For the `deploy` stage `exit=` is the exit code of `deploy.sh` after its handover rounds (up to three agent rounds on exit 3).

**Locks:** `locks/<stage>-<n>.lock/` per card and stage, holding `info` (`<pid> <epoch> <n>`), written by `launch`; `step` (`<k><TAB><epoch>`, from `shipfloor-config.sh step`); `last-gate`; `inbox` and `inbox.<agent>`. A lock older than `FACTORY_LOCK_TTL` (default 10800 s) whose pid is gone is removed. `locks/refresh-<n>.lock/` is a `deploy.sh --refresh` and does not count as a run.

**Concurrency:** limited by the machine pool (`pool`, `stages.<stage>`) and the project's `limits.refine.wip` and `limits.develop.wip`; `SHIPFLOOR_MAX_PARALLEL` overrides the pool; the deploy stage runs one at a time per project. Orphans (a card in a WIP column with no live run) are resumed before new cards are taken.

**The `claude -p` launch** is described in its own section below.

## shipfloor-dispatch.sh

One cycle of the scheduled task across every project in `~/.shipfloor/registry.tsv`.

**Interface:** none: no arguments, no subcommands. Reads `SHIPFLOOR_DISPATCH` (default `dispatch.sh` beside it) so a test can stand in for the per-project run.

**Behavior:** exits 0 at once when `registry.tsv` is empty or missing, when `PAUSE` exists in `~/.shipfloor`, or when another cycle is alive (see below). For each project (a subshell per project, so one failing project does not stop the others): brings the control checkout to `origin/<main>` (retrying `index.lock` three times, `SHIPFLOOR_LOCK_RETRY_S` apart, and removing one older than `SHIPFLOOR_STALE_LOCK_MIN` minutes, default 10); refreshes the config snapshot `<home>/factory.yml` from the checkout; validates it; clears `SKIPPED` and runs `dispatch.sh`. A project that fails any of the first three is skipped: one line `<ISO> shipfloor: <slug>: <reason>; skipped` on stderr, and `<home>/SKIPPED` holds `<ISO of the first failed cycle><TAB><reason>`. The exit code is 1 when any project failed, else 0.

**One cycle at a time:** `~/.shipfloor/dispatch.pid` holds the pid; a live pid in a file younger than `SHIPFLOOR_CYCLE_STALE_MIN` minutes (default 30) is an overlap: this cycle records it and stops. An older file is taken over.

**History:** on exit, however it ends, it appends one line to `logs/health-<YYYY-MM>.jsonl` through `shipfloor_health.py record --home <home> --seconds <n> --exit <rc> [--overlap]` and then runs `shipfloor_notify.py cycle`. Neither ever fails the cycle.

## run-dispatcher.sh

The entry point the scheduler runs (installed in `~/.shipfloor/factory`).

**Interface:** none. It appends all its output to `~/.shipfloor/logs/dispatcher.log`, exits 0 if `~/.shipfloor/PAUSE` exists, prepends the first line of `~/.shipfloor/dispatcher.path` (written by the installer) to `PATH`, and then `exec`s `shipfloor-dispatch.sh`. Its exit status is that script's.

## inbox-hook.sh

The `PostToolUse` hook of a factory run (`hooks/hooks.json`).

**Interface:** none: it reads the hook's JSON on stdin. With no `<SHIPFLOOR_RUN_LOCK>/inbox` or an empty one it exits 0 at once (the usual case, it must cost nothing). Otherwise it runs `inbox_hook.py`, which prints to stdout one JSON object `{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Message from the owner, sent while you work. ...<the new messages>"}}`. Each agent (the lead, and each subagent by its `agent_id`) gets each message once, tracked in `<lock>/inbox.<agent>` (`inbox.lead` for the lead) as the count of lines read. Each line of `inbox` is JSON with a `text`. The skills and agents treat a note that opens with that sentence, arriving as hook context, as the owner's instruction.

## metrics.sh

**Interface:** none; run as `shipfloor metrics <slug>` or directly in a project. It pulls the `factory-reports` worktree (`<home>/reports-wt`, failures ignored) and prints on stdout a TSV with the header `issue<TAB>pipeline<TAB>outcome<TAB>tokens<TAB>duration_min<TAB>rounds<TAB>gates_failed<TAB>manual_edit` and one row per `reports/*/*.json`: tokens is the sum over `agents`, duration the minutes between `finished_at` and `started_at` (empty when either is missing), rounds the sum of `rounds`, `gates_failed` comma-joined, `manual_edit` empty when null. Exit 2 when no project is found.

## report.sh

**Interface:** `report.sh <issue> <slug> <pipeline> <report.json> <report.md>`; `pipeline` is one of `refine`, `develop`, `validate` or `deploy`. `help`, `-h`, `--help` print the usage on stdout and exit 0; any other argument count prints it on stderr and exits 2.

**Behavior:** commits the two files to the orphan branch `factory-reports` as `reports/<issue>-<slug>/<pipeline>-<YYYY-MM-DDTHHMMSS>.json` and `.md`, in the worktree `<home>/reports-wt` (created from `origin/factory-reports`, or as a new orphan branch with a `README.md`, when missing), and pushes. Commit message `chore(factory): report #<issue> <pipeline> <stamp>` with a Co-Authored-By trailer. It never touches `main`.

**report.json:** `{"issue","slug","pipeline","started_at","finished_at","outcome":"ok|blocked|infra","agents":[{"role","tokens","duration_s"}],"rounds":{step:n},"gates_failed":[...],"flaky":["<layer> <selector>"],"gates_reused":["build","green <layer> <selector>"],"manual_edit":true|false|null}`. `metrics.sh` and the dashboard read it.

## review-page.sh

**Interface:** `review-page.sh <spec.md> <issue> <branch> <out.html>`. No subcommands. Exit 2 on a wrong argument count or a spec that is not a file; otherwise the exit status of `review_page.py`, which builds the local review page from the spec and `review-template.html` and writes `<out.html>` (its folder is created). `FACTORY_PROJECT` is passed through.

## setup-board.sh

**Interface:** none: a one-off per project, run as `shipfloor setup-board <slug>` from the control checkout. It snapshots every card's item and status (to `$SNAPSHOT`, or a temp file), rewrites the Status field's options to the ten columns (`Inbox`, `Ready for Refinement`, `Technical Refinement`, `Spec Review`, `Ready for Dev`, `Coding`, `Validation`, `Staged`, `Ready for Prod`, `Done`, each with its 👤 or 🤖 mark), restores each card's status by name ignoring the mark (a status with no column leaves the card without Status and prints `no column for '<status>' (item <id>): left without Status` on stderr), creates or updates the labels `ui`, `cybersec` and `blocked`, deletes the cached `board-ids`, and prints the count per status. Exit 1 when the project has no Status field; 2 when no project is found.

## shipfloor-config.sh

**Interface:** the first word selects: `step <k>`, `machine <query...>`, `validate`, or any other word, which is passed as a query to `shipfloor_config.py` for the resolved project (`get`, `values`, `fields`, `layers`, `layer`, `regex`, `describe`, `language`, `patterns`, `migration-layers`, `migration-check`, `migration-renumber`, `gate-fast` and others defined there).
- `step <k>`: a factory run records the skill step it is on: writes `<k><TAB><epoch>` to `<SHIPFLOOR_RUN_LOCK>/step`, only when the lock is a directory and `<k>` is a number. Never fails a run: always exit 0, no output.
- `machine ...`: the machine's own file `~/.shipfloor/config.yml`; needs no project (the installer asks from anywhere). Exits with the query's status.
- `validate`: the config is valid and every pattern works with `grep -E`; exit 0 or 1.
- Any other query needs a resolved project: exit 2 when there is none; otherwise the query's own status.

## lib/project.sh

Sourced, never run; shared by the scripts. **Interface:** no subcommands; the functions it defines are `shipfloor_native`, `shipfloor_py`, `shipfloor_python`, `shipfloor_cfg_ready`, `git_common`, `shipfloor_use`, `shipfloor_config_path`, `shipfloor_snapshot`, `shipfloor_resolve`, `ere_ok`, `shipfloor_validate`, `shipfloor_clean_tmp`, `shipfloor_stale_tmp`, `shipfloor_sweep_tmp`, `shipfloor_card_spec`, `shipfloor_spec_weight`, `shipfloor_card_weight`, `shipfloor_say`, `shipfloor_machine` and `shipfloor_cfg`.

**Exports:** `SHIPFLOOR_HOME` (default `~/.shipfloor`), `SHIPFLOOR_LIB`, and after `shipfloor_use` or `shipfloor_resolve`: `FACTORY_PROJECT`, `FACTORY_REPO`, `FACTORY_MAIN` (default `main`), `FACTORY_HOME`, `FACTORY_WT_ROOT` (default `<home>/wt`) and `FACTORY_CONFIG` (`<home>/factory.yml`, the snapshot).

**Contracts:**
- `shipfloor_resolve`: returns 0 when `FACTORY_CONFIG` is already set, or when the registry has a project whose repository shares its git common dir with the given directory; otherwise prints `shipfloor: <pwd> is not in a registered project (shipfloor add <repo>)` on stderr and returns 1.
- `shipfloor_snapshot`: writes the config as committed at the control checkout's HEAD to `FACTORY_CONFIG`; the config never comes from a worktree an agent can edit.
- `shipfloor_python` always runs `python -I`. `SHIPFLOOR_PY` is `FACTORY_PYTHON`, else `python3`, else `python`.
- `shipfloor_say <language>`: filters stdin through `scripts/lang/<language>.sed`; English or an unknown language passes it unchanged.
- `shipfloor_card_spec <n>`: the spec in `<worktrees>/<n>` named `<paths.specs>*-<slug>-design.md` where the branch is `feat/<n>-<slug>`; nothing otherwise. `shipfloor_spec_weight` gives `light`, `standard` or `heavy` from the spec header's single `**Weight:**` line, else `standard`.
- `shipfloor_sweep_tmp` prints `tmp/<name>` per thing removed; it does nothing when `board.tsv` has no card line.

## lib/stack.sh

Sourced after `lib/project.sh`, with a resolved project; the one place stack-slot state is computed (`gate.sh`, `dispatch.sh`, `shipfloor` and the dashboard ask here).

**Interface:** no subcommands of its own; `gate.sh stack up <owner>`, `down <owner>` and `status` are its command line. The functions are `stack_settings`, `slot_state`, `slot_env`, `slot_down`, `slot_release`, `slot_reclaim`, `solo_busy`, `queue_ticket`, `stack_lease`, `stack_up`, `stack_down`, `stack_release_run`, `stack_status`.

**Contracts:**
- Slot `k` is the directory `locks/stack-<k>.lock/` of `~/.shipfloor` (shared across projects) holding `info` (`<owner> <run lock|-> <epoch>`), `beat` (heartbeat file, touched every 15 s by `beat.pid`'s process), `beat.pid`, `solo` (the project's name, for a project with no `stack.up`: one run at a time), `env` (the `SHIPFLOOR_*` variables), `down` (the stored down command), `cwd` and `up.log`.
- A slot is `free`, `busy` or `stuck <reason>` (`no-info`, `run-ended`, `heartbeat` older than `stack_stale` s, `hold-max` older than `stack_hold_max` s); a stuck slot is reclaimed by the next lease, which appends `<ISO> reclaimed slot <k> from <owner> <reason>` to `logs/stacks.log`.
- Waiters take `locks/stack-queue/<19-digit sequence>-<owner>` tickets holding `<pid> <run lock|-> <solo|->`; slots go in ticket order; a ticket whose pid or run is gone leaves the queue. After `stack_wait` s (`FACTORY_STACK_WAIT` overrides) it prints `stack: no free slot after <n>s` on stderr and returns 3.
- `stack_up <owner>` exports `SHIPFLOOR_SLOT`, `SHIPFLOOR_STACK` (`shipfloor-<project>-<k>`), `SHIPFLOOR_PORT_<NAME>` (`ports.base + k * ports.span + i`) and `SHIPFLOOR_STACK_URL`, runs `stack.up`, waits for `stack.health` up to `stack.timeout` s (a body matching `stack.reject` is unhealthy), and prints the URL on stdout; failure returns 3 (`stack: up failed:` or `stack: not healthy after <n>s at <url>`).
- `stack_down <owner>` does nothing when the owner holds no slot. `stack_status` prints `<k><TAB><free|busy|stuck><TAB><owner|-><TAB><held seconds><TAB><reason>` per slot, then `queue<TAB><n>`.

## lib/portable.sh

Sourced, never run; defines functions only, for the tools that differ between GNU (Linux) and BSD (macOS) userlands. `deploy.sh` sources it directly and `dispatch.sh` gets it through `lib/stack.sh`.

**Interface:** no subcommands; the functions are `mtime`, `run_bounded` and the internal `_kill_tree`.

**Contracts:**
- `mtime <path>` prints the modification time in epoch seconds; it tries `stat -c %Y`, `stat -f %m`, `date -r` and `python3`, in that order, and fails when the path cannot be read.
- `run_bounded <seconds> <command...>` returns the command's exit code, or 124 when it was stopped at its limit. It uses `timeout` when present; otherwise it runs the command in the background with a watcher that, at the limit, kills the command's process tree.
- `_kill_tree <pid>` kills the process and all its descendants (found with `pgrep -P`), children first.

## shipfloor

The CLI, `scripts/shipfloor` (installed to `~/.shipfloor/factory/shipfloor`). Run with no argument or an unknown one it prints the header lines 2 to 10 of its own source on stderr and exits 2; the `dashboard` line (line 11) is not among them. Errors are `shipfloor: <message>` on stderr; `die` exits 1 unless it says otherwise.

**Interface:** each subcommand, with its arguments after it:
- `install` `[--force]`
- `doctor`
- `add` `<repo> [--worktrees DIR] [--main BRANCH]`
- `remove` `<slug>`
- `list`
- `pause` `[slug]` and `resume` `[slug]`
- `setup-board` `<slug>` and `metrics` `<slug>`
- `pool`, alone, or with `set` `<n>`, `stage` `<stage> <n>` (stage is `refine`, `develop`, `validate` or `deploy`) or `stacks` `<n>`
- `clean` `<slug>`
- `accept` `<slug> <n> <reason>`
- `weight` `<slug> <n> <weight>`, the weight being `light`, `standard` or `heavy`
- `dashboard` `[--port N] [--no-open] [--token T]`

**Per command:**
- `install`: copies `scripts/` (not `test/`) and `templates/` into `~/.shipfloor/factory` by rename (so a running script keeps its inode), removes what the plugin no longer ships, writes `.source` (the plugin checkout) and, when it is a git clone, `.origin` (`<commit><TAB><branch|detached><TAB>verified|forced`). Refuses (exit 1, reasons on stderr, `install anyway: shipfloor install --force`) when the clone is not a clean, current `main`, unless `--force`. Prints `installed <src> → <dest>: <n> replaced, <n> added, <n> removed` and a `next:` line on stdout; with `--force` a `WARN installed copy is not a verified <main>: ...` line. Exit 0 when nothing failed.
- `doctor`: one line per check on stdout, starting `ok   `, `WARN ` or `FAIL `; exit 1 when any is `FAIL`. Lines `WARN health: <alert> (~/.shipfloor/logs/health-*.jsonl)` come from `shipfloor_health.py alerts`, `WARN <slug>: the dispatcher skips it since <ISO>: <why>` from `SKIPPED`.
- `add <repo>`: needs `.shipfloor/factory.yml` on `origin/<main>`; creates the project's home, its control worktree at `origin/<main>`, the config snapshot and the registry line `<slug><TAB><repo><TAB><worktrees><TAB><main>`; prints `registered <slug> (<repo>, worktrees in <dir>)`. A slug registered for another repository is refused.
- `remove <slug>`: drops the control worktree and the registry line; logs and reports stay. `list`: `<slug><TAB>active|paused<TAB><repo><TAB><worktrees>` per project, `(all paused)` first when `~/.shipfloor/PAUSE` exists, `no projects` when none. `pause`/`resume` with no slug touch `~/.shipfloor/PAUSE`; with a slug, the project's `PAUSE`.
- `pool`: shows the machine pool (`shipfloor_machine show`) with `(<n> running)` per stage and the stack slots (`  slot <k>: <state> ...`, `  queue: <n> waiting`); `pool set <n>` sets `pool`, `pool stage <stage> <n>` sets `stages.<stage>`, `pool stacks <n>` sets `stacks`, all in `~/.shipfloor/config.yml`. Any other word: exit 2 with `usage: shipfloor pool [set <n> | stage <refine|develop|validate|deploy> <n> | stacks <n>]`.
- `clean <slug>`: removes what finished cards left under `tmp/`, printing `removed tmp/<name>`. `setup-board <slug>` and `metrics <slug>` run the scripts of those names for that project.
- `accept <slug> <n> <reason>`: owner only. For each file of card `<n>`'s QA commit that changed since, records a line `<file><TAB><blob or own:<hash>|deleted><TAB>#<n><TAB><ISO><TAB><reason>` in the project's `accepted.tsv` and prints `accepted <file> at <12 hex>` or `accepted the deletion of <file>`; `nothing to accept: acceptance-intact already passes for card <n>` when nothing differs. Exit 2 on a usage error, 1 on any other refusal.
- `weight <slug> <n> <weight>`: owner only. Rewrites the one `**Weight:** <w>` line of the card's spec header, commits it on the card's branch as `docs(<scope>): weight <w> for #<n>` and pushes (reset on a failed push); prints `weight <w>`. Exit 3 when the card is no longer in Spec Review or a run is working on it; 2 on usage; 1 otherwise.
- `dashboard`: runs `dashboard.py` with `--home`; its first stdout line is `shipfloor dashboard: <url>  (Ctrl+C stops it)`, which the dashboard skill reads and gives back as the one link; the URL carries the machine's token. When it cannot bind, it exits with `shipfloor dashboard: ports <a>-<b> are taken`.

## GitHub markers

What the factory writes on issues, PRs and commits, and who reads it. All stay in English whatever the project's language.

| Marker | Where | Written by | Read by |
|---|---|---|---|
| `staged-head: <40 hex>` | last line of an issue comment | the validate skill (the PR's head, when green); `deploy.sh` (the fix pushed back to Staged; the revert branch's head after a failed production deploy) | `deploy.sh`: the newest one from the factory's own user is the owner-approved commit |
| `deploy-merge: <merge sha> <main parent sha>` | a line in an issue comment | `deploy.sh`, before the push | `deploy.sh`: with `deploy-fix:`, extends the chain from the approved head; counts only under the newest `staged-head:` |
| `deploy-fix: <sha>` | a line in an issue comment | `deploy.sh` (a renumbered migration or a small fix), before the push | as above |
| commit message `acceptance tests for #<n>` | QA's commit | the develop skill | `gate.sh` (`qa-commit`, `qa-amend`, `acceptance-intact`), `deploy.sh`, `shipfloor accept` |
| `Factory report — <stage>` | an issue comment | each pipeline's skill | people and the dashboard |
| `Factory deploy stopped: <reason>`, `Back to Coding: <reason>`, `Back to Staged: ...`, `Deployed: merge <sha> ...`, `Production deploy failed: ...` | `deploy.sh`'s comments | `deploy.sh` | people |
| labels `blocked`, `blocked:infra`, `ui`, `cybersec` | issues | `board.sh label`, `deploy.sh`, `dispatch.sh`, the skills | `board.sh eligible` (skips the first two), `dispatch.sh` (retries `blocked:infra` once) |
| branches `feat/<n>-<slug>`, `revert/<n>`, `factory-reports` | git | skills, `deploy.sh`, `report.sh` | `deploy.sh` finds its PR by those branch names |

The record comment is posted **before** the push it records. Only the factory's own GitHub user's `staged-head:` counts: anyone can comment on a public repository.

## Files under ~/.shipfloor

`~/.shipfloor` is `SHIPFLOOR_HOME`; `<home>` below is `~/.shipfloor/projects/<slug>`.

| File | Format | Written by | Read by |
|---|---|---|---|
| `registry.tsv` | `<slug><TAB><repo><TAB><worktrees><TAB><main>` | `shipfloor add`, `remove` | `shipfloor`, `lib/project.sh`, `shipfloor-dispatch.sh`, `dashboard.py`, `dashboard_cost.py` |
| `config.yml` | the machine config: `pool`, `stages`, `stacks`, `ports`, `costs`, `hours`, `language`, `notify`, models | `shipfloor pool`, the dashboard | `shipfloor_config.py machine`, `dispatch.sh`, `dashboard.py`, `shipfloor_health.py`, `shipfloor_notify.py` |
| `overrides.yml` (beside `<home>/factory.yml`) | machine-side overrides of a project's config, such as `language` | the owner, the dashboard | `shipfloor_config.py`, `gate.sh` |
| `PAUSE` (here and in `<home>`) | empty file | `shipfloor pause`, the dashboard | `shipfloor-dispatch.sh`, `dispatch.sh`, `run-dispatcher.sh`, `shipfloor_health.py`, `shipfloor_notify.py`, `dashboard.py` |
| `dispatch.pid` | the cycle's pid | `shipfloor-dispatch.sh` | the same script, to detect an overlap |
| `dispatcher.path` | a PATH prefix, first line | the installer | `run-dispatcher.sh` |
| `factory/` | the installed copy of `scripts/` and `templates/`; `factory/.source` the plugin checkout path, `factory/.origin` `<commit><TAB><branch><TAB>verified|forced` | `shipfloor install` | `dispatch.sh` (`.source`), `shipfloor doctor`, `dashboard.py` |
| `<home>/factory.yml` | the config snapshot of `origin/main` | `shipfloor-dispatch.sh`, `shipfloor add` | every script, through `FACTORY_CONFIG` |
| `<home>/control/` | worktree of `origin/<main>`, where runs start | `shipfloor add`, the dispatcher | pipelines (cwd) |
| `<home>/wt/<n>/` | a card's worktree | the pipelines | `deploy.sh`, `shipfloor weight` and `accept` |
| `<home>/board.tsv` | `<issue><TAB><status><TAB><item id>` | `dispatch.sh` | `board.sh` (as `FACTORY_BOARD_SNAPSHOT`), `lib/project.sh` (stale tmp), `shipfloor_notify.py`, `dashboard.py` |
| `<home>/board-ids` | `<project id> <Status field id>` | `board.sh` | `board.sh`, `dashboard.py` |
| `<home>/SKIPPED` | `<ISO><TAB><reason>` | `shipfloor-dispatch.sh` | `shipfloor doctor`, `dashboard.py` |
| `<home>/accepted.tsv` | `<file><TAB><blob or own:<hash> or deleted><TAB>#<n><TAB><ISO><TAB><reason>` | `shipfloor accept` | `gate.sh acceptance-intact` |
| `<home>/locks/<stage>-<n>.lock/` | directory: `info` (`<pid> <epoch> <n>`), `step` (`<k><TAB><epoch>`), `last-gate` (`<gate><TAB><pass|FAIL|INFRA>`), `inbox`, `inbox.<agent>` | `dispatch.sh`, `shipfloor-config.sh step`, `gate.sh`, the dashboard | `dispatch.sh`, `dashboard.py`, `inbox_hook.py`, `shipfloor weight` |
| `<home>/locks/deploysh-<n>.lock/` | `info` (`<pid> <epoch>`) | `deploy.sh` | `deploy.sh` |
| `<home>/locks/refresh-<n>.lock/` | `info` (`<pid> <epoch> <n>`) | `dispatch.sh` | `dispatch.sh` |
| `<home>/stepup/<n>` | `<from model><TAB><to model><TAB><gate>` | `dispatch.sh` | `dispatch.sh`, `dashboard.py` |
| `<home>/infra/<n>` | `<epoch>`; the retry's marker | `dispatch.sh` | `dispatch.sh` (the run gets `SHIPFLOOR_INFRA_RETRY=1`), `dashboard.py` |
| `<home>/cost/<n>.json` | the baseline of a cost block | `dashboard_cost.py` | `dashboard_cost.py`, `dispatch.sh` (removes it when the card leaves the board) |
| `<home>/tmp/<n>/` | a run's scratch: `fix.round`, `fix.parent`, `fix.findings`, `resolve.parents`, `resolve.files`, `gates.txt`, `merge.txt`, `merge-pr.txt`, `local-ci.txt`, `report.json`, `report.md`, worktrees | the pipelines, `deploy.sh` | the same; removed with the run, and by the dispatcher's sweep |
| `<home>/gate-passes/<sha1>` | `<ISO><TAB><head><TAB><gate><TAB><arguments>` | `gate.sh` | `gate.sh` |
| `~/.shipfloor/locks/stack-<k>.lock/` | see `lib/stack.sh` | `lib/stack.sh` | `lib/stack.sh`, `shipfloor pool`, `dashboard.py` |
| `~/.shipfloor/locks/stack-queue/` | tickets, see `lib/stack.sh` | `lib/stack.sh` | `lib/stack.sh` |
| `<home>/logs/<YYYY-MM-DD>-<n>-<stage>.log` | the run's output with the `== ` lines | `dispatch.sh` | `dashboard.py` (`RUN_LINE`, `STEPUP_LINE`), `dispatch.sh` and `shipfloor-dispatch.sh` (`hit your session limit` after the last `== start`) |
| `<home>/logs/<YYYY-MM-DD>-<n>-refresh.log` | the output of `deploy.sh --refresh` | `dispatch.sh` | people |
| `~/.shipfloor/logs/dispatcher.log` | the scheduler's output | `run-dispatcher.sh` | people |
| `~/.shipfloor/logs/stacks.log` | `<ISO> reclaimed slot <k> from <owner> <reason>` | `lib/stack.sh` | people |
| `~/.shipfloor/logs/health-<YYYY-MM>.jsonl` | one JSON object per cycle | `shipfloor_health.py record` | `shipfloor doctor`, `shipfloor_notify.py`, `dashboard.py` |
| `<home>/reports-wt/` | worktree of the `factory-reports` branch | `report.sh` | `metrics.sh`, `dashboard.py` |
| `~/.shipfloor/cost-cache.json`, `notify.json` | caches | `dashboard_cost.py`, `shipfloor_notify.py` | the same |

Readers that parse what the scripts write, which a port must not break:
- `dashboard.py` reads the `== start`, `== end` and `== step-up` lines (and `hit your session limit`), `board.tsv`, `SKIPPED`, the locks' `info`, `step` and `inbox`, `stepup/`, `infra/`, `cost/`, `board-ids`, the health lines.
- `shipfloor_health.py` keeps its own copy of the stage table (queue column, resumed columns, WIP columns) that `dispatch.sh` encodes in its four `run_pipeline` calls: `refine` takes `Ready for Refinement`, resumes `Technical Refinement`, WIP `Spec Review`; `develop` takes `Ready for Dev`, resumes `Coding`, WIP `Coding` and `Validation`; `validate` takes `Validation`; `deploy` takes `Ready for Prod`. Change one, change the other.
- `dashboard_cost.py` finds a run's Claude Code transcripts in `<claude dir>/projects/*-projects-<slug>-control` (the directory name Claude derives from the control checkout, which is the run's cwd) and the card from the first user message, which holds `<command-name>/sf:<stage></command-name>` and `<command-args><n></command-args>`: that is how the `/sf:<stage> <n>` the launch writes on stdin appears in a transcript.
- The skills parse the first stdout line of `shipfloor dashboard`.

## Environment variables and test seams

**Set by `lib/project.sh` (`shipfloor_use`) and relied on by every script:** `SHIPFLOOR_HOME`, `FACTORY_PROJECT`, `FACTORY_REPO`, `FACTORY_MAIN`, `FACTORY_HOME`, `FACTORY_WT_ROOT`, `FACTORY_CONFIG`. `SHIPFLOOR_PY`, from `FACTORY_PYTHON`, is found once and handed to the scripts a script starts.

**Passed to every run by `dispatch.sh`:** `SHIPFLOOR_FACTORY=1`, `SHIPFLOOR_RUN_LOCK=<lock dir>` (how the run's scripts find their lock: `gate.sh` writes `last-gate`, `shipfloor-config.sh step` writes `step`, the hook reads `inbox`, `lib/stack.sh` records it in a lease), `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, `FACTORY_LANGUAGE=<project language>` (read once at launch: the run keeps it even if the owner changes it meanwhile; scripts prefer it over the config), `SHIPFLOOR_INFRA_RETRY=1` when `infra/<n>` exists. `FACTORY_BOARD_SNAPSHOT` is **removed** from the run's environment (`env -u`): an agent reads the live board. The stack slot's variables (`SHIPFLOOR_SLOT`, `SHIPFLOOR_STACK`, `SHIPFLOOR_STACK_URL`, `SHIPFLOOR_PORT_<NAME>`) are exported to a gate's runner, to `stack.up` and `stack.down`.

**Read as tunables:**

| Variable | Read by | Effect |
|---|---|---|
| `FACTORY_LANGUAGE` | `gate.sh`, `shipfloor_config.py` | pins the language of the run; wins over the machine's `overrides.yml` and the project's `factory.yml` |
| `FACTORY_MAIN` | `gate.sh`, `shipfloor` via `shipfloor_use` | the main branch's name (default `main`) |
| `FACTORY_QA_AMEND_MAX` | `gate.sh` | amendments of QA's tests allowed (default 2) |
| `SHIPFLOOR_GATE_FRESH` | `gate.sh` | `1` never reuses a recorded pass |
| `FACTORY_STACK_WAIT` | `lib/stack.sh` | seconds to wait for a stack slot |
| `FACTORY_LOCK_TTL` | `dispatch.sh` | seconds before a run's lock may be taken for dead (default 10800) |
| `FACTORY_CONTROL_REFRESH` | `dispatch.sh`, `shipfloor-dispatch.sh` | `0` leaves the control checkout alone |
| `FACTORY_CLEANUP` | `dispatch.sh` | `0` skips killing a run's leftover processes (Windows) |
| `SHIPFLOOR_MAX_PARALLEL` | `dispatch.sh` | overrides the machine `pool` |
| `SHIPFLOOR_CYCLE_STALE_MIN`, `SHIPFLOOR_STALE_LOCK_MIN`, `SHIPFLOOR_LOCK_RETRY_S` | `shipfloor-dispatch.sh` | minutes before a `dispatch.pid` or an `index.lock` is stale (30, 10); seconds between lock retries (5) |
| `FACTORY_POLL`, `FACTORY_POLLS` | `deploy.sh` | seconds between polls (default 30); with `FACTORY_POLL=0`, `FACTORY_POLLS` is the number of polls (default 60) |
| `SHIPFLOOR_NOW` | `shipfloor_config.py` | the clock (`HH:MM`) the working hours are judged by |
| `SHIPFLOOR_MACHINE_CONFIG` | `shipfloor_config.py` | the machine config file's path (set by `shipfloor_machine`) |
| `CLAUDE_CONFIG_DIR` | `dashboard.py`, `dashboard_cost.py`, `shipfloor_health.py` | Claude Code's directory (default `~/.claude`) |
| `SHIPFLOOR_BASH`, `SHIPFLOOR_SCHEDULER` | `dashboard.py` | the bash it uses to run scripts; the scheduler it asks |
| `SHIPFLOOR_NOTIFY_SEND` | `shipfloor_notify.py` | a script that sends a notification; it receives channel, title and body |
| `SNAPSHOT` | `setup-board.sh` | where the board's item-status snapshot goes |

**Test seams** (a test sets these to put a stand-in where the real thing would be): `FACTORY_GH` (the `gh` command: `board.sh`, `deploy.sh`, `dispatch.sh`), `FACTORY_CLAUDE` (`claude`, `dispatch.sh`), `FACTORY_BOARD` (the `board.sh` path: `dispatch.sh`, `deploy.sh`), `FACTORY_DEPLOY` (the `deploy.sh` path: `dispatch.sh`), `SHIPFLOOR_DISPATCH` (the `dispatch.sh` path: `shipfloor-dispatch.sh`), `FACTORY_CURL` (`curl`: `deploy.sh`), `FACTORY_POLL`, `SHIPFLOOR_NOW`, `FACTORY_PYTHON` (the python binary), `FACTORY_BOARD_SNAPSHOT` (a file standing in for the board), `FACTORY_CONTROL_REFRESH=0`, `SHIPFLOOR_HOME` and `FACTORY_CONFIG`. A script with a seam reads it with a default of the real thing; the seam is not a feature of production runs.

## The claude -p launch

`dispatch.sh` (`launch`) starts a run for a stage that is not `deploy` (and for the `deploy` stage only to resolve what `deploy.sh` hands over by exit 3). In this order:

1. The lock `locks/<stage>-<n>.lock` is made with `mkdir`; if it exists, nothing starts. `tmp/<n>` is created.
2. The prompt goes on **stdin**, never as an argument (Git Bash would turn `/develop 54` into a path): `printf '/sf:<stage> <n>'`.
3. The command, with `env -u FACTORY_BOARD_SNAPSHOT <envs>` before it, is `claude -p --permission-mode acceptEdits --add-dir <worktrees> --add-dir <home>/tmp --add-dir <home>/reviews --setting-sources project,local --strict-mcp-config --plugin-dir <plugin checkout>` then, when the directories exist, `--allowedTools Read(//<scripts dir>/**) Read(//<home>/reports-wt/**)`, then `--disallowedTools PowerShell`, then `--append-system-prompt "This is an unattended factory run. ..."`, and last `--model <model>` when the machine config names one for the stage and the card's weight.
4. cwd is the project's control checkout, `<home>/control`: a worktree of `origin/main`, never one an agent can edit. Output (stdout and stderr) is appended to the run's log.
5. The model is that of the stage and the card's weight (`light`, `standard`, `heavy`; `standard` when the spec has no weight). A develop run after a failed gate takes the model one up, from `stepup/<n>`.
6. After the run: `== end ...` is logged; for `develop` ending 0, a failed gate in `<lock>/last-gate` (`FAIL`, never `INFRA`) writes `stepup/<n>`, removes the label `blocked` and logs `== step-up ...`. The run's stack slots are released, `tmp/<n>` is removed and the lock goes (only when its `info` still names this process).

The skills and agents parse nothing of this; the dashboard parses the `== ` lines and the transcripts.

## Security invariants

- Configuration comes from the snapshot of the committed config of `origin/main` (`<home>/factory.yml`, taken from the control checkout), never from a worktree: a card's PR cannot change the gates that judge it. `.shipfloor/` is a forbidden path for agents.
- Fail closed: a bad revision (`require_rev`), a failed config query, a layer with an unknown name or an invalid `grep -E` pattern in the config is exit 2, never a pass. `board.sh eligible` and `first` return 1 on any failed lookup rather than an empty list. `shipfloor-dispatch.sh` skips a project whose config is invalid.
- The selector is an argument, never code: `"$1"` of `bash -c`.
- Only the factory's own user's `staged-head:` counts for approval; the comments an agent reads through `board.sh issue` are those of that user and of `trusted_commenters`; the others are counted, not shown.
- Names with control characters in the changed files make `forbidden` and `scope` fail rather than slip past the line-based checks.
- Acceptance tests cannot be changed after QA's commit, except as `gate.sh acceptance-intact` allows: what merges from main brought, a hand merge that keeps both sides, a change that moves no assertion line, or an edit the owner took with `shipfloor accept`.
- Only the owner moves cards to `Ready for Refinement`, `Ready for Dev`, `Ready for Prod`, or out of `Spec Review` and `Staged` (`board.sh move` exit 3).
- A fork's PR is never deployed. `deploy.sh` merges with `--match-head-commit`.
- A run reads, and never writes, the factory's scripts and the reports' worktree (`--allowedTools Read(...)`); it does not load the owner's own plugins, MCP servers or memory.
- PII never goes to a log or a report.

## Known quirks kept on purpose

- `shipfloor` prints its usage from lines 2 to 10 of its own header, so the `dashboard` line is not part of what a bad command prints. Kept: a card (not this document) changes it.
- `board.sh`'s printed usage lacks `eligible` and `snapshot`, and `gate.sh`'s usage lacks `fast` and `acceptance-own`: these are used by other scripts, not by people.
- `gate.sh stack` and `acceptance-own` print no verdict line: `stack up` prints a URL on stdout that callers read, and `acceptance-own` prints a key.
- The gate's verdict line is not translated though the rest of its stderr is, and the `== start` family and the markers have no translation: other code matches them.
- `dispatch.sh`'s `refresh_control` fetches the literal `main`, while `shipfloor-dispatch.sh`'s uses the project's `main`. Normally `shipfloor-dispatch.sh` has already refreshed it (`FACTORY_CONTROL_REFRESH=0`), so the difference only shows when `dispatch.sh` runs alone. Recorded as found; a card decides which is right.
- `deploy.sh` commits and merges with a fixed `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` trailer.
- `board.sh status` of a card missing from the board is an empty line with exit 0; `move` of it is exit 1.
- `shipfloor weight` exits 3 both for "no longer in Spec Review" and for "a run is working on it": both mean try again later or give up, the message tells which.
- `deploy.sh --refresh` exits 0 for nearly every case (not Staged, no single PR, head not approved, conflicts): a refresh never fails the dispatcher's cycle; only a deploy does.
- A dead lock is taken over by age and pid together: a lock older than the TTL whose pid is alive is kept.
- The dashboard's run lines also accept the legacy prefixes `aghanim` and `mylos`; the scripts write only `sf`.
