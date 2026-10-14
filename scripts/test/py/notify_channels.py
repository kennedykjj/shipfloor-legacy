"""Notification channels and settings: the push carries only the project, number, title and state, nothing leaves
the machine without a topic (AC-6); a failing channel is one log line and the other still delivers (AC-7); send()'s
three transports (a sender command, the Windows toast, ntfy) with doubles, never the network; the dashboard's
machine.notify settings, checked by shipfloor_config and applied from the next cycle (AC-8)."""
import io
import json
import os
import subprocess
import urllib.error
import urllib.request

import dashboard
import shipfloor_notify
from notify_support import NotifyCase

T = "\t"
BOTH = "notify: {channels: {toast: true, ntfy: true}, ntfy_topic: secret_topic_xyz}"
WAIT7 = "shop · #7 waits for you" + T + "Seven|Spec Review · spec to review"


class Push(NotifyCase):
    def test_only_what_it_needs(self):
        "AC-6 the push has the project, number, title and state; no spec text, path, token or topic is sent or logged"
        self.conf(BOTH)
        self.board("7\tSpec Review\tI7\n")
        self.write("h/projects/shop/SKIPPED", "2026-10-11T09:00:00\tcannot bring the control checkout: fatal: /secret/dir/.git/index.lock ghp_TOKEN123\n")
        self.write("h/projects/shop/reviews/7.html", "<html>SPEC-SECRET-TEXT in /secret/dir/src/Main.kt</html>")
        self.cycle("2026-10-11T10:00:00")
        self.has("ntfy" + T + WAIT7)
        self.has("ntfy" + T + "shop · the factory is stuck" + T + "The dispatcher skips this project. The dashboard says why.")
        everything = "\n".join(self.sent) + self.err
        for secret in ("SPEC-SECRET-TEXT", "/secret/dir", "ghp_TOKEN123", "secret_topic_xyz"):
            self.assertNotIn(secret, everything)

    def test_title_cut(self):
        "AC-6 a title of 100 characters is cut at 80 with an ellipsis"
        self.titles[13] = "abcdefghij" * 10
        self.conf(BOTH)
        self.board("13\tSpec Review\tI13\n")
        self.cycle("2026-10-11T10:00:00")
        line = [s for s in self.sent if s.startswith("ntfy") and "shop · #13 waits for you" in s][0]
        first = line.split(T)[2].split("|")[0]
        self.assertEqual(first, ("abcdefghij" * 8)[:79] + "…")

    def test_no_topic_no_push(self):
        "AC-6 with no topic, or a topic with the phone switch off, only the toast tells"
        for conf in ("notify: {channels: {toast: true}}", "notify: {channels: {toast: true}, ntfy_topic: secret_topic_xyz}"):
            with self.subTest(conf=conf):
                self.sent.clear()
                os.path.exists(self.H + "/notify.json") and os.remove(self.H + "/notify.json")
                self.conf(conf)
                self.board("7\tSpec Review\tI7\n")
                self.cycle("2026-10-11T10:00:00")
                self.assertEqual(self.sent, ["toast" + T + WAIT7])

    def test_toast_only_on_windows(self):
        "the toast is a channel on Windows (or with a sender command set), not on another machine"
        del os.environ["SHIPFLOOR_NOTIFY_SEND"]
        self.conf("notify: {channels: {toast: true}}")
        self.board("7\tSpec Review\tI7\n")
        self.cycle("2026-10-11T10:00:00")
        self.n_is(0)


class Failures(NotifyCase):
    def test_one_channel_fails(self):
        "AC-7 the push delivers when the toast fails; one log line, never the topic; a wait one channel delivered is not tried again"
        self.conf(BOTH)
        self.board("7\tSpec Review\tI7\n")
        self.fail_channels = {"toast"}
        self.cycle("2026-10-11T10:00:00")
        self.has("ntfy" + T + WAIT7)
        self.assertEqual(self.err.count("shipfloor: notify: toast failed:"), 1, self.err)
        self.assertNotIn("secret_topic_xyz", self.err)
        self.cycle("2026-10-11T10:05:00")
        self.n_is(2)

    def test_failed_channel_not_retried_in_cycle(self):
        "a channel that failed is not tried again in the same cycle: two waits, the toast is tried once"
        self.conf(BOTH)
        self.board("7\tSpec Review\tI7\n8\tStaged\tI8\n")
        self.fail_channels = {"toast"}
        self.cycle("2026-10-11T10:00:00")
        self.assertEqual(sum(s.startswith("toast") for s in self.sent), 1)
        self.assertEqual(sum(s.startswith("ntfy") for s in self.sent), 2)

    def test_every_channel_down(self):
        "AC-7 with every channel failing the wait is tried again each cycle until a channel delivers, then told"
        self.conf(BOTH)
        self.board("7\tSpec Review\tI7\n")
        self.fail_channels = {"toast", "ntfy"}
        self.cycle("2026-10-11T10:00:00")
        self.n_is(2)
        self.cycle("2026-10-11T10:05:00")
        self.n_is(4)
        self.fail_channels = set()
        self.cycle("2026-10-11T10:10:00")
        self.n_is(6)
        self.cycle("2026-10-11T10:15:00")
        self.n_is(6)

    def test_gh_down(self):
        "AC-7 titles that cannot be read: the notification goes out with the number only, and the log says why"
        self.conf("notify: {channels: {toast: true}}")
        self.board("7\tSpec Review\tI7\n")
        self.gh_down = True
        self.cycle("2026-10-11T10:00:00")
        self.has("toast" + T + "shop · #7 waits for you" + T + "Spec Review · spec to review")
        self.assertIn("shipfloor: notify: titles of shop not read: gh: network error", self.err)

    def test_bad_state_file(self):
        "a notify.json that is not a JSON object is read as no state (the waits are told anew)"
        self.write("h/notify.json", "[1, 2]")
        self.conf("notify: {channels: {toast: true}}")
        self.board("7\tSpec Review\tI7\n")
        self.cycle("2026-10-11T10:00:00")
        self.assertEqual(self.sent, ["toast" + T + WAIT7])
        self.assertIn('"cards"', open(self.H + "/notify.json").read())


class Send(NotifyCase):
    """send() for real (the setUp double put back), each transport behind its own double"""

    def setUp(self):
        super().setUp()
        shipfloor_notify.send = type(self).real_send

    def test_sender_command(self):
        "SHIPFLOOR_NOTIFY_SEND is run as <command> <channel> <title> <body>: exit 0 delivered, else 'the sender failed', a hang 'timed out'"
        out = self.path("args")
        os.environ["SHIPFLOOR_NOTIFY_SEND"] = self.write("send.sh", 'printf "%%s\\n" "$@" > %s/got; [ "$1" = toast ] || exit 1\n' % out)
        self.assertIsNone(shipfloor_notify.send("toast", "a title", "the body", "t"))
        self.assertEqual(open(out + "/got").read(), "toast\na title\nthe body\n")
        self.assertEqual(shipfloor_notify.send("ntfy", "x", "y", "t"), "the sender failed")
        saved = shipfloor_notify.TIMEOUT_S
        self.addCleanup(setattr, shipfloor_notify, "TIMEOUT_S", saved)
        shipfloor_notify.TIMEOUT_S = 0.2
        os.environ["SHIPFLOOR_NOTIFY_SEND"] = self.write("hang.sh", "sleep 5\n")
        self.assertEqual(shipfloor_notify.send("toast", "x", "y", "t"), "timed out")

    def test_toast(self):
        "the toast runs powershell.exe with the encoded script; the title and body go in the environment, never in argv"
        del os.environ["SHIPFLOOR_NOTIFY_SEND"]
        got = self.double("powershell.exe", "import os; log([os.environ['SHIPFLOOR_TOAST_TITLE'], os.environ['SHIPFLOOR_TOAST_BODY']])\n"
                                            "sys.exit(int(os.environ.get('PS_EXIT', '0')))")
        self.assertIsNone(shipfloor_notify.send("toast", "shop · #7", "Seven", ""))
        self.assertEqual(got()[0], ["-NoProfile", "-NonInteractive", "-EncodedCommand", shipfloor_notify.TOAST_ARG])
        self.assertEqual(got()[1], ["shop · #7", "Seven"])
        os.environ["PS_EXIT"] = "1"
        self.assertEqual(shipfloor_notify.send("toast", "x", "y", ""), "powershell failed")

    def test_ntfy(self):
        "ntfy: a POST of the body to ntfy.sh/<topic> with the title in RFC 2047; an HTTP error is its code, a network error its type, never the URL"
        del os.environ["SHIPFLOOR_NOTIFY_SEND"]
        seen, outcome = [], [None]

        class Reply(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def urlopen(req, timeout):
            seen.append((req.full_url, req.get_method(), req.data, req.get_header("Title"), timeout))
            if outcome[0]:
                raise outcome[0]
            return Reply(b"")
        saved = urllib.request.urlopen
        self.addCleanup(setattr, urllib.request, "urlopen", saved)
        urllib.request.urlopen = urlopen
        self.assertIsNone(shipfloor_notify.send("ntfy", "shop · #7", "Seven", "abc_123"))
        url, method, data, title, timeout = seen[0]
        self.assertEqual((url, method, data, timeout), ("https://ntfy.sh/abc_123", "POST", b"Seven", 20))
        self.assertEqual(title, "=?UTF-8?B?c2hvcCDCtyAjNw==?=")
        outcome[0] = urllib.error.HTTPError("https://ntfy.sh/abc_123", 502, "bad", {}, None)
        self.assertEqual(shipfloor_notify.send("ntfy", "x", "y", "abc_123"), "HTTP 502")
        outcome[0] = urllib.error.URLError("https://ntfy.sh/abc_123 unreachable")
        self.assertEqual(shipfloor_notify.send("ntfy", "x", "y", "abc_123"), "URLError")

    def test_ac5_click_link(self):
        "AC-5 the link to the card goes as the Click header (ntfy) or the sender's fourth argument; with no link, ntfy sends no Click and the sender gets an empty fourth argument"
        link = "http://127.0.0.1:7719/#card/7"
        out = self.path("args5")
        os.environ["SHIPFLOOR_NOTIFY_SEND"] = self.write("send5.sh", 'printf "%%s\\n" "$@" > %s/got\n' % out)
        self.assertIsNone(shipfloor_notify.send("toast", "a title", "the body", "t", link))
        self.assertEqual(open(out + "/got").read(), "toast\na title\nthe body\n%s\n" % link)
        self.assertIsNone(shipfloor_notify.send("toast", "a title", "the body", "t", ""))
        self.assertEqual(open(out + "/got").read(), "toast\na title\nthe body\n\n")
        del os.environ["SHIPFLOOR_NOTIFY_SEND"]
        seen = []

        class Reply(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def urlopen(req, timeout):
            seen.append(req.get_header("Click"))
            return Reply(b"")
        saved = urllib.request.urlopen
        self.addCleanup(setattr, urllib.request, "urlopen", saved)
        urllib.request.urlopen = urlopen
        self.assertIsNone(shipfloor_notify.send("ntfy", "shop · #7", "Seven", "abc_123", link))
        self.assertIsNone(shipfloor_notify.send("ntfy", "shop · #7", "Seven", "abc_123", ""))
        self.assertEqual(seen, [link, None])

    def test_ac5_click_url_reads_the_port_file(self):
        "AC-5 click_url(home, n) is http://127.0.0.1:<port>/#card/<n> when <home>/dashboard.port holds a port in 1-65535, else empty"
        path = os.path.join(self.H, "dashboard.port")
        self.assertEqual(shipfloor_notify.click_url(self.H, 7), "")
        for text, want in (("7719\n", "http://127.0.0.1:7719/#card/7"), ("65535", "http://127.0.0.1:65535/#card/7"),
                           ("0\n", ""), ("65536\n", ""), ("abc\n", ""), ("", "")):
            with open(path, "w") as f:
                f.write(text)
            self.assertEqual(shipfloor_notify.click_url(self.H, 7), want, repr(text))


Send.real_send = staticmethod(shipfloor_notify.send)

DEFAULTS = {"channels": {"ntfy": False, "toast": True}, "events": {"blocked": True, "done": False, "reminder": True, "stuck": True, "waiting": True},
            "ntfy_topic": "", "quiet": "", "reminder_min": 60}


class Settings(NotifyCase):
    """machine.notify through the dashboard's settings calls (dashboard.Factory.settings / set_machine)"""

    def setUp(self):
        super().setUp()
        os.environ["CLAUDE_CONFIG_DIR"] = self.path("claude")
        self.conf("pool: 6\nlanguage: pt-BR")

    def save(self, notify):
        return dashboard.Factory(self.H, "").set_machine({"notify": notify})

    def notify(self):
        return dashboard.Factory(self.H, "").settings()["machine"]["notify"]

    def config(self):
        return open(self.H + "/config.yml").read()

    def accepted(self, notify):
        code, body = self.save(notify)
        self.assertEqual(code, 200, body)

    def refused(self, notify, sentence=None):
        before = self.config()
        code, body = self.save(notify)
        self.assertEqual(code, 400, (notify, body))
        if sentence:
            self.assertIn(sentence, body["error"])
        self.assertEqual(self.config(), before, "a refused save wrote config.yml")
        return body

    def test_defaults_and_merge(self):
        "AC-8 the settings give machine.notify with the defaults; a partial save is merged key by key and the rest of config.yml stays"
        self.assertEqual(self.notify(), DEFAULTS)
        self.accepted({"events": {"done": True}, "reminder_min": 45})
        want = json.loads(json.dumps(DEFAULTS))
        want["events"]["done"], want["reminder_min"] = True, 45
        self.assertEqual(self.notify(), want)
        self.assertIn("pool: 6", self.config())
        self.assertIn("language: pt-BR", self.config())

    def test_accepted_values(self):
        "AC-8 a topic with the phone push and quiet hours, reminders of 15 and 720, empty quiet hours, a 64-character topic are accepted"
        for n in ({"ntfy_topic": "long_Random-topic_42", "channels": {"ntfy": True}, "quiet": "23:00-08:00"}, {"reminder_min": 15},
                  {"reminder_min": 720}, {"quiet": ""}, {"channels": {"ntfy": False}, "ntfy_topic": ""}, {"ntfy_topic": "a" * 64},
                  {"ntfy_topic": ""}):
            with self.subTest(notify=n):
                self.accepted(n)

    def test_refused_values(self):
        "AC-8 invalid values are refused with the spec's sentence (and its catalog key) and nothing is written"
        for n, sentence, key in (({"reminder_min": 14}, "The reminder takes 15 to 720 minutes.", "err.reminder"),
                                 ({"reminder_min": 721}, "The reminder takes 15 to 720 minutes.", "err.reminder"),
                                 ({"reminder_min": "60"}, "The reminder takes 15 to 720 minutes.", "err.reminder"),
                                 ({"quiet": "23:00-23:00"}, "Quiet hours need both times, and they cannot be the same.", "err.quiet"),
                                 ({"quiet": "23:00"}, "Quiet hours need both times, and they cannot be the same.", "err.quiet"),
                                 ({"ntfy_topic": "has space!"}, "The topic takes letters, digits, - and _, up to 64.", "err.topic"),
                                 ({"ntfy_topic": "a" * 65}, "The topic takes letters, digits, - and _, up to 64.", "err.topic"),
                                 ({"channels": {"ntfy": True}}, "The phone push needs a topic.", "err.ntfy_topic")):
            with self.subTest(notify=n):
                body = self.refused(n, sentence)
                self.assertIn(key, [e.get("key") for e in body["errors"]])
        for n, why in (({"events": {"waiting": "yes"}}, "notify.events.waiting must be true or false"),
                       ({"colour": "red"}, "notify.colour: unknown setting"),
                       ({"events": {"launch": True}}, "notify.events.launch: unknown setting"),
                       ({"events": "all"}, "notify.events must be a mapping")):
            with self.subTest(notify=n):
                self.refused(n, why)
        code, body = dashboard.Factory(self.H, "").set_machine({"notify": "on"})
        self.assertEqual((code, body["error"]), (400, "notify must be a mapping"))

    def test_applies_next_cycle(self):
        "AC-8 a saved change applies from the next cycle; with every event or every channel off nothing is sent"
        self.conf("pool: 6")
        self.board("")
        self.cycle("2026-10-11T10:00:00")
        self.accepted({"events": {"waiting": False, "blocked": False, "reminder": False, "stuck": False, "done": False}})
        self.board("8\tSpec Review\tI8\n")
        self.cycle("2026-10-11T10:05:00")
        self.n_is(0)
        self.accepted({"events": {"waiting": True}, "channels": {"toast": False}})
        self.board("8\tSpec Review\tI8\n9\tStaged\tI9\n")
        self.cycle("2026-10-11T10:10:00")
        self.n_is(0)
        self.accepted({"channels": {"toast": True}})
        self.board("8\tSpec Review\tI8\n9\tStaged\tI9\n10\tStaged\tI10\n")
        self.cycle("2026-10-11T10:15:00")
        self.has_part("toast" + T + "shop · #10 waits for you" + T)
        self.accepted({"events": {"waiting": False}})
        self.board("8\tSpec Review\tI8\n9\tStaged\tI9\n10\tStaged\tI10\n11\tStaged\tI11\n")
        self.cycle("2026-10-11T10:20:00")
        self.assertFalse(any("shop · #11 waits for you" in s for s in self.sent), self.sent)
