"""The factory's state database (#262, shipfloor_core/state.py): <shipfloor home>/state.db with the runs and the
cycles, imported from the run logs and health-*.jsonl, kept 90 days (the logs of finished runs 30), backed up once a day.
The dual writes at the supervisor and at the health record are in dispatch_launch.py and health_record.py (AC-4)."""
import json
import os
import re
import sqlite3
import time
from datetime import datetime, timedelta

from support import Case


def iso(ago_days=0.0, now=None):
    t = datetime.fromtimestamp(now or time.time()).astimezone() - timedelta(days=ago_days)
    return t.isoformat(timespec="seconds")


class StateCase(Case):
    def setUp(self):
        super().setUp()
        import importlib.util
        self.assertIsNotNone(importlib.util.find_spec("shipfloor_core.state"), "shipfloor_core/state.py does not exist")
        from shipfloor_core import state
        self.state = state
        self.home = self.path("shome")
        self.logs = os.path.join(self.home, "projects", "shop", "logs")
        os.makedirs(self.logs)

    def db(self):
        conn = sqlite3.connect(os.path.join(self.home, "state.db"))
        self.addCleanup(conn.close)
        return conn

    def count(self, table):
        return self.db().execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]

    def runlog(self, name, *runs, project="shop"):
        """a run log with one block per run: (card, started, ended or None, extra start fields)"""
        lines = []
        for card, started, ended, extra in runs:
            lines.append("== start /sf:develop %s %s pid=100%s" % (card, started, extra))
            lines.append("the agent says hi")
            if ended:
                lines.append("== end /sf:develop %s exit=0 %s outcome=ok" % (card, ended))
        d = os.path.join(self.home, "projects", project, "logs")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        return p

    def health(self, *lines, month="2026-10"):
        d = os.path.join(self.home, "logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "health-%s.jsonl" % month), "a", encoding="utf-8") as f:
            for l in lines:
                f.write((l if isinstance(l, str) else json.dumps(l)) + "\n")

    def cycle_line(self, ts, seconds=5, code=0, overlap=False):
        return {"ts": ts, "cycle": {"s": seconds, "exit": code, "overlap": overlap}, "idle": [], "over": []}


class Schema(StateCase):
    def test_AC1_created_in_wal_with_the_tables_and_the_version(self):
        "AC-1 a machine with no state.db gets it on connect: WAL, user_version at the last migration, runs and cycles"
        self.assertFalse(os.path.exists(os.path.join(self.home, "state.db")))
        conn = self.state.connect(self.home)
        self.addCleanup(conn.close)
        self.assertTrue(os.path.exists(os.path.join(self.home, "state.db")))
        self.assertEqual(conn.execute("PRAGMA journal_mode").fetchone()[0].lower(), "wal")
        self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], len(self.state.MIGRATIONS))
        self.assertGreaterEqual(len(self.state.MIGRATIONS), 1)
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertLessEqual({"runs", "cycles"}, tables)

    def test_AC1_older_database_migrates_without_losing_rows(self):
        "AC-1 a database at an older version gets the pending migrations and keeps its rows; connecting again changes nothing"
        old = sqlite3.connect(os.path.join(self.home, "state.db"))
        old.execute("CREATE TABLE legacy (k TEXT)")
        old.execute("INSERT INTO legacy VALUES ('kept')")
        old.commit()
        old.close()
        conn = self.state.connect(self.home)
        self.addCleanup(conn.close)
        self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], len(self.state.MIGRATIONS))
        self.assertEqual(conn.execute("SELECT k FROM legacy").fetchall(), [("kept",)])
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0], 0)
        self.assertTrue(self.state.run_started("shop", 7, "develop", 1, "2026-10-01T10:00:00+00:00", "sonnet", "standard",
                                               "claude-code", "/x/a.log") is not False)
        conn.close()
        again = self.state.connect(self.home)
        self.addCleanup(again.close)
        self.assertEqual(again.execute("SELECT COUNT(*) FROM runs").fetchone()[0], 1)
        self.assertEqual(again.execute("PRAGMA user_version").fetchone()[0], len(self.state.MIGRATIONS))


class Import(StateCase):
    def test_AC2_runs_and_cycles_from_the_files(self):
        "AC-2 each run of a log is a row of runs (project, card, stage, start, end, exit, model, weight, cost, log), each health line a row of cycles"
        s, e = "2026-10-01T10:00:00+00:00", "2026-10-01T10:30:00+00:00"
        log = self.runlog("2026-10-01-26-develop.log", (26, s, e, " model=sonnet weight=heavy runtime=claude-code"))
        with open(os.path.join(self.logs, "runs.jsonl"), "w") as f:
            for pid, start, cost in ((100, "2026-10-01T10:00:05+00:00", 1.25), (100, "2026-10-01T10:20:00+00:00", 0.5),
                                     (999, "2026-10-01T10:00:05+00:00", 7.0)):
                f.write(json.dumps({"stage": "develop", "card": 26, "pid": pid, "start": start, "cost_usd": cost}) + "\n")
        self.runlog("2026-10-02-27-develop.log", (27, "2026-10-02T09:00:00+00:00", "2026-10-02T09:10:00+00:00", ""))
        l1, l2 = self.cycle_line("2026-10-01T10:00:00+00:00", 12, 1, True), self.cycle_line("2026-10-01T10:05:00+00:00")
        self.health(l1, l2, '{"ts": "2026-10-01T10:10')  # a line cut short is skipped
        self.state.import_files(self.home)
        rows = self.db().execute("SELECT project, card, stage, started, ended, exit, model, weight, cost_usd, log FROM runs "
                                 "ORDER BY card").fetchall()
        self.assertEqual(len(rows), 2)
        project, card, stage, started, ended, code, model, weight, cost, path = rows[0]
        self.assertEqual((project, card, stage, started, ended, code, model, weight), ("shop", 26, "develop", s, e, 0, "sonnet", "heavy"))
        self.assertAlmostEqual(cost, 1.75)
        self.assertEqual(os.path.realpath(path), os.path.realpath(log))
        self.assertEqual((rows[1][1], rows[1][5], rows[1][6]), (27, 0, None), "a run in the older format has no model")
        cycles = self.db().execute("SELECT ts, seconds, exit, overlap, data FROM cycles ORDER BY ts").fetchall()
        self.assertEqual([c[:4] for c in cycles], [(l1["ts"], 12, 1, 1), (l2["ts"], 5, 0, 0)])
        self.assertEqual(json.loads(cycles[0][4]), l1)

    def test_AC3_import_again_adds_nothing_and_an_ended_run_is_updated(self):
        "AC-3 importing twice leaves the counts; a run with only == start that gains == end is updated, not duplicated"
        s = "2026-10-01T10:00:00+00:00"
        path = self.runlog("2026-10-01-26-develop.log", (26, s, None, " model=sonnet weight=standard runtime=claude-code"))
        self.runlog("2026-10-01-30-develop.log", (30, s, "2026-10-01T11:00:00+00:00", ""))
        self.health(self.cycle_line("2026-10-01T10:00:00+00:00"))
        self.state.import_files(self.home)
        self.assertEqual((self.count("runs"), self.count("cycles")), (2, 1))
        self.assertIsNone(self.db().execute("SELECT ended FROM runs WHERE card = 26").fetchone()[0])
        self.state.import_files(self.home)
        self.assertEqual((self.count("runs"), self.count("cycles")), (2, 1))
        with open(path, "a") as f:
            f.write("== end /sf:develop 26 exit=2 2026-10-01T10:45:00+00:00 outcome=fail\n")
        self.state.import_files(self.home)
        self.assertEqual(self.count("runs"), 2)
        self.assertEqual(self.db().execute("SELECT ended, exit FROM runs WHERE card = 26").fetchone(),
                         ("2026-10-01T10:45:00+00:00", 2))

    def test_AC3_live_writes_upsert_by_log_and_start(self):
        "AC-3 run_started then run_ended on the same (log, start) is one row, finished; a second start of the log is another"
        log = "/x/2026-10-01-26-develop.log"
        s = "2026-10-01T10:00:00+00:00"
        self.state.run_started("shop", 26, "develop", 1, s, "sonnet", "standard", "claude-code", log)
        self.state.run_started("shop", 26, "develop", 1, s, "sonnet", "standard", "claude-code", log)
        self.assertEqual(self.count("runs"), 1)
        self.state.run_ended(log, s, 0, "ok", "2026-10-01T10:30:00+00:00")
        self.assertEqual(self.db().execute("SELECT COUNT(*), ended, exit, outcome FROM runs").fetchone(),
                         (1, "2026-10-01T10:30:00+00:00", 0, "ok"))
        self.state.run_started("shop", 26, "develop", 2, "2026-10-01T12:00:00+00:00", "sonnet", "standard", "claude-code", log)
        self.assertEqual(self.count("runs"), 2)
        line = self.cycle_line("2026-10-01T10:00:00+00:00")
        self.state.record_cycle(line)
        self.state.record_cycle(line)
        self.assertEqual(self.count("cycles"), 1)


class Maintenance(StateCase):
    def test_AC5_retention_90_days_rows_30_days_logs(self):
        "AC-5 runs and cycles over 90 days go, and so do the logs (and their events) of runs all finished over 30 days ago; open and newer stay"
        now = time.time()
        ancient = self.runlog("a-1-develop.log", (1, iso(101, now), iso(100, now), ""))
        old = self.runlog("b-2-develop.log", (2, iso(41, now), iso(40, now), ""))
        recent = self.runlog("c-3-develop.log", (3, iso(11, now), iso(10, now), ""))
        opened = self.runlog("d-4-develop.log", (4, iso(51, now), None, ""))
        mixed = self.runlog("e-5-develop.log", (5, iso(41, now), iso(40, now), ""), (5, iso(6, now), iso(5, now), ""))
        events = [p[:-4] + ".events.jsonl" for p in (old, recent)]
        for p in events:
            with open(p, "w") as f:
                f.write("{}\n")
        self.health(self.cycle_line(iso(100, now)), self.cycle_line(iso(10, now)), month="2026-07")
        self.state.maintain(self.home, now)
        for p in (old, ancient):
            self.assertFalse(os.path.exists(p), p)
        self.assertFalse(os.path.exists(events[0]))
        for p in (recent, opened, mixed, events[1]):
            self.assertTrue(os.path.exists(p), p)
        self.assertEqual([r[0] for r in self.db().execute("SELECT card FROM runs ORDER BY card")], [2, 3, 4, 5, 5])
        self.assertEqual([r[0] for r in self.db().execute("SELECT ts FROM cycles")], [iso(10, now)])

    def backups(self):
        d = os.path.join(self.home, "backups")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def test_AC6_one_backup_a_day_keeping_the_seven_newest(self):
        "AC-6 with no backup of the day one .backup copy is written; a second run the same day writes none; only the 7 newest stay"
        now = time.time()
        bdir = os.path.join(self.home, "backups")
        os.makedirs(bdir)
        for d in range(1, 10):
            with open(os.path.join(bdir, "state-2020-01-0%d.db" % d), "w") as f:
                f.write("old")
        self.runlog("a-1-develop.log", (1, iso(1, now), iso(1, now), ""))
        self.state.maintain(self.home, now)
        names = self.backups()
        today = [n for n in names if not n.startswith("state-2020")]
        self.assertEqual(len(today), 1)
        self.assertRegex(today[0], r"^state-\d{4}-\d\d-\d\d\.db$")
        self.assertEqual(len(names), 7)
        self.assertEqual(names[:6], ["state-2020-01-0%d.db" % d for d in range(4, 10)])
        copy = sqlite3.connect(os.path.join(bdir, today[0]))
        self.addCleanup(copy.close)
        self.assertEqual(copy.execute("SELECT COUNT(*) FROM runs").fetchone()[0], 1)
        with open(os.path.join(bdir, today[0]), "w") as f:
            f.write("marker")
        self.state.maintain(self.home, now)
        self.assertEqual(self.backups(), names)
        with open(os.path.join(bdir, today[0])) as f:
            self.assertEqual(f.read(), "marker", "no second copy the same day")
