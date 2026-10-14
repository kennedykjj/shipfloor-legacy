"""Shared by the notification suites: a home with one project (shop) and its board, the last health line, and
shipfloor_notify.cycle called in process with two doubles: the transport (send) records what each channel is handed
and fails the channels a test names; the titles read (gh_json) answers from a dict, or fails."""
import contextlib
import io
import os
import shutil
from datetime import datetime

import shipfloor_notify
from support import FIXTURE, SCRIPTS, Case

TITLES = {7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten", 11: "Eleven", 12: "Twelve"}
TOAST = "notify: {channels: {toast: true}}"


class NotifyCase(Case):
    def setUp(self):
        super().setUp()
        self.H = self.path("h")
        self.P = self.path("h", "projects", "shop")
        self.path("h", "logs")
        self.write("h/registry.tsv", "shop\t/x/shop\t/x/wt\tmain\n")
        shutil.copy(os.path.join(FIXTURE, "factory.yml"), os.path.join(self.P, "factory.yml"))
        self.sent, self.fail_channels, self.titles, self.gh_down, self.err = [], set(), dict(TITLES), False, ""
        self.gh_calls, self.topics = [], []
        # a sender is set: the toast is a channel off Windows too (the real one never runs, send is a double)
        os.environ["SHIPFLOOR_NOTIFY_SEND"] = "test-double"
        # what the dashboard asks gh (board urls, block labels) goes to the fake gh, never the real one and its network
        os.environ.update(FACTORY_GH=os.path.join(SCRIPTS, "test", "fake-gh"), FAKE_GH_DIR=self.path("fake-gh"), FAKE_GH_NO_JQ="1")
        saved = shipfloor_notify.send, shipfloor_notify.gh_json
        self.addCleanup(lambda: (setattr(shipfloor_notify, "send", saved[0]), setattr(shipfloor_notify, "gh_json", saved[1])))
        shipfloor_notify.send = self._send
        shipfloor_notify.gh_json = self._gh_json
        self.health("false")

    def _send(self, channel, title, body, topic):
        self.sent.append("%s\t%s\t%s" % (channel, title, body.replace("\r", "").replace("\n", "|")))
        self.topics.append(topic)
        return "boom: %s is down" % channel if channel in self.fail_channels else None

    def _gh_json(self, *args):
        self.gh_calls.append(args)
        if self.gh_down:
            return None, "gh: network error"
        return [{"number": n, "title": t} for n, t in self.titles.items()], None

    def health(self, usage_limited, blocked="", ts="2026-10-11T10:00:00-03:00"):
        """the health line a dispatcher cycle leaves (appended)"""
        line = ('{"ts":"%s","paused":false,"usage_limited":%s,"projects":{"shop":{"paused":false,"skipped":false,'
                '"blocked":0,"blocked_cards":[%s]}}}\n') % (ts, usage_limited, blocked)
        with open(os.path.join(self.H, "logs", "health-2026-10.jsonl"), "a") as f:
            f.write(line)

    def board(self, text):
        self.write("h/projects/shop/board.tsv", text)

    def conf(self, text):
        self.write("h/config.yml", text + "\n")

    def cycle(self, at):
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            shipfloor_notify.cycle(self.H, datetime.fromisoformat(at))
        self.err += buf.getvalue()

    def n_is(self, n):
        self.assertEqual(len(self.sent), n, self.sent)

    def has(self, line):
        self.assertIn(line, self.sent)

    def has_part(self, text):
        self.assertTrue(any(text in s for s in self.sent), "no line with %r in %r" % (text, self.sent))
