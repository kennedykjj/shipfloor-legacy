# How Shipfloor works

The pipelines, the gates that judge them, how cards built at the same time stay out of each other's way, and what keeps the factory safe. Back to the [README](../README.md).

## How it works

The board (a GitHub Project v2) has fixed columns. The owner moves cards between the 👤 columns; the factory works the 🤖 ones:

| Pipeline | Takes from | Leaves in | What it does |
|---|---|---|---|
| `/sf:refine` | Ready for Refinement | Spec Review | PO, UX/UI and Cybersec write the spec; the Tech Lead writes architecture and test plan |
| `/sf:develop` | Ready for Dev | Validation | plan, failing acceptance tests (QA), implementation per layer |
| `/sf:validate` | Validation | Staged | gates, review (code, UX, security), PR with green CI |
| `/sf:deploy` | Ready for Prod | Done | up to date with `main` (resolving conflicts, fixing what breaks), merge tested on the current `main`, waits for CI and deploy; on failure opens a revert PR |

The gates (`scripts/gate.sh`) do not depend on the model: file scope per role, forbidden paths, untouched acceptance tests, immutable, unique and ordered migrations, build per layer, red by assertion (not by a compile error) and green with at least one test run. `build` and `green` reuse a pass the factory recorded for the same clean commit and inputs, say so in their output, and run again when anything differs.

A dispatcher (a scheduled task, every 3 minutes by default) goes through every registered project and starts pipelines with `claude -p`, within the machine's agent pool, each stage's slots and the project's WIP. It takes the cards of Ready for Refinement and Ready for Dev from the top: the order is the items' position in the GitHub Project, which the owner sets by dragging them in the dashboard (or on GitHub), and a card that cannot start (blocked) is skipped for the next one down. A running deploy counts as ONE unit of the pool, although it holds two locks (`deploy-<n>.lock` from the dispatcher, `deploysh-<n>.lock` from `deploy.sh`): only the first is counted.

Each run's model comes from the card's **weight**. Refine ends by writing `**Weight:** light|standard|heavy` in the spec header, from what the spec says (layers touched, files, acceptance criteria, security or UX work), and the `weight` gate refuses a spec without one. The owner sees it in Spec Review and can change it there (`shipfloor weight <project> <n> <weight>`, or the drawer's decision); the next run follows it. Settings, Agents and models maps each stage and weight to a model: by default Develop runs light and standard cards on Sonnet and heavy ones on Opus. A card refined before weights existed runs as `standard`.

A Develop run that ends on a failed gate **steps up**: the dispatcher reads the verdict the gate left in the run's lock (never the agent's report), takes the block off and resumes the card on its next cycle one model up (Sonnet to Opus), once per card while it stays in Coding. A run already stepped up, on the top model, or ended on an infrastructure failure stays blocked as before. The run's log (`== step-up ...`), the Feed and the card's Sessions tab name both models and the gate.

## Parallel work

Cards built at the same time do not break `main`:
- the `migration` gate refuses a version used twice and a migration older than the base's or `main`'s;
- only `deploy` merges `origin/main`, once, on the head the owner approved (`validate` does it only when the PR conflicts with main, so CI can run); the PR's CI already tests the branch merged with main;
- `deploy` merges only a head that contains the current `main` and passed CI; with `deploy.refresh_staged: true` the dispatcher also keeps Staged PRs on top of `main` (faster approvals, but every refresh reruns CI: leave it off when Actions minutes are tight);
- a project with no CI on GitHub (or no Actions minutes to spend) sets `deploy.local_ci` to a command: the deploy runs it in the card's worktree on the head merged with main, where it would wait for GitHub's checks. Red gets the same fix rounds as red CI, and `deploy.timeout_min` bounds it. With it set, `deploy.required_checks` is not read and validation does not wait for checks;
- to close the race with merges made by hand, enable branch protection on the main branch with "Require branches to be up to date before merging" and required CI; `/sf:deploy` reports when it is missing.

On deploy, what breaks on top of `main` is repaired in place. Conflicts are resolved by an agent, which may touch only the conflicted files. A migration whose version `main` took is renumbered above main's newest. A gate or CI that goes red after the merge gets up to two agent rounds: a fix within `deploy.fix_max_files` / `fix_max_lines` (3 files, 40 lines) that touches no acceptance test ships with the approved head, recorded on the issue as `deploy-fix`; a larger one goes back to Staged for a new approval. A CI run on `main` that fails has its failed jobs run once more before the revert. The card goes back to Coding only when a migration file itself conflicts, when the conflict is large (`deploy.conflict_max_files` / `conflict_max_hunks`), or when the two rounds do not turn it green.

## Security

- Scripts run from the installed copy in `~/.shipfloor/factory`, outside every worktree.
- The gates read a snapshot of the committed config (`origin/main`), outside the pipelines' reach; `.shipfloor/` is forbidden to agents, so a factory PR cannot change the gates that judge it.
- `templates/factory-guard.yml` repeats the forbidden-path check in GitHub Actions.
- The agents read an issue's title and body, and only the comments written by the factory's own GitHub user: on a public repository anyone can comment, and a comment would be an instruction. To listen to more people, name them in `.shipfloor/factory.yml`: `trusted_commenters: [alice, bob]` (`['*']` is anyone; only for a private repository). The setting is read from `origin/main`, where no agent can change it.
