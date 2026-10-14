"""What the dashboard shows, through its API: a card's cost from the Claude Code transcripts, the overview (typical
times, live steps, cost limits, skipped projects), the Feed (#114), the History (#130), the page's catalog (#122), the
review pages, and the routes' guards (the token, card numbers in ASCII digits only, paths outside logs). Also the
shell the server picks (find_bash) and the link's secret that survives a restart (link_token)."""
import json
import os
import re
import stat
import time
from datetime import datetime, timedelta

import dashboard_support as ds
from dashboard_support import ast, cmd, slash

U = {"input_tokens": 1000000, "output_tokens": 100000, "cache_read_input_tokens": 1000000, "cache_creation_input_tokens": 1000000,
     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 1000000}}


def clear_of_midnight(before_s, after_s=0):
    """the tests that write runs of "today" never straddle midnight: wait it out when it is that close"""
    now = datetime.now()
    left = (datetime.combine(now.date() + timedelta(days=1), datetime.min.time()) - now).total_seconds()
    if left < before_s:
        time.sleep(left + 2)
    since = (now - datetime.combine(now.date(), datetime.min.time())).total_seconds()
    if since < after_s:
        time.sleep(after_s - since + 2)


class Views(ds.Dash):
    def card7(self):
        """card 7: a develop session (two log lines per API message, one subagent, a half-written last line), a legacy
        /mylos refine session; card 14 a legacy /aghanim one; a manual session (ignored). Card 7 is US$ 24.30."""
        self.transcript("s1", cmd("<command-message>sf:develop</command-message>\n<command-name>/sf:develop</command-name>\n<command-args>7</command-args>"),
                        ast("m1", "claude-opus-5-5", U), ast("m1", "claude-opus-5-5", U), '{"type":"assistant","mess')
        self.transcript("s1", ast("a1", "claude-sonnet-5-5", {"input_tokens": 0, "output_tokens": 1000000}), sub="agent-a")
        self.transcript("s2", cmd([{"type": "text", "text": "<command-name>/mylos:refinar</command-name>\n<command-args>7</command-args>"}]),
                        ast("m2", "claude-haiku-5-5", {"input_tokens": 1000000, "output_tokens": 0}))
        self.transcript("s5", cmd([{"type": "text", "text": "<command-name>/aghanim:desenvolver</command-name>\n<command-args>14</command-args>"}]),
                        ast("m4", "claude-haiku-5-5", {"input_tokens": 1000000, "output_tokens": 0}))
        self.transcript("s3", cmd("hello"), ast("m3", "claude-opus-5-5", {"input_tokens": 1000000, "output_tokens": 0}))


class Card(Views):
    def test_cost_title_block(self):
        "a card's cost is its sessions' (subagents in, a message logged twice counted once, legacy /mylos and /aghanim runs too, manual ones out); title and block from gh JSON"
        self.card7()
        c = self.get("/api/card/shop/7").json
        self.assertEqual((c["total"], len(c["sessions"]), sorted(s["stage"] for s in c["sessions"])), (24.3, 2, ["develop", "refine"]))
        c14 = self.get("/api/card/shop/14").json
        self.assertEqual((c14["total"], [s["stage"] for s in c14["sessions"]]), (0.1, ["develop"]))
        self.assertEqual((c["title"], c["blocked"], c["block_reason"]), ("Seven", "owner", "**Validate blocked (infrastructure)**: stack down"))
        self.transcript("bad", '{"type":"user","timestamp":"not a time","message":{"content":"<command-name>/sf:develop</command-name><command-args>8</command-args>"}}\n')
        self.assertEqual(self.get("/api/card/shop/8").code, 200, "an unreadable transcript is skipped")

    def test_overview(self):
        "the overview: how long a stage usually takes (clean runs), when a card's last run ended, a project the dispatcher skips"
        self.log("2026-10-09-7-develop.log", "== start /sf:develop 7 2026-10-09T10:00:00-03:00 pid=1\n== end /sf:develop 7 exit=0 2026-10-09T10:01:00-03:00\n"
                 "== start /sf:develop 7 2026-10-09T11:00:00-03:00 pid=2\n== end /sf:develop 7 exit=4 2026-10-09T11:30:00-03:00\n")
        self.board({7: "Staged"})
        p = self.overview()["projects"][0]
        self.assertEqual((p["typical_s"], [c["since"] for c in p["cards"] if c["issue"] == 7]), ({"develop": 60}, ["2026-10-09T11:30:00-03:00"]))
        self.assertFalse(p.get("skipped"))
        self.write("shome/projects/shop/SKIPPED", "2026-10-09T20:06:50-03:00\tcannot bring the control checkout to origin/main: index.lock exists\n")
        s = self.overview()["projects"][0]["skipped"]
        self.assertEqual(s["since"], "2026-10-09T20:06:50-03:00")
        self.assertTrue(s["reason"].startswith("cannot bring the control checkout"))

    def test_shipped_today(self):
        "#182: the overview lists per project the cards that reached Done today, newest first, with their last PR and cost estimate; yesterday's and cards still before Done are left out"
        clear_of_midnight(120)
        now = datetime.now().astimezone()
        at = lambda minutes: (now - timedelta(minutes=minutes)).isoformat(timespec="seconds")
        self.board({30: "Done", 31: "Done", 32: "Done", 33: "Staged"})
        for n, ago in ((30, 20), (31, 10), (32, 24 * 60 + 10), (33, 5)):
            day = (now - timedelta(minutes=ago)).strftime("%Y-%m-%d")
            self.log("%s-%d-deploy.log" % (day, n), "== start /sf:deploy %d %s pid=1\n== end /sf:deploy %d exit=0 %s\n" % (n, at(ago + 5), n, at(ago)))
        self.write("shome/projects/shop/reports-wt/reports/30-a/deploy-%sT100000.json" % now.strftime("%Y-%m-%d"), '{"outcome":"done","pr":66}\n')
        shipped = self.overview()["projects"][0]["shipped"]
        self.assertEqual([(s["issue"], s["pr"], s["at"]) for s in shipped], [(31, None, at(10)), (30, 66, at(20))])
        self.assertEqual(sorted(shipped[0]), ["at", "cost", "issue", "pr", "title"])

    def test_live_step(self):
        "a live run tells its step, as its place among the stage's steps, and the last things its session did"
        d = self.lock("validate-9", 9)
        self.write(os.path.relpath(os.path.join(d, "info"), self.tmp), "1 1791600000 9\n")
        self.write(os.path.relpath(os.path.join(d, "step"), self.tmp), "3\t1791600300\n")
        self.transcript("s4", slash("validate", 9), {"type": "assistant", "timestamp": "2026-10-09T10:06:00Z", "message": {"id": "m9", "content": [
            {"type": "text", "text": "The e2e gate failed; reading its log."}, {"type": "tool_use", "name": "Bash", "input": {"description": "Rerun the e2e gate", "command": "x"}}]}})
        r = next(x for x in self.overview()["runs"] if x["issue"] == 9)
        self.assertEqual((r["step"]["i"], r["steps"], r["step"]["label"], [(a["kind"], a["text"]) for a in r["activity"]]),
                         (3, 5, "Review", [("says", "The e2e gate failed; reading its log."), ("Bash", "Rerun the e2e gate")]))

    def test_runs_today(self):
        "the history lists today's runs newest first; the deploy script's own lock inside a deploy run is not a second run; the overview carries no hours or ended"
        clear_of_midnight(120)
        d = datetime.now().strftime("%Y-%m-%d")
        self.log("%s-12-refine.log" % d, "== start /sf:refine 12 {d}T08:00:00-03:00 pid=1\n== end /sf:refine 12 exit=0 {d}T08:09:00-03:00\n"
                 "== start /sf:refine 12 {d}T09:00:00-03:00 pid=2\n== end /sf:refine 12 exit=3 {d}T09:01:00-03:00\n".format(d=d))
        self.lock("develop-11", 11); self.lock("deploysh-11", 11)
        runs = self.get("/api/history/shop").json["runs"]
        self.assertEqual([(r["issue"], r["stage"], r["exit"], r["cost"]) for r in runs], [(12, "refine", 3, 0.0), (12, "refine", 0, 0.0)])
        o = self.overview()
        self.assertEqual([(r["issue"], r["stage"]) for r in o["runs"]], [(11, "develop")])
        self.assertFalse("hours" in o["projects"][0] or "ended" in o["projects"][0])


class Costs(Views):
    """cost limits in this machine's config.yml: costs.card_warn / card_block / day_stop"""

    def setUp(self):
        super().setUp()
        clear_of_midnight(150)
        self.card7()
        self.board({7: "Staged", 30: "Coding"})

    def sess(self, name, n, model, tokens, day):
        tz = datetime.now().astimezone().strftime("%z")
        tz = tz[:3] + ":" + tz[3:]
        self.transcript(name, slash("develop", n, "%sT12:00:00%s" % (day, tz)), ast("c-" + name, model, {"input_tokens": tokens, "output_tokens": 0}, "%sT12:05:00%s" % (day, tz)))

    def test_card_warning(self):
        "a card over card_warn is flagged; the figure against the limits is the estimate less the baseline of its last cost block; no costs, no flag"
        o = self.overview(); c = {x["issue"]: x for x in o["projects"][0]["cards"]}
        self.assertEqual((c[7].get("over"), c[30].get("over")), (None, None))
        k = o.get("costs") or {}
        self.assertEqual((k.get("card_warn"), k.get("card_block"), k.get("day_stop")), (None, None, None))
        self.config("pool: 6\ncosts:\n  card_warn: 20\n  card_block: 40\n  day_stop: 80\n")
        o = self.overview(); c7 = self.cards()[7]
        self.assertEqual((c7["over"], round(c7["spent"], 2), c7["cost"]), ("warn", 24.3, 24.3))
        self.assertEqual((o["costs"]["card_warn"], o["costs"]["card_block"], o["costs"]["day_stop"], o["costs"]["day_stopped"]), (20, 40, 80, False))
        self.config("pool: 6\ncosts:\n  card_warn: 25\n  card_block: 40\n")
        self.assertIsNone(self.cards()[7]["over"])
        self.config("pool: 6\ncosts:\n  card_block: 40\n  day_stop: 80\n")
        self.assertEqual((self.cards()[7]["over"], self.overview()["costs"]["card_warn"]), (None, None), "no card_warn, no flag")
        self.config("pool: 6\ncosts:\n  card_warn: 14\n  card_block: 40\n")
        os.makedirs(os.path.join(self.P, "cost"))
        self.write("shome/projects/shop/cost/7.json", '{"at":"2026-10-09T12:00:00-03:00","limit":40,"total":10,"baseline":0,"stages":{"develop":10}}\n')
        c7 = self.cards()[7]
        self.assertEqual((c7["over"], round(c7["spent"], 2), c7["cost"]), ("warn", 14.3, 24.3), "the marker's total is the next baseline")
        self.write("shome/projects/shop/cost/7.json", '{"at":"2026-10-09T12:00:00-03:00","limit":40,"total":15,"baseline":0,"stages":{"develop":15}}\n')
        c7 = self.cards()[7]
        self.assertEqual((c7["over"], round(c7["spent"], 2), c7["cost"]), (None, 9.3, 24.3))

    def test_unpriced_model(self):
        "a card that ran on a model with no price has an unknown estimate: never flagged, adds nothing to the day, counted as unpriced"
        self.config("pool: 6\ncosts:\n  card_warn: 1\n  card_block: 2\n  day_stop: 5\n")
        self.sess("u30", 30, "claude-mystery-1", 900000000, datetime.now().strftime("%Y-%m-%d"))
        c30, o = self.cards()[30], self.overview()
        self.assertEqual((c30["cost"], c30.get("over", "MISSING"), c30.get("spent", "MISSING")), (None, None, None))
        self.assertEqual((o["today"]["cost"], o["costs"]["day_stopped"]), (0.0, False))
        self.assertEqual(self.settings()["unpriced"], 1)

    def test_day_stop(self):
        "today's estimate across projects past day_stop stops the day; the next local day clears it; no day_stop never stops"
        self.config("pool: 6\ncosts:\n  day_stop: 80\n")
        today, yday = datetime.now().strftime("%Y-%m-%d"), (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        self.sess("d21", 21, "claude-opus-5-5", 25000000, today)  # US$ 100 today
        self.assertEqual((self.overview()["costs"]["day_stop"], self.overview()["costs"]["day_stopped"]), (80, True))
        self.sess("d21", 21, "claude-opus-5-5", 25000000, yday)
        with open(os.path.join(self.T, "d21.jsonl"), "a") as f:
            f.write("\n")
        self.assertIs(self.overview()["costs"]["day_stopped"], False)
        self.config("pool: 6\n")
        self.sess("d21", 21, "claude-opus-5-5", 25000000, today)
        self.assertIs(self.overview()["costs"].get("day_stopped"), False)


class Empty(Views):
    def test_no_projects(self):
        "a home with no registry: the overview and the settings answer with no project"
        os.unlink(os.path.join(self.H, "registry.tsv"))
        o = self.overview()
        self.assertEqual((o["projects"], o["runs"]), ([], []))
        self.assertEqual(self.settings()["projects"], [])
        self.assertEqual(self.get("/api/card/shop/7").code, 404)


class Feed(Views):
    def setUp(self):
        super().setUp()
        self.d = d = datetime.now().strftime("%Y-%m-%d")
        os.environ["SHIPFLOOR_SCHEDULER"] = "none"
        self.write("shome/logs/dispatcher.log", "{d}T10:00:00-03:00 shipfloor: shop: first\nmv: stderr\n{d}T10:10:00-03:00 shipfloor: shop: last\n"
                   "{d}T10:20:00-03:00 shipfloor: shop: again\n{d}T10:23:00-03:00 shipfloor: shop: again\n".format(d=d))

    def test_timeline(self):
        "the feed is one timeline: dispatcher lines and a line per run by time, an untimed line after the one above it, a repeat as one event; a run with no end and no lock is lost"
        d = self.d
        self.log("%s-7-develop.log" % d, "== start /sf:develop 7 {d}T10:05:00-03:00 pid=1\ngate build: 2 tests failed\n\n== end /sf:develop 7 exit=4 {d}T10:06:00-03:00\n".format(d=d))
        ev = self.get("/api/feed").json["events"]
        self.assertEqual(" | ".join(e["text"] + (" exit=%s" % e["exit"] if e.get("issue") else "") for e in ev),
                         "shipfloor: shop: first | mv: stderr | develop #7 exit=4 | shipfloor: shop: last | shipfloor: shop: again")
        a, r = ev[-1], next(e for e in ev if e.get("issue"))
        self.assertEqual((a["n"], a["since"][11:16], a["ts"][11:16]), (2, "10:20", "10:23"))
        self.assertEqual((r["stage"], r["title"], "last" in r), ("develop", "Seven", False))
        self.log("%s-7-refine.log" % d, "== start /sf:refine 7 %sT09:00:00-03:00 pid=1\n" % d)
        self.assertEqual([e.get("lost") for e in self.get("/api/feed").json["events"] if e.get("stage") == "refine"], [True])
        self.assertEqual(self.get("/api/feed", token=False).code, 403)

    def test_why_a_run_failed(self):
        "#114: a failed run carries the gates its report names, or only its exit code, never its last log line; a good one its PR and column; the stacks' lines come along"
        d = self.d
        self.write("shome/logs/dispatcher.log", "{d}T10:00:00-03:00 shipfloor: shop: first\n{d}T10:20:00-03:00 shipfloor: shop: again\n{d}T10:23:00-03:00 shipfloor: shop: again\n".format(d=d))
        self.write("shome/logs/stacks.log", "%sT10:30:00-03:00 stacks: stack 1 is free\n" % d)
        self.board({21: "Validation", 22: "Validation", 23: "Staged"})
        self.log("%s-21-develop.log" % d, "== start /sf:develop 21 {d}T10:05:00-03:00 pid=1\ngate build: 2 tests failed\n== end /sf:develop 21 exit=4 {d}T10:06:00-03:00\n".format(d=d))
        self.write("shome/projects/shop/reports-wt/reports/21-gate/develop-%sT100530.json" % d, '{"outcome":"failed","pr":64,"failed_gates":["build","lint"]}\n')
        self.log("%s-22-develop.log" % d, "== start /sf:develop 22 {d}T10:10:00-03:00 pid=2\nok · now in Validation\n== end /sf:develop 22 exit=3 {d}T10:11:00-03:00\n".format(d=d))
        self.log("%s-23-develop.log" % d, "== start /sf:develop 23 {d}T10:15:00-03:00 pid=3\nall gates passed\n== end /sf:develop 23 exit=0 {d}T10:16:00-03:00\n".format(d=d))
        self.write("shome/projects/shop/reports-wt/reports/23-ok/develop-%sT101530.json" % d, '{"outcome":"done","pr":65}\n')
        ev = self.get("/api/feed").json["events"]
        run = lambda n: next(e for e in ev if e.get("issue") == n)
        sysev = [e for e in ev if not e.get("issue")]
        texts = {e["text"]: e for e in sysev}
        self.assertEqual(set(texts), {"shipfloor: shop: first", "shipfloor: shop: again", "stacks: stack 1 is free"})
        self.assertEqual((texts["shipfloor: shop: again"]["n"], texts["stacks: stack 1 is free"]["source"]), (2, "stacks"))
        self.assertTrue(all(set(e) == {"ts", "source", "text", "n", "since"} for e in sysev), "the dispatcher lines keep their fields")
        g, nr, ok = run(21), run(22), run(23)
        self.assertEqual((g.get("failed"), g.get("exit"), g.get("pr"), "last" in g), (["build", "lint"], 4, 64, False), "AC-3")
        self.assertEqual((nr.get("exit"), "failed" in nr, nr.get("column"), "last" in nr), (3, False, "Validation", False), "AC-4")
        self.assertNotIn("now in Validation", json.dumps(nr))
        self.assertEqual((ok.get("exit"), "last" in ok, ok.get("pr"), ok.get("column"), "failed" in ok), (0, False, 65, "Staged", False), "AC-5")


class Lang(Views):
    def test_catalog(self):
        "#122: the page's language is the machine's: its catalog by key, with the English one beside it"
        lang = lambda: (lambda d: (d["language"], len(d["messages"]) > 500, d["messages"] == d["en"], d["messages"].get("drawer.close")))(self.get("/api/lang").json)
        self.assertEqual(lang(), ("en", True, True, "Close"))
        self.config("language: pt-BR\n")
        self.assertEqual(lang(), ("pt-BR", True, False, "Fechar"))


class Routes(Views):
    def test_token(self):
        "the API wants the token in a header: none, a wrong one or one in the URL is a 403 on a GET and a POST; the page and the favicon need none"
        for path in ("/api/card/shop/7", "/api/overview", "/api/settings"):
            self.assertEqual(self.get(path, token=False).code, 403, path)
        self.assertEqual(self.get("/api/overview", token="wrong").code, 403)
        self.assertEqual(self.get("/api/overview?t=" + self.token, token=False).code, 403)
        self.assertEqual(self.req("POST", "/api/settings/pause", {}, token=False).code, 403)
        self.assertEqual(self.req("POST", "/api/settings/pause", {}, token="wrong").code, 403)
        self.assertEqual(self.get("/", token=False).code, 200)
        r = self.get("/favicon.ico", token=False)
        self.assertEqual((r.code, r.raw), (204, b""), "the favicon: empty, no data")
        self.assertEqual(self.req("GET", "/api/overview", token=True, headers={"Host": "evil.example:80"}).code, 403, "only a local Host")

    def test_paths(self):
        "no path outside logs; an unknown route or project is a 404; a log is read from a byte offset"
        self.assertEqual(self.get("/api/log/shop/..%2F..%2Fregistry.tsv").code, 404)
        self.assertEqual(self.get("/api/nothing").code, 404)
        self.assertEqual(self.get("/api/card/nope/7").code, 404)
        self.assertEqual(self.post("/api/card/shop/7/nothing", {}).code, 404)
        self.assertEqual(self.req("POST", "/api/card/shop/7/approve", b"{nope").code, 400, "a body that is not JSON")
        self.log("ac5.log", "0123456789abcdefghijklmnopqrstuvwxyz0123456789\n")
        ref = self.get("/api/log/shop/ac5.log?from=abc")
        self.assertEqual(ref.code, 200)
        for v in ("%C2%B2", "%D9%A1%D9%A2"):
            r = self.get("/api/log/shop/ac5.log?from=" + v)
            self.assertEqual((r.code, r.raw), (ref.code, ref.raw), "from=%s answers as a non-numeric from" % v)

    def test_card_numbers_are_ascii_digits(self):
        "#7: card 12 on every route that takes a number; a segment isdigit() takes but [0-9]+ does not is a 404, on a GET and on a POST, and reaches no board"
        self.write("shome/projects/shop/reviews/12.html", "<p>spec 12</p>\n")
        for r in ("api/card", "api/decide", "api/live"):
            self.assertEqual(self.get("/%s/shop/12" % r).code, 200, r)
        self.assertEqual(self.get("/review/shop/12?t=" + self.token, token=False).code, 200)
        self.assertEqual(self.get("/api/card/shop/12").json["issue"], 12)
        r = self.get("/api/card/shop/%D9%A1%D9%A2")
        self.assertEqual(r.code, 404)
        self.assertNotIn(b'"issue"', r.raw)
        for seg in ("%C2%B2", "%D9%A1%D9%A2"):
            for route in ("api/card", "api/decide", "api/live", "review"):
                self.assertEqual(self.get("/%s/shop/%s?t=%s" % (route, seg, self.token)).code, 404, route + "/" + seg)
        before = len(self.calls())
        for seg in (b"%C2%B2", b"\xb2", b"%D9%A1%D9%A2"):
            body = b'{"column":"Spec Review"}'
            req = (b"POST /api/card/shop/" + seg + b"/approve HTTP/1.1\r\nHost: 127.0.0.1:" + str(self.port).encode() + b"\r\nContent-Type: application/json\r\n"
                   b"X-Shipfloor-Token: " + self.token.encode() + b"\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            self.assertEqual(self.raw(req), "404", seg)
        self.assertEqual(len(self.calls()), before, "no board call for a card number that is not [0-9]+")


class Review(Views):
    EMBED_CSS = "\n".join(('<style>', 'header.top{display:none}',
                           'html:root:not([data-x]){--page:#0d1014;--sheet:#151a21;--surface:#1b212a;--ink:#ebe5d5;--muted:#8f8b80;--rule:#262e39;',
                           '--linen:#262e39;--linen-ink:#ebe5d5;--display:"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;--body:var(--display)}',
                           '@media (prefers-color-scheme:light){html:root:not([data-x]){--page:#e7e7e4;--sheet:#f4f4f2;--surface:#ececea;--ink:#23262b;',
                           '--muted:#6b6a66;--rule:#d9d9d4;--linen:#d9d9d4;--linen-ink:#23262b}}',
                           'h1,section h2{font-weight:600}', 'section h2{font-size:17px;line-height:1.3}', '.count{display:none}',
                           'button{background:transparent;color:var(--ink);border-color:var(--rule)}', '</style>'))

    def test_review_pages(self):
        "agent-written review pages are sandboxed; ?embed=1 adds the theme's style block, then the script, before </head>; a page without </head>, or without embed, is the file's bytes"
        self.write("shome/projects/shop/reviews/21.html", "<!doctype html><html><head><title>spec</title></head><body><p>spec</p></body></html>\n")
        self.write("shome/projects/shop/reviews/22.html", "<p>a hand-written page, no head</p>\n")
        r = self.get("/review/shop/21?t=" + self.token, token=False)
        self.assertEqual(r.headers.get("Content-Security-Policy"), "sandbox allow-scripts")
        with open(self.pdir("shop", "reviews", "21.html"), "rb") as f:
            self.assertEqual(r.raw, f.read(), "without embed=1 the bytes are the file's")
        embed = self.get("/review/shop/21?embed=1&t=" + self.token, token=False).text
        self.assertIn(self.EMBED_CSS, embed, "the embed style block is byte for byte what it was")
        self.assertIn("<p>spec</p></body>", embed)
        self.assertRegex(embed, r"(?s)--page:#0d1014.*</style>.*<script>.*</script></head>")
        with open(self.pdir("shop", "reviews", "22.html"), "rb") as f:
            self.assertEqual(self.get("/review/shop/22?embed=1&t=" + self.token, token=False).raw, f.read(), "a page without </head> comes back unchanged")
        self.assertEqual(self.get("/review/shop/23?t=" + self.token, token=False).code, 404, "no page")


class History(Views):
    def setUp(self):
        super().setUp()
        clear_of_midnight(180, 720)
        now = datetime.now().astimezone()
        self.day = lambda n: (now + timedelta(days=n)).strftime("%Y-%m-%d")
        at = lambda s: datetime.strptime(s, "%Y-%m-%d %H:%M:%S").astimezone().isoformat(timespec="seconds")
        rel = lambda m: (now + timedelta(minutes=m)).isoformat(timespec="seconds")
        D0, D2, D3, D5, D9, D20 = (self.day(-n) for n in (0, 2, 3, 5, 9, 20))
        def run(day, n, stage, start, end, ex):
            self.log("%s-%d-%s.log" % (day, n, stage), "== start /sf:%s %d %s pid=1\n== end /sf:%s %d exit=%d %s\n" % (stage, n, start, stage, n, ex, end))
        def sess(name, n, stage, start, model, tokens):
            self.transcript(name, slash(stage, n, start), ast("m-" + name, model, {"input_tokens": tokens, "output_tokens": 0}, start))
        self.E0, self.E0b = rel(-7), rel(-4)
        run(D0, 5, "refine", rel(-9), self.E0, 0); run(D0, 5, "develop", rel(-6), self.E0b, 4)  # today: #5 refine clean (US$ 4), develop failed
        sess("s5", 5, "refine", rel(-9), "claude-opus-5-5", 1000000)
        run(D2, 6, "develop", at(D2 + " 09:00:00"), at(D2 + " 09:30:00"), 0); run(D2, 6, "deploy", at(D2 + " 10:00:00"), at(D2 + " 10:06:00"), 0)
        sess("s6", 6, "develop", at(D2 + " 09:01:00"), "claude-opus-5-5", 500000)  # #6 reached Done, US$ 2
        run(D5, 7, "refine", at(D5 + " 14:00:00"), at(D5 + " 14:20:00"), 0)
        for i in range(60):  # a busy day: 60 refine runs of #10, two pages of runs
            run(D3, 10, "refine", at("%s 08:%02d:00" % (D3, i)), at("%s 08:%02d:30" % (D3, i)), 0)
        run(D9, 8, "deploy", at(D9 + " 11:00:00"), at(D9 + " 11:05:00"), 0)
        run(D20, 9, "refine", at(D20 + " 10:00:00"), at(D20 + " 10:10:00"), 0)
        sess("s9", 9, "refine", at(D20 + " 10:01:00"), "claude-mystery-1", 1000)
        D4, D10 = self.day(-4), self.day(-10)
        self.gh("titles.tsv", "5\tFive\n6\tSix\t%s\n7\tSeven\n8\tEight\t%s\n9\tNine\n10\tTen\n" % (at(D4 + " 10:06:00"), at(D10 + " 11:05:00")))
        ep = lambda s: datetime.strptime(s, "%Y-%m-%d %H:%M:%S").timestamp()
        self.WAIT6 = int(ep(D2 + " 10:06:00") - ep(D4 + " 10:06:00"))
        self.WAIT8 = int(ep(D9 + " 11:05:00") - ep(D10 + " 11:05:00"))
        self.board({5: "Coding", 6: "Done", 7: "Spec Review", 9: "Inbox", 10: "Ready for Dev"})
        self.overview()  # the first read asks GitHub for the titles

    def h(self, q):
        return self.get("/api/history/shop?" + q).json

    def test_buckets(self):
        "#130 AC-1: by day over 7 and 30 days with every slot in place, Today by hour; the runs and spend where they ended"
        D0 = self.day(0)
        d = self.h("days=7")
        self.assertEqual((d["unit"], len(d["buckets"]), d["buckets"][0]["day"], d["buckets"][-1]["day"]), ("day", 7, self.day(-6), D0))
        self.assertEqual([(b["day"], b["ok"], b["failed"], b["cost"]) for b in d["buckets"] if b["ok"] + b["failed"]],
                         [(self.day(-5), 1, 0, 0.0), (self.day(-3), 60, 0, 0.0), (self.day(-2), 2, 0, 2.0), (D0, 1, 1, 4.0)])
        empty = [b for b in d["buckets"] if not b["ok"] + b["failed"]]
        self.assertEqual((len(empty), all(b["cost"] == 0 for b in empty)), (3, True))
        d = self.h("days=30")
        self.assertEqual((d["unit"], len(d["buckets"]), sum(b["ok"] + b["failed"] for b in d["buckets"])), ("day", 30, 67))
        d = self.h("")
        self.assertEqual((d["unit"], d["days"], d["from"] == d["to"], [b["h"] for b in d["buckets"]]), ("hour", 1, True, list(range(int(time.strftime("%H")) + 1))))
        d = self.h("days=1")
        h0, h0b = (datetime.fromisoformat(x).hour for x in (self.E0, self.E0b))
        self.assertEqual((sum(b["ok"] for b in d["buckets"] if b["h"] == h0), sum(b["failed"] for b in d["buckets"] if b["h"] == h0b), round(sum(b["cost"] for b in d["buckets"]), 2)), (1, 1, 4.0))

    def test_periods(self):
        "#130 AC-2: the arrows' neighbours, a custom range, and the refused ones"
        D0, D1, D2, D5 = (self.day(-n) for n in (0, 1, 2, 5))
        span = lambda a, b: {"from": a, "to": b}
        d = self.h("days=1")
        self.assertEqual((d["present"], d["next"], d["now"], d["prev"]), (True, None, None, span(D1, D1)))
        d = self.h("from=%s&to=%s" % (D1, D1))
        self.assertEqual((d["present"], d["next"], d["now"], d["unit"]), (False, span(D0, D0), span(D0, D0), "hour"))
        self.assertEqual(self.h("days=7")["prev"], span(self.day(-13), self.day(-7)))
        d = self.h("from=%s&to=%s" % (D5, D2))
        self.assertEqual((d["days"], [b["day"] for b in d["buckets"]], d["totals"]["ok"]), (4, [D5, self.day(-4), self.day(-3), D2], 63))
        code = lambda q: self.get("/api/history/shop?" + q).code
        for q in ("from=%s&to=%s" % (D2, D5), "from=%s&to=%s" % (D0, self.day(1)), "from=%s&to=%s" % (self.day(-92), D0), "from=12-10-2026&to=" + D0, "days=0", "days=93", "days=x"):
            self.assertEqual(code(q), 400, q)
        self.assertEqual(code("from=%s&to=%s" % (self.day(-91), D0)), 200, "92 days")
        self.assertEqual(self.get("/api/history/nope").code, 404)
        self.assertEqual(self.get("/api/history/shop", token=False).code, 403)

    def test_totals(self):
        "#130 AC-4: the totals and the previous period's, the median from Inbox to Done (none without a card done), a stage's time over the period"
        t = self.h("days=7")["totals"]
        self.assertEqual((t["done"], t["ok"], t["failed"], t["cost"], t["unpriced"], t["median_s"], t["median_of"]), (1, 64, 1, 6.0, 0, self.WAIT6, 1))
        t = self.h("days=7")["previous"]
        self.assertEqual((t["done"], t["ok"], t["failed"], t["median_s"]), (1, 1, 0, self.WAIT8))
        t = self.h("days=1")["totals"]
        self.assertEqual((t["done"], t["median_s"], t["median_of"]), (0, None, 0))
        self.assertEqual(sorted(self.h("days=7")["typical_s"].items()), [("deploy", 360), ("develop", 1800), ("refine", 30)])
        D5 = self.day(-5)
        self.assertEqual(self.h("from=%s&to=%s" % (D5, D5))["typical_s"], {"refine": 1200})

    def test_runs_and_cards(self):
        "#130 AC-5/AC-6: the runs page by page, newest first, adding up to the totals; the cards by cost, unpriced last; an empty period; a missing price"
        d = self.h("days=7")
        self.assertEqual((d["runs_total"], d["page"], d["pages"], len(d["runs"]), d["runs"][0]["issue"], d["runs"][0]["stage"], d["runs"][0]["title"]),
                         (65, 1, 2, 50, 5, "develop", "Five"))
        d2 = self.h("days=7&page=2")
        self.assertEqual((d2["page"], len(d2["runs"]), d2["runs"][-1]["issue"]), (2, 15, 7))
        rows = d["runs"] + d2["runs"]
        self.assertEqual((len(rows), len({(r["log"], r["start"]) for r in rows}), round(sum(r["cost"] for r in rows if r["cost"] is not None), 2),
                          sum(r["exit"] == 0 for r in rows), sum(r["exit"] != 0 for r in rows)), (65, 65, 6.0, 64, 1))
        self.assertEqual(self.h("days=7&page=x")["page"], 1, "a page that is not a number is the first")
        self.assertEqual([(c["issue"], c["column"], c["runs"], c["cost"]) for c in self.h("days=30")["cards"]],
                         [(5, "Coding", 2, 4.0), (6, "Done", 2, 2.0), (7, "Spec Review", 1, 0.0), (8, None, 1, 0.0), (10, "Ready for Dev", 60, 0.0), (9, "Inbox", 1, None)])
        D60, D20 = self.day(-60), self.day(-20)
        d = self.h("from=%s&to=%s" % (D60, D60))
        self.assertEqual((d["empty"], d["runs"], d["cards"], d["totals"]["ok"] + d["totals"]["failed"]), (True, [], [], 0))
        d = self.h("days=30")
        self.assertEqual((d["totals"]["unpriced"], d["empty"]), (1, False))
        d = self.h("from=%s&to=%s" % (D20, D20))
        self.assertEqual((d["runs"][0]["cost"], d["buckets"][10]["unpriced"]), (None, 1))


class Shell(ds.support.Case):
    """find_bash(environ, windows): the dashboard started directly picks a usable bash, never the WSL launcher"""

    def setUp(self):
        super().setUp()
        import dashboard
        self.find = dashboard.find_bash
        self.SR, self.WA, self.GIT, self.EMPTY = self.path("Windows"), self.path("Local", "Microsoft", "WindowsApps"), self.path("Git", "bin"), self.path("empty")
        self.S32 = self.path("Windows", "System32")
        for d in (self.S32, self.WA, self.GIT):
            self.mkbash(d)
        self.win = {"SystemRoot": self.SR, "LOCALAPPDATA": self.path("Local")}

    def mkbash(self, d):
        for f in ("bash", "bash.exe"):
            p = self.write(os.path.relpath(os.path.join(d, f), self.tmp), "#!/bin/sh\nexit 0\n")
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)

    def got(self, windows, **env):
        if "PATH" in env:
            env["PATH"] = os.pathsep.join(env["PATH"])
        return self.find(env, windows)

    def test_refuses_the_wsl_launcher(self):
        "AC-3/AC-4: on Windows a bash in System32 or WindowsApps is refused (any case, dot segments); no bash at all gives None"
        self.assertIsNone(self.got(True, PATH=[self.S32], **self.win))
        self.assertIsNone(self.got(True, PATH=[self.WA], **self.win))
        self.assertIsNone(self.got(True, SystemRoot=self.SR.upper().replace("/", "/./"), LOCALAPPDATA=self.win["LOCALAPPDATA"], PATH=[self.S32.lower()]))
        self.assertIsNone(self.got(True, PATH=[self.EMPTY], **self.win))
        self.assertIsNone(self.got(False, PATH=[self.EMPTY]))

    def test_first_usable_wins(self):
        "AC-1: a WSL bash earlier in PATH is skipped, the next one wins, in PATH order"
        d = lambda p: os.path.normcase(os.path.dirname(p))
        self.assertEqual(d(self.got(True, PATH=[self.S32, self.GIT], **self.win)), os.path.normcase(self.GIT))
        self.assertEqual(d(self.got(True, PATH=[self.WA, self.S32, self.GIT], **self.win)), os.path.normcase(self.GIT))
        self.assertEqual(d(self.got(True, PATH=[self.GIT, self.S32], **self.win)), os.path.normcase(self.GIT))

    def test_shipfloor_bash_as_given(self):
        "AC-6: SHIPFLOOR_BASH is taken as given: no lookup, no check, not refused, before a bash on PATH"
        self.assertEqual(self.got(False, SHIPFLOOR_BASH="/no/such/shell/bash", PATH=[]), "/no/such/shell/bash")
        self.assertEqual(self.got(True, SHIPFLOOR_BASH="/no/such/shell/bash", PATH=[], **self.win), "/no/such/shell/bash")
        own = os.path.join(self.S32, "bash.exe")
        self.assertEqual(self.got(True, SHIPFLOOR_BASH=own, PATH=[self.GIT], **self.win), own)
        self.assertEqual(self.got(True, SHIPFLOOR_BASH="/my/own/bash", PATH=[self.GIT], **self.win), "/my/own/bash")

    def test_not_windows(self):
        "AC-7: off Windows a directory named System32 means nothing"
        ux = self.path("unix", "System32"); self.mkbash(ux)
        self.assertEqual(os.path.dirname(self.got(False, PATH=[ux])), ux)
        self.assertEqual(os.path.dirname(self.got(False, PATH=[self.S32, self.GIT], **self.win)), self.S32)


class LinkToken(ds.support.Case):
    """link_token(home): the link's secret kept in <home>/dashboard.token, so a link survives a restart"""

    def test_kept_and_replaced(self):
        "a saved token is used as is; a missing or damaged one (empty, short, other characters, long) is replaced by a new one, written with a newline, mode 600"
        import dashboard
        home = self.path("h")
        f = os.path.join(home, "dashboard.token")
        first = dashboard.link_token(home)
        self.assertRegex(first, r"^[A-Za-z0-9_-]{22}$")
        self.assertEqual(dashboard.link_token(home), first, "the same home keeps its token")
        for label, held in (("deleted", None), ("empty", ""), ("too short", "abc"), ("other characters", "aaaaaaaaaaaaaaaaaaaa!!"), ("too long", "a" * 36)):
            if held is None:
                os.unlink(f)
            else:
                with open(f, "w") as w:
                    w.write(held + "\n")
            tok = dashboard.link_token(home)
            self.assertRegex(tok, r"^[A-Za-z0-9_-]{22}$", label)
            self.assertNotIn(tok, (first, held), label)
            with open(f, "rb") as r:
                self.assertEqual(r.read(), tok.encode() + b"\n", label)
            if os.name != "nt":
                self.assertEqual(stat.S_IMODE(os.stat(f).st_mode), 0o600, label)
            first = tok
        self.assertNotEqual(dashboard.link_token(self.path("other")), first, "another home, another token")
