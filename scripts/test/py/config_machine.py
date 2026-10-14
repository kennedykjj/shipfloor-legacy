"""~/.shipfloor/config.yml, the machine's own settings, through shipfloor-config.sh machine in process: the pool and
stage runs, stack slots, notify, costs, working hours, the dispatcher's pace, and the models each stage and agent runs
on (stage-models, models-check, describe's `agent models:` line)."""
import os
import re
from unittest import mock

from config_support import ConfigCase, FIXTURE_YML

import shipfloor_config

DEF = "sonnet|sonnet|sonnet|sonnet|sonnet|opus|sonnet|sonnet|sonnet|sonnet|sonnet|sonnet|"  # develop's heavy on opus
UNKNOWN = '"gpt" is not a model the factory knows (opus, sonnet, haiku, fable)'


class MachineCase(ConfigCase):
    def vals(self):
        return self.values("pool", "stages.refine", "stages.develop", "stages.validate", "stages.deploy")

    def bad(self, text, *want):
        self.conf(text)
        rc, _, err = self.mach("validate")
        self.assertEqual(rc, 1, "validate accepted %r" % text)
        for w in want:
            self.assertIn(w, err)
        return err

    def good(self, text):
        self.conf(text)
        self.assertEqual(self.mach("validate"), (0, "", ""), text)


class Machine(MachineCase):
    def test_defaults_and_merge(self):
        "no file: the defaults; a file's values merged over them"
        self.assertEqual(self.vals(), "4 2 2 2 1 ")
        self.assertEqual(self.mach("validate")[0], 0)
        self.conf("pool: 6\nstages: {develop: 3}")
        self.assertEqual(self.vals(), "6 2 3 2 1 ")
        rc, out, _ = self.mach("show")
        self.assertEqual((rc, out), (0, "pool: 6\n  refine: 2\n  develop: 3\n  validate: 2\n  deploy: 1\nstacks: 3\n"))

    def test_pool_refusals(self):
        "a bad pool or stage is refused, and an unusable machine config is never read as a limit (exit 2)"
        self.bad("pool: 0", "pool must be an integer >= 1")
        self.bad("pool: two", "pool must be an integer >= 1")
        self.bad("pool: 2\nstages: {develop: 3}", "stages.develop (3) is above the pool (2)")
        self.bad("pool: 1", "stages.refine defaults to 2, above the pool (1): set it")
        self.bad("pool: 4\nstages: {review: 1}", "stages.review: unknown stage (use refine, develop, validate, deploy)")
        self.bad("pool: 4\nstages: {refine: -1}", "stages.refine must be an integer >= 0")
        self.bad("stages: 3", "stages must be a mapping of stage: runs")
        self.bad("[unclosed", "not valid YAML: ")
        self.bad("- 1", "the file is not a YAML mapping")
        self.bad("language: xx", "language must be one of en, ")
        rc, _, err = self.mach("values", "pool")
        self.assertEqual(rc, 2)
        self.assertIn("config.yml is invalid: language must be one of en, ", err)

    def test_set(self):
        "set writes a value and keeps the others and the file's other keys; a refused set changes nothing"
        self.conf("# my machine\npool: 4\nstages: {refine: 1}")
        self.assertEqual(self.mach("set", "pool", "6")[0], 0)
        self.assertEqual(self.mach("set", "stages.validate", "3")[0], 0)
        self.assertEqual(self.vals(), "6 1 2 3 1 ")
        for argv, want in ((("stages.validate", "9"), "stages.validate (9) is above the pool (6)"),
                           (("stages.review", "1"), "stages.review: unknown stage"),
                           (("pool", "x"), "x is not an integer"),
                           (("dispatcher.every_min", "5"), "cannot set dispatcher.every_min (pool, stacks, stack_wait, "
                                                           "stack_stale, stack_hold_max or stages.<stage>)")):
            rc, _, err = self.mach("set", *argv)
            self.assertEqual(rc, 1, argv)
            self.assertIn(want, err)
        self.assertEqual(self.vals(), "6 1 2 3 1 ")
        self.conf("stages: 3")
        self.assertEqual(self.mach("set", "stages.develop", "1")[0], 0, "a stages that is not a mapping is replaced")
        self.conf("[unclosed")
        rc, _, err = self.mach("set", "pool", "3")
        self.assertEqual(rc, 1)
        self.assertIn("is not valid YAML; fix it by hand", err)

    def test_stacks(self):
        "stack slots and their timers have defaults and are validated like the pool"
        self.assertEqual(self.values("stacks", "ports.base", "ports.span", "stack_wait", "stack_stale", "stack_hold_max"),
                         "3 20000 20 1800 90 2700 ")
        self.bad("stacks: 0", "stacks must be an integer >= 1")
        self.bad("ports: {base: 70000, span: 20}", "ports: base .. base + span * stacks must fit in 1024..65535")
        self.bad("ports: {base: x}", "ports.base and ports.span must be integers >= 1")
        self.bad("ports: 3", "ports must be a mapping {base, span}")
        self.bad("stack_wait: x", "stack_wait must be an integer >= 1")

    def test_notify(self):
        "the notify block: defaults without it, and every value checked"
        self.assertEqual(self.values("notify.reminder_min", "notify.events.done", "notify.channels.toast"), "60 false true ")
        self.bad("notify: {reminder_min: 14}", "The reminder takes 15 to 720 minutes.")
        self.bad('notify: {quiet: "08:00-08:00"}', "Quiet hours need both times, and they cannot be the same.")
        self.bad('notify: {ntfy_topic: "has space"}', "The topic takes letters, digits, - and _, up to 64.")
        self.bad("notify: {channels: {ntfy: true}}", "The phone push needs a topic.")
        self.bad("notify: {events: {launch: true}}", "notify.events.launch: unknown setting")
        self.bad("notify: {events: {done: 1}}", "notify.events.done must be true or false")
        self.bad("notify: {channels: 3, ntfy_topic: t}", "notify.channels must be a mapping")
        self.bad("notify: {colour: red}", "notify.colour: unknown setting")
        self.bad("notify: 3", "notify must be a mapping")
        self.good('notify: {quiet: "23:00-08:00", ntfy_topic: abc_1-2, channels: {ntfy: true}}')

    def test_notify_channels_not_a_mapping_without_topic(self):
        "AC-1 channels a list or a string and no ntfy_topic: validate names the key, no traceback, exit 1"
        for channels in ("[toast]", "toast", "3", "[]"):
            for topic in ("", ', ntfy_topic: ""'):
                self.conf("notify: {channels: %s%s}" % (channels, topic))
                rc, _, err = self.mach("validate")
                self.assertEqual(rc, 1, "%s%s" % (channels, topic))
                self.assertIn("notify.channels must be a mapping", err)
                self.assertNotIn("Traceback", err)

    def test_notify_valid_unchanged(self):
        "AC-3 channels a mapping with or without a topic, or no channels at all: validate is silent and exits 0"
        self.good("notify: {channels: {toast: true}}")
        self.good("notify: {channels: {ntfy: true}, ntfy_topic: abc_1}")
        self.good("notify: {channels: {toast: false}, ntfy_topic: abc_1}")
        self.good("notify: {reminder_min: 30}")
        self.bad("notify: {channels: {ntfy: true}}", "The phone push needs a topic.")


class Costs(MachineCase):
    """costs: optional limits in US$, no defaults; each a number > 0, card_warn <= card_block, no other key."""

    def cv(self):
        return self.values("costs.card_warn", "costs.card_block", "costs.day_stop", sep="|")

    def test_read(self):
        "AC-7/AC-8 no costs reads empty; the limits read back, decimals too, the missing ones empty"
        self.assertEqual(self.cv(), "|||")
        for text, want in (("costs:\n  card_warn: 20\n  card_block: 40\n  day_stop: 80", "20|40|80|"),
                           ("costs:\n  card_warn: 12.5\n  card_block: 40.25\n  day_stop: 80.5", "12.5|40.25|80.5|"),
                           ("costs:\n  day_stop: 80", "||80|")):
            self.good(text)
            self.assertEqual(self.cv(), want)
        for text in ("costs:\n  card_warn: 20", "costs:\n  card_block: 40", "costs:\n  card_warn: 40\n  card_block: 40",
                     "pool: 4\ncosts: {}"):
            self.good(text)

    def test_refused(self):
        "a limit at or below 0, not a number, an unknown key, warn above block or a costs that is no mapping is refused"
        for text in ("card_warn: 0", "card_block: -5", "day_stop: 0", "day_stop: lots", "card_block: true", "card_warn: [20]"):
            self.bad("costs:\n  " + text, "costs.%s must be a number above 0" % text.split(":")[0])
        self.bad("costs:\n  card_warn: 50\n  card_block: 40", "costs.card_warn (50) is above costs.card_block (40)")
        self.bad("costs:\n  card_stop: 10", "costs.card_stop: unknown limit (use card_warn, card_block, day_stop)")
        self.bad("costs:\n  day_stop: 80\n  daily: 5", "costs.daily: unknown limit")
        self.bad("costs: 5", "costs must be a mapping of limit: US$")
        self.bad("costs:\n  - 10", "costs must be a mapping of limit: US$")
        self.conf("costs:\n  card_warn: 50\n  card_block: 40")
        self.assertEqual(self.mach("values", "costs.card_block")[0], 2, "an invalid costs section is never read as a limit")


class Disk(MachineCase):
    """disk: the floor under which the dispatcher starts no run (min_free_gb 2, min_free_inodes_pct 10 by default)."""

    def test_read(self):
        "the defaults read back; a file's values win; 0 is allowed (that check is off)"
        self.assertEqual(self.values("disk.min_free_gb", "disk.min_free_inodes_pct", sep="|"), "2|10|")
        self.good("disk: {min_free_gb: 5.5, min_free_inodes_pct: 0}")
        self.assertEqual(self.values("disk.min_free_gb", "disk.min_free_inodes_pct", sep="|"), "5.5|0|")

    def test_refused(self):
        "a negative or non-number floor, inodes above 100, an unknown key or a disk that is no mapping is refused"
        self.bad("disk: {min_free_gb: -1}", "disk.min_free_gb must be a number from 0")
        self.bad("disk: {min_free_gb: lots}", "disk.min_free_gb must be a number from 0")
        self.bad("disk: {min_free_inodes_pct: 101}", "disk.min_free_inodes_pct must be a number from 0 to 100")
        self.bad("disk: {min_free_gb: true}", "disk.min_free_gb must be a number from 0")
        self.bad("disk: {free: 1}", "disk.free: unknown key (use min_free_gb, min_free_inodes_pct)")
        self.bad("disk: 5", "disk must be a mapping of min_free_gb, min_free_inodes_pct")


class Limits(MachineCase):
    """limits: the dispatcher's optional memory and CPU ceilings; `machine limits` prints the systemd lines."""

    def lines(self, *flags):
        rc, out, err = self.mach("limits", *flags)
        return rc, out.splitlines(), err

    def test_directives(self):
        "no limits prints nothing; the file's limits become directives, MemoryHigh at 90%; flags win over the file"
        self.assertEqual(self.lines(), (0, [], ""))
        self.conf("limits: {memory_max: 10G, cpu_weight: 200, cpu_quota: 150%}")
        self.assertEqual(self.lines(), (0, ["MemoryMax=10G", "MemoryHigh=9437184K", "CPUWeight=200", "CPUQuota=150%"], ""))
        self.assertEqual(self.lines("--memory-max", "4G", "--cpu-weight", "none", "--cpu-quota", "none"),
                         (0, ["MemoryMax=4G", "MemoryHigh=3774873K"], ""))
        self.conf("limits: {memory_max: none, cpu_weight: none, cpu_quota: none}")
        self.assertEqual(self.lines(), (0, [], ""))
        self.assertEqual(self.lines("--cpu-weight", "50")[1], ["CPUWeight=50"])

    def test_normalized(self):
        "machine_limits fills none for what is missing"
        self.assertEqual(shipfloor_config.machine_limits(None), {"memory_max": "none", "cpu_weight": "none", "cpu_quota": "none"})
        self.assertEqual(shipfloor_config.machine_limits({"cpu_weight": 100, "cpu_quota": None}),
                         {"memory_max": "none", "cpu_weight": "100", "cpu_quota": "none"})

    def test_refused(self):
        "every problem names limits.<field>, in the file and in a flag (exit 2)"
        for text, field in (("cpu_weight: 0", "cpu_weight"), ("cpu_weight: 10001", "cpu_weight"), ("cpu_weight: abc", "cpu_weight"),
                            ("memory_max: lots", "memory_max"), ("memory_max: 8X", "memory_max"), ("memory_max: 8", "memory_max"),
                            ("cpu_quota: fast", "cpu_quota"), ("cpu_quota: 0%", "cpu_quota"), ("cpu_quota: 99999%", "cpu_quota")):
            self.bad("limits: {%s}" % text, "limits.%s " % field)
        self.bad("limits: {speed: 1}", "limits.speed: unknown limit")
        self.bad("limits: 5", "limits must be a mapping")
        self.conf("")
        for flag, field in (("--cpu-weight", "cpu_weight"), ("--memory-max", "memory_max"), ("--cpu-quota", "cpu_quota")):
            rc, out, err = self.lines(flag, "0x")
            self.assertEqual((rc, out), (2, []))
            self.assertIn("limits.%s " % field, err)


class Hours(MachineCase):
    """working hours: `machine hours` says open, or closed and when the next window starts; the clock is SHIPFLOOR_NOW."""

    def at(self, hhmm):
        os.environ["SHIPFLOOR_NOW"] = hhmm
        rc, out, _ = self.mach("hours")
        self.assertEqual(rc, 0, "closed or open, it exits 0")
        return out.strip()

    def table(self, hours, rows):
        self.conf(hours)
        for hhmm, want in rows:
            self.assertEqual(self.at(hhmm), want, "%s at %s" % (hours, hhmm))

    def test_one_window(self):
        "AC-1/AC-2 one window: includes its start, excludes its end; closed names the next start"
        self.table('hours: ["08:00-23:00"]', [("23:30", "closed 08:00"), ("08:00", "open"), ("23:00", "closed 08:00"),
                                              ("07:59", "closed 08:00"), ("12:00", "open")])

    def test_midnight(self):
        "AC-3 a window across midnight"
        self.table('hours: ["20:00-04:00"]', [("02:00", "open"), ("23:59", "open"), ("04:00", "closed 20:00"),
                                              ("12:00", "closed 20:00")])

    def test_two_windows(self):
        "two windows: the next start is the nearest coming one, tomorrow's first after the last"
        self.table('hours: ["06:00-08:00", "20:00-23:00"]', [("12:00", "closed 20:00"), ("23:30", "closed 06:00"), ("07:00", "open")])
        self.table('hours: ["00:00-23:59"]', [("12:00", "open")])

    def test_always_open(self):
        "AC-8 an empty list, or no hours, is always open"
        self.table("hours: []", [("03:00", "open")])
        self.table(None, [("03:00", "open")])

    def test_malformed(self):
        "AC-5 a malformed hours is reported by name and ignored: validate exits 0, open at all hours"
        for bad in ('hours: "08:00-23:00"', 'hours: ["8-23"]', 'hours: ["08:00-08:00"]', 'hours: ["24:00-25:00"]',
                    'hours: ["08:00-23:60"]', 'hours: ["08:00-23:00", 5]', "hours: 8"):
            self.conf(bad)
            rc, _, err = self.mach("validate")
            self.assertEqual(rc, 0, bad)
            self.assertRegex(err, r"hours.*; ignored, runs start at all hours", bad)
            self.assertEqual(self.at("23:30"), "open", bad)
        self.conf('pool: 6\nhours: ["8-23"]')
        self.assertEqual(self.vals(), "6 2 2 2 1 ", "a malformed hours leaves the other values usable")
        self.conf('pool: 0\nhours: ["8-23"]')
        self.assertEqual(self.mach("validate")[0], 1, "another problem next to a bad hours still exits 1")


class Dispatcher(MachineCase):
    """the dispatcher's pace: 1, 3, 5 or 10 minutes, 3 when missing; anything else names the key and the values."""

    def test_pace(self):
        "AC-5 every_min defaults to 3 and reads back 1, 3, 5 and 10"
        self.assertEqual(self.values("dispatcher.every_min"), "3 ")
        for v in (1, 3, 5, 10):
            self.good("dispatcher: {every_min: %d}" % v)
            self.assertEqual(self.values("dispatcher.every_min"), "%d " % v)
            self.assertEqual(shipfloor_config.dispatcher_every({"dispatcher": {"every_min": v}}), v)
        self.assertEqual(shipfloor_config.dispatcher_every({"dispatcher": {"every_min": True}}), 3)

    def test_refused(self):
        "AC-5 any other every_min, or a dispatcher that is no mapping, is a machine problem"
        for v in ("0", "2", "7", "15", "true", '"5"', "3.5"):
            self.bad("dispatcher: {every_min: %s}" % v, "dispatcher.every_min must be 1, 3, 5 or 10")
        self.bad("dispatcher: 5", "dispatcher must be a mapping")


class Models(MachineCase):
    """Which model runs each stage and each agent is config.yml's `models` map, not code (#34)."""

    def sm(self):
        rc, out, err = self.mach("stage-models")  # each stage x light|standard|heavy
        self.assertEqual(rc, 0, err)
        return out.replace("\0", "|")

    def check(self, *agents):
        rc, _, err = self.mach("models-check", *agents)
        return rc, err

    def describe(self, config=FIXTURE_YML):
        """describe, with the machine config of $SHIPFLOOR_HOME beside the projects folder."""
        home = os.path.join(os.environ["SHIPFLOOR_HOME"], "projects", "shop")
        return self.out("--home", home, "describe", config=config)

    def project_with_reviewer(self):
        return self.yml("project: {name: shop, repo: acme/shop}\nboard: {owner: acme, number: 7}\nlayers:\n"
                        "  - {name: api, path: 'api/', agent: reviewer, test: 't {selector}', ran: 'ok', tests: ['api/t/**']}\n")

    def test_shipped(self):
        "AC-2 no file, no models key, an empty map or only agents: the shipped models"
        for text in (None, "pool: 4", "models: {}", "models:\n  agents: {engineer: haiku}"):
            self.conf(text)
            self.assertEqual(self.sm(), DEF, text)

    def test_stages(self):
        "AC-2 a stage set takes every weight, the others keep theirs; a mapping sets weights; model-up climbs the ladder"
        self.conf("models:\n  stages: {develop: sonnet}")
        self.assertEqual(self.sm(), "sonnet|" * 12)
        self.conf("models:\n  stages: {validate: opus, deploy: haiku, refine: fable}")
        self.assertEqual(self.sm(), "fable|fable|fable|sonnet|sonnet|opus|opus|opus|opus|haiku|haiku|haiku|")
        self.conf("models:\n  stages: {develop: {light: haiku}}")
        self.assertEqual(self.sm(), "sonnet|sonnet|sonnet|haiku|sonnet|opus|" + "sonnet|" * 6)
        self.assertEqual([self.mach("model-up", m)[1] for m in ("haiku", "sonnet", "opus", "fable")], ["sonnet\n", "opus\n", "", ""])

    def test_runtime_models_and_ladder(self):
        "a stage off claude-code takes runtime.models (a name as written, no model = none) and climbs runtime.ladder; the project's over the machine's"
        names = ("claude-code", "codex")
        with mock.patch.object(shipfloor_config.runtimes, "NAMES", names):
            machine = {"runtime": {"default": "codex", "models": {"stages": {"develop": "gpt-6-mini", "refine": "gpt-6"}},
                                   "ladder": ["gpt-6-mini", "gpt-6-sol"]}}
            self.assertEqual(shipfloor_config.runtime_problems(machine["runtime"]), [])
            got = shipfloor_config.runtime_stage_models(machine, {"runtime": {"stages": {"deploy": "claude-code"},
                                                                              "models": {"stages": {"develop": {"heavy": "gpt-6-sol"}}}}})
            self.assertEqual(got["refine"], dict.fromkeys(shipfloor_config.WEIGHTS, "gpt-6"))
            self.assertEqual(got["develop"], {"light": "", "standard": "", "heavy": "gpt-6-sol"})
            self.assertEqual(got["validate"], dict.fromkeys(shipfloor_config.WEIGHTS, ""))
            self.assertNotIn("deploy", got)
            ladder = tuple(shipfloor_config.runtime_setting(machine, None, "ladder"))
            self.assertEqual([shipfloor_config.model_up(m, ladder) for m in ("gpt-6-mini", "gpt-6-sol", "other")], ["gpt-6-sol", None, None])
            self.assertEqual(shipfloor_config.model_up("x", ()), None)
            for bad in ({"ladder": "gpt-6"}, {"ladder": [""]}, {"models": {"stages": {"develop": ""}}}, {"models": {"nope": {}}},
                        {"models": {"stages": {"build": "x"}}}, {"models": {"stages": {"refine": {"light": "x"}}}}):
                self.assertTrue(shipfloor_config.runtime_problems(bad), bad)

    def test_constants(self):
        "the shipped models and every plugin agent's default, which agents/*.md's model: line must match"
        self.assertEqual(shipfloor_config.MODELS, ("opus", "sonnet", "haiku", "fable"))
        self.assertEqual(shipfloor_config.STAGE_MODELS, {
            "refine": "sonnet", "develop": {"light": "sonnet", "standard": "sonnet", "heavy": "opus"},
            "validate": {"light": "sonnet", "standard": "sonnet", "heavy": "sonnet"},
            "deploy": {"light": "sonnet", "standard": "sonnet", "heavy": "sonnet"}})
        agents = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(shipfloor_config.__file__))), "agents")
        want = {}
        for f in sorted(os.listdir(agents)):
            if f.endswith(".md"):
                t = open(os.path.join(agents, f), encoding="utf-8").read()
                want[re.search(r"^name:\s*(\S+)", t, re.M).group(1)] = re.search(r"^model:\s*(\S+)", t, re.M).group(1)
        self.assertEqual(shipfloor_config.PLUGIN_AGENTS, want)

    def test_describe_line(self):
        "AC-3 describe's agent models: line, after language:, only when an agent's model is set and valid"
        self.conf("models:\n  agents: {engineer: haiku}")
        d = self.describe()
        self.assertIn("agent models: engineer=haiku", d)
        self.assertRegex(d, r"(?s)language:.*agent models:.*stack:")
        self.conf("models:\n  agents: {engineer: haiku, qa-engineer: opus}")
        self.assertIn("agent models: engineer=haiku, qa-engineer=opus", self.describe())
        for text in ("models:\n  stages: {develop: sonnet}", None, "models:\n  agents: {engineer: gpt}"):
            self.conf(text)
            self.assertNotIn("agent models:", self.describe(), text)
        self.conf("models:\n  agents: {engineer: gpt, qa-engineer: opus}")
        d = self.describe()
        self.assertIn("agent models: qa-engineer=opus", d)
        self.assertNotIn("engineer=gpt", d)
        self.conf("[unclosed")
        self.assertNotIn("agent models:", self.describe())

    def test_project_agent(self):
        "AC-4 an agent a layer names is accepted and printed for that project only"
        proj = self.project_with_reviewer()
        self.assertEqual(self.cfg("validate", config=proj)[0], 0)
        self.conf("models:\n  agents: {reviewer: haiku}")
        self.assertIn("agent models: reviewer=haiku", self.describe(proj))
        self.assertNotIn("agent models:", self.describe())
        self.assertEqual(self.check("reviewer"), (0, ""))
        rc, err = self.check()
        self.assertEqual(rc, 1)
        self.assertIn("models.agents.reviewer: not a stage or an agent here", err)
        self.assertEqual(self.mach("validate")[0], 0)

    def test_problems(self):
        "AC-5 an unknown model, stage, agent, weight or shape is reported with its key, never an invalid config.yml"
        cases = [
            ("models:\n  agents: {engineer: gpt}", ["models.agents.engineer: " + UNKNOWN]),
            ("models:\n  stages: {develop: gpt, validate: gpt}", ["models.stages.develop: " + UNKNOWN, 'models.stages.validate: "gpt"']),
            ("models:\n  stages: {review: opus}", ["models.stages.review: not a stage or an agent here"]),
            ("models:\n  agents: {nobody: opus}", ["models.agents.nobody: not a stage or an agent here"]),
            ("models:\n  stages: {develop: {huge: opus, light: gpt}}", ["models.stages.develop.huge: not a weight (light, standard, heavy)",
                                                                        "models.stages.develop.light: " + UNKNOWN]),
            ("models:\n  stages: {refine: {light: opus}}", ["models.stages.refine: must be one model (Refine runs before the card has a weight)"]),
            ("models: 3", ["models: must be a mapping"]),
            ("models:\n  stages: 3", ["models.stages: must be a mapping"]),
        ]
        for text, want in cases:
            self.conf(text)
            rc, err = self.check()
            self.assertEqual(rc, 1, text)
            for w in want:
                self.assertIn(w, err)
            self.assertEqual(self.mach("validate")[0], 0, text)
            self.assertEqual(self.sm(), DEF, "%s: the bad entry runs on today's model" % text)
        self.conf("models:\n  stages: {develop: opus, deploy: gpt}")
        self.assertEqual(self.sm(), "sonnet|sonnet|sonnet|opus|opus|opus|" + "sonnet|" * 6, "the valid stage keeps its model")
        self.conf("models:\n  stages: {develop: haiku}\n  agents: {engineer: opus, qa-engineer: sonnet}")
        self.assertEqual(self.check(), (0, ""), "a valid models map is silent")

    def test_usage(self):
        "an unknown machine command is unusable (exit 2) with the usage"
        rc, _, err = self.mach("bogus")
        self.assertEqual(rc, 2)
        self.assertIn("usage: machine validate | values <key>... | show | hours | set <key> <int>", err)
