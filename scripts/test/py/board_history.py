"""The board history (#184): the dispatcher records where the cards are, one line per change, in
<project home>/logs/board-<YYYY-MM>.jsonl (shipfloor_core/board_history.py, called by Dispatch.read_board).
AC-1 is a line per change, not per cycle; AC-2 is that the files of past months stay when tmp/ is swept."""
import json
import os
import re
import time
from datetime import datetime, timedelta

import dispatch_support as ds
from shipfloor_core import project

ISO = re.compile(ds.ISO)


def snapshot(**cards):
    """a board.tsv as the board script prints it: number, column, item id"""
    return "".join("%s\t%s\tI_%s\n" % (n[1:], col, n[1:]) for n, col in cards.items())


class History(ds.DispatchCase):
    def logs(self):
        return os.path.join(self.home, "logs")

    def files(self):
        return sorted(f for f in os.listdir(self.logs()) if re.fullmatch(r"board-\d{4}-\d\d\.jsonl", f))

    def lines(self):
        out = []
        for f in self.files():
            with open(os.path.join(self.logs(), f), encoding="utf-8") as fh:
                out += [json.loads(l) for l in fh.read().splitlines() if l.strip()]
        return out

    def test_ac1_a_cycle_writes_a_line_only_when_the_board_changed(self):
        "AC-1 two cycles over one board leave one line in logs/board-<YYYY-MM>.jsonl, a cycle after a change adds exactly one"
        self.board(snapshot=snapshot(c11="Inbox", c12="Coding", c13="Done"))
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.files(), ["board-%s.jsonl" % datetime.now().strftime("%Y-%m")])
        first = self.lines()
        self.assertEqual(len(first), 1, "the same board twice is one line")
        self.assertEqual(first[0]["cards"], {"11": "Inbox", "12": "Coding", "13": "Done"})
        self.assertRegex(first[0]["t"], ISO)
        self.board(snapshot=snapshot(c11="Inbox", c12="Validation", c13="Done"))
        self.assertEqual(self.cycle(runs=False), 0)
        lines = self.lines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0], first[0])
        self.assertEqual(lines[1]["cards"], {"11": "Inbox", "12": "Validation", "13": "Done"}, "the whole board, not the diff")
        self.assertRegex(lines[1]["t"], ISO)
        self.assertEqual(list(lines[1]["cards"]), sorted(lines[1]["cards"]), "keys are strings, sorted")

    def test_ac1_record_compares_with_the_last_line_of_the_newest_file(self):
        "AC-1 record: nothing for an empty read or an unchanged board (also across a month), a line for a new board, False when logs/ cannot be written"
        from shipfloor_core import board_history
        home = self.path("rec")
        os.makedirs(os.path.join(home, "logs"))
        t0 = datetime(2026, 10, 31, 23, 50).astimezone()
        board_history.record(home, [], now=t0)
        self.assertEqual(os.listdir(os.path.join(home, "logs")), [], "an empty read proves nothing: no file")
        board_history.record(home, [("12", "Coding"), ("11", "Inbox")], now=t0)
        board_history.record(home, [("11", "Inbox"), ("12", "Coding")], now=t0 + timedelta(minutes=30))  # next month, same board
        self.assertEqual(os.listdir(os.path.join(home, "logs")), ["board-2026-10.jsonl"])
        board_history.record(home, [("11", "Inbox"), ("12", "Validation")], now=t0 + timedelta(minutes=40))
        self.assertEqual(sorted(os.listdir(os.path.join(home, "logs"))), ["board-2026-10.jsonl", "board-2026-11.jsonl"])
        self.assertEqual([l["cards"] for f in ("2026-10", "2026-11") for l in
                          map(json.loads, open(os.path.join(home, "logs", "board-%s.jsonl" % f), encoding="utf-8").read().splitlines())],
                         [{"11": "Inbox", "12": "Coding"}, {"11": "Inbox", "12": "Validation"}])
        self.assertEqual(datetime.fromisoformat(board_history.day(home, t0.date())[0]["t"]), t0)
        broken = self.path("broken")
        with open(os.path.join(broken, "logs"), "w") as f:  # logs is a file: the write fails
            f.write("x")
        self.assertIs(board_history.record(broken, [("11", "Inbox")], now=t0), False)

    def test_ac1_day_lists_the_lines_of_that_date_and_skips_bad_ones(self):
        "AC-1 day: the lines of one local date in file order; a line that is not JSON is skipped"
        from shipfloor_core import board_history
        home = self.path("day")
        t = datetime(2026, 10, 14, 9, 0).astimezone()
        rows = [{"t": (t - timedelta(days=1)).isoformat(), "cards": {"1": "Inbox"}}, {"t": t.isoformat(), "cards": {"1": "Coding"}},
                {"t": (t + timedelta(hours=1)).isoformat(), "cards": {"1": "Done"}}]
        self.write("day/logs/board-2026-10.jsonl", "\n".join([json.dumps(rows[0]), "not json", json.dumps(rows[1]), json.dumps(rows[2])]) + "\n")
        self.assertEqual(board_history.day(home, t.date()), rows[1:])

    def test_ac2_past_months_stay_when_tmp_is_swept(self):
        "AC-2 board-<month>.jsonl of past months survive a cycle's sweep of tmp/ (which does remove what it should)"
        old = [os.path.join(self.logs(), n) for n in ("board-2025-12.jsonl", "board-2026-01.jsonl")]
        for p in old:
            with open(p, "w", encoding="utf-8") as f:
                f.write('{"t": "2025-12-31T10:00:00+00:00", "cards": {"1": "Inbox"}}\n')
            long_ago = time.time() - 400 * 86400
            os.utime(p, (long_ago, long_ago))
        os.makedirs(os.path.join(self.home, "tmp", "5", "x"))
        self.board(snapshot=snapshot(c5="Done", c6="Coding"))
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertFalse(os.path.exists(os.path.join(self.home, "tmp", "5")), "the cycle swept tmp/")
        self.assertEqual(project.sweep_tmp(), [])
        for p in old:
            self.assertTrue(os.path.exists(p), p)
        self.assertEqual(self.files(), ["board-2025-12.jsonl", "board-2026-01.jsonl", "board-%s.jsonl" % datetime.now().strftime("%Y-%m")])
