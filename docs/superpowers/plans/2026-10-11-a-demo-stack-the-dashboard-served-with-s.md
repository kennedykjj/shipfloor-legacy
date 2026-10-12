# A demo stack: the dashboard served with sample data — plan

**Issue:** #72 · **Spec:** `docs/superpowers/specs/2026-10-11-a-demo-stack-the-dashboard-served-with-s-design.md`
**Layers:** `factory` (path `./`, agent `engineer`). No migration, no new dependency, no change to `scripts/dashboard.html` or `.shipfloor/factory.yml`.

Acceptance tests (written by QA before any task): `scripts/test/demo-stack.test.sh` (new; AC-1 to AC-8).

One task, not three: the layer's build runs every test tied to what the card changed, the acceptance file included, and that file passes only when the token, the sample, the `gh` stand-in and the start/stop script are all there. A task that ended before that would fail its own build gate.

No test and no step may read or write the real `~/.shipfloor` or call the real `gh`: the demo's server gets its own home, transcripts folder, `gh` stand-in and scheduler stub.

## Task 1 — the token option, the sample and the demo's start and stop

- **Layer:** factory · **Owner:** engineer · **Depends on:** nothing
- **Files:** `scripts/dashboard.py`, `scripts/shipfloor`, `scripts/test/demo_home.py` (new), `scripts/test/demo-gh` (new), `scripts/test/demo-stack.sh` (new), `README.md`
- **ACs:** AC-1 to AC-8

Build it in this order; each part is checked by hand against the one before it.

1. **`scripts/dashboard.py`: `--token <text>`** (AC-8). Given and not empty, it is `Handler.token`; otherwise `secrets.token_urlsafe(16)` as today. Nothing else in the server changes. `scripts/shipfloor`: only the usage comment, `dashboard [--port N] [--no-open] [--token T]`.
2. **`scripts/test/demo_home.py <state folder>`** (AC-3, AC-4 and the UX section's list). Standard library only. Writes `<state>/home`, `<state>/claude` and `<state>/gh`; same content on every call, every time counted from the call.
   - Home: `registry.tsv` with two projects, `config.yml` (`language: en`, stage slots that add up to less than the pool), `logs/dispatcher.log` with dispatcher lines and one stack line, one `logs/health-<day>.jsonl`.
   - Project A (the full one, no alert): cards in six or more columns, Done included; two in Spec Review (one with `reviews/<n>.html` of three or more items, one without); one in Staged with a validation report and a PR; one labelled `blocked` with a block note (reason and "What the factory already tried"); one labelled `blocked:infra`; two run locks (`<stage>-<n>.lock/info`) in different stages, one with `step`, a "says" line and three or more actions, one with no step, their logs with `== start` and no `== end`; one waiting card; today's logs with a clean and a failed run in the same hour and one more hour with spend; run logs of more than 12 lines; `typical_s` for the four stages; one `overrides.yml` knob that differs from the repository; a title of about 90 characters, a four-digit issue number, a cost of $10 or more next to ones under $1.
   - Project B (the quiet one): a `PAUSE` file, a `board.tsv` older than 5 minutes, no lock, no run today.
   - Each project: `factory.yml` with two layers (one `tests_only`), a `stack.url` and a context list; `board.tsv`, `logs/`, `locks/`, `reviews/` and reports as `Factory.reports` reads them.
   - Transcripts under `<state>/claude/projects/*-projects-<project>-control/`: one card past Coding with four or more sessions over two or more stages, a subagent, a passed and a failed gate, a stage with no gates, two or more log files and a last report; costs from the shipped `templates/prices.yml`; one session of a model that table does not price.
   - `<state>/gh`: the board, issues, labels, comments and pull requests of both repositories, as `demo-gh` reads them.
3. **`scripts/test/demo-gh`** (AC-5). The `gh` stand-in the server gets as `FACTORY_GH`, reading and writing only its data folder. Answers every call `scripts/dashboard.py` and `scripts/board.sh` make (`project view`, `project field-list`, `project item-list` / `api graphql`, `project item-edit`, `issue list`, `issue comment`, `api repos/<repo>/issues?labels=`, `api repos/<repo>/issues/<n>/comments`, `api -X DELETE .../labels/<label>`, `pr view` / `pr list`) for both sample repositories. Keeps state: `item-edit` moves the card, `issue comment` is appended, a removed label stays removed. Refuses to refresh project B's board, so B's old snapshot keeps serving. An unknown call exits non-zero with its arguments on stderr.
4. **`scripts/test/demo-stack.sh up|down`** (AC-1, AC-2, AC-5, AC-6, AC-7). Reads only `SHIPFLOOR_STACK` (default `shipfloor-demo`), `SHIPFLOOR_PORT_WEB` (default `7727`) and `SHIPFLOOR_DEMO_TOKEN` (default `demo`). State folder `${TMPDIR:-/tmp}/shipfloor-demo/<SHIPFLOOR_STACK>/` with `home/`, `claude/`, `gh/`, `server.log` and `pid`.
   - `up`: runs `down` for the same name, builds the sample, starts `scripts/dashboard.py` of its own checkout with `--home <state>/home --port <port> --token <token> --no-open`. The server's environment is the one in the spec's Architecture: `SHIPFLOOR_HOME`, `CLAUDE_CONFIG_DIR`, `FACTORY_GH` and its data folder, `SHIPFLOOR_BASH`, `SHIPFLOOR_SCHEDULER` as a stub that records the minutes in the state folder, every other inherited `FACTORY_*` and `SHIPFLOOR_*` unset. Its stdin, stdout and stderr go to `/dev/null` and `<state>/server.log`, so it holds no file of the caller. Prints `http://127.0.0.1:<port>/?t=<token>` and exits 0 once `GET /` answers; exits 1, with the server's log on stderr and nothing left behind, when it does not answer in 30 seconds or the server took another port.
   - `down`: stops the server, waits until its process is gone, removes the state folder; exits 0 with nothing to stop.
   - `pid` holds the pid the operating system knows: in Git Bash the Windows pid from `/proc/<pid>/winpid`, stopped with `taskkill`.
5. **`README.md`**: `--token` in the dashboard paragraph and two lines on the demo under Operation.
