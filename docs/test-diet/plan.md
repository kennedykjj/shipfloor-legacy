# Test diet, pass 2: measurement and plan

Step A of pass 2: measure, cut nothing. The per-file data is in [`coverage-by-file.tsv`](coverage-by-file.tsv).
Branch `chore/test-diet-2`, based on pass 1 (#230).

## How this was measured

- **Python line coverage per test file.** Every Python process a test starts (`bash scripts/x.sh` → `python3 -I sf.py …`,
  `dashboard.py` servers, heredoc `python3 -`, installed copies under `$FACTORY_HOME/factory/`, `plugin_copy` copies)
  ran under coverage.py 7.16. The hook is a `.pth` file in a venv's site-packages, which still loads under `-I`. That venv was first on `PATH` as
  `python3`/`FACTORY_PYTHON`, with `COVERAGE_PROCESS_START`, a data file per test file, `sigterm = True` (the tests
  stop servers with `kill`), and `[paths]` that map copies back to `scripts/`. One wrapper call was checked by hand
  first: it recorded `sf.py`, `shipfloor_core/board.py` and `project.py`.
- **Product statements**: every `scripts/*.py` and `scripts/shipfloor_core/**/*.py`, **8,519 statements**. The Bash
  scripts are wrappers (231 lines in all) and were not measured. Neither was `dashboard.html`'s JS/CSS (see Caveats).
- **Seconds and asserts** come from the real `run.sh` (8 jobs, 16 CPUs): `== file (Ns)` and the count of `  ok` lines.
  The run was all green: 162 files, 5,780 ok, 0 FAIL, 134 s wall.
- **Unique lines**: product lines that this file covers and no other file covers. **subset_of**: the files that cover at least 95% of
  this file's lines.
- **Source-grep asserts (estimate)**: a file that runs no product Python and reads `dashboard.html`, `lang/*.json`, docs
  or scripts as text counts all of its oks. For any other file, the count is its oks × (assertion sites that read
  source text ÷ all assertion sites). A static scan found those sites: `grep`/`sed`/`cat` on product files,
  `page_english`, `en_msg`, `ptb`-style helpers, and heredoc checkers fed `dashboard.html`. Treat it as ±20%.

## Headline numbers

| | now |
|---|---|
| test files | 162 (18,290 lines) |
| `ok` assertions | 5,780 |
| serial seconds (sum of per-file) | 873 s (local 8 jobs: 134 s wall; CI: 3 shards × 4 jobs ≈ 4 min) |
| Python statements covered by the whole suite | 7,624 / 8,519 = **89.5%** |
| files that cover **no** product Python | 19 (15 of them pure source-grep) |
| files with **0 unique lines** | 63 |
| files with **≤ 5 unique lines** | 126 |
| source-grep asserts (est.) | ~580 (10%), 504 of them in dashboard*/theme/design-doc |
| files a greedy set cover needs for 100% of today's covered lines | 89 (20 files → 90%, 40 → 97%, 60 → 99%) |

Where the time goes: 9 files take 284 s serial (33%) and add 11 unique lines between them.

| file | s | oks | unique lines | why it is slow |
|---|---|---|---|---|
| deploy-local-ci | 66 | 20 | 2 | waits on a real local_ci timeout |
| stack-queue | 40 | 9 | 0 | real waits on the slot queue |
| shipfloor-dispatch | 34 | 41 | 3 | real cycles; the same lines as shipfloor-dispatch-cycle |
| dashboard-names | 28 | 8 | 0 (no Python) | a regex checker over dashboard.html, 8 static checks |
| gate-stack | 27 | 23 | 2 | real stack slots |
| shipfloor-dispatch-cycle | 26 | 62 | 4 | real cycles |
| gate-stack-deadline | 26 | 13 | 0 | real clock deadlines |
| gate-stack-solo | 20 | 25 | 0 | real stack slots |
| stack-py-heartbeat | 17 | 11 | 0 | real heartbeat child |

## Per module: now

| module | files | s | oks | unique lines | files with 0 unique lines | files with ≤5 unique lines | source-grep oks |
|---|---|---|---|---|---|---|---|
| gate | 34 | 174 | 1,021 | 45 | 24 | 33 | 4 |
| dispatch | 28 | 159 | 596 | 36 | 18 | 25 | 0 |
| deploy | 17 | 145 | 761 | 114 | 4 | 11 | 0 |
| dashboard (+theme, design-doc, demo-stack) | 32 | 98 | 1,596 | 450 | 17 | 22 | 504 |
| stack | 8 | 96 | 178 | 40 | 4 | 5 | 0 |
| cycle | 5 | 78 | 146 | 7 | 3 | 5 | 0 |
| cli / install / core | 14 | 53 | 546 | 216 | 6 | 9 | 3 |
| board | 5 | 25 | 147 | 82 | 2 | 4 | 0 |
| health / notify | 5 | 23 | 186 | 45 | 0 | 3 | 11 |
| config | 5 | 14 | 292 | 24 | 1 | 3 | 0 |
| report / metrics / review-page | 5 | 4 | 193 | 89 | 0 | 2 | 6 |
| meta (hygiene, contracts-doc, run-changed, lib-wait) | 4 | 4 | 116 | 3 | 3 | 4 | 52 |

Gate and dispatch are the clearest case. 62 files, 333 s, 81 unique lines between them. Each file drives the same `sf.py`
path through Bash to pin one more input.

## Top deletion and merge candidates

**Delete: source-grep only, no product Python run** (≈ 443 oks, ≈ 35 s, 0 unique lines):
`design-doc` (90 oks), `theme` (71, but keep its computed contrast check, see dashboard), `contracts-doc` (46),
`dashboard-empty` (45), `dashboard-short` (37), `dashboard-first-screen` (37), `dashboard-touch` (23),
`dashboard-glance` (21), `dashboard-take-back-page` (20), `dashboard-narrow` (15), `dashboard-targets` (10),
`dashboard-icon` (8), `dashboard-page` (8), `dashboard-names` (8 oks for 28 s), `dashboard-accent` (4).
Also drop the source-grep parts of `dashboard` (≈49), `dashboard-weight` (12), `dashboard-order` (11),
`dashboard-block-line` (11), `notify-settings` (11), `dashboard-move` (10).

**Merge: covered by others, near-zero unique lines, slow:**

| cluster | files | s | unique lines | covered by |
|---|---|---|---|---|
| cycle CLI | shipfloor-dispatch, shipfloor-dispatch-cycle, run-dispatcher, cycle-port | 78 | 7 | each other (1.00) |
| stack-backed gate | gate-stack, -deadline, -solo, -lang, -verdict, gate-py-stack-fifo, stack-signal, stack-queue, stack-py-heartbeat | 140 | 2 | gate-stack / stack-pin-queue (0.96–1.00) |
| dispatch launch | dispatch-launch, -launch-argv, -launch-flags, -weight, -models, -stepup, -tmpdir | 37 | 2 | dispatch-lang-files / dispatch-process (0.96–1.00) |
| dispatch core | dispatch, -parallel, -pool, -project, -policies, -home-space, -control-missing, -refresh-main, -review, -wrapper, -pycache, -block-repo | 56 | 2 | dispatch-process / dispatch-cost-cleanup (0.95–1.00) |
| gate static | gate-scope, -migration, -migration-order, -test-plan, -py-changes, -py-qa-migration, -pin-static, -py-plan-weight, -weight | 43 | 6 | gate-pin-static / gate-review (0.95–1.00) |
| gate cache | gate-pin-cache, -py-pass-cache, -py-cache-key, -reuse, -retry | 15 | 5 | each other (1.00) |
| deploy merge | deploy-conflict, -conflict-automerge, -flow, -flow-retry | 7 | 0 | deploy-continue-checks / deploy-other (0.97–1.00) |
| dashboard server | dashboard-quick, -move, -order, -take-back, -link, -titles | 34 | 91 | each other (0.99–1.00); merge, don't drop: the unique lines are endpoint branches |

## Target layout per module

The model for every module:

1. **One in-process suite.** It imports `shipfloor_core` (or `dashboard`, `shipfloor_config`, …) and calls functions
   with test doubles: a fake `gh`/runner callable, a fake clock (`SHIPFLOOR_NOW` already exists), and tmp dirs. These suites
   would be Python `unittest` modules under `scripts/test/py/`, all run by one `python3 -I -m unittest` call in a single
   `py.test.sh` file. `py-board-unit` already works this way, but with a subprocess per module.
2. **A thin CLI contract layer.** One bash file per wrapper family that pins exit codes, stderr verdict lines and
   stdout shape. It holds a handful of cases per command, not one per input.
3. **Real-process tests only where the process model is the behavior.** That covers signals, locks between processes,
   detached heartbeats and the server lifecycle. Each keeps one scenario per behavior, with waits shortened through the
   existing settings, not real minutes.

| module | target suite (files) | moves in-process | stays as CLI / real process | deleted | files | oks | s (serial) |
|---|---|---|---|---|---|---|---|
| gate | `py/test_gate_spec.py` (test-plan, weight), `py/test_gate_diff.py` (scope, forbidden, qa-commit/amend, migration, migration-order, acceptance-intact on a fixture repo built once), `py/test_gate_run.py` (build/red/green/retry/install/layers, fake runner), `py/test_gate_cache.py` (pass key/record/reuse/prune, cache key); `gate-cli.test.sh`; `gate-stack.test.sh` | every gate's decision table (today one Bash call per input) | `gate-cli`: exit 0/1/2/3, final verdict line, `last-gate`, language, `-C`, ANSI stripping (replaces gate-pin-verdict, gate-py-verdict, gate-py-exit, gate-py-language, gate-color, gate-dir). `gate-stack`: one slot per run, FIFO, a signal frees the slot, verdict last (fake clock for deadlines) | gate-review/-hardening regressions fold into the suites above; duplicate en/pt-BR verdict copies | 34 → 6 | 1,021 → ~350 | 174 → ~25 |
| stack | `py/test_stack_lease.py` (lease, queue order, stuck-lease reclaim, portable stat), `py/test_stack_up.py` (up/down/health/heartbeat with fake compose + clock); `stack-cli.test.sh` | lease/queue/slot logic (stack-pin-*, stack-py-*, portable-tools, stack-queue's date-format case) | `stack-cli`: the lib/stack.sh shim, one queue arrival-order run, the heartbeat outliving its parent | stack-queue's 40 s real waits | 8 → 3 | 178 → ~90 | 96 → ~12 |
| dispatch | `py/test_dispatch_select.py` (order, parallel, pool, project limits, policies, working hours), `py/test_dispatch_launch.py` (argv, flags, prompt, tmpdir, models/weight/step-up, language), `py/test_dispatch_cost.py` (block, day stop, cleanup order); `dispatch-process.test.sh` (trimmed); `dispatch-cli.test.sh` | selection, launch arguments and cost decisions, with a fake launcher and a fake board | `dispatch-process`: the lock, exit codes, SIGHUP, orphan resume (real processes). `dispatch-cli`: dispatch.sh = `sf.py dispatch`, missing lib, pycache, home with a space | ~20 one-scenario files (see the merge clusters) | 28 → 5 | 596 → ~300 | 159 → ~30 |
| cycle | `py/test_cycle.py` (usage limit, per-project loop, validation); `cycle-cli.test.sh` (shipfloor-dispatch.sh + run-dispatcher.sh) | cycle.py decisions | one real cycle over two projects; run-dispatcher's entry contract | shipfloor-dispatch-cycle / run-dispatcher / cycle-port duplicates | 5 → 2 | 146 → ~60 | 78 → ~10 |
| deploy | `py/test_deploy_approval.py` (approval, checks, limits), `py/test_deploy_merge.py` (conflict, automerge, merge-fail, continue-checks), `py/test_deploy_fix.py` (fix, fix rounds), `py/test_deploy_ci.py` (push/CI wait, local_ci, production, flow-retry, refresh, start/lock); `deploy-cli.test.sh` | everything behind the fake gh (today: deploy.sh + fake-gh-deploy per case) | `deploy-cli`: one happy path to Done, one blocked, the lock, `--continue`/`--refresh` exit codes | local_ci's real timeout (use a 1 s limit) | 17 → 5 | 761 → ~400 | 145 → ~30 |
| board | `py/test_board.py` (py-board-unit's modules + board-review + setup-board); `board-cli.test.sh` (board.sh/setup-board.sh contract, GraphQL budget) | board/setup logic | the wrapper contract and budget | board-budget / board as separate files | 5 → 2 | 147 → ~110 | 25 → ~6 |
| cli / install / core | `py/test_cli.py` (registry, add/remove, doctor, clean/tmp-sweep, weight, pool), `py/test_project.py` (py-project, project-resolve, finish-migration, transition, text helpers), `install.test.sh` (atomic + source + py-install: real file ops), `install-dispatcher.test.sh` (Bash installer, stays), `wrappers.test.sh` (py-wrapper, lib/py.sh, sf-broken-pipe, inbox-hook) | shipfloor-cli's 156 oks (29 s) become calls to cli.py | install and wrappers stay process-level by nature | py-unit (2 oks) folds into test_project | 14 → 5 | 546 → ~350 | 53 → ~15 |
| config | `py/test_config.py` (config, machine, models, config-machine); `config-cli.test.sh` (shipfloor-config.sh get/validate/step/machine) | shipfloor_config validation and queries | the query contract | — | 5 → 2 | 292 → ~180 | 14 → ~4 |
| health / notify | `py/test_notify.py` (channels, quiet hours, cycle message, settings model), `py/test_health.py` | all of it | one `sf.py` call each, inside the test files above | notify-settings' page greps | 5 → 2 | 186 → ~120 | 23 → ~5 |
| report / review | `py/test_report.py` (report, metrics, port-reports), `review-page.test.sh` (review-page + review-diff: they render real HTML output, keep) | report/metrics | review-page output checks | report's 6 source greps | 5 → 2 | 193 → ~150 | 4 → ~3 |
| dashboard | `py/test_dashboard_cards.py` (move, order, take-back, weight, quick approve, marks, titles: handlers called in-process with a fake gh), `py/test_dashboard_settings.py` (models, language, dispatcher, notify, machine), `py/test_dashboard_cost.py` (dashboard_cost, history, feed); `dashboard-server.test.sh` (one real server: start, port, link survives restart, bash pick, inbox hook); `dashboard-catalog.test.sh` (catalog consistency: keys, plurals, markup; takes the names/pt-BR key checks); `dashboard-theme.test.sh` (only the computed contrast/token-set check); `demo-stack.test.sh` | every API behavior now tested over HTTP per file | one server smoke, catalog integrity, theme contrast | 15 source-grep files (list above) + source-grep blocks in mixed files | 32 → 7 | 1,596 → ~600 | 98 → ~20 |
| meta | `hygiene.test.sh` (+ contracts-doc reduced to "every script has a section"), `test-infra.test.sh` (run-changed + lib-wait) | — | both | contracts-doc's per-subcommand greps | 4 → 2 | 116 → ~40 | 4 → ~3 |
| **total** | | | | | **162 → ~43 bash + py modules** | **5,780 → ~2,750** | **873 → ~165** |

On file count: in this table one Python module counts as one file. If a module goes past ~400 lines, split it by
area (e.g. `test_deploy_ci.py` into push/production), which lands at **~55–65 files**, inside the 60–80 aim.

**CI estimate.** About 165 s serial. The slowest files left are dispatch-process, gate-stack and dashboard-server at
~10 s each. Over 3 shards × 4 jobs that comes to ~25 s of test wall time per shard, so **< 1.5 min per job** with
checkout and setup. Two shards would likely do.

**Coverage target for the cut.** Keep today's 7,624 covered statements, minus at most ~1% (tracked lines that only a
deleted duplicate reaches). Re-run this measurement after each module lands. The scripts are under "Reproduce".

## Uncovered code (no test runs it)

895 statements (10.5%). By file, with the functions that hold the most:

| file | statements | uncovered | covered % | where |
|---|---|---|---|---|
| shipfloor_core/cli.py | 826 | 114 | 86% | cmd_weight 14, cmd_doctor 9, cmd_add 9, cmd_pool 9, _put_text 6, cmd_install 6 |
| dashboard.py | 1,353 | 110 | 92% | do_POST 12 (error branches), pull 10, take_back 9, scheduler 7, set_machine 7, owner_move 4 |
| shipfloor_core/deploy.py | 799 | 86 | 89% | _bounded 19 (the timeout wrapper), run 10, approve 5, _run 4, check_fix 4, take_lock 3 |
| shipfloor_core/dispatch.py | 730 | 79 | 89% | _run 7, run 7, _python 6, supervise 6, _posix 5, run_pipeline 5 |
| shipfloor_config.py | 748 | 56 | 93% | problems 20 (validation messages), main 6, machine_problems 5 |
| shipfloor_core/cycle.py | 323 | 54 | 83% | _found_younger 9, _alive 6, take 5, _record 4, _cycle 4 |
| shipfloor_core/stack.py | 555 | 54 | 90% | _guarded 10, read_settings 4, queue_ticket 4, lease 4 |
| shipfloor_core/board.py | 410 | 47 | 89% | board_ids 14, rest_rows 8, issue 5, main 5 |
| shipfloor_core/gate/run.py | 406 | 44 | 89% | pass_record 11 (pruning), _stamped 7, ensure_deps 4, pass_key 4 |
| shipfloor_core/project.py | 340 | 44 | 87% | main 20, snapshot 9, config_path 5 |
| shipfloor_health.py | 133 | 25 | 81% | mem_free_mb 8, cpu_percent 7 (per-platform probes), alerts 4 |
| dashboard_cost.py | 255 | 24 | 91% | cli 6, load_prices 3, save 3, read_costs 3 |
| shipfloor_core/gate/spec.py | 160 | 24 | 85% | _percent_b 15 (percent-decoding), _read_tabs 4, test_plan 4 |
| shipfloor_core/setup.py | 102 | 24 | 76% | main 24 |
| shipfloor_notify.py | 203 | 21 | 90% | send 15 (real delivery), last_health 3 |
| shipfloor_core/proc.py | 58 | 18 | 69% | alive 9, native_path 4, uname_s 3 (Windows/MSYS branches) |
| shipfloor_core/fs.py | 29 | 9 | 69% | write_atomic 6 (fallback path), lock_dir 2 |
| others | | 62 | | gate/acceptance 10, gate/migration 10, report 10, text.grep_lines 9, review_page 6, sf.py 6, … |

Reading them:
- **Real gaps worth a test when the in-process suites land:** `deploy._bounded` (timeouts), `cli.cmd_weight`, `cmd_doctor`,
  `cmd_add`, `cmd_pool`, `dashboard.do_POST`'s refusals and `take_back`/`pull` failures, `shipfloor_config.problems` (20
  validation messages nobody sees fail), `cycle._found_younger`, `board.board_ids`/`rest_rows`, `gate/run.pass_record`
  pruning, `gate/spec._percent_b`, `setup.main`.
- **Platform branches** (`proc.native_path`/`uname_s`, `health.cpu_percent`/`mem_free_mb`, `dispatch._posix`,
  `fs.write_atomic`'s fallback): this Linux run cannot reach them. They are cheap in-process with a patched `os.name`/`platform`.
- **Real side effects** (`notify.send`): leave uncovered, or test with a fake transport.

## Caveats

- **Line coverage is not behavior.** "0 unique lines" means another file runs the same lines. It does not mean nobody else checks this input or output.
  Many gate/dispatch/deploy pins assert a different exit code or message on shared lines. Before each deletion, carry over its distinct assertions into the
  module's table-driven suite. Never drop them blind. Branch coverage was off.
- **Not measured:** the Bash wrappers (231 lines, thin) and `dashboard.html`'s JS/CSS (2,558 lines). The dashboard's
  real UI behavior is tested only by the static checks this plan deletes (and a `node` run of `t()` in
  dashboard-catalog). If page behavior matters, add a small node/playwright smoke in `dashboard-server`, not more greps.
- **Lost coverage on SIGKILL:** coverage is saved on exit and on SIGTERM. A process killed with `-9` (one dashboard
  test) or a detached child still running at the end loses its lines, so those numbers are a lower bound.
- **Timing** is local (16 CPUs, `run.sh` with 8 jobs, integer seconds). CI's 4-vCPU shards are slower, but the order of the slow files holds.
  My first driver wrapped each file in `timeout`, which broke one SIGHUP assertion (dispatch-process). The coverage run
  kept that driver, so the SIGHUP path may be slightly under-counted. The `run.sh` timing run was 162/162 green.
- **Source-grep counts** come from a heuristic (±20%). Files with no product Python are exact.

## Reproduce

Coverage venv (coverage 7.x + PyYAML) with a `zz_cov_startup.pth` in site-packages:
`import os; exec("try:\n import coverage; coverage.process_startup()\nexcept Exception: pass") if os.environ.get("COVERAGE_PROCESS_START") else None`.
The rc file:

```
[run]
parallel = True
sigterm = True
include = */scripts/*.py
    */scripts/shipfloor_core/*
    */factory/*.py
    */factory/shipfloor_core/*
omit = */scripts/test/*
[paths]
source =
    <worktree>/scripts/
    */scripts/
    */factory/
```

Run each `*.test.sh` with the venv's `bin` first on `PATH`, `COVERAGE_PROCESS_START=<rc>` and
`COVERAGE_FILE=<dir per test>/.coverage`, and build `DEPLOY_BASE` once as `run.sh` does. Then `coverage combine` per directory
and diff the line sets.
