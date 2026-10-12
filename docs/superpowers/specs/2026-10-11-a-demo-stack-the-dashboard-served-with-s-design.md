# A demo stack: the dashboard served with sample data, so ui cards get a screen check — spec

**Issue:** #72 · **Branch:** `feat/72-a-demo-stack-the-dashboard-served-with-s` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** The dashboard page has no automated test and this repository has no `stack`, so a `ui` card that changes the page reaches Staged without the UX screen check: the dashboard needs a factory home to show anything and its URL carries a random token.
**Audience:** The factory's owner, who approves Staged cards that change the dashboard and adds the `stack:` block once this ships.
**Acceptance criteria**
- **AC-1** — Given a free port and a chosen token, when the demo is started with one command, then the command returns, `GET /` on 127.0.0.1 at that port answers 200, and `GET /api/overview` with that token answers 200 with two projects and cards in at least six columns.
- **AC-2** — Given the demo is stopped and started again with the same port and token, when the same URL is requested, then it answers 200 again.
- **AC-3** — Given the demo is running, when the page is opened at its URL with the token, then the Factory view shows a card waiting in Spec Review and one in Staged, a running card with live steps, a card blocked for the owner and one blocked by infrastructure, and Feed and Settings show data.
- **AC-4** — Given the demo is running, when its data is read, then today's runs include one that ended clean and one that failed, every card has an estimated cost, and one session of an unpriced model shows the unpriced marker instead of a zero.
- **AC-5** — Given the demo is running with no network and no real `gh` on the path, when the page loads and a Spec Review card is approved in it, then titles and labels still show, the card changes column in the sample board, and no file under the real `~/.shipfloor` is created or changed.
- **AC-6** — Given two demos started with different stack names and ports, when one is stopped, then the other still answers 200 with its own data.
- **AC-7** — Given a running demo, when it is stopped with one command, then its port no longer answers, its process is gone and every file the start created is removed.
- **AC-8** — Given `shipfloor dashboard` is started without a token, when it prints its URL twice in two starts, then each carries a random token and the two differ.
**Out of scope:** The `stack:` block in `.shipfloor/factory.yml` (the owner adds it afterwards); tests of the page's JavaScript; any change to what the dashboard page shows or how it looks; installing the demo with the factory (`~/.shipfloor/factory`) or offering it as a `shipfloor` command to other projects; pause and settings actions beyond working against the sample (not separately verified).
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): a `ui` card's screen check runs against a real page instead of being skipped. Keeps principle 1 (the sample board is the demo's only card state; the page keeps none) and the local-only constraint (127.0.0.1). The sample data is a test fixture that never leaves the repository's tests, so it does not contradict "no evidence may be invented"; a chosen token is opt-in and the random token stays the default, so the real dashboard's access is unchanged.
**Touches UI:** no

## UX
_UX/UI Designer_

No screen, component, token or string is added or changed, so there is no copy and no layout work. AC-3 and AC-4 are not enough for a screen check, though: they leave the empty states, the card panel and the project switch unseen. The sample must put these states on screen, all of them ones `scripts/dashboard.html` already renders:

- **Two projects, opposite states.** Project A is the full one (every item below unless B is named) and raises no alert, so the alerts line is seen absent. Project B is the quiet one: nothing waiting for the owner, nothing in progress, no run ended today, the project paused and its board snapshot older than 5 minutes. Switching to B shows the three empty messages ("Nothing waits for you…", "Nothing is in progress.", "No run has ended today.") and the warn flags "<B> paused" and "Board N min old". The header shows the Project select.
- **Factory, lifecycle line and Yours (A).** Cards in at least six columns, Done included. Waiting for the owner: two in Spec Review (one with a review page of three or more items to mark, one without, for "This card has no review page yet."), one in Staged with a validation report and a PR, and the owner-blocked card with a block note that has both the reason and "What the factory already tried".
- **In progress (A).** Two running cards in different stages: one with a reported step, a "says" line and three or more actions; one with no step yet ("No step reported yet"). One waiting card under "Waiting", and the infrastructure-blocked card.
- **Today (A).** One hour holding both a clean and a failed run (the stacked, hatched bar) and one more hour with spend; `typical_s` for all four stages, so "A stage usually takes" and the "Usually takes N minutes" hints show.
- **Card panel (A).** One card past Coding with four or more sessions over two or more stages, a subagent sub-row, the unpriced session (`$ ?`, AC-4), a passed and a failed gate, a stage with no gates, two or more log files and a last report. The Spec Review card opens on Review with the decision; the running card opens maximized on Live.
- **Feed.** Dispatcher lines, one stack line, and run rows in the three outcomes: ok, `exit N`, running. Each run's log has more than 12 lines, so the row opened in place is cut and "Whole log" has more to show.
- **Settings.** Both projects under Projects, each with two or more layers (one `tests only`), a context list and a stack URL; A has one limit that differs from its repository ("the repository says N"); B's Paused switch is on. The stage limits add up to less than the pool, so the Sessions note reads its "never used" form. Costs lists the price table without the unpriced model.
- **Text that stresses the layout.** One card title of about 90 characters in A (the clamp on tiles and the drawer head), one issue number of four digits, one cost of $10 or more next to ones under $1.
- **Small screen.** Nothing to build; the amounts above are what make the existing rules at 1180px, 860px and 600px visible (the lanes scroll, Settings folds to one column, the drawer takes the full width). Validation of later cards checks 390px and 1440px.
- **Stable between starts.** Same cards, numbers, titles, costs and order on every start; every time is set relative to the start, so runs stay "today", the running clocks start near the same value and B's board stays stale. Sample titles and logs are written in English and the sample home sets `language: en`, so the screen matches the copy that later specs quote.
- **Left out on purpose.** Offline, "Not updating", "Factory paused", "Usage limit hit", a skipped project, a stuck stack and an orphaned lock: each paints a page-wide alert over both projects and would hide the normal state. A later card that touches one of them adds it to the sample.

## Architecture
_Tech Lead_

One layer, `factory`. No migration, no new endpoint, no change to `scripts/dashboard.html`.

**Contracts**
- `scripts/dashboard.py` (changed): new option `--token <text>`. Given and not empty, it is the token; otherwise `secrets.token_urlsafe(16)` as today. `shipfloor dashboard` already passes its arguments through, so `scripts/shipfloor` changes only its usage comment (`dashboard [--port N] [--no-open] [--token T]`).
- `scripts/test/demo-stack.sh` (new): `demo-stack.sh up` and `demo-stack.sh down`. It reads three variables and nothing else from the caller's factory:
  - `SHIPFLOOR_STACK`: the stack's name (default `shipfloor-demo`); names the state folder.
  - `SHIPFLOOR_PORT_WEB`: the port (default `7727`).
  - `SHIPFLOOR_DEMO_TOKEN`: the token (default `demo`).
  - `up` prints `http://127.0.0.1:<port>/?t=<token>` and exits 0 once `GET /` answers; exits 1, with the server's log on stderr and nothing left behind, when the server does not answer in 30 seconds or did not get the port asked for (`dashboard.py` moves to the next port when one is taken; the demo's URL must be the known one).
  - `down` stops the server, waits until its process is gone, removes the state folder; exits 0 when there is nothing to stop.
- `scripts/test/demo_home.py` (new): `demo_home.py <state folder>` writes the sample: the factory home, the Claude transcripts folder and the `gh` stand-in's data. Same content on every call; every time is counted from the call.
- `scripts/test/demo-gh` (new): the `gh` stand-in the server gets as `FACTORY_GH`. It answers the calls `dashboard.py` and `board.sh` make (`project view`, `project field-list`, `project item-list` / `api graphql`, `project item-edit`, `issue list`, `issue comment`, `api repos/<repo>/issues?labels=`, `api repos/<repo>/issues/<n>/comments`, `api -X DELETE .../labels/<label>`, `pr view` / `pr list` as `Factory.pull` asks) for both sample repositories, from files in the state folder. It keeps state: `item-edit` moves the card in the sample board, `issue comment` is appended, a removed label stays removed. An unknown call exits non-zero with its arguments on stderr.
- `README.md` (changed): `--token` in the dashboard paragraph and two lines on the demo under Operation.

**State folder:** `${TMPDIR:-/tmp}/shipfloor-demo/<SHIPFLOOR_STACK>/` holds `home/`, `claude/`, `gh/`, `server.log` and `pid`. `up` first runs `down` for the same name, so a start after a crash is clean. Two names never share a file.

**The server's environment** (set by `up`, whatever the caller had): `SHIPFLOOR_HOME=<state>/home`, `CLAUDE_CONFIG_DIR=<state>/claude`, `FACTORY_GH=<worktree>/scripts/test/demo-gh` with its data folder, `SHIPFLOOR_BASH`, `SHIPFLOOR_SCHEDULER` pointing at a stub that records the minutes in the state folder, and every other inherited `FACTORY_*` and `SHIPFLOOR_*` unset. The server is `scripts/dashboard.py` of the same checkout as the script, started with `--home <state>/home --port <port> --token <token> --no-open`.

**Start and stop on every platform**
- The server's stdin, stdout and stderr go to `/dev/null` and `<state>/server.log`: `stack_up` runs `up` with its output in the slot's `up.log`, and on Windows a server that held that file would keep the slot's lock folder from being removed.
- `pid` holds the pid the operating system knows (in Git Bash the Windows pid from `/proc/<pid>/winpid`, stopped with `taskkill`): a later shell does not know the first shell's msys pid.

**The sample** (`demo_home.py`), following the UX section's list:
- `registry.tsv` with two projects, each with `factory.yml` (two layers, one `tests_only`; a `stack.url`; a context list), `board.tsv`, `logs/`, `locks/`, `reviews/`, `reports` as `Factory.reports` reads them.
- Project A: cards in at least six columns (Done included), two in Spec Review (one with `reviews/<n>.html`), one in Staged, two run locks (`<stage>-<n>.lock/info`, one with `step`) whose logs have a `== start` and no `== end`, today's logs with one clean and one failed run in the same hour, one `overrides.yml` knob, labels `blocked` on one card and `blocked:infra` on another.
- Project B: a `PAUSE` file, a `board.tsv` older than 5 minutes that the stand-in refuses to refresh (the board read fails for B, so the old snapshot keeps serving), no lock, no run today.
- Home: `config.yml` (`language: en`, stage slots that add up to less than the pool), `logs/dispatcher.log` with dispatcher and stack lines, one `logs/health-<day>.jsonl`.
- Transcripts under `<state>/claude/projects/*-projects-<project>-control/`: sessions over two stages with a subagent, costs under $1 and over $10 from the shipped `templates/prices.yml`, and one session of a model that table does not price.

**Files**

| File | Change | Layer |
|---|---|---|
| `scripts/dashboard.py` | `--token` | factory |
| `scripts/shipfloor` | usage comment | factory |
| `scripts/test/demo-stack.sh` | new | factory |
| `scripts/test/demo_home.py` | new | factory |
| `scripts/test/demo-gh` | new | factory |
| `scripts/test/demo-stack.test.sh` | new (QA) | factory |
| `README.md` | two lines | factory |

**After this ships (the owner, by hand):** `.shipfloor/factory.yml` gets

```yaml
stack:
  up: bash scripts/test/demo-stack.sh up
  down: bash scripts/test/demo-stack.sh down
  ports: [web]
  url: http://127.0.0.1:{web}/?t=demo
  health: http://127.0.0.1:{web}/
```

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/demo-stack.test.sh` |
| AC-2 | factory | `scripts/test/demo-stack.test.sh` |
| AC-3 | factory | `scripts/test/demo-stack.test.sh` |
| AC-4 | factory | `scripts/test/demo-stack.test.sh` |
| AC-5 | factory | `scripts/test/demo-stack.test.sh` |
| AC-6 | factory | `scripts/test/demo-stack.test.sh` |
| AC-7 | factory | `scripts/test/demo-stack.test.sh` |
| AC-8 | factory | `scripts/test/demo-stack.test.sh` |

How each is checked, all with `curl` against the running demo on ports the test asks the system for:
- AC-1, AC-2: `up` exits 0; `GET /` and `GET /api/overview` (token in the header) answer 200; two projects, six or more distinct columns; `down`, `up` again, same URL answers.
- AC-3: the page cannot be opened by this layer's runner, so the test reads what each view reads: `/api/overview` has cards in Spec Review and Staged with `awaiting`, a run with a `step`, one card `blocked: owner` and one `blocked: infra`; `/api/feed` has dispatcher lines and runs; `/api/settings` has both projects.
- AC-4: `/api/overview` `today` has `ok` ≥ 1 and `failed` ≥ 1 and every card of project A a cost; `/api/card/<A>/<n>` of the unpriced card has a session with `cost: null`.
- AC-5: the test starts the demo with `HOME` and `SHIPFLOOR_HOME` pointing at empty folders and `FACTORY_GH` at a script that fails; approve, pause and a settings change answer 200; the card is in Ready for Dev on the next overview; both folders are still empty.
- AC-6, AC-7: two names and ports; after `down` of one, its port refuses, its pid is gone, its state folder does not exist, and the other answers 200 with its own state folder intact.
- AC-8: `dashboard.py` started twice without `--token` prints two different tokens of 16 or more characters; with `--token x` it prints `?t=x`.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- **Touches UI: no, UX still called.** The issue has the `ui` label; UX wrote which states the sample must show, not a screen.
- **The UX list is the sample's content, not more acceptance criteria.** The eight ACs are what the tests prove; the rest of the list is seen in the first screen check after the owner adds the `stack:` block.
- **AC-3 is tested through the API, not marked `manual`.** The layer's runner has no browser; the test proves the data each view reads, and the page's JavaScript is out of scope by the issue.
- **Token as `--token` on `dashboard.py`.** The CLI already passes arguments through; no token given keeps the random one, so the real dashboard is unchanged.
- **The demo's default token is `demo`.** The `stack.url` in `factory.yml` is a fixed text, and the token guards only sample data on 127.0.0.1.
- **A taken port fails `up`.** `dashboard.py` moves to the next port; a demo on another port would not be at the URL the factory waits on.
- **A new `gh` stand-in, not `scripts/test/fake-gh`.** The existing one answers one repository and one issue and keeps no board state; changing it would touch the tests that depend on it.
- **The sample is built by a Python script.** Times counted from the start and JSON transcripts are simpler there than in Bash; it uses the standard library only.
- **State under the temp folder, by stack name.** `down` runs in another shell with only the slot's `SHIPFLOOR_*` variables; the name is what both commands share.
- **Nothing installed.** The demo lives in `scripts/test/`, which `shipfloor install` does not copy; `stack.up` runs from the card's worktree.
- **`.shipfloor/factory.yml` is not touched.** The issue leaves the `stack:` block to the owner; the block to paste is in Architecture.
- **Page-wide alerts are left out of the sample** (UX): they would hide the normal state of both projects.
- **`DESIGN.md` describes an older board layout than the page renders** (found by UX): not changed here, out of scope.

## Open questions
- none
