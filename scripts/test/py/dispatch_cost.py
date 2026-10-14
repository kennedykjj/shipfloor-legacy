"""Cost limits (machine config `costs`): the dispatcher's side (block a card at card_block, stop the day at day_stop, the
order and the failures) over a fake dashboard_cost.py, and the estimate's side (dashboard_cost.py limits / block, called
in this process) over fake Claude Code transcripts in temp dirs. One case runs the real dashboard_cost.py under the
dispatcher. Nothing here reads the real ~/.claude or ~/.shipfloor."""
import contextlib
import datetime
import io
import json
import os
import sys

import dispatch_support as ds
import dashboard_cost

PRICES = "claude-opus-5-5: {input: 4.00, output: 20.00, cache_write_5m: 5.00, cache_write_1h: 8.00, cache_read: 0.20}\n"

# python, as the dispatcher runs dashboard_cost.py with it: fake.json's "cost" answers `limits` (its text and exit code)
# and `block` (its exit code; with mutate, it writes the marker first, as a CLI that died half way would); each call is
# a line of <tmp>/cost.calls; every other python call is the real one
FAKE_PY = r'''
import json, os, sys
argv = sys.argv[1:]
if len(argv) > 2 and os.path.basename(argv[1]) == "dashboard_cost.py":
    fake = json.load(open(%(fake)r)).get("cost", {}) if os.path.exists(%(fake)r) else {}
    open(%(calls)r, "a").write(json.dumps(argv[2:]) + "\n")
    if argv[2] == "limits":
        sys.stdout.write(fake.get("limits", ""))
        sys.exit(fake.get("limits_rc", 0))
    n, out = argv[argv.index("--issue") + 1], argv[argv.index("--out") + 1]
    if fake.get("mutate"):
        m = os.path.join(os.environ["FACTORY_HOME"], "cost")
        os.makedirs(m, exist_ok=True)
        open(os.path.join(m, n + ".json"), "w").write("mutated\n")
    rc = fake.get("block_rc", 0)
    if rc == 0:
        open(out, "w").write("Cost limit: blocked.\n")
    sys.exit(rc)
os.execv(%(real)r, [%(real)r] + argv)
'''

# gh: each call a JSON line of <tmp>/gh.calls, with the board's label calls made before it; fake.json's "gh_fails" fails it
GH = r'''
import json, os, sys
fake = json.load(open(%(fake)r)) if os.path.exists(%(fake)r) else {}
argv = sys.argv[1:]
board = open(%(board)r).read().splitlines() if os.path.exists(%(board)r) else []
body = open(argv[argv.index("--body-file") + 1]).read() if "--body-file" in argv else None
open(%(calls)r, "a").write(json.dumps({"argv": argv, "labels_before": [l for l in board if l.startswith("label")],
                                       "body": body}) + "\n")
if fake.get("gh_fails"):
    sys.stderr.write("gh: HTTP 502\n")
    sys.exit(1)
'''


class Base(ds.DispatchCase):
    def setUp(self):
        super().setUp()
        self.claude_dir = os.environ["CLAUDE_CONFIG_DIR"] = self.path("claude")
        self.write(os.path.join(self.shome, "prices.yml"), PRICES)
        self.write(os.path.join(self.shome, "registry.tsv"), "shop\t/x/shop\t/x/wt\tmain\nother\t/x/other\t/x/wt2\tmain\n")
        fake = os.path.join(self.tmp, "fake.json")
        os.environ["FACTORY_GH"] = self.script("gh", GH % {"fake": fake, "board": os.path.join(self.tmp, "board", "calls"),
                                                         "calls": os.path.join(self.tmp, "gh.calls")})

    def costs(self, text):
        self.machine_cfg(ds.POOL8 + "\ncosts:\n" + "".join("  %s\n" % l for l in text.split("\n")))

    def started(self):
        return ["%s %s" % (s["p"], s["n"]) for s in self.launches]

    def gh_calls(self):
        return self._records("gh")

    def tx(self, name, issue, stage, usd, day="today", model="claude-opus-5-5", slug="shop"):
        """A transcript of one session of a card, costing <usd> at opus input prices ($4 per million), at noon."""
        d = os.path.join(self.claude_dir, "projects", "C--x--shipfloor-projects-%s-control" % slug)
        os.makedirs(d, exist_ok=True)
        date = datetime.date.today() - datetime.timedelta(days=1 if day == "yesterday" else 0)
        tz = datetime.datetime.now().astimezone().strftime("%z")
        tz = tz[:3] + ":" + tz[3:]
        user = {"type": "user", "timestamp": "%sT12:00:00%s" % (date, tz),
                "message": {"role": "user", "content": "<command-name>/sf:%s</command-name>\n<command-args>%s"
                                                       "</command-args>" % (stage, issue)}}
        asst = {"type": "assistant", "timestamp": "%sT12:05:00%s" % (date, tz),
                "message": {"id": "m-" + name, "model": model, "usage": {"input_tokens": int(usd * 250000),
                                                                         "output_tokens": 0}}}
        with open(os.path.join(d, name + ".jsonl"), "w") as f:
            f.write(json.dumps(user) + "\n" + json.dumps(asst) + "\n")


class Dispatcher(Base):
    """The dispatcher's side, over a fake dashboard_cost.py."""

    def setUp(self):
        super().setUp()
        os.environ["FACTORY_PYTHON"] = self.script("python", FAKE_PY % {
            "fake": os.path.join(self.tmp, "fake.json"), "calls": os.path.join(self.tmp, "cost.calls"),
            "real": sys.executable})
        self.marker = os.path.join(self.home, "cost", "77.json")

    def cost_calls(self):
        return self._records("cost")

    def test_no_limit_no_estimate(self):
        "with no costs, or only card_warn, the estimate is never started and every card starts"
        self.board(queues={"Ready for Dev": "77 78"})
        self.cycle(runs=False)
        self.costs("card_warn: 20")
        for d in os.listdir(os.path.join(self.home, "locks")):
            os.rmdir(os.path.join(self.home, "locks", d))
        self.cycle(runs=False)
        self.assertEqual(self.cost_calls(), [])
        self.assertEqual(self.started(), ["develop 77", "develop 78"] * 2)

    def test_block(self):
        "a card at card_block is not started: one comment (with -R owner/repo, never the clone's path), then the blocked label"
        self.costs("card_block: 40")
        os.environ["FACTORY_REPO"] = self.path("clones", "shop")
        self.set_fake(cost={"limits": "block\t77\n"})
        self.board(queues={"Ready for Dev": "77 78"})
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.started(), ["develop 78"])
        self.assertIn("dispatch: #77 reached costs.card_block; blocked", self.out)
        gh = self.gh_calls()
        self.assertEqual(len(gh), 1)
        self.assertEqual(gh[0]["argv"][:5], ["issue", "comment", "77", "-R", "acme/shop"])
        self.assertEqual(gh[0]["argv"][5], "--body-file")
        self.assertEqual(gh[0]["body"], "Cost limit: blocked.\n")
        self.assertNotIn(os.environ["FACTORY_REPO"], " ".join(gh[0]["argv"]))
        self.assertEqual(gh[0]["labels_before"], [], "the comment comes before the label")
        self.assertEqual([c for c in self.board_calls() if c.startswith("label")], ["label 77 add blocked"])
        block = [c for c in self.cost_calls() if c[0] == "block"][0]
        self.assertEqual(block[:5], ["block", "--home", self.shome, "--project", "shop"])
        self.assertEqual(block[5:7], ["--issue", "77"])
        self.assertFalse(os.path.exists(os.path.join(self.home, "tmp", "cost-77.md")), "the comment body goes")

    def test_failed_comment_or_label(self):
        "a failed comment (no label then) or label fails the cycle, and the card is still not started"
        self.costs("card_block: 40")
        self.set_fake(cost={"limits": "block\t77\n"}, gh_fails=True)
        self.board(queues={"Ready for Dev": 77})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertIn("dispatch: could not block #77 at costs.card_block", self.err)
        self.assertEqual((self.started(), [c for c in self.board_calls() if c.startswith("label")]), ([], []))
        self.set_fake(gh_fails=False)
        self.board(fail={"label": ""})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertEqual(self.started(), [])

    def test_block_failures(self):
        "block exits 1 (no estimate): the card starts; exit 2: its marker is put back from .prev (or removed), no start, no comment, exit 1"
        self.costs("card_block: 40")
        self.board(queues={"Ready for Dev": "77 78"})
        self.set_fake(cost={"limits": "block\t77\n", "block_rc": 1})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 77", "develop 78"])
        wrong = []
        for before, mutate in (("baseline\n", True), (None, True), ("baseline\n", False)):
            self.launches = []
            for d in os.listdir(os.path.join(self.home, "locks")):
                os.rmdir(os.path.join(self.home, "locks", d))
            if before is None:
                if os.path.exists(self.marker):
                    os.unlink(self.marker)
            else:
                self.write(self.marker, before)
            self.set_fake(cost={"limits": "block\t77\n", "block_rc": 2, "mutate": mutate})
            rc = self.cycle(runs=False)
            now = open(self.marker).read() if os.path.exists(self.marker) else None
            if (rc, self.started(), now, os.path.exists(self.marker + ".prev")) != (1, ["develop 78"], before, False):
                wrong.append((before, mutate, rc, self.started(), now))
            if "dispatch: could not block #77 at costs.card_block" not in self.err:
                wrong.append((before, mutate, self.err))
        self.assertEqual(wrong, [])
        self.assertEqual((self.gh_calls(), [c for c in self.board_calls() if c.startswith("label")]), ([], []))

    def test_day_stop(self):
        "past day_stop nothing starts (exit 0, says why) and the cycle stops before the infra retry; a running session is left alone"
        self.costs("day_stop: 80")
        self.set_fake(cost={"limits": "day_stop\t81.00\t80.00\n"})
        live = self.lock("develop-5")
        self.board(queues={"Ready for Dev": 90, "Ready for Refinement": 92, "Validation": 91, "Ready for Prod": 93},
                   infra=[54])
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertIn("dispatch: today's estimate US$ 81.00 reached costs.day_stop (US$ 80.00); no new run until "
                      "tomorrow", self.out)
        self.assertEqual(self.started(), [])
        self.assertTrue(os.path.isdir(live))
        self.assertEqual(self.board_calls(), ["snapshot"], "no infra, queue or label call after the snapshot")
        self.assertFalse(os.path.exists(os.path.join(self.home, "infra", "54")))
        self.set_fake(cost={"limits": ""})
        self.cycle(runs=False)
        self.assertTrue(os.path.isfile(os.path.join(self.home, "infra", "54")), "under day_stop the infra retry runs")
        self.assertIn("develop 90", self.started())

    def test_unreadable_limits(self):
        "cost limits that cannot be read: exit 1, on stderr, nothing starts"
        self.costs("day_stop: 80")
        self.set_fake(cost={"limits_rc": 1})
        self.board(queues={"Ready for Dev": 26})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertIn("dispatch: cannot read the cost limits", self.err)
        self.assertEqual(self.started(), [])


class Estimate(Base):
    """dashboard_cost.py limits / block in this process: what the dispatcher acts on."""

    def cli(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = dashboard_cost.cli(list(argv))
        return rc, out.getvalue()

    def limits(self):
        rc, out = self.cli("limits", "--home", self.shome, "--project", "shop", "--claude-dir", self.claude_dir)
        self.assertEqual(rc, 0)
        return out

    def block(self, n):
        body = self.path("body", "%s.md" % n)
        rc, _ = self.cli("block", "--home", self.shome, "--project", "shop", "--issue", str(n), "--out", body)
        return rc, (open(body).read() if os.path.exists(body) else None)

    def marker(self, n):
        return json.load(open(os.path.join(self.home, "cost", "%s.json" % n)))

    def test_block_at_card_block(self):
        "limits lists the project's cards at card_block or over (>=); block writes the comment and the marker"
        self.costs("card_block: 40")
        self.tx("s1", 77, "develop", 30)
        self.tx("s2", 77, "refine", 11)
        self.tx("s3", 78, "develop", 39)
        self.tx("s4", 79, "develop", 40)
        self.tx("s5", 5, "develop", 90, slug="other")
        self.assertEqual(self.limits(), "block\t77\nblock\t79\n")
        rc, body = self.block(77)
        self.assertEqual(rc, 0)
        lines = body.splitlines()
        self.assertEqual(lines[0], "Cost limit: blocked.")
        for want in ("$41.00", "$40.00", "estimate", "- develop: $30.00", "- refine: $11.00"):
            self.assertIn(want, body)
        m = self.marker(77)
        self.assertEqual((round(m["total"], 2), m["limit"], m["baseline"]), (41.0, 40, 0.0))
        self.assertEqual({k: round(v) for k, v in m["stages"].items()}, {"develop": 30, "refine": 11})
        self.assertTrue(m["at"])
        self.assertEqual(self.block(78)[0], 0, "block does what it is told; limits decides who")
        self.assertEqual(self.block(80), (1, None), "a card with no estimate: exit 1")

    def test_unblock_counts_from_the_block(self):
        "an unblocked card may spend up to card_block again, counted from the block; the next marker's baseline is the last total"
        self.costs("card_block: 40")
        self.tx("s1", 77, "develop", 30)
        self.tx("s2", 77, "refine", 11)
        self.block(77)
        self.assertEqual(self.limits(), "", "unblocked: not blocked again at once")
        self.tx("s4", 77, "develop", 39)
        self.assertEqual(self.limits(), "", "39 since the unblock")
        self.tx("s5", 77, "develop", 2)
        self.assertEqual(self.limits(), "block\t77\n", "41 since the unblock")
        rc, body = self.block(77)
        self.assertIn("since it was last unblocked", body)
        m = self.marker(77)
        self.assertEqual((round(m["baseline"], 2), round(m["total"], 2), round(sum(m["stages"].values()), 2)),
                         (41.0, 82.0, 41.0))

    def test_day_stop(self):
        "day_stop is today's estimate across every project (>=), and a new local day starts again"
        self.costs("day_stop: 80")
        self.tx("s1", 11, "develop", 50)
        self.tx("s2", 12, "develop", 31, slug="other")
        self.assertEqual(self.limits(), "day_stop\t81.00\t80.00\n")
        self.tx("s2", 12, "develop", 30, slug="other")
        self.assertEqual(self.limits(), "day_stop\t80.00\t80.00\n")
        self.tx("s2", 12, "develop", 29, slug="other")
        self.assertEqual(self.limits(), "")
        self.tx("s1", 11, "develop", 50, day="yesterday")
        self.tx("s2", 12, "develop", 31, day="yesterday", slug="other")
        self.assertEqual(self.limits(), "", "yesterday's spend does not stop today")

    def test_unpriced_is_never_judged(self):
        "a card that ran on a model with no price has an unknown estimate: never blocked, and adds nothing to the day"
        self.costs("card_warn: 50\ncard_block: 60\nday_stop: 5")
        self.tx("u1", 80, "develop", 100, model="claude-mystery-1")
        self.tx("p1", 81, "develop", 3)
        self.tx("p2", 82, "develop", 70, day="yesterday")
        self.tx("u2", 82, "refine", 100, model="claude-mystery-1")
        self.assertEqual(self.limits(), "")
        self.assertEqual(self.block(80), (1, None))
        self.assertFalse(os.path.exists(os.path.join(self.home, "cost")))

    def test_each_limit_alone(self):
        "an absent limit does nothing: no costs (not even an estimate), card_warn only, card_block only, day_stop only"
        self.tx("b", 78, "develop", 30)
        self.tx("c", 79, "develop", 30)
        self.tx("d", 80, "develop", 30)
        self.tx("e", 5, "develop", 30, slug="other")
        self.tx("a", 77, "develop", 500, day="yesterday")
        self.machine_cfg()
        self.assertEqual(self.limits(), "")
        self.assertFalse(os.path.exists(os.path.join(self.shome, "cost-cache.json")), "no estimate without a limit")
        got = {}
        for text in ("card_warn: 20", "day_stop: 200", "card_warn: 20\nday_stop: 200"):
            self.costs(text)
            got[text] = self.limits()
        os.unlink(os.path.join(self.claude_dir, "projects", "C--x--shipfloor-projects-shop-control", "a.jsonl"))
        self.costs("card_block: 40")
        got["card_block: 40"] = self.limits()
        self.assertEqual(got, dict.fromkeys(got, ""))


class EndToEnd(Base):
    def test_real_estimate_blocks_the_card(self):
        "the real dashboard_cost.py under the dispatcher: card 77 over card_block is commented on (acme/shop), labeled, not started"
        self.costs("card_block: 40")
        os.environ["FACTORY_REPO"] = self.path("clones", "shop")
        self.tx("s1", 77, "develop", 41)
        self.board(queues={"Ready for Dev": "77 78"})
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.started(), ["develop 78"])
        gh = self.gh_calls()
        self.assertEqual(gh[0]["argv"][:5], ["issue", "comment", "77", "-R", "acme/shop"])
        self.assertTrue(gh[0]["body"].startswith("Cost limit: blocked.\n"))
        self.assertIn("label 77 add blocked", self.board_calls())
        self.assertAlmostEqual(json.load(open(os.path.join(self.home, "cost", "77.json")))["total"], 41.0, places=2)
