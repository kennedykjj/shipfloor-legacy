# Validate does not rerun a gate that already passed on the same commit — spec

**Issue:** #75 · **Branch:** `feat/75-validate-does-not-rerun-a-gate-that-alre` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** `/sf:validate` reruns every gate that `/sf:develop` already passed on the same commit minutes before; `build` alone took 243 s a call on 2026-10-11, most of a 10-minute validate run. The time and cost buy no new evidence.
**Audience:** The factory's owner and other developers who install the plugin (they wait for, and pay for, each run).
**Acceptance criteria**
- **AC-1** — Given `build` passed on commit A, when `build` is called again on A with the same arguments, base and project config, then it ends `gate build: pass` without running the layer's build command.
- **AC-2** — Given a gate answers from a recorded pass, when its output is read, then it says it reused a pass and names the commit and when that pass was recorded, so a reuse is never mistaken for a run.
- **AC-3** — Given `build` passed on A, when it is called on another commit, with other arguments, against a base that moved (e.g. `origin/main` advanced), or after the project config in the factory snapshot changed, then the build command runs.
- **AC-4** — Given `build` failed on A, when it is called again on A, then the build command runs.
- **AC-5** — Given a file claiming a pass sits anywhere inside the card's worktree or branch, when the gate is called, then the file is ignored and the gate runs; passes are recorded only under the project's home (`~/.shipfloor/projects/<slug>/`).
- **AC-6** — Given `green <layer> <selector>` passed on A, when it is called again on A, then the same selector reuses its pass and a different selector runs its tests.
- **AC-7** — Given a gate passed on A, when the worktree holds tracked changes not in commit A, then the gate runs and records no pass for A.
- **AC-8** — Given deploy runs its gates on the merged head, when that head is a commit no gate has passed on, then every gate runs as it does today.
**Out of scope:** Skipping gates in deploy. Changing which gates validate asks for. Showing reuse in the dashboard. Reusing passes across projects or machines. Making any gate itself faster.
**Product fit:** Serves principle 2 (deterministic gates outrank any agent's claim): the pass is the factory's own record, out of the agent's reach, and is valid only for exactly what the gate read. Serves principle 3 (numbers are exact and sourced): a reused answer is labeled as reused, with its source commit and time. No conflict with the positioning as long as AC-5 and AC-7 hold; a reuse an agent could forge or that covered unverified changes would contradict "the gates hold".
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. No migration, no new dependency.

**Contracts touched**
- `gate.sh build <base>` and `gate.sh green <layer> <selector>`: same arguments and exit codes. Before running, each looks for a recorded pass; after exit 0, each records one. No other gate reads or writes a record (`fast`, `forbidden`, `migration`, `acceptance-intact`, `scope`, `red`, `test-plan` run as today).
- Record store: `$FACTORY_HOME/gate-passes/<key>`, one file per pass, written to a temp name and renamed. Content is one tab-separated line: `<ISO time> <HEAD sha> <gate> <arguments>`.
- `<key>` = `git hash-object` of these lines, so any difference is a different file:
  - `build`: HEAD sha, `build`, `<base>` resolved to a sha, the sha of `origin/<main>` (empty when there is none), the blob hash of `$FACTORY_CONFIG`, the blob hash of `gate.sh`.
  - `green`: HEAD sha, `green`, layer, selector, the blob hash of `$FACTORY_CONFIG`, the blob hash of `gate.sh`.
- A record is looked up and written only when all of these hold; otherwise the gate runs and writes nothing:
  - the worktree is clean (`git status --porcelain` prints nothing: no tracked change, no untracked file that is not ignored), checked before the command runs;
  - `$FACTORY_HOME` is set and `gate-passes` does not resolve to a path inside the worktree's top-level directory;
  - `SHIPFLOOR_GATE_FRESH` is not `1`.
- New line on stderr when a pass is reused, before the verdict: `<gate>: reused the pass on <HEAD sha, 12 chars> recorded <ISO time>; nothing ran`. The verdict stays `gate <gate>: pass`. A reuse installs no dependency and starts no stack.
- `SHIPFLOOR_GATE_FRESH=1` (environment): the gate runs and records nothing. `scripts/test/lib.sh` exports it so the existing tests, which call a gate twice on one commit with a different fake runner, keep running the command; `scripts/test/gate-reuse.test.sh` unsets it.
- A record older than 14 days is deleted when a gate records a new pass.
- `report.json`: new optional field `"gates_reused":["build","green <layer> <selector>"]`, beside `flaky`.

**Files**
- `scripts/gate.sh` — `pass_key`, `pass_reused`, `pass_record`, called from `gate_build` and `gate_green`; usage text says build and green reuse a pass.
- `scripts/test/lib.sh` — exports `SHIPFLOOR_GATE_FRESH=1` after the unset loop.
- `scripts/lang/pt-BR.sed` — the reuse line in Portuguese.
- `scripts/report.sh` — schema comment gains `gates_reused`.
- `skills/validate/SKILL.md`, `skills/develop/SKILL.md` — a gate that says "reused the pass" goes into the report's `gates_reused`, never counted as run.
- `README.md` — one sentence where the gates are described.
- `scripts/deploy.sh` — not changed: it calls only `fast` and `forbidden`, which never reuse.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-reuse.test.sh` |
| AC-2 | factory | `scripts/test/gate-reuse.test.sh` |
| AC-3 | factory | `scripts/test/gate-reuse.test.sh` |
| AC-4 | factory | `scripts/test/gate-reuse.test.sh` |
| AC-5 | factory | `scripts/test/gate-reuse.test.sh` |
| AC-6 | factory | `scripts/test/gate-reuse.test.sh` |
| AC-7 | factory | `scripts/test/gate-reuse.test.sh` |
| AC-8 | factory | `scripts/test/gate-reuse.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Only `build` and `green` reuse a pass: they are where the time goes (243 s a build); the other gates take seconds and read more than a commit (`accepted.tsv`, `origin/main`, the spec file).
- Deploy needs no change and no opt-out: `deploy.sh` calls only `fast` and `forbidden`, which never reuse, so AC-8 holds even when the merged head equals the staged head.
- `build`'s key always carries the sha of `origin/<main>`: a layer's build command may read it (this project's does, `run.sh --changed origin/main`), and the gate cannot tell. Cost: a build reruns when main moved between develop and validate.
- `green`'s key carries no base: a selector's result on a commit does not depend on main.
- The key carries the hash of `gate.sh`: a pass given by an older gate does not count after a factory update.
- A dirty worktree means untracked files too, not only tracked changes (AC-7): `build` reads untracked files.
- One file per pass, renamed into place: cards run in parallel, and appending to one shared file could interleave lines.
- A store that resolves inside the worktree is refused: `FACTORY_HOME` can come from the environment, and AC-5 must hold then too. Otherwise the record has the trust of `accepted.tsv`, which lives in the same home.
- `SHIPFLOOR_GATE_FRESH=1` exists because the test suite fakes runners through the environment, which no key can see; it can only make a gate run more, never less.
- Records expire after 14 days, cleaned when a pass is recorded: no card stays between develop and validate that long, and no new job is needed.
- `gates_reused` is a new optional report field, not a change to `gates_failed` or `flaky`: old reports and readers stay valid.
- No dashboard change: the PO left showing reuse there out of scope.

## Open questions
- none
