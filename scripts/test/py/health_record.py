"""shipfloor_health in process: snapshot (the line a dispatcher cycle records: board, runs against their limits, the
machine, what stops the factory, an idle slot), alerts (read back from the last cycles: idle for 3 cycles, over a
limit, overlapping cycles, a missed cycle), the dependency record (#202), and the platform probes with a patched
os.name and a fake ctypes.windll. Block labels are read through the fake gh; stack slots are a double here (the
real `gate.sh stack status` runs in health.test.sh)."""
import ctypes
import json
import os
import shutil
import time
import types
from datetime import datetime, timedelta

import dashboard
import shipfloor_health
from support import FIXTURE, SCRIPTS, Case


class HealthCase(Case):
    def setUp(self):
        super().setUp()
        self.setup()
        os.environ.update(FACTORY_GH=os.path.join(SCRIPTS, "test", "fake-gh"), FAKE_GH_DIR=self.path("fake-gh"), FAKE_GH_NO_JQ="1",
                          CLAUDE_CONFIG_DIR=self.path("claude"))
        saved = dashboard.Factory.stacks
        self.addCleanup(setattr, dashboard.Factory, "stacks", saved)
        dashboard.Factory.stacks = lambda self: ([], 0)

    def setup(self):
        """a fresh home with one project: develop has 3 machine slots, refine 2, the pool 6"""
        self.H = self.path("h%d" % len(os.listdir(self.tmp)))
        self.P = os.path.join(self.H, "projects", "shop")
        os.makedirs(os.path.join(self.P, "logs"))
        os.makedirs(os.path.join(self.P, "locks"))
        self.put("registry.tsv", "shop\t/x/shop\t/x/wt\tmain\n")
        shutil.copy(os.path.join(FIXTURE, "factory.yml"), os.path.join(self.P, "factory.yml"))
        self.put("config.yml", "pool: 6\nstages: {refine: 2, develop: 3}\n")

    def put(self, rel, text):
        p = os.path.join(self.H, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        return p

    def board(self, *cards):
        self.put("projects/shop/board.tsv", "".join("%s\t%s\tI%s\n" % (n, c, n) for n, c in cards))

    def run_(self, stage, n):
        """a live run: its lock (this process's pid) and its log"""
        self.put("projects/shop/locks/%s-%s.lock/info" % (stage, n), "%d %d %s\n" % (os.getpid(), time.time(), n))
        self.put("projects/shop/logs/%s-%s-%s.log" % (time.strftime("%F"), n, stage),
                 "== start /sf:%s %s %s pid=1\n" % (stage, n, datetime.now().astimezone().isoformat(timespec="seconds")))

    def record(self, seconds=0, code=0, overlap=False):
        line = shipfloor_health.snapshot(self.H, seconds, code, overlap)
        self.put_line(line)
        return line

    def put_line(self, line):
        os.makedirs(os.path.join(self.H, "logs"), exist_ok=True)
        with open(os.path.join(self.H, "logs", "health-%s.jsonl" % datetime.now().strftime("%Y-%m")), "a") as f:
            f.write(json.dumps(line) + "\n")

    def alerts(self):
        return shipfloor_health.alerts(self.H)

    def idle_after(self, *cards, deps=None):
        self.setup()
        self.board(*cards)
        if deps is not None:
            self.put("projects/shop/deps.json", json.dumps(deps))
        return self.record()["idle"]


IDLE = "shop/develop: a free slot and cards waiting for 3 cycles in a row"


class Record(HealthCase):
    def test_line(self):
        "a line holds the cycle, the board's columns, the runs against their limits, the pool, the machine, and the idle slots"
        self.board((26, "Ready for Dev"), (27, "Ready for Dev"), (30, "Coding"), (33, "Done"))
        self.run_("develop", 30)
        d = self.record(12, 1)
        self.assertEqual(d["cycle"], {"s": 12, "exit": 1, "overlap": False})
        self.assertEqual(d["projects"]["shop"]["columns"], {"Coding": 1, "Done": 1, "Ready for Dev": 2})
        self.assertEqual((d["stages"]["develop"], d["pool"]), ({"slots": 3, "running": 1}, {"size": 6, "used": 1}))
        self.assertEqual(d["projects"]["shop"]["stages"]["develop"], {"queue": 2, "orphans": 0, "running": 1, "cap": 0})
        self.assertGreater(d["machine"]["disk_free_gb"], 0)
        self.assertEqual((d["idle"], d["over"]), (["shop/develop"], []))
        self.assertEqual(d["stacks"], {"busy": 0, "total": 0, "queue": 0})
        self.assertFalse(d["paused"] or d["usage_limited"] or d["github_limited"] or d["cost_stop"] or d["outside_hours"])

    def cgroup(self, current_mb, max_text):
        """a fake cgroup root holding this process's own cgroup path, as snapshot() resolves it through /proc/self/cgroup"""
        with open("/proc/self/cgroup") as f:
            mine = next(l.strip().split(":", 2)[2] for l in f if l.startswith("0::"))
        d = os.path.join(self.tmp, "cgroup", mine.strip("/"))
        os.makedirs(d, exist_ok=True)
        for name, text in (("memory.current", str(current_mb * 2**20)), ("memory.max", max_text)):
            with open(os.path.join(d, name), "w") as f:
                f.write(text + "\n")
        os.environ["SHIPFLOOR_CGROUP_ROOT"] = os.path.join(self.tmp, "cgroup")
        self.addCleanup(os.environ.pop, "SHIPFLOOR_CGROUP_ROOT", None)

    def test_AC7_cgroup_memory(self):
        "AC-7 memory at 90% of a finite cgroup ceiling lands in the health line with usage and ceiling, and as an alert; below it, or with no ceiling, it does not"
        if not os.path.exists("/proc/self/cgroup"):
            self.skipTest("Linux only")
        self.board()
        self.cgroup(500, str(1000 * 2**20))
        d = self.record()
        self.assertEqual(d["cgroup"], {"mem_mb": 500, "max_mb": 1000})
        self.assertFalse([o for o in d["over"] if o.startswith("memory")])
        self.cgroup(950, str(1000 * 2**20))
        d = self.record()
        self.assertEqual(d["cgroup"], {"mem_mb": 950, "max_mb": 1000})
        self.assertIn("memory 950/1000 MB", d["over"])
        self.assertIn("memory 950/1000 MB: more runs than the limit", self.alerts())
        self.cgroup(950, "max")
        d = self.record()
        self.assertIsNone(d["cgroup"])
        self.assertFalse([o for o in d["over"] if o.startswith("memory")])

    def test_idle_needs_three_cycles(self):
        "one idle cycle is no alert (the dispatcher's own timing); three in a row are"
        self.board((26, "Ready for Dev"))
        self.record()
        self.assertEqual(self.alerts(), [])
        self.record()
        self.record()
        self.assertEqual(self.alerts(), [IDLE])

    def test_nothing_waits(self):
        "no idle slot when the stage is full, the WIP is full, the card is blocked (fake gh: #7) or the factory is paused"
        self.setup()
        self.board((26, "Ready for Dev"))
        for n in (30, 31, 32):
            self.run_("develop", n)
        self.assertEqual(self.record()["idle"], [])
        self.setup()
        self.board((26, "Ready for Dev"), (1, "Coding"), (2, "Coding"), (3, "Validation"), (4, "Validation"))
        for st, n in (("develop", 1), ("develop", 2), ("validate", 3), ("validate", 4)):
            self.run_(st, n)
        self.assertEqual(self.record()["idle"], [])
        self.setup()
        self.board((7, "Ready for Dev"))
        d = self.record()
        self.assertEqual((d["idle"], d["projects"]["shop"]["blocked"], d["projects"]["shop"]["blocked_cards"]), ([], 1, [7]))
        self.setup()
        self.board((26, "Ready for Dev"))
        self.put("PAUSE", "")
        d = self.record()
        self.assertEqual((d["idle"], d["paused"]), ([], True))

    def test_paused_or_skipped_project(self):
        "a paused or skipped project has no idle slot, and its line says so"
        self.board((26, "Ready for Dev"))
        self.put("projects/shop/PAUSE", "")
        d = self.record()
        self.assertEqual((d["idle"], d["projects"]["shop"]["paused"]), ([], True))
        self.setup()
        self.board((26, "Ready for Dev"))
        self.put("projects/shop/SKIPPED", "2026-10-11T09:00:00\tinvalid factory.yml\n")
        d = self.record()
        self.assertEqual((d["idle"], d["projects"]["shop"]["skipped"]), ([], True))

    def test_usage_limited(self):
        "a run that hit the usage limit stops the factory: the line says usage_limited and no slot is idle"
        self.board((26, "Ready for Dev"))
        self.put("projects/shop/logs/x-26-develop.log", "== start /sf:develop 26\nYou've hit your session limit\n")
        d = self.record()
        self.assertEqual((d["idle"], d["usage_limited"]), ([], True))

    def test_github_limited(self):
        "a fresh GitHub-limit mark (#190) stops the factory: recorded, no idle slot; one 11 minutes old no longer does"
        self.board((26, "Ready for Dev"))
        mark = self.put("github-limited", "")
        d = self.record()
        self.assertEqual((d["idle"], d["github_limited"]), ([], True))
        old = time.time() - 11 * 60
        os.utime(mark, (old, old))
        d = self.record()
        self.assertEqual((d["idle"], d["github_limited"]), (["shop/develop"], False))

    def test_orphan(self):
        "a card left in a work column with no run is waiting to be resumed, whatever the WIP"
        self.board((30, "Coding"))
        d = self.record()
        self.assertEqual(d["idle"], ["shop/develop"])
        self.assertEqual(d["projects"]["shop"]["stages"]["develop"]["orphans"], 1)

    def test_over_limits(self):
        "more runs than a machine limit or a project's deploy cap, and two cycles at once, are alerts at once"
        self.board()
        for st, n in (("refine", 40), ("refine", 41), ("refine", 42), ("deploy", 50), ("deploy", 51)):
            self.run_(st, n)
        self.record(overlap=True)
        out = self.alerts()
        self.assertIn("refine 3/2: more runs than the limit", out)
        self.assertIn("shop/deploy 2/1: more runs than the limit", out)
        self.assertIn("two dispatcher cycles ran at once", out)

    def test_pool_over(self):
        "more runs than the pool is an over line of its own"
        self.put("config.yml", "pool: 1\nstages: {refine: 2, develop: 3}\n")
        self.board()
        self.run_("develop", 30)
        self.run_("refine", 40)
        self.assertIn("pool 2/1", self.record()["over"])

    def test_cost_stop(self):
        "costs.day_stop reached (today US$ 100 of opus input): cost_stop and no idle alert; without costs or under the stop it is false"
        cd = os.path.join(self.tmp, "claude", "projects", "C--x--shipfloor-projects-shop-control")
        os.makedirs(cd)
        day, tz = datetime.now().strftime("%F"), datetime.now().astimezone().strftime("%z")
        tz = tz[:3] + ":" + tz[3:]
        with open(os.path.join(cd, "s.jsonl"), "w") as f:
            f.write(json.dumps({"type": "user", "timestamp": "%sT12:00:00%s" % (day, tz),
                                "message": {"role": "user", "content": "<command-name>/sf:develop</command-name>\n<command-args>26</command-args>"}}) + "\n")
            f.write(json.dumps({"type": "assistant", "timestamp": "%sT12:05:00%s" % (day, tz),
                                "message": {"id": "c1", "model": "claude-opus-5-5", "usage": {"input_tokens": 25000000, "output_tokens": 0}}}) + "\n")
        self.board((26, "Ready for Dev"))
        for _ in range(3):
            d = self.record()
        self.assertFalse(d["cost_stop"])
        self.assertIn(IDLE, self.alerts())
        self.put("config.yml", "pool: 6\nstages: {refine: 2, develop: 3}\ncosts:\n  day_stop: 80\n")
        for _ in range(3):
            d = self.record()
        self.assertEqual((d["cost_stop"], d["idle"]), (True, []))
        self.assertEqual(self.alerts(), [])
        self.put("config.yml", "pool: 6\nstages: {refine: 2, develop: 3}\ncosts:\n  day_stop: 150\n")
        self.assertFalse(self.record()["cost_stop"])

    def test_cost_unreadable(self):
        "an unreadable cost config is no cost stop: the dispatcher says so itself"
        self.put("config.yml", "pool: 6\ncosts: [1, 2]\n")
        self.assertFalse(shipfloor_health.cost_stopped(self.H, ["shop"]))
        self.assertFalse(shipfloor_health.cost_stopped(self.H, []))

    def test_hours(self):
        "AC-6 outside the working hours the line says outside_hours, no idle key, no alert; inside, or with no hours, it is false"
        self.put("config.yml", 'pool: 6\nstages: {refine: 2, develop: 3}\nhours: ["08:00-23:00"]\n')
        self.board((26, "Ready for Dev"), (27, "Ready for Dev"))
        os.environ["SHIPFLOOR_NOW"] = "23:30"
        d = self.record()
        self.assertEqual((d["outside_hours"], d["idle"]), (True, []))
        self.record()
        self.record()
        self.assertEqual(self.alerts(), [])
        os.environ["SHIPFLOOR_NOW"] = "12:00"
        d = self.record()
        self.assertEqual((d["outside_hours"], d["idle"]), (False, ["shop/develop"]))
        self.record()
        self.record()
        self.assertIn(IDLE, self.alerts())
        os.environ["SHIPFLOOR_NOW"] = "23:30"
        self.setup()
        self.board((26, "Ready for Dev"))
        d = self.record()
        self.assertEqual((d["outside_hours"], d["idle"]), (False, ["shop/develop"]))


class Deps(HealthCase):
    """#202: <project home>/deps.json, {"<n>": {"read": bool, "deps": [{"n", "title", "state"}]}}"""
    OPEN = {"n": 162, "title": "The base", "state": "open"}
    CLOSED = {"n": 163, "title": "Done base", "state": "closed"}

    def test_held(self):
        "AC-5 a card on an open dependency (alone or with closed ones), or with dependencies not read, keeps no slot idle, nor alerts"
        self.assertEqual(self.idle_after((26, "Ready for Dev")), ["shop/develop"])
        self.assertEqual(self.idle_after((26, "Ready for Dev"), deps={"26": {"read": True, "deps": [self.OPEN]}}), [])
        self.record()
        self.record()
        self.assertEqual(self.alerts(), [])
        self.assertEqual(self.idle_after((26, "Ready for Dev"), deps={"26": {"read": True, "deps": [self.CLOSED, self.OPEN]}}), [])
        self.assertEqual(self.idle_after((26, "Ready for Dev"), deps={"26": {"read": False, "deps": []}}), [])

    def test_free(self):
        "AC-5 only closed dependencies, or a second queued card with none, keep the slot idle"
        self.assertEqual(self.idle_after((26, "Ready for Dev"), deps={"26": {"read": True, "deps": [self.CLOSED]}}), ["shop/develop"])
        self.assertEqual(self.idle_after((26, "Ready for Dev"), (27, "Ready for Dev"), deps={"26": {"read": True, "deps": [self.OPEN]}}),
                         ["shop/develop"])

    def test_orphan_held(self):
        "AC-5 an orphan (a card left in Coding with no run) on an open dependency is not resumed, so not idle"
        self.assertEqual(self.idle_after((30, "Coding"), deps={"30": {"read": True, "deps": [self.OPEN]}}), [])


class Alerts(HealthCase):
    def cyc(self, minutes_ago):
        """a health line for a cycle that ended that long ago"""
        t = (datetime.now().astimezone() - timedelta(minutes=minutes_ago)).isoformat(timespec="seconds")
        self.put_line({"ts": t, "cycle": {"s": 5, "exit": 0, "overlap": False}, "paused": False, "idle": [], "over": []})

    def test_no_log(self):
        "no health log yet: no alert at all"
        self.assertEqual(self.alerts(), [])
        os.makedirs(os.path.join(self.H, "logs"))
        self.assertEqual(self.alerts(), [])

    def test_old_lines(self):
        "lines written before outside_hours and ts existed still count their idle keys, and a line cut short is skipped"
        for _ in range(3):
            self.put_line({"cycle": {"s": 1, "exit": 0, "overlap": False}, "idle": ["shop/develop"], "over": []})
        self.assertEqual(self.alerts(), [IDLE])
        with open(os.path.join(self.H, "logs", "health-%s.jsonl" % datetime.now().strftime("%Y-%m")), "a") as f:
            f.write('{"cycle": {"s"')
        self.assertEqual(self.alerts(), [])  # two whole lines in the last three: not 3 cycles in a row

    def missed(self):
        return [a for a in self.alerts() if "no dispatcher cycle" in a]

    def test_missed_cycle(self):
        "AC-7 a stopped dispatcher: the newest line older than 3 x the pace in config.yml (default 3); on time, or up to 3 x (#176), is no alert"
        self.put("config.yml", "dispatcher: {every_min: 10}\n")
        for m in (30, 20, 10):
            self.cyc(m)
        self.assertEqual(self.missed(), [])
        self.setup()
        self.put("config.yml", "dispatcher: {every_min: 10}\n")
        for m in (75, 65, 55):
            self.cyc(m)
        self.assertEqual(self.missed(), ["no dispatcher cycle for 55 min (it runs every 10)"])
        self.setup()
        self.put("config.yml", "dispatcher: {every_min: 10}\n")
        for m in (40, 30, 20):  # 2 x the pace: one slow or missed cycle, not a stopped dispatcher
            self.cyc(m)
        self.assertEqual(self.missed(), [])
        self.cyc(31)  # appended last, so the newest: just past 3 x 10
        self.assertEqual(self.missed(), ["no dispatcher cycle for 31 min (it runs every 10)"])
        self.setup()
        for m in (30, 20, 12):
            self.cyc(m)
        self.assertEqual(self.missed(), ["no dispatcher cycle for 12 min (it runs every 3)"])
        self.put("config.yml", "dispatcher: [")
        self.assertEqual(self.missed(), ["no dispatcher cycle for 12 min (it runs every 3)"])

    def test_silence(self):
        "#176 silence(): the age and the pace past 3 x every_min and at least 3 min (missing or invalid: 3), else None; alerts(skip_silence=True) leaves only that line out"
        self.assertIsNone(shipfloor_health.silence(self.H))  # no log at all
        os.makedirs(os.path.join(self.H, "logs"))
        self.assertIsNone(shipfloor_health.silence(self.H))  # no health line yet
        for conf, ago, want in (("dispatcher: {every_min: 10}\n", 60, [60, 10]), ("dispatcher: {every_min: 10}\n", 20, None),
                                (None, 12, [12, 3]), ("dispatcher: {every_min: banana}\n", 12, [12, 3]),
                                ("dispatcher: {every_min: 5}\n", 12, None), (None, 8, None),
                                # 30 seconds: 3 x the pace would be 90 s, a long cycle's length; the floor stays 3 min
                                ("dispatcher: {every_min: 0.5}\n", 2, None), ("dispatcher: {every_min: 0.5}\n", 4, [4, 0.5])):
            self.setup()
            if conf:
                self.put("config.yml", conf)
            self.cyc(ago)
            got = shipfloor_health.silence(self.H)
            self.assertEqual(got and [int(got["min"]), got["every"]], want, (conf, ago))
        self.setup()
        self.put("config.yml", "dispatcher: {every_min: 10}\n")
        self.cyc(60)
        with open(os.path.join(self.H, "logs", "health-%s.jsonl" % datetime.now().strftime("%Y-%m")), "a") as f:
            f.write('{"ts": "2\n')  # a line cut short by a cycle that died writing it: the one before counts
        self.assertEqual(int(shipfloor_health.silence(self.H)["min"]), 60)
        self.put_line({"ts": "not a time", "cycle": {"s": 5, "exit": 0, "overlap": True}, "idle": [], "over": []})
        self.assertIsNone(shipfloor_health.silence(self.H))
        self.assertEqual(shipfloor_health.alerts(self.H, skip_silence=True), ["two dispatcher cycles ran at once"])


class Probes(HealthCase):
    def windll(self, **kernel32):
        saved = getattr(ctypes, "windll", None)
        self.addCleanup(lambda: setattr(ctypes, "windll", saved) if saved else delattr(ctypes, "windll"))
        ctypes.windll = types.SimpleNamespace(kernel32=types.SimpleNamespace(**kernel32))
        self.os_name("nt")

    def os_name(self, name):
        saved = shipfloor_health.os
        self.addCleanup(setattr, shipfloor_health, "os", saved)
        shipfloor_health.os = types.SimpleNamespace(**{k: getattr(os, k) for k in ("getloadavg", "cpu_count", "environ")}, name=name)

    def test_posix(self):
        "on Linux: cpu from the load average per CPU, free memory from /proc/meminfo; None when they cannot be read"
        self.assertIsInstance(shipfloor_health.cpu_percent(), int)
        self.assertGreater(shipfloor_health.mem_free_mb(), 0)
        self.os_name("posix")

        def no_load():
            raise OSError("no load")
        shipfloor_health.os.getloadavg = no_load
        self.assertIsNone(shipfloor_health.cpu_percent())
        saved = shipfloor_health.Path
        self.addCleanup(setattr, shipfloor_health, "Path", saved)
        shipfloor_health.Path = lambda p: saved(self.write("meminfo", "MemTotal: 1 kB\n"))
        self.assertIsNone(shipfloor_health.mem_free_mb())
        shipfloor_health.Path = lambda p: saved(self.tmp, "none")
        self.assertIsNone(shipfloor_health.mem_free_mb())

    def test_windows(self):
        "on Windows: cpu from two GetSystemTimes reads 0.25 s apart, free memory from GlobalMemoryStatusEx"
        reads = iter([(100, 300, 100), (150, 400, 200)])  # idle, kernel (with idle), user: 50 idle of 200 → 75 %

        def times(i, k, u):
            i._obj.value, k._obj.value, u._obj.value = next(reads)

        def status(s):
            s._obj.avail = 3 * 2**30
            return 1
        self.windll(GetSystemTimes=times, GlobalMemoryStatusEx=status)
        saved = shipfloor_health.time.sleep
        self.addCleanup(setattr, shipfloor_health.time, "sleep", saved)
        shipfloor_health.time.sleep = lambda s: None
        self.assertEqual(shipfloor_health.cpu_percent(), 75)
        self.assertEqual(shipfloor_health.mem_free_mb(), 3072)
        reads = iter([(1, 2, 3), (1, 2, 3)])
        self.assertIsNone(shipfloor_health.cpu_percent())  # no time passed: no answer
        ctypes.windll.kernel32.GlobalMemoryStatusEx = lambda s: 0
        self.assertIsNone(shipfloor_health.mem_free_mb())
