# Dashboard titles: an empty cache for 5 min after one gh failure, and 300 issues at most — plan

**Issue:** #6 · **Spec:** `docs/superpowers/specs/2026-10-11-dashboard-titles-an-empty-cache-for-5-design.md`
**Layers:** `factory` (path `./`, agent `engineer`)

## Order

1. QA writes the acceptance tests (`scripts/test/dashboard-titles.test.sh`), red.
2. Task 1 (factory), one task: the fake and the read change together, because `dashboard.test.sh` reads its "Seven" title through the fake and the build runs the whole suite.

## Acceptance tests — QA

- **File:** `scripts/test/dashboard-titles.test.sh` (new), AC-1 to AC-7.
- Starts the dashboard with `FAKE_GH_NO_JQ=1` on a board it writes itself (`board.tsv`), as `dashboard.test.sh` does.
- Writes `$FAKE_GH_DIR/titles.tsv` (`number<TAB>title`); counts title reads as the lines of `$FAKE_GH_DIR/calls` that contain `issueOrPullRequest`; turns gh off and on with `$FAKE_GH_DIR/fail`.
- AC-5 uses a card whose title exists only in `titles.tsv`, with a number above 300.
- The fake's `titles.tsv` answer does not exist yet (Task 1 writes it): before the implementation the tests fail on their assertions, not on a missing file or a crash.

## Task 1 — factory: titles by number, and a failed read keeps what was known

**Owner:** `engineer` · **Depends on:** the QA commit

**Files**
- `scripts/dashboard.py` (change)
- `scripts/test/fake-gh` (change)
- `scripts/test/dashboard.test.sh` (only if its title assertion needs the new fake; not an acceptance test of this card)

**`scripts/test/fake-gh`**
- Under `FAKE_GH_NO_JQ`, an `api graphql` call whose query contains `issueOrPullRequest` answers JSON built from `$FAKE_GH_DIR/titles.tsv` (`number<TAB>title`; without the file: `7<TAB>Seven`): `{"data":{"repository":{"i<n>":{"title":"..."}, ...}}}`.
- A number asked that is not in the file: its alias is `null`, an `errors` entry is printed and the exit is 1, with the other numbers still under `data.repository`.
- The `issue list` branch goes away.
- `$FAKE_GH_DIR/fail` keeps failing every call, before anything is written to `calls`.
- `board.sh`'s own `api graphql` read (with `--jq`) keeps answering from `items.tsv`.

**`scripts/dashboard.py`**
- `Factory.titles(p, wanted)` replaces `titles(p)`; returns `{number: title}`.
- The read: one `gh api graphql` call per 100 numbers, `repository(owner:, name:)` with an alias per number, `i<n>: issueOrPullRequest(number: <n>) { ... on Issue { title } ... on PullRequest { title } }`. Owner and name as GraphQL variables (`-f owner=`, `-f name=`); only the numbers (`int`) are written into the query. No `--jq`.
- gh exits non-zero when a number does not exist and still prints the others: the read succeeded when the output is JSON with `data.repository`, whatever the exit code (`gh_json` may need a way to hand over stdout of a non-zero exit). A number without a title in the answer is kept as `""`.
- The read failed when there is no JSON with `data.repository`.
- The cache `self._titles[p] = (read_at, known)`:
  - window over (300 s) → ask for all of `wanted`; success merges into `known` and sets `read_at`;
  - inside the window, `wanted` has numbers not in `known` → ask only for those; success merges, `read_at` stays;
  - failure → `known` and `read_at` stay as they were;
  - otherwise no gh call.
- Callers: `overview()` passes the board's card numbers (`columns`); `card(p, n)` passes the board's numbers plus `n`.
- The HTTP responses keep their shape: `title` is a string, empty when unknown.

**Done when:** `scripts/test/dashboard-titles.test.sh` passes and `TEST_JOBS=4 bash scripts/test/run.sh` is green.
