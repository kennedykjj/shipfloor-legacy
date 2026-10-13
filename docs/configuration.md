# Configuring Shipfloor

What this machine runs at once, what it may spend, when it works and how it tells you. Back to the [README](../README.md).

## Agent pool

Each pipeline run is one agent. `~/.shipfloor/config.yml` sets how many run at once on the machine, across all projects, and how many each stage may take (absolute numbers):

```yaml
pool: 4
stages: {refine: 2, develop: 2, validate: 2, deploy: 1}
```

`shipfloor pool` shows it and the runs in progress; `shipfloor pool set 6` and `shipfloor pool stage validate 3` change it. A project runs one deploy at a time (merges into main are serial); its `limits.<stage>.wip` in `factory.yml` caps the cards waiting in Spec Review (refine, default 2) and in Coding + Validation (develop, default 4).

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

## Language

The factory speaks English unless told otherwise. Two keys change that, each `en` (default) or `pt-BR`:

- `language` in a project's `.shipfloor/factory.yml`: what people read about that project. The agents write specs, comments, reports and review pages in it; the gates' messages and what the deploy logs and posts on the card come out in it.
- `language` in `~/.shipfloor/config.yml`: this machine. The dashboard and the dispatcher's own log lines. It can also be set in Settings > Language, which shows each project's language too (read-only).

What other code reads stays in English whatever the language: commit messages, the spec's `##` headings, the markers on a card (`staged-head:`, `deploy-merge:`, `deploy-fix:`, "Factory report"), labels, and the board's column names on GitHub (the dashboard shows them translated). The scripts and the page are written in English and translated where their text leaves them, by the catalogs in `scripts/lang/` (`<code>.sed` for the scripts, `dashboard.<code>.json` for the page): a phrase with no entry there comes out in English, and a new language is a new pair of files plus its code in `LANGS` (`scripts/shipfloor_config.py`).
