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
        "AC-1 no runtime anywhere: claude-code runs every stage; the contract names claude-code first, then codex"
        self.assertEqual(self.of(None), ["claude-code"] * 4)
        self.assertEqual(self.of("pool: 4"), ["claude-code"] * 4)
        self.assertEqual(runtimes().NAMES, ("claude-code", "codex"))
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
