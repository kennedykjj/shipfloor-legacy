"""The runtime contract (scripts/runtimes/, #149): which runtimes a machine and a project name (`runtime`: nothing, a
string or a map; the project over the machine key by key; every invalid form refused with the known runtimes listed,
and a dispatch that exits 2 on it), the claude-code adapter's outcome and doctor line, the `outcome=` the run log ends
on, and the one pause rule every reader of the log shares (dispatch, the scheduled dispatcher, the dashboard and, by
it, health). Only claude-code exists, so a second name is put in runtimes.NAMES by the tests that need one."""
import os
import re
import time
from unittest import mock

import config_support as cs
import dispatch_support as ds
import dashboard
import fake_llm
from shipfloor_core import cycle as cyclemod

LIMIT = "You've hit your session limit · resets 6pm\n"
START_NEW = "== start /sf:develop 5 2026-10-14T10:00:00-03:00 pid=1 model=sonnet weight=standard runtime=claude-code\n"
START_OLD = "== start /sf:develop 5 2026-10-14T10:00:00-03:00 pid=1 model=sonnet weight=standard\n"


def end(outcome=None, rc=0):
    return "== end /sf:develop 5 exit=%d 2026-10-14T10:20:00-03:00%s\n" % (rc, " outcome=" + outcome if outcome else "")


def runtimes():
    import runtimes as rt
    return rt


def names(out):
    return [n for n in out.split("\0") if n]


class Config(cs.ConfigCase):
    def known(self, *extra):
        """runtimes.NAMES with more names in it (the tests' second runtime)."""
        return mock.patch.object(runtimes(), "NAMES", ("claude-code",) + extra)

    def of(self, machine=None, project=None):
        """`machine runtimes [<factory.yml>]`: the runtime of refine, develop, validate, deploy."""
        self.conf(machine)
        argv = ["runtimes"]
        if project:
            argv.append(self.yml(open(cs.FIXTURE_YML, encoding="utf-8").read() + "\n" + project + "\n"))
        rc, out, err = self.mach(*argv)
        self.assertEqual(rc, 0, err)
        return names(out)

    def test_AC1_no_runtime_is_claude_code(self):
        "AC-1 no runtime anywhere: claude-code runs every stage; the contract names claude-code first, then codex and opencode"
        self.assertEqual(self.of(None), ["claude-code"] * 4)
        self.assertEqual(self.of("pool: 4"), ["claude-code"] * 4)
        self.assertEqual(runtimes().NAMES, ("claude-code", "codex", "opencode"))
        self.assertEqual(runtimes().get("claude-code").NAME, "claude-code")

    def test_AC1_string_and_map(self):
        "AC-1 runtime as a string or as a map {default, stages}: the stage's own name, else the default, else the first"
        with self.known("fake"):
            self.assertEqual(self.of("runtime: fake"), ["fake"] * 4)
            self.assertEqual(self.of("runtime: {stages: {deploy: fake}}"), ["claude-code"] * 3 + ["fake"])
            self.assertEqual(self.of("runtime: {default: fake, stages: {develop: claude-code}}"),
                             ["fake", "claude-code", "fake", "fake"])

    def test_AC1_project_over_machine_key_by_key(self):
        "AC-1 the project's runtime overrides the machine's key by key, string or map"
        machine = "runtime: {default: fake, stages: {develop: claude-code, deploy: fake}}"
        with self.known("fake"):
            self.assertEqual(self.of(machine, "runtime: claude-code"), ["claude-code", "claude-code", "claude-code", "fake"])
            self.assertEqual(self.of(machine, "runtime: {stages: {refine: claude-code}}"),
                             ["claude-code", "claude-code", "fake", "fake"])
            self.assertEqual(self.of(None, "runtime: {default: fake}"), ["fake"] * 4)

    def test_AC1_invalid_forms(self):
        "AC-1 an unknown runtime, an unknown stage, a key beside default/stages or a wrong type is invalid, naming the known runtimes (machine and project)"
        for text in ("runtime: nope", "runtime: {default: nope}", "runtime: {stages: {develop: nope}}",
                     "runtime: {stages: {review: claude-code}}", "runtime: {models: {x: y}}", "runtime: {provider: x}",
                     "runtime: 3", "runtime: [claude-code]", "runtime: {stages: claude-code}"):
            self.conf("pool: 4\n" + text)
            rc, _, err = self.mach("validate")
            self.assertEqual(rc, 1, "machine validate accepted %r" % text)
            self.assertIn("runtime", err, text)
            self.assertIn("claude-code", err, text)
            rc, _, err = self.mach("runtimes")
            self.assertEqual(rc, 2, "a machine config that is invalid is never read: %r" % text)
            cfg = self.yml(open(cs.FIXTURE_YML, encoding="utf-8").read() + "\n" + text + "\n")
            rc, _, err = self.raw("validate", config=cfg)
            self.assertEqual(rc, 1, "project validate accepted %r" % text)
            self.assertIn("runtime", err, text)
            self.assertIn("claude-code", err, text)


class Dispatch(ds.DispatchCase):
    def test_AC1_invalid_runtime_stops_the_dispatch(self):
        "AC-1 a runtime nobody knows in the machine or the project config: exit 2, the known runtimes in the message, no agent started"
        self.board(queues={"Ready for Dev": 54})
        for where, text in (("machine", "runtime: nope"), ("machine", "runtime: {stages: {review: claude-code}}"),
                            ("project", "runtime: {default: nope}"), ("project", "runtime: {models: {a: b}}")):
            self.machine_cfg(ds.POOL8 + ("\n" + text if where == "machine" else ""))
            self.project_cfg(open(ds.FIXTURE_CONFIG, encoding="utf-8").read() + ("\n" + text if where == "project" else ""))
            self.assertEqual(self.cycle(), 2, (where, text, self.err, self.out))
            self.assertIn("claude-code", self.err + self.out, "the message lists the known runtimes")
            self.assertEqual((self.claude_calls(), self.launches), ([], []), "no fallback to another CLI")


class Adapter(ds.DispatchCase):
    def outcome(self, rc, text):
        fn = runtimes().get("claude-code").outcome
        try:
            return fn(rc, text)
        except (TypeError, AttributeError):  # the block as bytes
            return fn(rc, text.encode())

    def test_AC3_claude_code_outcome(self):
        "AC-3 the adapter's outcome: usage_limit when the block says the limit (even on exit 0), else ok on exit 0, else fail"
        self.assertEqual(self.outcome(0, "all fine\n"), "ok")
        self.assertEqual(self.outcome(3, "all fine\n"), "fail")
        self.assertEqual(self.outcome(0, "x\n" + LIMIT), "usage_limit")
        self.assertEqual(self.outcome(1, "x\n" + LIMIT), "usage_limit")

    def test_AC5_doctor_line(self):
        "AC-5 the adapter's doctor names itself and the binary: claude-code: claude"
        self.double("claude", "")
        os.environ.pop("FACTORY_CLAUDE", None)
        self.assertEqual(runtimes().get("claude-code").doctor(), [(True, "claude-code: claude")])

    def test_AC8_runs_and_their_log(self):
        "AC-3/AC-8 the log of a run: == start carries runtime=claude-code, == end ends on outcome=ok|fail|usage_limit"
        self.machine_cfg(ds.POOL8)
        self.board(queues={"Ready for Dev": "54 55 56 57"})
        self.set_fake(claude={"cards": {"55": {"exit": 3}, "56": {"say": LIMIT.strip()},
                                        "57": {"say": LIMIT.strip(), "exit": 1}}})
        self.assertEqual(self.cycle(), 0, self.err)
        got = {}
        for n in ("54", "55", "56", "57"):
            lines = self.log("develop", n).splitlines()
            self.assertRegex(lines[0], r" weight=standard runtime=claude-code$")
            got[n] = re.search(r" outcome=(\S+)$", lines[-1]).group(1) if re.search(r" outcome=", lines[-1]) else None
            self.assertRegex(lines[-1], r"^== end /sf:develop %s exit=\d+ %s outcome=" % (n, ds.ISO))
        self.assertEqual(got, {"54": "ok", "55": "fail", "56": "usage_limit", "57": "usage_limit"})


class Pause(ds.DispatchCase):
    """One log, four readers: the dispatcher's own cycle, the scheduled dispatcher (cycle.py), and the dashboard
    (whose Factory.usage_limited health inherits)."""

    def verdicts(self, text):
        self.usage_log(text=text)
        shome = self.shome
        scheduled = cyclemod.usage_limited(shome)
        shown = dashboard.Factory(shome, self.path("claude")).usage_limited()
        self.board(queues={"Ready for Dev": 26})
        self.launches = []
        for d in os.listdir(os.path.join(self.home, "locks")):
            os.rmdir(os.path.join(self.home, "locks", d))
        self.cycle(runs=False)
        dispatched = not self.launches and "usage limit hit recently" in self.out
        return scheduled, shown, dispatched

    def test_AC3_pause_rule(self):
        "AC-3/AC-8 the pause follows the outcome the run wrote: ok with the limit's text in the log does not pause, usage_limit does, an old log without outcome= pauses by its text"
        cases = [
            ("ok that quotes the limit", START_NEW + LIMIT + end("ok"), False),
            ("usage_limit without the text", START_NEW + "some other words\n" + end("usage_limit"), True),
            ("usage_limit with the text", START_NEW + LIMIT + end("usage_limit"), True),
            ("old log with the text", START_OLD + LIMIT + end(), True),
            ("old log without the text", START_OLD + "fine\n" + end(), False),
            ("fail", START_NEW + "boom\n" + end("fail", rc=1), False),
            ("only the last run counts", START_NEW + LIMIT + end("usage_limit") + START_NEW + "fine\n" + end("ok"), False),
            ("the last run is the one that hit it", START_NEW + "fine\n" + end("ok") + START_NEW + LIMIT + end("usage_limit"), True),
        ]
        wrong = []
        for name, text, want in cases:
            got = self.verdicts(text)
            if got != (want, want, want):
                wrong.append((name, "scheduled, dashboard, dispatch = %s, want %s" % (got, want)))
        self.assertEqual(wrong, [])

    def test_AC3_an_old_pause_ages_out(self):
        "AC-3 a usage_limit log older than 30 minutes no longer pauses"
        p = self.usage_log(text=START_NEW + end("usage_limit"))
        os.utime(p, (time.time() - 40 * 60,) * 2)
        self.assertFalse(cyclemod.usage_limited(self.shome))
        self.assertFalse(dashboard.Factory(self.shome, self.path("claude")).usage_limited())


class CodexUnits(ds.DispatchCase):
    """The codex runtime's own logic, called in-process: the limit's runtime, what the outcome ignores, the generated
    CODEX_HOME, the inbox hook in Codex's mode and the token reading."""

    def test_limited_runtime_is_the_start_lines(self):
        "the runtime a limit belongs to is the last == start line's runtime=; an old log without one is claude-code; no limit is None"
        rt = runtimes()
        start = "== start /sf:develop 5 2026-10-14T10:00:00-03:00 pid=1 weight=standard runtime=%s\n"
        self.assertEqual(rt.limited_runtime(start % "codex" + end("usage_limit")), "codex")
        self.assertEqual(rt.limited_runtime((start % "codex" + end("usage_limit")).encode()), "codex")
        self.assertEqual(rt.limited_runtime(START_OLD + LIMIT + end()), "claude-code")
        self.assertIsNone(rt.limited_runtime(start % "codex" + end("ok")))
        self.assertEqual((rt.label("codex"), rt.label("claude-code")), ("Codex", "Claude"))

    def test_outcome_ignores_the_commands_the_agent_ran(self):
        "a limit's words inside an item.* event (a file the agent read) are not the CLI speaking; an error event is"
        out = runtimes().get("codex").outcome
        quoted = '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"Quota exceeded"}}\n'
        self.assertEqual(out(0, quoted), "ok")
        self.assertEqual(out(1, quoted), "fail")
        self.assertEqual(out(1, quoted + '{"type":"error","message":"Quota exceeded"}\n'), "usage_limit")

    def test_generated_home(self):
        "codex_gen writes config, hooks, one agent file and one prompt per stage: codex blocks kept, others dropped, frontmatter out, the model from runtime.models.agents; a second run changes nothing; stale files go; auth.json stays"
        from runtimes import codex_gen
        src, home = self.path("plugin"), self.path("chome")
        self.write(os.path.join(src, "agents", "engineer.md"),
                   "---\nname: engineer\ndescription: Builds it\nmodel: sonnet\n---\n\nBody <!-- rt:codex -->for codex <!-- /rt --><!-- rt:other -->no<!-- /rt -->\n")
        self.write(os.path.join(src, "skills", "develop", "SKILL.md"),
                   "---\nname: develop\n---\n# Develop\n<!-- rt:codex -->\nCodex line\n<!-- /rt -->\n<!-- rt:claude-code -->\nClaude line\n<!-- /rt -->\n")
        self.write(os.path.join(home, "auth.json"), "secret")
        self.write(os.path.join(home, "agents", "old.toml"), "x")
        n = codex_gen.generate(src, home, "/scripts", {"engineer": "gpt-6-mini"}, python="/usr/bin/python3")
        self.assertGreaterEqual(n, 4)
        agent = open(os.path.join(home, "agents", "engineer.toml"), encoding="utf-8").read()
        self.assertIn('model = "gpt-6-mini"', agent)
        self.assertNotIn("sonnet", agent)
        self.assertIn("for codex", agent)
        self.assertNotIn("no<", agent)
        prompt = open(os.path.join(home, "sf", "develop.md"), encoding="utf-8").read()
        self.assertTrue(prompt.startswith("<!-- sf:stage=develop -->\n"))
        self.assertIn("Codex line", prompt)
        self.assertNotIn("Claude line", prompt)
        self.assertNotIn("name: develop", prompt)
        self.assertIn("inbox_hook.py --codex", open(os.path.join(home, "hooks.json"), encoding="utf-8").read())
        self.assertFalse(os.path.exists(os.path.join(home, "agents", "old.toml")))
        self.assertEqual(open(os.path.join(home, "auth.json")).read(), "secret")
        self.assertEqual(codex_gen.generate(src, home, "/scripts", {"engineer": "gpt-6-mini"}, python="/usr/bin/python3"), 0)

    def test_generated_from_the_real_skills_and_agents(self):
        "generating from the plugin's own skills and agents: every stage prompt has its stage marker, no rt: marker or frontmatter is left, and codex gets its own instructions instead of Claude's"
        import json
        from runtimes import codex_gen
        repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
        home = self.path("chome-real")
        codex_gen.generate(repo, home, "/scripts", python="/usr/bin/python3")
        for stage in codex_gen.STAGES:
            text = open(os.path.join(home, "sf", stage + ".md"), encoding="utf-8").read()
            self.assertTrue(text.startswith("<!-- sf:stage=%s -->\n" % stage), stage)
            self.assertNotIn("<!-- rt:", text, stage)
            self.assertNotIn("<!-- /rt", text, stage)
            self.assertNotIn("\nname: %s\n" % stage, text, stage)
            self.assertNotIn("Claude Opus", text, stage)
            self.assertNotIn("Agent tool", text, stage)
        for name in os.listdir(os.path.join(repo, "agents")):
            agent = open(os.path.join(home, "agents", name[:-3] + ".toml"), encoding="utf-8").read()
            instructions = json.loads(re.search(r"^developer_instructions = (.*)$", agent, re.M).group(1))
            self.assertNotIn("<!-- rt:", instructions, name)
            self.assertNotIn("<!-- /rt", instructions, name)
            self.assertNotIn("Claude Opus", instructions, name)
            self.assertIn("apply_patch" if name not in ("cybersec.md",) else "rg", instructions, name)

    def test_codex_hook_gives_each_agent_each_message_once(self):
        "inbox_hook --codex: the first session is the lead (inbox.lead), another session counts on its own; outside a run it says nothing"
        import io
        import json
        import inbox_hook
        lock = self.path("lock")
        self.write(os.path.join(lock, "inbox"), json.dumps({"text": "one"}) + "\n")

        def call(session):
            out = io.StringIO()
            with mock.patch.dict(os.environ, {"SHIPFLOOR_RUN_LOCK": lock}), \
                    mock.patch("sys.stdin", io.StringIO(json.dumps({"session_id": session}))), mock.patch("sys.stdout", out):
                inbox_hook.main(codex=True)
            return out.getvalue()

        first = json.loads(call("s1"))["hookSpecificOutput"]["additionalContext"]
        self.assertTrue(first.startswith(inbox_hook.INTRO) and first.endswith("one"))
        self.assertEqual(call("s1"), "", "the lead has read it")
        self.assertEqual(open(os.path.join(lock, "inbox.lead")).read(), "1")
        self.assertIn("one", call("s2"), "a subagent gets it too")
        self.assertEqual(call("s2"), "")
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("SHIPFLOOR_RUN_LOCK", None)
            with mock.patch("sys.stdin", io.StringIO("{}")):
                inbox_hook.main(codex=True)

    def test_tokens_follow_the_model_of_the_turn(self):
        "parse adds what the running total grew by to the model of the turn, cached input apart; a repeated total adds nothing"
        import json
        codex = runtimes().get("codex")
        rows = [{"timestamp": "2026-10-14T10:00:0%dZ" % i, "type": k, "payload": p} for i, (k, p) in enumerate([
            ("session_meta", {"id": "a", "cwd": "/x"}), ("turn_context", {"model": "m1"}),
            ("event_msg", {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10}}}),
            ("event_msg", {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10}}}),
            ("turn_context", {"model": "m2"}),
            ("event_msg", {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 150, "cached_input_tokens": 50, "output_tokens": 30}}}),
            ("event_msg", {"type": "token_count", "info": None})])]
        path = self.path("rollout.jsonl")
        self.write(path, "\n".join(json.dumps(r) for r in rows) + "\n")
        t = codex.parse(path)["tokens"]
        self.assertEqual((t["m1"]["input"], t["m1"]["cache_read"], t["m1"]["output"]), (60, 40, 10))
        self.assertEqual((t["m2"]["input"], t["m2"]["cache_read"], t["m2"]["output"]), (40, 10, 20))


KEY = "SF_LLM_KEY"
SECRET = "sk-selfhosted-151-7f3a9c"

# A codex that talks to the endpoint the way the real one does: base_url and env_key from the -c of the provider, the key
# from the environment; then it hands over to the recording fake codex.
LLM_CODEX = r'''
import os, re, subprocess, sys, urllib.request
data = sys.stdin.buffer.read()
args = sys.argv[1:]
cs = [args[i + 1] for i, a in enumerate(args) if a == "-c"]
table = next(c for c in cs if c.startswith("model_providers.sf="))
base = re.search(r'base_url="([^"]+)"', table).group(1)
key = os.environ[re.search(r'env_key="([^"]+)"', table).group(1)]
req = urllib.request.Request(base + "/responses", data=b'{"model": "x", "input": "hi"}',
                             headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=5).read()
r = subprocess.run([%(real)r] + args, input=data, capture_output=True)
sys.stdout.buffer.write(r.stdout)
sys.stderr.buffer.write(r.stderr)
sys.exit(r.returncode)
'''

SWITCHES = ("analytics.enabled=false", 'otel.metrics_exporter="none"', "feedback.enabled=false",
            "check_for_update_on_startup=false", 'web_search="disabled"')


class CodexProvider(ds.CodexCase):
    """`runtime.provider` (#151): codex pointed at a self-hosted, OpenAI-compatible endpoint, over a fake codex and the
    fake endpoint of fake_llm.py."""

    def setUp(self):
        super().setUp()
        self.llm = fake_llm.FakeLLM()
        self.addCleanup(self.llm.stop)
        os.environ[KEY] = SECRET

    def machine(self, provider_extra="", runtime_extra=""):
        self.machine_cfg(ds.POOL8 + "\nruntime:\n  default: codex\n" + runtime_extra
                         + "  provider:\n    base_url: %s\n    api_key_env: %s\n" % (self.llm.base_url, KEY)
                         + "    models:\n      stages: {refine: qwen3-coder, develop: qwen3-coder, validate: qwen3-coder}\n"
                         + provider_extra)

    def fresh_cycle(self, queues, snapshot=None):
        self.board(queues=queues, snapshot=snapshot)
        self.launches, self.pending = [], []
        for d in os.listdir(os.path.join(self.home, "locks")):
            os.rmdir(os.path.join(self.home, "locks", d))
        return self.cycle()

    @staticmethod
    def dash_c(call):
        a = call["argv"]
        return [a[i + 1] for i, x in enumerate(a) if x == "-c"]

    def models_of(self, queues):
        """{card: the -m flag} of one cycle's runs."""
        self.assertEqual(self.fresh_cycle(queues), 0, self.err)
        return {c["stdin"].split("Card: #")[-1].strip(): self.flag(c, "-m") for c in self.codex_calls()[-len(self.launches):]}

    def end_lines(self):
        return {(s, n): self.log(s, n).splitlines()[-1] for s, n in (("refine", 70), ("develop", 54), ("validate", 60))}

    def test_AC1_invalid_provider_stops_the_dispatch(self):
        "AC-1 a runtime.provider that is not valid in the machine config or in the project's: exit 2, the key named, no codex started"
        self.board(queues={"Ready for Dev": 54})
        bad = "runtime: {default: codex, provider: {base_url: 'ftp://x/v1'}}"
        self.machine_cfg(ds.POOL8 + "\n" + bad)
        self.assertEqual(self.cycle(), 2, (self.err, self.out))
        self.assertIn("runtime.provider.base_url", self.err + self.out)
        self.machine_cfg(ds.POOL8 + "\nruntime: codex")
        self.project_cfg(open(ds.FIXTURE_CONFIG, encoding="utf-8").read() + "\nruntime:\n  provider: {base_url: 'http://x/v1', api_key_env: 'A-B'}\n")
        self.assertEqual(self.cycle(), 2, (self.err, self.out))
        self.assertIn("runtime.provider.api_key_env", self.err + self.out)
        self.assertEqual(self.codex_calls(), [])

    def test_AC2_the_command_line_carries_the_provider_and_no_key(self):
        "AC-2 a run with a provider: -c model_providers.sf={base_url, env_key, wire_api responses}, -c model_provider=sf, -m the stage's model, the network switches off by -c, the key's value only in the environment"
        self.machine()
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0, self.err)
        call = self.codex_calls()[0]
        cs_ = self.dash_c(call)
        table = [c for c in cs_ if c.startswith("model_providers.sf=")]
        self.assertEqual(len(table), 1, cs_)
        for want in ('base_url="%s"' % self.llm.base_url, 'env_key="%s"' % KEY, 'wire_api="responses"'):
            self.assertIn(want, table[0])
        self.assertIn("model_provider=sf", cs_)
        for switch in SWITCHES:
            self.assertIn(switch, cs_)
        self.assertEqual(self.flag(call, "-m"), "qwen3-coder")
        self.assertNotIn(SECRET, " ".join(call["argv"]) + call["stdin"], "the key never goes on the command line")
        self.assertEqual(call["env"][KEY], SECRET, "the key reaches codex through the environment")

    def test_AC2_without_a_provider_nothing_changes(self):
        "AC-2 runtime: codex without a provider has no model_provider -c"
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0, self.err)
        self.assertFalse([c for c in self.dash_c(self.codex_calls()[0]) if c.startswith("model_provider")])

    def test_AC2_a_missing_key_variable_fails_before_codex(self):
        "AC-2 api_key_env naming a variable the dispatcher does not have: `provider: <VAR> is not set` in the log, the run fails, codex is not called"
        self.machine()
        del os.environ[KEY]
        self.board(queues={"Ready for Dev": 54})
        self.cycle()
        self.assertIn("provider: %s is not set" % KEY, self.log("develop", 54))
        self.assertEqual(self.codex_calls(), [])
        self.assertRegex(self.log("develop", 54).splitlines()[-1], r"^== end /sf:develop 54 exit=[1-9]\d* %s outcome=fail$" % ds.ISO)

    def provider_over_runtime(self):
        self.machine_cfg(
            ds.POOL8 + "\nruntime:\n  default: codex\n"
            "  provider: {base_url: '%s', api_key_env: %s, models: {stages: {develop: m-low, validate: m-val}}, ladder: [m-low, m-mid]}\n"
            "  models: {stages: {develop: ignored-m, validate: ignored-m, refine: ignored-m}}\n"
            "  ladder: [ignored-m, ignored-up]\n" % (self.llm.base_url, KEY))
        self.project_cfg(open(ds.FIXTURE_CONFIG, encoding="utf-8").read()
                         + "\nruntime:\n  provider: {models: {stages: {develop: p-low}}, ladder: [p-low, p-high]}\n"
                           "  models: {stages: {refine: ignored-p}}\n  ladder: [ignored-p, ignored-q]\n")

    def test_AC3_provider_models_win_and_the_project_overrides_by_key(self):
        "AC-3 with a provider the run's model is the provider's (the project's over the machine's, name by name); runtime.models of either is ignored"
        self.provider_over_runtime()
        got = self.models_of({"Ready for Dev": 54, "Validation": 60, "Ready for Refinement": 70})
        self.assertEqual(got, {"54": "p-low", "60": "m-val", "70": None})

    def test_AC3_a_failed_gate_steps_up_the_provider_ladder(self):
        "AC-3 after a failed gate the develop run climbs provider.ladder (the project's), not runtime.ladder, once"
        self.provider_over_runtime()
        self.set_fake(codex={"verdict": "FAIL", "gate": "build"})
        self.fresh_cycle({"Ready for Dev": 54}, snapshot="54\tCoding\tI_1\n")
        self.assertRegex(self.log("develop", 54), r"== step-up /sf:develop 54 p-low -> p-high: gate build failed %s\n" % ds.ISO)
        self.set_fake(codex={"verdict": "FAIL", "gate": "green"})
        self.fresh_cycle({"Coding": 54}, snapshot="54\tCoding\tI_1\n")
        self.assertEqual(self.flag(self.codex_calls()[1], "-m"), "p-high")
        self.assertEqual(self.log("develop", 54).count("== step-up"), 1)

    def test_AC4_a_card_goes_through_the_stages_on_the_endpoint(self):
        "AC-4 refine, develop and validate with a provider and a fake endpoint: each run reaches the endpoint with the key from the environment and ends on outcome=ok, claude is never started"
        import runtimes.codex as adapter
        wrapper = self.script("codex-llm", LLM_CODEX % {"real": self.codex_bin})
        os.environ["FACTORY_CODEX"] = wrapper
        p = mock.patch.object(adapter, "BINARY", wrapper)
        p.start()
        self.addCleanup(p.stop)
        self.machine()
        self.assertEqual(self.fresh_cycle({"Ready for Refinement": 70, "Ready for Dev": 54, "Validation": 60}), 0, self.err)
        self.assertEqual(self.claude_calls(), [])
        self.assertEqual(sorted(c["stdin"].split("Card: #")[-1].strip() for c in self.codex_calls()), ["54", "60", "70"])
        for (stage, n), line in self.end_lines().items():
            self.assertRegex(line, r"^== end /sf:%s %s exit=0 %s outcome=ok$" % (stage, n, ds.ISO))
        self.assertEqual(self.llm.paths.count("POST /v1/responses"), 3)
        self.assertEqual(set(self.llm.auth), {"Bearer " + SECRET})

    def test_AC5_the_endpoints_rate_limit_is_a_usage_limit(self):
        "AC-5 a run whose output says `rate limit exceeded` or `exceeded retry limit, last status: 429` ends on outcome=usage_limit and the next cycle waits as for the usage limit"
        self.machine()
        self.set_fake(codex={"say": "stream error: exceeded retry limit, last status: 429 Too Many Requests", "exit": 1})
        self.fresh_cycle({"Ready for Dev": 54})
        self.assertRegex(self.log("develop", 54).splitlines()[-1], r"^== end /sf:develop 54 exit=1 %s outcome=usage_limit$" % ds.ISO)
        self.launches = []
        self.board(queues={"Ready for Dev": 55})
        self.cycle(runs=False)
        self.assertEqual(self.launches, [], "new runs wait")
        self.assertIn("Codex usage limit hit recently; waiting", self.out)

    def test_AC5_rate_limit_exceeded_wording(self):
        "AC-5 the adapter's outcome: `rate limit exceeded` in any case is usage_limit (exit 0 or not); an agent's command that printed it is not the CLI speaking"
        out = runtimes().get("codex").outcome
        for text in ("Error: rate limit exceeded", "Rate Limit Exceeded for model qwen3", '{"type":"error","message":"rate limit exceeded"}'):
            for rc in (0, 1):
                self.assertEqual(out(rc, "work\n" + text + "\n"), "usage_limit", (rc, text))
        quoted = '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"rate limit exceeded"}}\n'
        self.assertEqual((out(0, quoted), out(1, quoted)), ("ok", "fail"))
        self.assertEqual(out(1, "rate limiting is a topic\n"), "fail")

    def test_AC8_the_key_is_in_no_file_of_the_factory(self):
        "AC-8 after a stage ran on a provider the key's value is in no file under SHIPFLOOR_HOME (config, logs, locks) nor in the CODEX_HOME"
        self.machine()
        self.assertEqual(self.fresh_cycle({"Ready for Dev": 54}), 0, self.err)
        self.assertEqual(self.codex_calls()[0]["env"].get(KEY), SECRET, "the run had the key")
        self.assertRegex(self.log("develop", 54).splitlines()[-1], r" outcome=ok$")
        seen = 0
        for root in (self.shome, self.codex_home):
            for d, _, files in os.walk(root):
                for f in files:
                    seen += 1
                    with open(os.path.join(d, f), "rb") as fh:
                        self.assertNotIn(SECRET.encode(), fh.read(), os.path.join(d, f))
        self.assertGreater(seen, 3, "the factory's files were read")
