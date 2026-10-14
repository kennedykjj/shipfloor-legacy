"""The dashboard's Settings through its API: this machine's limits, pauses, cost limits, working hours, models (#34, #133),
the dispatcher's pace, the page's language and each project's (#129), and a project's operational overrides. Every test
runs with SHIPFLOOR_SCHEDULER set to a stub or "none": never the real ShipfloorDispatcher task."""
import json
import os
import subprocess
import sys

import dashboard_support as ds

SCRIPTS = ds.support.SCRIPTS
LANGS_MSG = "language must be one of en, zh-CN, zh-TW, es, ja, de, fr, pt-BR, ru, ko, it, tr"


def sh(cmd, **env):
    """a bash command line with extra environment: its stdout, \\r and NULs as given"""
    return subprocess.run(["bash", "-c", cmd], env=dict(os.environ, **env), capture_output=True, text=True).stdout


class Settings(ds.Dash):
    def setUp(self):
        super().setUp()
        self.stub = self.write("sched.sh", "#!/usr/bin/env bash\necho \"$@\" >> \"%s\"\nexit 0\n" % os.path.join(self.tmp, "sched.calls"))
        os.environ["SHIPFLOOR_SCHEDULER"] = '"%s" "%s"' % (ds.BASH, self.stub)

    def sched_calls(self):
        try:
            with open(os.path.join(self.tmp, "sched.calls")) as f:
                return f.read()
        except OSError:
            return ""

    def machine(self, body, token=True):
        return self.req("POST", "/api/settings/machine", body, token=token)


class Machine(Settings):
    def test_limits_and_pauses(self):
        "this machine's limits are read with their defaults and written all at once, checked together; the rest of config.yml stays; a pause is the PAUSE file"
        self.config("pool: 6\nlanguage: pt-BR\nstages:\n  develop: 3\n")
        def sget():
            s = self.settings(); m, p = s["machine"], s["projects"][0]
            return (m["pool"], m["stages"]["develop"], m["stages"]["refine"], m["stacks"], s["paused"], p["slug"], p["paused"], p["repo"], type(p["layers"]))
        self.assertEqual(sget(), (6, 3, 2, 3, False, "shop", False, "acme/shop", list))
        self.assertEqual(self.get("/api/settings", token=False).code, 403)
        self.assertEqual(self.machine({"pool": 2, "stages": {"develop": 3}}).code, 400, "a stage above the pool")
        self.assertIn("pool: 6", self.config_text())
        self.assertEqual(self.machine({"pool": 4}, token=False).code, 403)
        self.assertEqual(self.machine({"pool": 8, "stages": {"develop": 4, "validate": 1}, "stacks": 2}).code, 200)
        self.assertEqual(sget()[:6], (8, 4, 2, 2, False, "shop"))
        self.assertIn("language: pt-BR", self.config_text())
        self.assertEqual(self.post("/api/settings/pause", {"paused": True}).code, 200)
        self.assertTrue(os.path.exists(os.path.join(self.H, "PAUSE")))
        self.assertEqual(self.post("/api/settings/pause", {"project": "shop", "paused": True}).code, 200)
        self.assertTrue(os.path.exists(os.path.join(self.P, "PAUSE")))
        self.assertEqual(sget()[:7], (8, 4, 2, 2, True, "shop", True))
        self.assertEqual(self.post("/api/settings/pause", {"project": "nope", "paused": True}).code, 404)
        self.post("/api/settings/pause", {"paused": False}); self.post("/api/settings/pause", {"project": "shop", "paused": False})
        self.assertFalse(os.path.exists(os.path.join(self.H, "PAUSE")) or os.path.exists(os.path.join(self.P, "PAUSE")), "resumed")

    def test_bad_bodies(self):
        "a settings body that is not JSON is a 400; the token is checked first, in the header only"
        r = self.req("POST", "/api/settings/machine", b"{not json")
        self.assertEqual((r.code, r.json), (400, {"error": "body is not JSON"}))
        self.assertEqual(self.req("POST", "/api/settings/pause?t=" + self.token, {}, token=False).code, 403)
        self.assertEqual(self.req("POST", "/api/settings/pause", {}, token="wrong").code, 403)

    def test_cost_limits(self):
        "the three cost limits are saved, changed (decimals) and cleared with null; bad values are refused, saying which, and change nothing"
        self.config("pool: 6\nlanguage: pt-BR\n")
        cget = lambda: (lambda c: (c["card_warn"], c["card_block"], c["day_stop"]))(self.settings()["machine"]["costs"])
        self.assertEqual(self.machine({"costs": {"card_warn": 20, "card_block": 40, "day_stop": 80}}).code, 200)
        c = self.read_config()
        self.assertEqual((c["costs"], c["pool"], c["language"]), ({"card_warn": 20, "card_block": 40, "day_stop": 80}, 6, "pt-BR"))
        self.assertEqual(cget(), (20, 40, 80))
        self.assertEqual(self.machine({"costs": {"card_warn": 12.5}}).code, 200)
        self.assertEqual(cget(), (12.5, 40, 80))
        self.assertEqual(self.machine({"costs": {"day_stop": None}}).code, 200)
        self.assertEqual(cget(), (12.5, 40, None))
        self.assertNotIn("day_stop", self.config_text(), "a cleared limit leaves config.yml")
        before = self.config_text()
        for bad in ({"card_warn": 0}, {"card_block": -3}, {"day_stop": "abc"}, {"day_stop": True}, {"card_warn": 50}, {"card_block": 10}, {"bogus": 5}):
            self.assertEqual(self.machine({"costs": bad}).code, 400, str(bad))
        self.assertEqual(self.config_text(), before, "refusals change nothing")
        self.assertIn("card_warn", self.machine({"costs": {"card_warn": 50}}).text, "the refusal says which")
        self.assertEqual(self.machine({"costs": {"day_stop": 9}}, token=False).code, 403)
        self.assertEqual(self.machine({"costs": {"card_warn": None, "card_block": None}}).code, 200)
        self.assertNotIn("costs", self.config_text(), "an empty costs is dropped")
        self.assertIn("pool: 6", self.config_text())
        self.assertEqual(cget(), (None, None, None))


class Hours(Settings):
    def hours(self, now, what):
        os.environ["SHIPFLOOR_NOW"] = now
        h = self.get("/api/" + what).json.get("hours") or {}
        return h.get("windows"), h.get("open"), h.get("next"), h.get("error") is not None

    def both(self, now, want):
        self.assertEqual((self.hours(now, "overview"), self.hours(now, "settings")), (want, want))

    def test_open_or_closed(self):
        "the overview and the settings say whether the factory is outside its hours and when the next window starts; unset or malformed: always open"
        self.config('hours: ["08:00-23:00"]\n')
        self.both("23:30", (["08:00-23:00"], False, "08:00", False))
        self.both("12:00", (["08:00-23:00"], True, None, False))
        self.config('hours: ["08:00-23:00", "20:00-04:00"]\n')
        self.assertEqual(self.hours("23:30", "overview"), (["08:00-23:00", "20:00-04:00"], True, None, False))
        os.unlink(os.path.join(self.H, "config.yml"))
        self.both("23:30", ([], True, None, False))
        self.config('hours: ["8-23"]\n')
        self.both("23:30", (["8-23"], True, None, True))

    def test_set_change_clear(self):
        "Settings sets, changes and clears the windows; the rest of config.yml stays; a malformed value is refused and writes nothing"
        os.environ["SHIPFLOOR_NOW"] = "23:30"
        self.config("pool: 6\nlanguage: pt-BR\nstages:\n  develop: 3\n")
        rest = lambda: {k: v for k, v in self.read_config().items() if k != "hours"}
        hours = lambda: self.read_config().get("hours", "<unset>")
        before = rest()
        self.assertEqual(self.machine({"hours": ["08:00-23:00", "20:00-04:00"]}).code, 200)
        self.assertEqual((hours(), rest()), (["08:00-23:00", "20:00-04:00"], before))
        self.assertEqual(self.hours("23:30", "settings"), (["08:00-23:00", "20:00-04:00"], True, None, False))
        self.assertEqual(self.machine({"hours": ["09:00-17:00"]}).code, 200)
        self.assertEqual(hours(), ["09:00-17:00"])
        self.assertEqual(self.hours("23:30", "settings"), (["09:00-17:00"], False, "09:00", False))
        self.assertEqual(sh("source '%s/lib/project.sh'; shipfloor_machine hours" % SCRIPTS, SHIPFLOOR_NOW="23:30").strip(), "closed 09:00",
                         "the dispatcher's reader sees the saved window")
        saved = self.config_text()
        for bad in (["25:00-26:00"], ["8-23"], ["08:00-08:00"], ["08:00-23:00", ""], ["09:00-17:00", "nine-five"]):
            r = self.machine({"hours": bad})
            self.assertEqual(r.code, 400, str(bad))
            self.assertIn("hours", r.json["error"])
            self.assertEqual(self.config_text(), saved, "%s writes nothing" % bad)
        self.assertEqual(self.machine({"hours": ["01:00-02:00"]}, token=False).code, 403)
        self.assertEqual(self.config_text(), saved)
        self.assertEqual(self.machine({"hours": None}).code, 200)
        self.assertEqual((hours(), rest()), ("<unset>", before), "null removes the key, the rest stays")
        self.assertEqual(self.hours("23:30", "settings"), ([], True, None, False))
        self.machine({"hours": ["09:00-17:00"]})
        self.assertEqual(self.machine({"hours": []}).code, 200)
        self.assertEqual(hours(), "<unset>", "an empty list clears hours")
        self.assertEqual(self.machine({"pool": 7}).code, 200)
        self.assertEqual((rest()["pool"], hours()), (7, "<unset>"))
        self.config('pool: 6\nhours: ["09:00-17:00"]\n')
        self.assertEqual(self.machine({"pool": 7}).code, 200)
        self.assertEqual(hours(), ["09:00-17:00"], "saving the pool leaves hours as it was")


class Overrides(Settings):
    def knobs(self):
        k = self.settings()["projects"][0]["knobs"]
        return k["limits.develop.wip"]["value"], k["limits.develop.wip"]["repo"], k["deploy.timeout_min"]["value"], k["deploy.timeout_min"]["repo"]

    def project(self, values, token=True):
        return self.req("POST", "/api/settings/project", {"project": "shop", "values": values}, token=token)

    def cfg(self, *args):
        return subprocess.run(["bash", os.path.join(SCRIPTS, "shipfloor-config.sh"), *args], capture_output=True, text=True,
                              env=dict(os.environ, FACTORY_CONFIG=os.path.join(self.P, "factory.yml")))

    def test_operational_limits(self):
        "a project's operational limits are set on this machine in overrides.yml, laid over factory.yml by every reader, and gone again on null"
        was = self.knobs()
        self.assertEqual(self.project({"limits.develop.wip": 9, "deploy.timeout_min": 45}).code, 200)
        self.assertEqual(self.knobs()[:3], (9, was[1], 45))
        self.assertEqual((self.cfg("get", "limits.develop.wip").stdout.strip(), self.cfg("get", "deploy.timeout_min").stdout.strip()), ("9", "45"))
        self.assertEqual(self.project({"limits.develop.wip": -1}).code, 400)
        self.assertEqual(self.project({"project.repo": "x/y"}).code, 400, "only the operational limits")
        self.assertEqual(self.project({"limits.develop.wip": 3}, token=False).code, 403)
        ov = os.path.join(self.P, "overrides.yml")
        with open(ov) as f:
            keep = f.read()
        self.write("shome/projects/shop/overrides.yml", "layers: []\n")
        r = self.cfg("validate")
        self.assertIn("overrides.yml: layers cannot be overridden", r.stdout + r.stderr)
        self.write("shome/projects/shop/overrides.yml", keep)
        self.assertEqual(self.project({"limits.develop.wip": None, "deploy.timeout_min": None}).code, 200)
        self.assertFalse(os.path.exists(ov))
        self.assertEqual(self.knobs(), was)

    def test_project_language(self):
        "#129: a project's language is an override too: a code of LANGS or null; overrides.yml goes when empty; a bad language writes nothing"
        plang = lambda: (lambda l: (l["code"], l["repo"], l["from"], l["set"]))(self.settings()["projects"][0]["language"])
        ov, fy = os.path.join(self.P, "overrides.yml"), os.path.join(self.P, "factory.yml")
        with open(fy, "rb") as f:
            factory = f.read()
        self.assertEqual(self.project({"language": "pt-BR"}).code, 200)
        self.assertEqual(plang(), ("pt-BR", "en", "machine", False))
        with open(ov) as f:
            self.assertIn("language: pt-BR", f.read())
        self.assertEqual(self.project({"language": None}).code, 200)
        self.assertFalse(os.path.exists(ov), "back to the repository's language: overrides.yml deleted")
        self.assertEqual(plang(), ("en", "en", "repository", False))
        self.project({"language": "pt-BR", "deploy.timeout_min": 45})
        self.assertEqual(self.project({"language": None}).code, 200)
        with open(ov) as f:
            kept = f.read()
        self.assertNotIn("language:", kept, "the language override is gone")
        self.assertIn("timeout_min: 45", kept, "overrides.yml kept with its other keys")
        for bad in ("xx", 7, ["en"], ""):
            r = self.project({"language": bad})
            self.assertEqual(r.code, 400, repr(bad))
            self.assertIn(LANGS_MSG, r.text)
        with open(ov) as f:
            self.assertEqual(f.read(), kept, "AC-6 overrides.yml byte-identical after the refusals")
        with open(fy, "rb") as f:
            self.assertEqual(f.read(), factory, "AC-6 factory.yml never written")
        self.project({"deploy.timeout_min": None})
        self.assertFalse(os.path.exists(ov))


class Models(Settings):
    PRICES = ("claude-opus-5-5:   {input: 4.00, output: 20.00, cache_write_5m: 5.00,  cache_write_1h: 8.00,  cache_read: 0.20}\n"
              "claude-sonnet-5-5: {input: 2.00, output: 10.00, cache_write_5m: 2.50,  cache_write_1h: 4.00,  cache_read: 0.20}\n"
              "claude-haiku-5-5:  {input: 0.10, output: 0.50,  cache_write_5m: 0.125, cache_write_1h: 0.20,  cache_read: 0.01}\n")

    def setUp(self):
        super().setUp()
        with open(os.path.join(self.P, "factory.yml"), "a") as f:
            f.write("  - {name: docs, path: 'docs/', agent: reviewer, test: 't {selector}', ran: 'ok', tests: ['docs/t/**']}\n")
        self.write("shome/prices.yml", self.PRICES)
        from datetime import datetime, timedelta, timezone
        IN1, OUT1 = {"input_tokens": 1000000, "output_tokens": 0}, {"input_tokens": 0, "output_tokens": 1000000}
        def sess(sid, stage, n, days, model, usage, sub=None):
            ts = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
            self.transcript(sid, ds.slash(stage, n, ts), ds.ast("m-" + sid, model, usage, ts))
            if sub:
                self.transcript(sid, ds.ast("a-" + sid, sub[0], sub[1], ts), sub="agent-a")
        sess("s21", "develop", 21, 2, "claude-sonnet-5-5", IN1, ("claude-sonnet-5-5", OUT1))  # card 21: 12.00
        sess("s22a", "develop", 22, 3, "claude-sonnet-5-5", IN1)                             # card 22: 4.00
        sess("s22b", "develop", 22, 4, "claude-sonnet-5-5", IN1)
        sess("s23", "develop", 23, 20, "claude-opus-5-5", IN1)                               # outside the window
        sess("s24", "develop", 24, 1, "claude-mystery-1", IN1)                               # unpriced: left out
        sess("v21", "validate", 21, 2, "claude-haiku-5-5", IN1)                              # 0.10
        sess("d25", "deploy", 25, 1, "claude-mystery-1", IN1)
        sess("r26", "refine", 26, 20, "claude-opus-5-5", IN1)

    def models(self):
        return self.settings()["models"]

    def stage_models(self):
        return sh("source '%s/lib/project.sh'; shipfloor_machine stage-models" % SCRIPTS).replace("\0", "|")

    def test_listing_and_cost(self):
        "#34: every stage and agent with its default, the project's own agent and where it is used, and the 7-day average cost per card per stage"
        self.config("pool: 6\n")
        m = self.models()
        self.assertEqual((list(m["stages"]), m["choices"]), (["refine", "develop", "validate", "deploy"], ["opus", "sonnet", "haiku", "fable"]))
        w = lambda l, s, h: {"light": l, "standard": s, "heavy": h}
        self.assertEqual([m["stages"][k]["default"] for k in m["stages"]], ["sonnet", w("sonnet", "sonnet", "opus"), w("sonnet", "sonnet", "sonnet"), w("sonnet", "sonnet", "sonnet")])
        self.assertEqual([m["stages"][k]["value"] for k in m["stages"]], [None, w(None, None, None), w(None, None, None), w(None, None, None)])
        self.assertEqual(list(m["agents"]), ["product-owner", "ux-designer", "qa-engineer", "engineer", "cybersec", "reviewer"])
        self.assertEqual((m["agents"]["engineer"]["default"], m["agents"]["product-owner"]["default"], m["agents"]["reviewer"]["default"]), ("sonnet", "opus", None))
        self.assertEqual(m["agents"]["reviewer"]["projects"], [{"project": "shop", "layer": "docs"}])
        self.assertEqual(m["problems"], [])
        cost = lambda st: m["stages"][st]["cost"]
        self.assertEqual((cost("develop")["avg"], cost("develop")["cards"]), (8.0, 2), "AC-7 21 and 22; 23 too old, 24 unpriced")
        self.assertEqual((cost("validate")["avg"], cost("validate")["cards"]), (0.1, 1))
        for st in ("refine", "deploy"):
            c = cost(st)
            self.assertTrue(c is None or (c["avg"] is None and c["cards"] == 0), "AC-7 %s has no figure" % st)
        self.assertFalse(any("cost" in a for a in m["agents"].values()), "agent rows carry no cost")

    def test_save(self):
        "#34 AC-6/AC-5: a change lands in config.yml for the next cycle, null prunes; an unknown model, stage or agent refuses the whole save; hand-written problems block nothing"
        self.config("pool: 6\n")
        save = lambda body: self.machine({"models": body})
        self.assertEqual(save({"stages": {"develop": "sonnet"}, "agents": {"engineer": "haiku"}}).code, 200)
        self.assertEqual((self.read_config()["models"], self.read_config()["pool"]), ({"stages": {"develop": "sonnet"}, "agents": {"engineer": "haiku"}}, 6))
        self.assertEqual(self.stage_models(), "sonnet|" * 12)
        m = self.models()
        self.assertEqual((m["stages"]["develop"]["value"], m["agents"]["engineer"]["value"]), ({"light": "sonnet", "standard": "sonnet", "heavy": "sonnet"}, "haiku"))
        save({"stages": {"validate": "opus"}})
        self.assertEqual(self.read_config()["models"], {"stages": {"develop": "sonnet", "validate": "opus"}, "agents": {"engineer": "haiku"}})
        self.assertEqual(save({"stages": {"develop": None, "validate": None}}).code, 200)
        self.assertEqual(self.read_config()["models"], {"agents": {"engineer": "haiku"}})
        self.assertEqual(self.stage_models(), "sonnet|" * 5 + "opus|" + "sonnet|" * 6, "back to the shipped models")
        save({"agents": {"engineer": None}})
        self.assertNotIn("models", self.read_config())
        self.config("pool: 6\nmodels:\n  stages: {develop: haiku}\n")
        before = self.config_text()
        r = save({"agents": {"engineer": "gpt"}})
        self.assertEqual(r.code, 400)
        self.assertRegex(r.text, r"engineer.*gpt.*is not a model the factory knows\. Nothing was saved\.")
        for bad in ({"stages": {"review": "opus"}}, {"agents": {"nobody": "opus"}}, {"stages": {"develop": "opus"}, "agents": {"engineer": "gpt"}}):
            self.assertEqual(save(bad).code, 400, str(bad))
        self.assertEqual(self.config_text(), before)
        self.assertEqual(save({"agents": {"reviewer": "haiku"}}).code, 200, "a project agent a layer names")
        self.assertEqual(self.read_config()["models"]["agents"], {"reviewer": "haiku"})
        self.config("pool: 6\nmodels:\n  agents: {engineer: gpt}\n  stages: {review: opus}\n")
        m = self.models()
        self.assertEqual((m["agents"]["engineer"]["value"], [(p["key"], p["value"], p["why"]) for p in m["problems"]]),
                         (None, [("models.agents.engineer", "gpt", "model"), ("models.stages.review", "opus", "name")]))
        self.assertEqual(save({"stages": {"develop": "haiku"}}).code, 200)
        c = self.read_config()["models"]
        self.assertEqual((c["agents"]["engineer"], c["stages"]["review"], c["stages"]["develop"]), ("gpt", "opus", "haiku"))

    def test_unpriced_and_per_weight(self):
        "#34 AC-8: a model with no price is flagged and still saved; #133 AC-7: a model per weight for develop, validate and deploy"
        save = lambda body: self.machine({"models": body})
        self.assertEqual(save({"stages": {"deploy": "fable", "develop": "sonnet"}, "agents": {"engineer": "fable"}}).code, 200)
        m = self.models()
        f3, t3 = {"light": False, "standard": False, "heavy": False}, {"light": True, "standard": True, "heavy": True}
        self.assertEqual((m["stages"]["deploy"]["value"], m["stages"]["deploy"]["priced"], m["agents"]["engineer"]["priced"]),
                         ({"light": "fable", "standard": "fable", "heavy": "fable"}, f3, False))
        self.assertEqual((m["stages"]["develop"]["priced"], m["stages"]["refine"]["priced"], m["agents"]["cybersec"]["priced"]), (t3, True, True))
        os.unlink(os.path.join(self.H, "config.yml"))
        self.assertEqual(save({"stages": {"develop": {"light": "haiku", "heavy": "sonnet"}}}).code, 200)
        self.assertEqual(self.read_config()["models"]["stages"]["develop"], {"light": "haiku", "heavy": "sonnet"})
        self.assertEqual(self.stage_models(), "sonnet|" * 3 + "haiku|" + "sonnet|" * 8)
        self.assertEqual(self.models()["stages"]["develop"]["value"], {"light": "haiku", "standard": None, "heavy": "sonnet"})
        save({"stages": {"develop": {"light": None}}})
        self.assertEqual(self.read_config()["models"]["stages"]["develop"], {"heavy": "sonnet"})
        save({"stages": {"develop": {"heavy": None}}})
        self.assertNotIn("models", self.read_config())
        self.config("pool: 6\nmodels:\n  stages: {validate: opus}\n")
        save({"stages": {"develop": {"heavy": "haiku"}}})
        self.assertEqual(self.read_config()["models"]["stages"]["validate"], "opus", "a single model of a stage not in the request stays")
        save({"stages": {"validate": {"heavy": "haiku"}}})
        self.assertEqual(self.read_config()["models"]["stages"]["validate"], {"light": "opus", "standard": "opus", "heavy": "haiku"})
        before = self.config_text()
        r = save({"stages": {"develop": {"huge": "opus"}}})
        self.assertEqual(r.code, 400)
        self.assertIn("models.stages.develop.huge: not a weight", r.text)
        self.assertEqual(save({"stages": {"refine": {"light": "opus"}}}).code, 400, "refine takes one model")
        self.assertEqual(save({"stages": {"deploy": {"light": "gpt"}}}).code, 400)
        self.assertEqual(self.config_text(), before)


class Dispatcher(Settings):
    def disp(self):
        return self.settings()["dispatcher"]

    def test_pace(self):
        "the dispatcher's pace: 3 by default of 1, 3, 5, 10; a save re-registers the task with the minutes last and leaves a running cycle alone; 7 is refused before anything runs"
        self.assertEqual((self.disp()["every_min"], self.disp()["choices"], self.disp()["can_set"], self.disp()["why"]), (3, [1, 3, 5, 10], True, None))
        sleeper = subprocess.Popen(["sleep", "300"])
        self.addCleanup(sleeper.kill)
        self.write("shome/dispatch.pid", "%d\n" % sleeper.pid)
        self.assertEqual(self.machine({"dispatcher": {"every_min": 5}}).code, 200)
        self.assertEqual(self.sched_calls().strip(), "5")
        self.assertEqual(self.read_config()["dispatcher"]["every_min"], 5)
        self.assertEqual(self.disp()["every_min"], 5)
        out = subprocess.run(["bash", os.path.join(SCRIPTS, "shipfloor-config.sh"), "machine", "values", "dispatcher.every_min"], capture_output=True, text=True).stdout
        self.assertEqual(out.replace("\0", " "), "5 ")
        self.assertIsNone(sleeper.poll(), "the running cycle survived the save")
        with open(os.path.join(self.H, "dispatch.pid")) as f:
            self.assertEqual(f.read().strip(), str(sleeper.pid))
        os.unlink(os.path.join(self.tmp, "sched.calls"))
        self.assertEqual(self.machine({"dispatcher": {"every_min": 7}}).code, 400)
        self.assertEqual(self.sched_calls(), "", "the scheduler is not called")

    def test_scheduler_fails(self):
        "a failing re-register is a 409 with the scheduler's last line; config.yml stays byte for byte (the other limits are not saved either)"
        bad = self.write("bad.sh", "#!/usr/bin/env bash\necho \"$@\" >> \"%s\"\necho \"trying the task\"\necho \"boom: access denied\"\nexit 1\n" % os.path.join(self.tmp, "sched.calls"))
        os.environ["SHIPFLOOR_SCHEDULER"] = '"%s" "%s"' % (ds.BASH, bad)
        self.config("pool: 6\ndispatcher:\n  every_min: 3\n")
        before = self.config_text()
        r = self.machine({"dispatcher": {"every_min": 10}, "pool": 7})
        self.assertEqual((r.code, r.json.get("error")), (409, "boom: access denied"))
        self.assertEqual(self.config_text(), before)
        self.assertEqual(self.disp()["every_min"], 3)
        self.assertEqual(self.sched_calls().strip(), "10")

    def test_next_cycle(self):
        "the next cycle is the last cycle's start (at - took) plus the interval"
        self.config("dispatcher:\n  every_min: 5\n")
        self.write("shome/logs/health-2026-10.jsonl", '{"ts":"2026-10-11T10:00:10+00:00","cycle":{"s":10,"exit":0,"overlap":false},"paused":false,"idle":[],"over":[]}\n')
        from datetime import datetime, timezone
        n = self.settings()["cycle"].get("next_at")
        self.assertEqual(datetime.fromisoformat(n).astimezone(timezone.utc).isoformat(), "2026-10-11T10:05:00+00:00")

    def test_no_scheduler(self):
        "no scheduled task here: the control is off with a reason, a save is a 409 and changes nothing"
        os.environ["SHIPFLOOR_SCHEDULER"] = "none"
        self.config("pool: 6\n")
        self.assertEqual((self.disp()["can_set"], bool(self.disp()["why"])), (False, True))
        self.assertEqual(self.machine({"dispatcher": {"every_min": 5}}).code, 409)
        self.assertEqual(self.config_text(), "pool: 6\n")


class Language(Settings):
    PROJECTS = ("shop", "blog")

    def setUp(self):
        super().setUp()
        fy = self.pdir("blog", "factory.yml")
        with open(fy) as f:
            body = f.read()
        with open(fy, "w") as f:
            f.write("language: pt-BR\n" + body)

    def plang(self, slug):
        return next((p["language"]["code"], p["language"]["repo"], p["language"]["from"]) for p in self.settings()["projects"] if p["slug"] == slug)

    def project(self, slug, lang):
        return self.req("POST", "/api/settings/project", {"project": slug, "values": {"language": lang}})

    def test_defaults_and_options(self):
        "no language key: en for the page and a project; a project's language and the file that sets it; the options are LANGS, each under its own name"
        self.config("pool: 6\n")
        s = self.settings()
        self.assertEqual(s["machine"].get("language"), "en")
        self.assertEqual(sorted(x["slug"] for x in s["projects"] if "language" in x), ["blog", "shop"], "every registered project carries a language")
        p = {x["slug"]: x["language"] for x in s["projects"]}
        self.assertEqual((p["shop"]["code"], p["shop"]["set"]), ("en", False))
        self.assertEqual((p["blog"]["code"], p["blog"]["set"], p["blog"]["file"]), ("pt-BR", True, ".shipfloor/factory.yml"))
        import shipfloor_config
        want = {k: json.load(open(os.path.join(SCRIPTS, "lang", "dashboard.%s.json" % k), encoding="utf-8"))["name"] for k in shipfloor_config.LANGS}
        self.assertEqual(list(s["languages"].items()), list(want.items()), "LANGS in its own order, each under its own name")
        self.assertEqual(len(s["languages"]), 12)
        self.assertEqual((s["languages"]["es"], s["languages"]["ja"], s["languages"]["pt-BR"]), ("Español", "日本語", "Português (Brasil)"))

    def test_page_language(self):
        "the page's language: a code outside LANGS is refused with its key and config.yml stays; pt-BR is saved, served with the English catalog beside it, in the page, without the scheduler"
        self.config("language: en\npool: 6\n")
        before = self.config_text()
        r = self.machine({"language": "xx"})
        self.assertEqual(r.code, 400)
        self.assertIn(LANGS_MSG, r.json["error"])
        self.assertEqual(r.json["errors"][0]["key"], "err.language")
        self.assertEqual(self.config_text(), before)
        self.config("language: en\npool: 6\nstages:\n  refine: 3\n  develop: 1\nstacks: 2\nstack_wait: 90\ndispatcher:\n  every_min: 5\n")
        rest = lambda: {k: v for k, v in self.read_config().items() if k != "language"}
        was = rest()
        self.assertEqual(self.machine({"language": "pt-BR"}).code, 200)
        self.assertEqual((self.read_config()["language"], rest()), ("pt-BR", was), "only language changes in config.yml")
        lang = self.get("/api/lang").json
        self.assertEqual((lang["language"], lang["messages"]["sec.language"], lang["en"]["sec.language"]), ("pt-BR", "Idioma", "Language"))
        page = self.get("/", token=False).text
        self.assertIn('<html lang="pt-BR">', page)
        self.assertIn('id="lang-data">{"language": "pt-BR", "messages": {', page, "the page carries its catalog for the first paint")
        self.assertEqual(self.settings()["machine"]["language"], "pt-BR")
        self.assertEqual(self.sched_calls(), "", "a language change does not call the scheduler")

    def test_project_language_is_independent(self):
        "#129: each project's language over the repository's, and the page's, never change each other"
        self.config("language: en\n")
        self.assertEqual((self.plang("shop"), self.plang("blog")), (("en", "en", "repository"), ("pt-BR", "pt-BR", "repository")))
        self.assertEqual(self.project("blog", "en").code, 200)
        self.assertEqual(self.plang("blog"), ("en", "pt-BR", "machine"))
        self.assertEqual((self.read_config()["language"], self.get("/api/lang").json["language"]), ("en", "en"))
        self.assertEqual(self.machine({"language": "pt-BR"}).code, 200)
        self.assertEqual((self.plang("blog"), self.plang("shop")), (("en", "pt-BR", "machine"), ("en", "en", "repository")))
        self.project("shop", "pt-BR")
        self.assertEqual((self.plang("shop"), self.read_config()["language"]), (("pt-BR", "en", "machine"), "pt-BR"))
        self.machine({"language": "en"})
        self.assertEqual((self.plang("shop"), self.read_config()["language"]), (("pt-BR", "en", "machine"), "en"))
        self.assertEqual(self.sched_calls(), "")
