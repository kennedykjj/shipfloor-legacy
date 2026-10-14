"""GET /api/day/<project> (#184, AC-3 server side): today's board history and the marks of the logbook line under the belt.
Every mark comes from a recorded fact: a finished run in the run logs (ok, or bad when its report says blocked/infra or it
exited non-zero), or a card that left Spec Review / Staged for an owner move between two history lines (decision). The
server sends keys (kind, what), never English."""
import json
import os
from datetime import datetime, timedelta

import dashboard_support as ds

NOW = datetime.now().astimezone().replace(second=0, microsecond=0)
DAY = NOW.replace(hour=0, minute=0)


def at(h, m=0):
    return DAY.replace(hour=h, minute=m)


def iso(d):
    return d.isoformat(timespec="seconds")


class Day(ds.Dash):
    def runlog(self, n, stage, start, end, exit=0, day=None):
        d = (day or DAY).date().isoformat()
        body = "== start /sf:%s %d %s pid=1\n" % (stage, n, iso(start))
        if end:
            body += "== end /sf:%s %d exit=%d %s\n" % (stage, n, exit, iso(end))
        self.log("%s-%d-%s.log" % (d, n, stage), body)

    def report(self, n, stage, when, outcome):
        self.write("shome/projects/shop/reports-wt/reports/%d-x/%s-%s.json" % (n, stage, when.strftime("%Y-%m-%dT%H%M%S")),
                   json.dumps({"outcome": outcome}) + "\n")

    def history(self, *lines, raw=()):
        path = os.path.join(self.pdir("shop", "logs"), "board-%s.jsonl" % DAY.strftime("%Y-%m"))
        with open(path, "a", encoding="utf-8") as f:
            for r in raw:
                f.write(r + "\n")
            for t, cards in lines:
                f.write(json.dumps({"t": iso(t), "cards": cards}) + "\n")

    def day(self):
        r = self.get("/api/day/shop")
        self.assertEqual(r.code, 200, r.text)
        return r.json

    def test_ac3_a_project_without_history_has_a_day_with_no_marks(self):
        "AC-3 /api/day answers the date, the time and empty board and marks when nothing was recorded; it needs the token and a known project"
        d = self.day()
        self.assertEqual((d["date"], d["board"], d["marks"]), (DAY.date().isoformat(), [], []))
        self.assertIn("now", d)
        self.assertEqual(self.get("/api/day/shop", token=False).code, 403)
        self.assertEqual(self.get("/api/day/nope").code, 404)

    def test_ac3_finished_runs_are_ok_or_bad_ticks(self):
        "AC-3 a finished run of today is an ok mark at its end; blocked, infra and a non-zero exit are bad; a running run and another day's run are none"
        self.runlog(11, "validate", at(1, 0), at(1, 10))
        self.runlog(12, "validate", at(1, 15), at(1, 20))
        self.report(12, "validate", at(1, 17), "blocked")
        self.runlog(13, "develop", at(1, 30), at(1, 40), exit=4)
        self.runlog(14, "refine", at(2, 0), at(2, 5))
        self.report(14, "refine", at(2, 2), "infra")
        self.runlog(15, "develop", at(2, 10), None)  # still running: no end, no mark
        self.runlog(16, "develop", at(3, 0), at(3, 5), day=DAY - timedelta(days=1))
        self.report(11, "validate", at(1, 5), "done")
        marks = [m for m in self.day()["marks"] if m["kind"] in ("ok", "bad")]
        self.assertEqual(sorted((int(m["n"]), m["kind"]) for m in marks), [(11, "ok"), (12, "bad"), (13, "bad"), (14, "bad")])
        by = {int(m["n"]): m for m in marks}
        self.assertEqual(datetime.fromisoformat(by[11]["t"]), at(1, 10))
        self.assertEqual(datetime.fromisoformat(by[13]["t"]), at(1, 40))
        self.assertEqual(by[12]["stage"], "validate")

    def test_ac3_owner_moves_between_history_lines_are_decisions(self):
        "AC-3 a card leaving Spec Review or Staged for an owner move is a decision at the line that saw it; other moves and new cards are not"
        self.history((at(1, 0), {"21": "Spec Review", "22": "Staged", "23": "Spec Review", "24": "Staged", "25": "Coding", "26": "Spec Review"}),
                     (at(1, 10), {"21": "Ready for Dev", "22": "Ready for Prod", "23": "Ready for Refinement", "24": "Coding", "25": "Validation",
                                  "26": "Staged", "27": "Ready for Dev"}),
                     raw=("this line is not json",))
        d = self.day()
        decisions = sorted((int(m["n"]), m["what"]) for m in d["marks"] if m["kind"] == "decision")
        self.assertEqual(decisions, [(21, "approved-spec"), (22, "approved-pr"), (23, "requested-changes"), (24, "requested-changes")])
        self.assertEqual({datetime.fromisoformat(m["t"]) for m in d["marks"]}, {at(1, 10)})
        self.assertEqual([l["cards"]["21"] for l in d["board"]], ["Spec Review", "Ready for Dev"])
        self.assertEqual([datetime.fromisoformat(l["t"]) for l in d["board"]], [at(1, 0), at(1, 10)])

    def test_ac3_the_day_is_read_again_on_every_request(self):
        "AC-3 a line the dispatcher appends after a first read shows in the next one (the page polls it)"
        self.history((at(1, 0), {"31": "Staged"}))
        self.assertEqual([m for m in self.day()["marks"] if m["kind"] == "decision"], [])
        self.history((at(1, 5), {"31": "Ready for Prod"}))
        d = self.day()
        self.assertEqual([(int(m["n"]), m["what"]) for m in d["marks"] if m["kind"] == "decision"], [(31, "approved-pr")])
        self.assertEqual(len(d["board"]), 2)
