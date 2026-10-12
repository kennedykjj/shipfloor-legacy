# Dashboard titles: an empty cache for 5 min after one gh failure, and 300 issues at most — spec

**Issue:** #6 · **Branch:** `feat/6-dashboard-titles-an-empty-cache-for-5` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** One failed `gh` read leaves every card on the dashboard as "Title not loaded" for 5 minutes, and a card whose issue is not among the repository's 300 newest never gets a title.
**Audience:** The factory's owner, on a quick check of the board: a card without a title cannot be told from its neighbours, least of all one waiting for approval.
**Acceptance criteria**
- **AC-1** — Given the dashboard's first title read fails, when gh works again and the overview is polled once, then every card on the board carries its title in that response.
- **AC-2** — Given titles were already read, when a later title read fails, then the overview keeps serving the titles it had, none of them empty.
- **AC-3** — Given a title read failed, when the overview is polled again, then gh is asked for titles again on that poll, not after the 5-minute cache window.
- **AC-4** — Given a title read succeeded, when the overview is polled again inside the cache window, then gh is not asked for titles again.
- **AC-5** — Given a board card whose issue is not among the repository's 300 newest (open or closed), when the overview is requested with gh working, then that card carries its title.
- **AC-6** — Given the first title read failed and gh works again, when `/api/card/<project>/<n>` is requested, then the card's title is in the response.
- **AC-7** — Given gh fails on every title read, when the overview or a card is requested, then the response is still a 200 with the board's cards, each with an empty title.
**Out of scope:** Any change to the page (the "Title not loaded" text, its tooltip, markup, styles); titles of issues that are not on the board; keeping titles across a dashboard restart; the cache and retry of the other gh reads (board columns, block labels, board URL); showing the owner that gh is failing.
**Product fit:** Serves principle 1 (the board is the source of truth; the dashboard keeps no card state of its own): a title is GitHub's data, and a failed read must not stand in for it as if the card had none. Also serves the dashboard's use in quick checks (Users). No conflict with the positioning or with what is out of scope.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Layer:** `factory` only. Files: `scripts/dashboard.py` (change), `scripts/test/fake-gh` (change), `scripts/test/dashboard-titles.test.sh` (new). No page, catalog, config or script contract changes.

**Contract touched:** `Factory.titles(p, wanted)` in `scripts/dashboard.py` (was `titles(p)`): `wanted` is the issue numbers the caller will show; it returns `{number: title}`.
- `overview()` passes the board's card numbers (`columns`); `card(p, n)` passes the board's numbers plus `n`.
- The HTTP responses keep their shape: `title` stays a string, empty when unknown.

**The read:** titles are asked by number, not by listing the repository, so there is no 300 cap.
- One `gh api graphql` call per 100 numbers: `repository(owner:, name:)` with one alias per number, `i<n>: issueOrPullRequest(number: <n>) { ... on Issue { title } ... on PullRequest { title } }`.
- Owner and name go as GraphQL variables (`-f owner=`, `-f name=`); only the numbers, already `int`, are written into the query. No `--jq`.
- gh exits non-zero when one number does not exist but still prints the others under `data.repository`: such an answer is a successful read. A number GitHub does not know is kept as an empty title until the next refresh, so it is not asked on every poll.
- A read failed when gh prints no JSON with `data.repository` (network, quota, auth).

**The cache** (`self._titles[p] = (read_at, known)`):
- Asks gh when the 300 s window is over (all of `wanted`), or when `wanted` has a number not in `known` (only those numbers).
- Success: merge into `known`; a full refresh also sets `read_at`.
- Failure: `known` and `read_at` stay as they were, so the previous titles are served and the next call asks again.
- Nothing else is asked inside the window: same cards, no gh call.

**`scripts/test/fake-gh`:** under `FAKE_GH_NO_JQ`, an `api graphql` call whose query has `issueOrPullRequest` answers JSON from `$FAKE_GH_DIR/titles.tsv` (`number<TAB>title`, default `7<TAB>Seven`), with a GraphQL error and exit 1 for a number not in the file; the `issue list` branch goes away. `$FAKE_GH_DIR/fail` keeps failing every call.

**Migration:** none; the cache lives in memory.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-titles.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-titles.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-titles.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-titles.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-titles.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-titles.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-titles.test.sh` |

The test starts the dashboard on a board snapshot (`board.tsv`) it writes itself, counts title reads in `$FAKE_GH_DIR/calls`, and turns gh off and on with `$FAKE_GH_DIR/fail`. AC-5 uses a card numbered above 300 issues' reach (a title only in `titles.tsv`).

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Titles are asked for the board's cards by number, not by a longer `gh issue list`: any `--limit` is another cap, and a list pays for issues no card shows.
- One GraphQL call per 100 cards instead of one REST call per card: the factory keeps its gh calls few (see `board-budget.test.sh`).
- `issueOrPullRequest`, not `issue`: a board card can be a pull request, and `issue(number:)` answers nothing for one.
- A failed read is retried on the very next poll (every 2 s), with no back-off: the issue asks for it, and the cost during an outage is one failing gh call per poll.
- A card that reaches the board inside the cache window gets its title on its first poll: the by-number read makes it one small call, and the 5-minute wait served nobody.
- A number GitHub does not know is remembered as untitled until the next refresh: otherwise every poll would ask for it again.
- "Covers every card" means cards on the board; issues that are on no board are not read (PO).
- gh failing on every read still answers 200 with empty titles; the page already shows "Title not loaded" (PO).
- The acceptance tests go in a new `dashboard-titles.test.sh`: they need gh to fail from the dashboard's first read, which `dashboard.test.sh` cannot stage.
- No UX section: no screen, text or markup changes (PO: Touches UI no).

## Open questions
- none
