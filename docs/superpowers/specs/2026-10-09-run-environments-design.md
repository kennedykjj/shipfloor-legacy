# Run environments and infrastructure resilience — design

**Date:** 2026-10-09 · **Status:** approved by the owner (2026-10-09), with the stack queue and slot states added at their request

## Problem

Issue #86 blocked in validate: the UX check started `pnpm dev` on port 3000 from a copy of `main`, the dev server crashed, and the `green e2e` gate attached to it (Playwright `reuseExistingServer: true`), so 20 of 26 tests failed. The agent could not stop the process (correctly), the dispatcher's cleanup missed it (it was started under `tmp/86/`, and a `next dev` command line does not carry the worktree path), and the card waited for the owner.

The incident shows a worse hole: nobody owns what runs on port 3000. `stack.lock` serializes access, but the e2e of one card can run against another worktree's server, which is a false green as easily as a false red. While the incident was being investigated, port 3000 was held by card #85's dev server with no lock held, while #100 was validating. The API side is the same: e2e runs against whatever API the shared `docker compose` started, not the branch under test.

Smaller, related gaps: every infrastructure failure costs the owner a round trip; temp files of finished cards pile up (`tmp/35` … `tmp/44`); a flaky test blocks a run; the dashboard does not say why a card is blocked.

## Decisions

1. **One stack per run, on its own port range.** The machine has a fixed number of stack slots. A run that needs the stack leases a slot, and the slot gives it an exclusive port range and its own `docker compose` project, started from the run's worktree. Nothing is shared, so `stack.lock` and its queue go away.
2. **The scripts own the stack, never an agent.** `gate.sh` brings the slot's stack up and down. At both ends it clears anything listening in the slot's range, which it can do safely because the range belongs to that slot alone. Agents get the ports through environment variables and never kill processes.
3. **Infrastructure blocks retry once on their own.** A run that hits an infrastructure failure labels the card `blocked:infra`. On the next cycle the dispatcher cleans that card's leftovers and relaunches it once. A second infrastructure failure turns into `blocked`, for the owner.
4. **Runs clean up what they created**, by ownership (the slot's compose project, `tmp/<n>/`), not by matching command lines.
5. **A failed test is run once more.** A layer may set `retry: 1`. A selector that passes on the retry passes the gate, and is reported as flaky.
6. **The dashboard shows why a card is blocked** and offers "Unblock & retry".

## 1. Stack slots

### Machine config (`~/.aghanim/config.yml`)

```yaml
stacks: 3            # stacks running at once on this machine (each is a full compose project)
ports: {base: 20000, span: 20}   # slot k owns ports base + k*span .. base + (k+1)*span - 1
```

The defaults are 3 and `{base: 20000, span: 20}`. They are validated like `pool`. `aghanim pool` also shows `stacks: 1/3`.

### Project config (`.aghanim/factory.yml`)

```yaml
stack:
  up: docker compose -p "$AGHANIM_STACK" up -d --build --wait
  down: docker compose -p "$AGHANIM_STACK" down -v --remove-orphans
  ports: [web, api, db, s3, s3console, smtp, mail]   # offsets 0..n-1 inside the slot's range
  url: "http://localhost:{web}"
  health: "http://localhost:{web}/"                  # must answer 2xx within stack.timeout
  reject: "Runtime Error|Unhandled Runtime Error"      # a body matching this is unhealthy (dev overlays)
  timeout: 300
```

`stack.url` remains the only required key for projects that run no stack themselves.

### Environment given to `up`, `down`, the tests and the agents

- `AGHANIM_SLOT=<k>`
- `AGHANIM_STACK=aghanim-<project>-<k>` (the compose project name)
- `AGHANIM_PORT_<NAME>=<port>` for each name in `stack.ports`, upper-cased
- `AGHANIM_STACK_URL=<url with ports filled in>`

### Lease, queue and slot state

Each slot has a machine-wide lock, `~/.aghanim/locks/stack-<k>.lock/`:

- `info` holds `<project>/<pipeline>-<n> <run lock path> <epoch>`.
- `beat` is touched every 15 s by a heartbeat loop that `stack up` starts in the background and `stack down` stops.

A slot is in exactly one of three states, computed the same way by `gate.sh`, `aghanim pool` and the dashboard:

| State | When |
|---|---|
| **free** | no lock |
| **busy** | lock present, `beat` younger than `stack.stale` (default 90 s), the owner's run lock still present, and held for less than `stack.hold_max` (default 45 min) |
| **stuck** | lock present but any busy condition fails: the heartbeat stopped, the owning run ended, or the lease outlived `hold_max` |

A stuck slot is reclaimed by the next process that needs one. Reclaiming means `down` with that slot's environment, freeing the range, and removing the lock. Each reclaim is logged to `~/.aghanim/logs/stacks.log` with the holder and the reason.

**Queue when every slot is busy:**

- A waiter takes a ticket: a file `~/.aghanim/locks/stack-queue/<epoch-ns>-<owner>`.
- Slots go to tickets in order, so a later run never jumps an earlier one. A waiter takes a slot only when its ticket is the oldest live one. A ticket is live while its owner's run lock exists.
- A waiter waits up to `stack.wait` (machine config, default 30 min). After that it removes its ticket and exits 3 (infrastructure), so the card goes through the automatic retry (decision 3) instead of holding an agent slot forever.
- While waiting, it prints the queue position and the holders once a minute, which lands in the run's log.

Machine config gains `stack_wait: 1800`, `stack_stale: 90` and `stack_hold_max: 2700` (seconds), validated like `pool`.

### Lifecycle, all in `gate.sh`

`gate.sh -C <wt> stack up <owner>` does the following, in order:

1. Lease a slot.
2. Free the range: run `down`, then kill any process still listening on a port in the range.
3. Run `up` in the worktree with the environment above.
4. Poll `health` until it answers 2xx with a body that does not match `reject`, or until `timeout`. On timeout the gate prints the last `up` output and `docker compose ps`, runs `down`, and exits 3, which means infrastructure.
5. Print the URL.

`gate.sh -C <wt> stack down <owner>` runs `down`, frees the range and releases the lease.

A gate whose layer has `needs_stack: true` wraps its test run in `stack up` … `stack down` itself, with the environment exported to the runner. The validate skill's UX check calls `stack up validate-<n>` and `stack down validate-<n>` around the `ux-designer` call, and passes it the printed URL. That replaces `stack-lock acquire/release`. A run that ends while it still holds a lease has it released by the dispatcher, as today for `stack.lock`.

### Exit code 3

The gate exits 3 on infrastructure: the stack did not come up or did not become healthy, or a slot could not be leased. Skills treat exit 3 as an infrastructure error (decision 3). Exit 1 (blocked by the code) and exit 2 (bad usage) keep their meaning.

### Pickio (manual PR, `.aghanim/` and the compose file are forbidden to agents)

- `docker-compose.yml`: every published port takes its variable with today's port as the default, for example `"${AGHANIM_PORT_WEB:-3000}:3000"`. Service-to-service URLs stay on the compose network names. Browser-facing URLs (`NEXT_PUBLIC_*`, CORS origins, MinIO public URL) come from the same variables. Without the factory, `docker compose up` behaves exactly as today.
- `web/playwright.config.ts`: `baseURL: process.env.AGHANIM_STACK_URL ?? 'http://localhost:3000'`. Under the factory there is no `webServer` (the gate brought the stack up); outside it, `webServer` stays as today with `reuseExistingServer: !process.env.CI`.
- `.aghanim/factory.yml`: the `stack` block above.

## 2. Infrastructure blocks

- Skills (refine, develop, validate): an infrastructure error, meaning a gate exit 3, Docker, network or a runner crash outside the code, means `gh issue edit <n> --add-label blocked:infra`. The skill also comments the step, the output and what was tried, and writes the report with `outcome: infra`. Infrastructure errors are still not rounds.
- Dispatcher, each cycle, for a card with `blocked:infra` and no live run:
  - When its last report has no `infra_retry: true`: clean up the card (section 3), remove the label, and relaunch the card's pipeline with `AGHANIM_INFRA_RETRY=1`. The report then carries `infra_retry: true`.
  - When the retried run hits infrastructure again: the skill replaces `blocked:infra` with `blocked` and says in the comment that the automatic retry failed.
- `board.sh eligible` skips cards labeled `blocked` or `blocked:infra`; the dispatcher's retry step is the only path that takes `blocked:infra` cards.

## 3. Cleanup by ownership

At the end of every run, in `dispatch.sh launch`, after the agent or deploy exits:

- `gate.sh stack down` for any slot this run still leases.
- Remove `tmp/<n>/`: first every git worktree registered under it (`git worktree remove --force`, then `prune`), then the directory.
- `cleanup_processes` as today.

`aghanim doctor` reports `tmp/<n>/` directories of cards that are Done or closed. The new `aghanim clean <project>` removes them.

## 4. Flaky tests

A layer may set `retry: 1`. In `green` and `acceptance-intact`, a failing selector runs once more. When the second run passes, the gate passes and prints `flaky: <layer> <selector>`. Skills copy that line into the report's `flaky` list. `red` never retries, because a test that must fail is not allowed to be flaky.

## 5. Dashboard

- The overview gets each card's `blocked` value (`null`, `infra` or `owner`) from one `gh api "repos/<repo>/issues?labels=..."` call per label, cached for 60 s.
- A blocked card shows a marker on the board. Infra is labeled "retrying" until the retry has run, and "blocked" after.
- The drawer shows the reason: the `notes` of the last report with `outcome: blocked|infra`, and a link to the issue comment.
- The top strip gets a stacks cell: `stacks 2/3`, each slot with its state (free, busy or stuck), holder (`#86 validate`), time held, and the queue length. A stuck slot is drawn as a warning.
- "Unblock & retry" is an owner action available in any column for a blocked card. `POST /api/card/<p>/<n>/unblock` removes both labels. The dispatcher picks the card up on its next cycle.

## Tests

Only what protects a decision:

- `gate-stack.test.sh` (rewritten), with `up`, `down` and `health` replaced by fake commands:
  - two leases get different slots and port ranges;
  - a third lease waits when `stacks: 2` and takes the slot when one is released;
  - two waiters take slots in ticket order;
  - a waiter gives up after `stack_wait` with exit 3;
  - a slot whose heartbeat is stale, whose owner run is gone, or whose lease is past `hold_max` is reported stuck and reclaimed (`down` runs);
  - `up` sees the slot's environment;
  - an unhealthy body (matches `reject`) exits 3 and runs `down`;
  - a stale lease is reclaimed.
- `dispatch-resilience.test.sh`:
  - a `blocked:infra` card is cleaned and relaunched once;
  - a card whose last report has `infra_retry: true` is not relaunched.
- `gate-build.test.sh` or a new small test: with `retry: 1`, a runner that fails then passes passes the gate and prints `flaky:`; `red` does not retry.
- `dashboard.test.sh`: `unblock` without the token is 403; with it, it removes the labels (`fake-gh` records the call).

## Out of scope

- Remote or shared Docker hosts.
- Choosing the number of stack slots automatically from free memory.
- Rewriting existing tests to remove flakiness (the retry only keeps a run from blocking on one).
