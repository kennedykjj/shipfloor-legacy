# Configuring Shipfloor

What this machine runs at once, what it may spend, when it works and how it tells you. Back to the [README](../README.md).

## Agent pool

Each pipeline run is one agent. `~/.shipfloor/config.yml` sets how many run at once on the machine, across all projects, and how many each stage may take (absolute numbers):

```yaml
pool: 4
stages: {refine: 2, develop: 2, validate: 2, deploy: 1}
```

`shipfloor pool` shows it and the runs in progress; `shipfloor pool set 6` and `shipfloor pool stage validate 3` change it. A project runs one deploy at a time (merges into main are serial); its `limits.<stage>.wip` in `factory.yml` caps the cards waiting in Spec Review (refine, default 2) and in Coding + Validation (develop, default 4); `0` is no cap (the dispatcher starts cards however many are there, and so does the agent's first step). With the column full and cards waiting, the cycle says so (`dispatch: develop: Coding + Validation is full (limits.develop.wip 4); 2 cards wait`) and starts none.

## Cost limits

The same `~/.shipfloor/config.yml` can cap what a card and a day spend. All three keys are optional, in US$, and a key you leave out does nothing:

```yaml
costs: {card_warn: 20, card_block: 40, day_stop: 80}
```

- `card_warn`: a card whose estimate passes it is flagged on the dashboard. Nothing stops.
- `card_block`: past it, the card's next run does not start. The card gets the `blocked` label and a comment with the estimated total and the estimate per stage, and waits for your call. Unblocking it grants one more `card_block`, counted from the unblock.
- `day_stop`: when today's estimate across every project passes it, no new run starts and the dashboard says so. Sessions already running finish. Runs start again on their own when the machine's local day changes.

The figures are an estimate, from the tokens of the runs and `~/.shipfloor/prices.yml`, not a bill. A card that ran on a model with no price has an unknown estimate: no card limit flags or blocks it, its runs add nothing to the day, and the dashboard says the price is missing. The dashboard's Settings, Costs section sets the three values (an empty field removes one; `card_warn` cannot be above `card_block`), and a change applies from the next dispatcher cycle.

The same file picks the model each stage's session and each agent runs on, in two optional maps:

```yaml
models:
  stages:
    refine: opus                                       # one model: Refine runs before the card has a weight
    develop: {light: haiku, standard: sonnet, heavy: opus}   # develop, validate, deploy: a model per weight
    validate: sonnet                                   # or one model for every weight
  agents: {engineer: haiku}   # a plugin agent, or the agent a project's layer names
```

A model is `opus`, `sonnet`, `haiku` or `fable`. A card's weight (`light`, `standard` or `heavy`) is the `**Weight:**` line Refine writes in its spec header, which the owner can change in Spec Review; a card with no weight line runs as `standard`. A stage, weight or agent left out keeps the model the plugin ships with: refine on Sonnet; develop on Sonnet for light and standard cards and Opus for heavy ones; validate and deploy on Sonnet for every weight; each agent on its frontmatter model. A develop run that ends on a failed gate runs once more one model up (haiku → sonnet → opus; `fable` is not on the ladder), from the next dispatcher cycle; the run's log, the Feed and the card's Sessions tab say so. A bad model, weight or name does not stop the factory: `shipfloor doctor` warns about it, the run uses the shipped model, and the dashboard's Settings section "Agents and models" edits it, with the average cost per card of the last 7 days next to each stage.

## Disk floor

A run that cannot write has nothing to do but stop, and it still pays for its start. The machine config sets how much room the disks a run writes to must have before the dispatcher starts one:

```yaml
disk: {min_free_gb: 2, min_free_inodes_pct: 10}   # the defaults; 0 turns a check off
```

Each cycle checks the folder the runs' `TMPDIR` is made in (`<home>/tmp`), the machine's temp folder (`TMPDIR`) and the worktrees' folder, once per filesystem. Under the floor no run starts (the rest of the cycle still runs) and one line says where and how much: `dispatch: /tmp has 0.5 GB free, the floor is 2 GB; no run starts until there is space`. Windows has no inode count, so only the space is checked there; a filesystem that does not count inodes (btrfs) is skipped for that check.

## Runs that stop

An agent can end without doing its stage: it finds a limit, a rate limit or a change only the owner may make, writes a report saying so, and exits 0. The run's `== end` line then carries `stopped=<why>` (and `runs.jsonl` the same field), so these runs are counted apart from the ones that did the work:

| `stopped=` | What the run's report says |
|---|---|
| `blocked`, `infra` | outcome `blocked` or `infra` with no round done (the agent stopped at its first steps). The label it puts on the card already holds the card |
| `owner-only` | `blocked` and its words say the change is the owner's (`owner-only`) |
| `no-report` | the agent ended well and wrote no report for this run (read only where the project has a `reports-wt`) |

A run that crashed (non-zero exit) or ended on the usage limit is not judged. `owner-only` and `no-report` also leave a mark in `<home>/stopped/<n>` (the stage, the reason and the column the run started from). Two marks in a row hold the card: the dispatcher says `#<n> stopped twice in a row` and does not start it until you move it to another column or delete the mark. A run that did its stage clears the marks, and so does the card leaving the board. `shipfloor_health.py` puts today's counts per project in the health line (`stopped_runs`).

## Notifications

The factory tells the owner when it needs them, so the dashboard does not have to be open. At the end of each dispatcher cycle it sends, once per wait:

- a card waits in Spec Review or Staged;
- a run is blocked (the message says the stage it stopped in);
- one reminder for a wait that lasts `reminder_min` minutes, and no more;
- the factory is stuck: the Claude usage limit was hit, a project is skipped, or no card moved for an hour in a project with cards at work and nothing paused;
- optionally (`done`, off by default), a card reached production.

A card that leaves its state and comes back waits anew and is told again. There are two channels: a Windows toast on this machine, and a phone push through [ntfy.sh](https://ntfy.sh), which is off until a topic is set. A message that one channel delivered counts as told. Quiet hours hold what is new; when they end, one notification lists what still waits. While `config.yml` is invalid, nothing is sent.

Set it in the dashboard's Settings > Notifications, or by hand in the `notify` block of `~/.shipfloor/config.yml` (these are the defaults):

```yaml
notify:
  events: {waiting: true, blocked: true, reminder: true, stuck: true, done: false}
  channels: {toast: true, ntfy: false}
  ntfy_topic: ""        # letters, digits, - and _, up to 64
  reminder_min: 60      # 15 to 720
  quiet: ""             # "HH:MM-HH:MM", for example "22:00-07:00"; the two times differ
```

To get the push, pick a topic that is long and random: anyone who knows the topic can read its notifications. Put it in `ntfy_topic`, turn `channels.ntfy` on, and subscribe to the same topic in the ntfy app on the phone. The push carries only the project and the card's number, title and state.

## Working hours

`hours` in `~/.shipfloor/config.yml` lists the windows (local time, 24-hour `HH:MM-HH:MM`, start included, end excluded) in which the dispatcher starts runs. Outside them it does everything else (board snapshot, reaping, retries) but starts nothing; runs in progress finish. A window whose end is before its start crosses midnight. Unset or `[]` means all hours; a malformed value is reported by `machine validate` and ignored.

```yaml
hours: ["08:00-23:00"]
```

## Runtime

`runtime` names the agent runtime that runs a stage's session. It goes in `~/.shipfloor/config.yml` or in a project's `.shipfloor/factory.yml`, as a string for every stage or as a map with only `default` and `stages` (`refine`, `develop`, `validate`, `deploy`):

```yaml
runtime: claude-code            # every stage
```

```yaml
runtime:
  default: claude-code
  stages: {validate: claude-code}   # a stage here wins over default
```

`factory.yml` wins over `config.yml` key by key: `default` and each stage are resolved on their own. Unset means `claude-code`, which is the only runtime today. A value that is not a known runtime, or a map with any other key, makes the config invalid and the dispatch exits 2. The dispatcher's log lines carry `runtime=` and `outcome=` for each run.

## Language

The factory speaks English unless told otherwise. Two keys change that, each a code of the twelve languages the dashboard ships in: `en` (default), `zh-CN`, `zh-TW`, `es`, `ja`, `de`, `fr`, `pt-BR`, `ru`, `ko`, `it` and `tr`.

- `language` in a project's `.shipfloor/factory.yml`: what people read about that project. The agents write specs, comments, reports and review pages in it; the gates' messages and what the deploy logs and posts on the card come out in it. This machine can override it per project in Settings > Language.
- `language` in `~/.shipfloor/config.yml`: this machine. The dashboard and the dispatcher's own log lines. It can also be set in Settings > Language, which lists every language under its own name (`Español`, `日本語`).

What other code reads stays in English whatever the language: commit messages, the spec's `##` headings, the markers on a card (`staged-head:`, `deploy-merge:`, `deploy-fix:`, "Factory report"), labels, and the board's column names on GitHub (the dashboard shows them translated). What the scripts say is translated by `scripts/lang/<code>.sed` and the notifications by `scripts/lang/notify.<code>.json`; only `pt-BR` has those today, and a language without them has the scripts speak English.

### The dashboard's catalogs

Every string the dashboard shows is a message in `scripts/lang/dashboard.<code>.json`, asked for by a stable key (`"tab.log": "Log"`). English is one of these catalogs, not the key: rewording an English message changes nothing in the others, and a key a catalog lacks comes out in English. A message takes values by name (`"#{n} moved to {column}."`) and plural forms by [`Intl.PluralRules`](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Intl/PluralRules) (`"{n, plural, one {# card} other {# cards}}"`, `#` is the number); it may keep the page's own markup (`<code>`, `<b>`). Dates, times, amounts and token counts are formatted by `Intl` in the page's language, and the page declares that language (`<html lang>`), so the browser picks the right glyphs and case rules. Card titles, logs and what the agents wrote are shown as written.

To add a language:

1. Copy `scripts/lang/dashboard.en.json` to `scripts/lang/dashboard.<code>.json`, with `<code>` a BCP 47 tag (`nl`, `pt-PT`). Set `name` to the language's name written in itself and translate every message of `messages`, keeping each `{value}`, the plural syntax with the forms the language needs, and the markup.
2. Add the code to `LANGS` in `scripts/shipfloor_config.py`, with its English name: the agents read that name to know what to write in.
3. Optionally, `scripts/lang/<code>.sed` and `scripts/lang/notify.<code>.json`, as `pt-BR`'s, for what the scripts say.
4. Run `bash scripts/test/dashboard-catalog.test.sh`. It fails when a catalog lacks a key the English one has, carries one it does not, drops or renames a value, lacks a plural form its language needs (add the language to `NEEDS` there), or changes the markup; and when the English catalog lacks a key the page or the server asks for, or keeps one nothing asks for. A language with a right-to-left script needs a mirrored layout the page does not have yet.

A new string on the page is a new key in `dashboard.en.json`, asked for with `t("key", {values})` (`ta()` inside an attribute), and the same key in every other catalog; a server refusal the page shows carries its key too (`shipfloor_config.Msg`).
