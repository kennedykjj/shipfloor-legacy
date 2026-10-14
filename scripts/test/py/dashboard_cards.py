"""The owner's actions on a card, through the dashboard's API with a fake gh: approve and request changes (#50), move
(#125), reorder (#128), take back (#127), unblock, accept and send back, a message to a running card, a comment, the
weight (#133) and the review page's marks. The gestures in the page are checked by hand in review."""
import hashlib
import json
import os
import subprocess
import time

import dashboard_support as ds
from dashboard_support import opt, slash

OWNER_MOVES = {("Inbox", "Ready for Refinement"), ("Ready for Refinement", "Inbox"), ("Spec Review", "Ready for Dev"),
               ("Staged", "Ready for Prod")}
NOTE_MOVES = {("Spec Review", "Ready for Refinement"), ("Ready for Dev", "Ready for Refinement"), ("Staged", "Coding")}


class Decisions(ds.Dash):
    def test_approve_and_request_changes(self):
        "approve and request-changes: the owner's columns only, the token in the header only, the note before the move"
        self.items((7, "👤 Spec Review"), (8, "🤖 Coding"), (9, "👤 Staged"))
        r = self.req("POST", "/api/card/shop/7/approve?t=" + self.token, {"column": "Spec Review"}, token=False)
        self.assertEqual(r.code, 403, "a token in the URL does not act")
        self.assertEqual(self.post("/api/card/shop/7/approve", {"column": "Spec Review"}, token=False).code, 403)
        self.assertEqual(self.card_post(8, "approve", {"column": "Coding"}).code, 409, "Coding is not the owner's")
        self.assertEqual(self.edits(), [], "nothing moved")
        self.assertEqual(self.card_post(7, "approve", {"column": "Spec Review"}).code, 200)
        self.assertIn("--id PVTI_7 --field-id FLD_x --single-select-option-id opt5", self.gh("edits"))
        self.assertEqual(self.card_post(9, "request-changes", {"column": "Staged", "text": "fix the header"}).code, 200)
        self.assertIn("fix the header", self.gh("comments"))
        c, m = self.line_of("issue comment 9"), next(i for i, l in enumerate(self.calls()) if "item-edit" in l and "PVTI_9" in l and "opt6" in l)
        self.assertLess(c, m, "the comment first, then back to Coding")

    def test_approve_with_a_note(self):
        "an approval may carry a note (the answer to an open question): it is posted on the issue"
        self.items((9, "👤 Staged"))
        self.assertEqual(self.card_post(9, "approve", {"column": "Staged", "text": "yes, keep it"}).code, 200)
        self.assertIn("yes, keep it", self.gh("comments"))

    def test_quick_approve_survives_a_closed_tab(self):
        "#50: an approve or a request-changes whose client hangs up still acts, once, with nothing logged; a second approve is a 409"
        self.items((9, "👤 Staged"), (10, "👤 Staged"), (11, "🤖 Coding"))
        self.hangup("api/card/shop/9/approve", {"column": "Staged"})
        self.assertTrue(self.wait_file("edits", "PVTI_9"), "AC-1 the card moved after the client hung up")
        self.assertIn("opt9", self.gh("edits"))
        time.sleep(0.5)
        self.assertEqual(len(self.edits()), 1, "AC-1 the card moved once")
        self.items((9, "👤 Ready for Prod"), (10, "👤 Staged"), (11, "🤖 Coding"))
        self.assertEqual(self.card_post(9, "approve", {"column": "Staged"}).code, 409, "AC-3 a second approve with the old column")
        self.assertEqual(len(self.edits()), 1, "AC-3 the second approve moved nothing")
        self.gh_rm("edits", "comments")
        self.hangup("api/card/shop/10/request-changes", {"column": "Staged", "text": "fix the header"})
        self.assertTrue(self.wait_file("edits", "PVTI_10"), "AC-7 the card went back after the client hung up")
        self.assertIn("opt6", self.gh("edits"))
        self.assertTrue(self.wait_file("comments", "fix the header"), "AC-7 the note is posted")
        self.assertEqual(self.server_errors(), [], "the hung-up clients leave no error in the server")

    def test_overview_says_whether_a_review_page_exists(self):
        "#50 AC-5: only a card that waits for the owner reads its review page into the overview"
        self.items((9, "👤 Staged"), (10, "👤 Staged"), (11, "🤖 Coding"))
        self.board({9: "Staged", 10: "Staged", 11: "Coding"})
        for n in (9, 11):
            self.write("shome/projects/shop/reviews/%d.html" % n, "<p>review</p>\n")
        c = self.cards()
        self.assertEqual((c[9].get("review"), c[10].get("review"), c[11].get("review")), (True, False, False))

    def test_unblock(self):
        "unblock: header token only, both block labels removed"
        self.assertEqual(self.post("/api/card/shop/7/unblock", {}, token=False).code, 403)
        self.assertEqual(self.card_post(7, "unblock", {}).code, 200)
        self.assertIn("api -X DELETE repos/acme/shop/issues/7/labels/blocked:infra", self.calls())

    def test_decide_accept_send_back(self):
        "the decision inbox reads the spec and the newest block note; accept needs a reason and a worktree; send-back needs a blocked card and a note"
        self.items((7, "👤 Spec Review"), (8, "🤖 Coding"))
        self.write("shome/projects/shop/reviews/7.html", '<script>const S=[{"id":"open-questions","t":"Open questions","intro":"","items":["Keep the old header?"],"ro":false},'
                   '{"id":"product","t":"Product","intro":"","items":["Problem: the header is cut.","AC-1: Given a phone, Then the header fits.",'
                   '"AC-2 Given a tablet, Then it fits too."],"ro":true}];\n</script>\n')
        self.gh("issue-comments", json.dumps([{"body": "Validate blocked before"},
                                              {"body": "Factory validate, step 2 (gates): blocked.\nacceptance-intact failed: a test changed.\nTried: a diff of the files."},
                                              {"body": "## Factory report: validate, outcome blocked"}]))
        d = self.get("/api/decide/shop/7").json
        s, b = d["spec"], d["block"]
        self.assertEqual((s["problem"], [c["id"] for c in s["criteria"]], s["questions"]),
                         ("the header is cut.", ["AC-1", "AC-2"], ["Keep the old header?"]))
        self.assertEqual((b["stage"], b["step"], b["times"], b["gate"], b["why"], b["tried"]),
                         ("validate", 2, 0, "acceptance-intact", "acceptance-intact failed: a test changed.", "a diff of the files."))
        self.assertEqual(self.get("/api/decide/shop/7", token=False).code, 403)
        self.assertEqual(self.card_post(7, "accept", {"text": ""}).code, 400, "accepting the tests needs a reason")
        self.assertEqual(self.card_post(7, "accept", {"text": "the label changed"}).code, 502, "a failed accept (no worktree) leaves the card blocked")
        self.assertEqual(self.card_post(8, "send-back", {"text": "restore the test"}).code, 409, "only a blocked card is sent back")
        self.assertEqual(self.card_post(7, "send-back", {"text": " "}).code, 400, "sending back needs a note")
        self.gh("calls", "")
        self.assertEqual(self.card_post(7, "send-back", {"text": "restore the test"}).code, 200)
        self.assertIn("restore the test", self.gh("comments"))
        calls = self.calls()
        self.assertIn("issue comment 7 --repo acme/shop --body-file -", calls)
        self.assertTrue(any("--id PVTI_7 --field-id FLD_x --single-select-option-id opt6" in c for c in calls))
        self.assertIn("api -X DELETE repos/acme/shop/issues/7/labels/blocked", calls)

    def test_cost_block_in_the_inbox(self):
        "a card blocked by cost reads as spend per stage against the limit; only when the newest block note is the cost one"
        os.makedirs(os.path.join(self.P, "cost"))
        self.write("shome/projects/shop/cost/7.json", '{"at":"2026-10-11T10:00:00-03:00","limit":40,"total":41.2,"baseline":0,"stages":{"develop":30.2,"refine":11}}\n')
        def block(notes):
            self.gh("issue-comments", json.dumps([{"body": n} for n in notes]))
            self.fresh()
            return self.get("/api/decide/shop/7").json["block"] or {}
        b = block(["Factory validate, step 2 (gates): blocked.\nacceptance-intact failed.",
                   "Cost limit: blocked.\nEstimated total: $41.20 (estimate), limit $40.00.\n- develop: $30.20\n- refine: $11.00"])
        self.assertEqual((b.get("kind"), float(b["limit"]), float(b["total"]), sorted((k, float(v)) for k, v in b["stages"].items())),
                         ("cost", 40.0, 41.2, [("develop", 30.2), ("refine", 11.0)]))
        self.assertEqual((b.get("stage"), b.get("step"), bool(b.get("tried"))), (None, None, False))
        b = block(["Cost limit: blocked.\nEstimated total: $41.20 (estimate)", "Factory validate, step 2 (gates): blocked.\nacceptance-intact failed."])
        self.assertNotEqual(b.get("kind"), "cost", "the newest block note decides, not the marker")
        os.unlink(os.path.join(self.P, "cost", "7.json"))
        b = block(["Cost limit: blocked.\nEstimated total: $41.20 (estimate)"])
        self.assertNotEqual(b.get("kind"), "cost", "a cost note without the marker is an ordinary block")


class Live(ds.Dash):
    def test_messages_reach_a_running_card(self):
        "a running card's session and handed-over messages come from its transcript; a message waits in its inbox until the hook hands it over, once per agent"
        L = self.lock("develop-11", 11)
        import inbox_hook
        self.transcript("s4", slash("develop", 11),
                        {"type": "assistant", "timestamp": "2026-10-09T10:01:00Z", "message": {"content": [{"type": "text", "text": "Planning the work."}, {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]}},
                        {"type": "attachment", "timestamp": "2026-10-09T10:02:00Z", "attachment": {"type": "hook_additional_context", "content": [inbox_hook.INTRO + "\n\nuse the old header"]}})
        def live():
            s = self.get("/api/live/shop/11").json
            return s["running"], [(e["kind"], e["text"]) for e in s["events"]], [m["text"] for m in s["pending"]]
        self.assertEqual(live(), (True, [("says", "Planning the work."), ("Bash", "ls"), ("owner", "use the old header")], []))
        self.assertEqual(self.post("/api/card/shop/11/message", {"text": "keep the footer"}, token=False).code, 403)
        self.assertEqual(self.card_post(7, "message", {"text": "keep the footer"}).code, 409, "no run, no message")
        self.assertEqual(self.card_post(11, "message", {"text": " "}).code, 400, "an empty message is refused")
        self.assertEqual(self.card_post(11, "message", {"text": 'keep the "footer"'}).code, 200)
        self.assertEqual(live()[2], ['keep the "footer"'])
        def hook(stdin, lock=L):
            r = subprocess.run(["bash", os.path.join(ds.support.SCRIPTS, "inbox-hook.sh")], input=stdin, capture_output=True, text=True,
                               env=dict(os.environ, SHIPFLOOR_RUN_LOCK=lock))
            return r.returncode, (json.loads(r.stdout)["hookSpecificOutput"]["additionalContext"] if r.stdout else "nothing")
        self.assertIn('keep the "footer"', hook("{}")[1])
        self.assertEqual(hook("{}")[1], "nothing", "handed over once")
        self.assertIn('keep the "footer"', hook('{"agent_id":"a1"}')[1], "once per agent")
        self.assertEqual(live()[2], [])
        self.assertEqual(hook("{}", os.path.join(self.P, "locks", "none.lock"))[0], 0, "a lock with no inbox: exit 0")


    def test_AC5_a_message_reaches_a_codex_run_and_shows_as_owner(self):
        "AC-5 on a running Codex card a message waits in the inbox until the agent has read it (inbox.lead), and the message it was handed shows in Live as owner beside what it said and ran"
        import inbox_hook
        home = os.environ["SHIPFLOOR_CODEX_HOME"] = self.path("codex-home")
        L = self.lock("develop-11", 11)
        ds.support.codex_rollout(home, "s1", self.pdir("shop", "control"), stage="develop", issue=11, says=["Planning the work."],
                                 commands=["ls -la"], owner=[inbox_hook.INTRO + "\n\nuse the old header"])
        self.fresh()
        def live():
            s = self.get("/api/live/shop/11").json
            return s["running"], [(e["kind"], e["text"]) for e in s["events"]], [m["text"] for m in s["pending"]]
        running, events, pending = live()
        self.assertTrue(running)
        self.assertIn(("says", "Planning the work."), events)
        self.assertIn(("owner", "use the old header"), events)
        self.assertTrue([k for k, t in events if k not in ("says", "owner") and "ls -la" in t], "the command it ran: %s" % events)
        self.assertEqual([t for k, t in events if k == "owner"], ["use the old header"], "only what the owner sent is the owner's")
        self.assertEqual(pending, [])
        self.assertEqual(self.card_post(11, "message", {"text": "keep the footer"}).code, 200)
        self.assertEqual(live()[2], ["keep the footer"])
        self.write(os.path.relpath(os.path.join(L, "inbox.lead"), self.tmp), "1")  # the agent read it and kept its count
        self.assertEqual(live()[2], [])


class Move(ds.Dash):
    def alone(self, col):
        self.items((9, col))

    def move(self, frm, to, text=""):
        return self.card_post(9, "move", {"column": frm, "to": to, "text": text})

    def test_owner_moves(self):
        "#125: four moves go at once, three need a note (posted first), every other pair of the ten columns is a 403"
        for frm, to in sorted(OWNER_MOVES):
            self.reset_gh(); self.alone(frm)
            r = self.move(frm, to)
            self.assertEqual(r.code, 200, "AC-1 %s -> %s" % (frm, to))
            self.assertTrue(self.gh("edits").rstrip().endswith("PVTI_9 --field-id FLD_x --single-select-option-id " + opt(to)) or opt(to) in self.gh("edits"))
            self.assertEqual(self.gh("comments"), "")
        self.assertEqual(r.json.get("moved_to"), "Ready for Prod", "AC-1 the answer names where the card went")
        for frm, to in sorted(NOTE_MOVES):
            self.reset_gh(); self.alone(frm)
            self.assertEqual(self.move(frm, to, "  ").code, 400, "AC-2 %s -> %s with an empty note" % (frm, to))
            self.assertEqual((self.edits(), self.gh("comments")), ([], ""))
            self.assertEqual(self.move(frm, to, "do it again").code, 200)
            self.assertIn("do it again", self.gh("comments"))
            self.assertIn(opt(to), self.gh("edits"))
            self.assertLess(self.line_of("issue comment"), self.line_of("item-edit"), "AC-2 the note goes before the move")
        self.reset_gh()
        self.memo_board()
        bad = []
        for frm in ds.COLS:
            for to in ds.COLS:
                if (frm, to) in OWNER_MOVES | NOTE_MOVES:
                    continue
                self.alone(frm)
                code = self.move(frm, to, "a note").code
                if code != 403:
                    bad.append("%s->%s=%s" % (frm, to, code))
        self.assertEqual(bad, [], "AC-3 every other pair is refused with 403")
        self.assertEqual(self.gh("edits"), "", "AC-3 no refused pair moved anything")
        self.alone("Inbox")
        self.assertEqual(self.card_post(9, "move", {"column": "Inbox", "to": ["Ready for Refinement"]}).code, 403, "a target that is not a column name")

    def test_stale_column_and_comment(self):
        "#125 AC-5: a stale column is a 409 that says where the card is; comment posts and moves nothing"
        self.alone("Ready for Dev")
        r = self.move("Spec Review", "Ready for Dev")
        self.assertEqual((r.code, self.edits()), (409, []))
        self.assertEqual(r.json.get("column"), "Ready for Dev")
        self.assertEqual(self.card_post(9, "comment", {"text": "one more thing"}).code, 200)
        self.assertIn("one more thing", self.gh("comments"))
        self.assertEqual(self.edits(), [])
        self.assertEqual(self.card_post(9, "comment", {"text": " "}).code, 400)

    def test_locked_cards(self):
        "#125 AC-6: a live run or blocked:infra is a 423 through move, approve and request-changes; nothing posted or moved"
        self.alone("Spec Review")
        self.lock("refine-9", 26)
        r = self.move("Spec Review", "Ready for Dev")
        self.assertEqual((r.code, r.json.get("locked")), (423, "run"))
        self.assertEqual(self.card_post(9, "approve", {"column": "Spec Review"}).code, 423)
        self.assertEqual(self.card_post(9, "request-changes", {"column": "Spec Review", "text": "x"}).code, 423)
        self.assertEqual(self.gh("comments"), "", "a locked request-changes posts no note")
        self.unlock("refine-9")
        self.gh("labels-9", "blocked:infra\n")
        r = self.move("Spec Review", "Ready for Dev")
        self.assertEqual((r.code, r.json.get("locked")), (423, "infra"))
        self.assertEqual(self.card_post(9, "approve", {"column": "Spec Review"}).code, 423)
        self.assertEqual(self.edits(), [])

    def test_overview_lock_opened_position_moves(self):
        "#125 AC-6/AC-8: the overview carries lock, opened, position and the table of owner moves"
        self.items((1, "Ready for Dev"), (2, "Spec Review"), (3, "Ready for Dev"), (4, "Ready for Prod"), (5, "Coding"))
        self.board({1: "Ready for Dev", 2: "Spec Review", 3: "Ready for Dev", 4: "Ready for Prod", 5: "Coding"})
        self.gh("titles.tsv", "1\tOne\t2026-10-01T10:00:00Z\n2\tTwo\n3\tThree\n4\tFour\n5\tFive\n")
        self.gh("label-blocked-infra", '[{"number":3}]'); self.gh("label-blocked", "[]")
        self.lock("develop-5", 26)
        o = self.overview()
        c = {x["issue"]: x for x in o["projects"][0]["cards"]}
        self.assertEqual((c[5]["lock"], c[3]["lock"], c[1]["lock"]), ("run", "infra", None))
        self.assertEqual(c[1]["opened"], "2026-10-01T10:00:00Z")
        self.assertEqual((c[1]["position"], c[3]["position"], c[4]["position"], c[2]["position"]), (1, 2, 1, None))
        self.assertEqual(sorted((f, t["to"], t["note"]) for f in o["moves"] for t in o["moves"][f]),
                         sorted([(f, t, False) for f, t in OWNER_MOVES] + [(f, t, True) for f, t in NOTE_MOVES]))


class Reorder(ds.Dash):
    def setUp(self):
        super().setUp()
        self.gh("label-blocked-infra", "[]"); self.gh("label-blocked", "[]")

    def order(self, col):
        return [int(l.split("\t")[1]) for l in self.gh("items.tsv").splitlines() if l.split("\t")[2] == col]

    def ov_order(self, col):
        return [(c["issue"], c["position"]) for c in self.overview()["projects"][0]["cards"] if c["column"] == col]

    def lastpos(self):
        return (self.gh("positions").splitlines() or [""])[-1]

    def writes(self):
        return len(self.gh("positions").splitlines())

    def reorder(self, n, col, before):
        return self.card_post(n, "reorder", {"column": col, "before": before})

    def test_positions(self):
        "#128 AC-1: positions in board order in Inbox, Ready for Refinement and Ready for Dev; the overview names those columns"
        self.items((20, "Inbox"), (1, "Ready for Dev"), (21, "Inbox"), (8, "Coding"), (2, "Ready for Dev"), (30, "Ready for Refinement"),
                   (3, "Ready for Dev"), (31, "Ready for Refinement"))
        self.board([(20, "Inbox"), (1, "Ready for Dev"), (21, "Inbox"), (8, "Coding"), (2, "Ready for Dev"), (30, "Ready for Refinement"),
                    (3, "Ready for Dev"), (31, "Ready for Refinement")])
        self.assertEqual(self.ov_order("Inbox"), [(20, 1), (21, 2)])
        self.assertEqual(self.ov_order("Ready for Refinement"), [(30, 1), (31, 2)])
        self.assertEqual(self.ov_order("Ready for Dev"), [(1, 1), (2, 2), (3, 3)])
        self.assertEqual(self.ov_order("Coding"), [(8, None)])
        self.assertEqual(self.overview()["ordered"], ["Inbox", "Ready for Refinement", "Ready for Dev"])

    def test_reorder(self):
        "#128 AC-2: the mutation's afterId for the middle, the end and the project's first item; the next overview has the order; a no-op writes nothing"
        self.items((1, "Ready for Dev"), (8, "Coding"), (2, "Ready for Dev"), (3, "Ready for Dev"), (5, "Ready for Refinement"), (6, "Ready for Refinement"))
        r = self.reorder(3, "Ready for Dev", 2)
        self.assertEqual((r.code, r.json.get("position")), (200, 2))
        self.assertEqual(self.lastpos(), "PVTI_3 after PVTI_8", "before #2: after the item right before it")
        self.assertEqual(self.order("Ready for Dev"), [1, 3, 2])
        self.assertEqual(self.ov_order("Ready for Dev"), [(1, 1), (3, 2), (2, 3)], "the next overview has the new order at once")
        self.assertEqual(self.reorder(1, "Ready for Dev", None).code, 200)
        self.assertEqual(self.lastpos(), "PVTI_1 after PVTI_2", "to the end: after the column's last card")
        self.assertEqual(self.ov_order("Ready for Dev"), [(3, 1), (2, 2), (1, 3)])
        self.assertEqual(self.reorder(6, "Ready for Refinement", 5).code, 200)
        self.assertEqual(self.lastpos(), "PVTI_6 after PVTI_1")
        self.items((5, "Ready for Refinement"), (6, "Ready for Refinement"), (7, "Ready for Dev"))
        self.reorder(6, "Ready for Refinement", 5)
        self.assertEqual(self.lastpos(), "PVTI_6 after -", "before the project's first item: no afterId")
        n = self.writes()
        r = self.reorder(6, "Ready for Refinement", 5)
        self.assertEqual((r.code, self.writes(), r.json.get("position")), (200, n, 1), "already in place: a 200 with no write, and the position")

    def test_refusals(self):
        "#128 AC-6/AC-7: locked 423, another column 403, a bad before 400, a card or before that left the column 409 naming it; no write"
        self.items((1, "Ready for Dev"), (2, "Ready for Dev"), (4, "Spec Review"), (9, "Ready for Prod"))
        self.lock("develop-2", 26)
        r = self.reorder(2, "Ready for Dev", 1)
        self.assertEqual((r.code, r.json.get("locked")), (423, "run"))
        self.unlock("develop-2"); self.gh("labels-2", "blocked\n")
        self.assertEqual(self.reorder(2, "Ready for Dev", 1).code, 423, "a blocked card")
        self.gh_rm("labels-2")
        self.assertEqual(self.reorder(1, "Ready for Dev", 2).code, 200, "the same card unlocked is reordered")
        self.reset_gh()
        self.assertEqual(self.reorder(4, "Spec Review", None).code, 403)
        self.assertEqual(self.reorder(9, "Ready for Prod", None).code, 403)
        for before in (1, "2", True):
            self.assertEqual(self.reorder(1, "Ready for Dev", before).code, 400, "before %r" % (before,))
        r = self.reorder(4, "Ready for Dev", 1)
        self.assertEqual((r.code, r.json.get("gone")), (409, 4))
        r = self.reorder(2, "Ready for Dev", 4)
        self.assertEqual((r.code, r.json.get("gone")), (409, 4))
        self.assertEqual(self.writes(), 0)

    def test_move_into_an_ordered_column_goes_last(self):
        "#128 AC-9: a card moved into an ordered column goes after its last card before its Status changes; a failed place write moves nothing"
        for frm, to, last, text in (("Inbox", "Ready for Refinement", "PVTI_11", ""), ("Ready for Refinement", "Inbox", "PVTI_10", ""),
                                    ("Spec Review", "Ready for Dev", "PVTI_12", ""), ("Spec Review", "Ready for Refinement", "PVTI_11", "why"),
                                    ("Ready for Dev", "Ready for Refinement", "PVTI_11", "why")):
            self.reset_gh()
            self.items((9, frm), (10, "Inbox"), (11, "Ready for Refinement"), (12, "Ready for Dev"), (13, "Coding"))
            self.assertEqual(self.card_post(9, "move", {"column": frm, "to": to, "text": text}).code, 200, "%s -> %s" % (frm, to))
            self.assertEqual(self.lastpos(), "PVTI_9 after " + last)
            self.assertLess(self.line_of("updateProjectV2ItemPosition"), self.line_of("item-edit"), "the place is written before the Status")
        self.assertEqual(self.ov_order("Ready for Refinement"), [(11, 1), (9, 2)])
        self.reset_gh(); self.items((9, "Spec Review"), (12, "Ready for Dev")); self.gh("fail-position", "")
        self.assertEqual(self.card_post(9, "move", {"column": "Spec Review", "to": "Ready for Dev"}).code, 502)
        self.assertEqual(self.gh("edits"), "")
        self.reset_gh(); self.items((9, "Inbox"), (12, "Ready for Dev"))
        self.assertEqual((self.card_post(9, "move", {"column": "Inbox", "to": "Ready for Refinement"}).code, self.writes()), (200, 0), "into an empty column")
        self.reset_gh(); self.items((9, "Staged"), (14, "Ready for Prod"))
        self.assertEqual((self.card_post(9, "move", {"column": "Staged", "to": "Ready for Prod"}).code, self.writes()), (200, 0), "Ready for Prod is not ordered")


class TakeBack(ds.Dash):
    PRS = '[{"number":41,"headRefName":"feat/90-other"},{"number":42,"headRefName":"feat/9-the-card"}]'

    def blocked(self, col):
        self.items((9, col)); self.gh("labels-9", "blocked\n")

    def take(self, to, text=""):
        return self.card_post(9, "take-back", {"to": to, "text": text})

    def test_table(self):
        "#127 AC-2: from Coding and Validation three columns, from anywhere else two; the own column and the rest are 409; others 400"
        self.memo_board()
        bad = []
        for frm in ds.COLS:
            allowed = ("Inbox", "Ready for Refinement", "Ready for Dev") if frm in ("Coding", "Validation") else ("Inbox", "Ready for Refinement")
            for to in ("Inbox", "Ready for Refinement", "Ready for Dev"):
                self.reset_gh(); self.blocked(frm)
                code = self.take(to).code
                if to != frm and to in allowed:
                    if code != 200 or opt(to) not in self.gh("edits"):
                        bad.append("%s->%s=%s(want 200)" % (frm, to, code))
                elif code != 409 or self.edits():
                    bad.append("%s->%s=%s(want 409)" % (frm, to, code))
        self.assertEqual(bad, [])
        self.reset_gh(); self.blocked("Validation")
        self.assertEqual((self.take("Coding").code, self.edits()), (400, []))
        self.assertEqual(self.card_post(9, "take-back", {"to": ["Inbox"]}).code, 400)
        tb = self.overview()["take_back"]
        self.assertEqual(sorted((f, tuple(v)) for f, v in tb.items()),
                         [("*", ("Inbox", "Ready for Refinement")), ("Coding", ("Inbox", "Ready for Refinement", "Ready for Dev")),
                          ("Validation", ("Inbox", "Ready for Refinement", "Ready for Dev"))], "the overview's take_back is the server's table")

    def test_comment(self):
        "#127 AC-3: a comment is posted before the move; a blank one posts nothing; a failed one moves nothing and keeps the block"
        self.blocked("Validation")
        r = self.take("Ready for Dev", "the spec was right, the code was not")
        self.assertEqual(r.code, 200)
        self.assertIn("the spec was right", self.gh("comments"))
        self.assertLess(self.line_of("issue comment"), self.line_of("item-edit"))
        self.assertIs(r.json.get("commented"), True)
        self.reset_gh(); self.blocked("Validation")
        self.assertEqual((self.take("Ready for Dev", "   ").code, self.gh("comments"), len(self.edits())), (200, "", 1))
        self.reset_gh(); self.blocked("Validation"); self.gh("fail-comment", "")
        self.assertEqual((self.take("Ready for Dev", "x").code, self.edits()), (502, []))
        self.assertFalse(any("labels/blocked" in c for c in self.calls()))

    def test_pull_request(self):
        "#127 AC-4/AC-5: to the Inbox the card's open pull request is closed (branch kept) before the move; a failed close moves nothing; elsewhere it stays"
        self.blocked("Validation"); self.gh("prs", self.PRS)
        r = self.take("Inbox")
        self.assertEqual(r.code, 200)
        closed = self.gh("pr-closed").splitlines()
        self.assertEqual(len(closed), 1, "another card's pull request stays open")
        self.assertTrue(closed[0].startswith("pr close 42 "))
        self.assertNotIn("--delete-branch", closed[0])
        self.assertLess(self.line_of("pr close"), self.line_of("item-edit"))
        self.assertEqual(r.json.get("pr_closed"), 42)
        self.reset_gh(); self.blocked("Validation"); self.gh("prs", self.PRS); self.gh("fail-pr-close", "")
        self.assertEqual((self.take("Inbox").code, self.edits()), (502, []))
        self.assertFalse(any("labels/blocked" in c for c in self.calls()))
        self.reset_gh(); self.blocked("Technical Refinement")
        r = self.take("Inbox")
        self.assertEqual((r.code, r.json.get("pr_closed", "missing")), (200, None), "no open pull request is not an error")
        for to in ("Ready for Dev", "Ready for Refinement"):
            self.reset_gh(); self.blocked("Coding"); self.gh("prs", self.PRS)
            self.assertEqual(self.take(to).code, 200)
            self.assertFalse(any(c.startswith("pr ") for c in self.calls()), "to %s the pull request is not touched" % to)

    def test_unblocks_after_the_move(self):
        "#127 AC-6: both block labels come off after the move and the next overview shows the card unblocked"
        self.blocked("Validation")
        self.board({9: "Validation"}); self.gh("label-blocked", '[{"number":9}]'); self.gh("label-blocked-infra", "[]"); self.gh("titles.tsv", "9\tNine\n")
        c = self.cards()[9]
        self.assertEqual((c["column"], c["blocked"], c["lock"]), ("Validation", "owner", "blocked"))
        r = self.take("Ready for Refinement")
        self.assertEqual(r.code, 200)
        d = next(i for i, l in enumerate(self.calls()) if l.endswith("labels/blocked"))
        self.assertGreater(d, self.line_of("item-edit"))
        self.assertTrue(any("labels/blocked:infra" in l for l in self.calls()))
        self.gh("label-blocked", "[]")
        c = self.cards()[9]
        self.assertEqual((c["column"], c["blocked"], c["lock"]), ("Ready for Refinement", None, None))
        self.assertIs(r.json.get("unblocked"), True)

    def test_refused(self):
        "#127 AC-7: blocked by infrastructure, a live run, not blocked, not on the board: 409, nothing posted or moved"
        self.items((9, "Validation")); self.gh("labels-9", "blocked:infra\nblocked\n")
        r = self.take("Inbox", "x")
        self.assertEqual((r.code, r.json.get("locked")), (409, "infra"))
        self.assertEqual((self.gh("comments"), self.edits()), ("", []))
        self.reset_gh(); self.blocked("Validation"); self.lock("validate-9", 26)
        r = self.take("Inbox")
        self.assertEqual((r.code, r.json.get("locked")), (409, "run"))
        self.unlock("validate-9")
        self.reset_gh(); self.items((9, "Validation"))
        self.assertEqual((self.take("Inbox").code, self.edits()), (409, []), "not blocked")
        self.reset_gh(); self.items((8, "Validation"))
        self.assertEqual(self.take("Inbox").code, 409, "not on the board")


class Titles(ds.Dash):
    def titles(self, *rows):
        self.gh("titles.tsv", "".join("%s\t%s\n" % r for r in rows))
        self.gh_rm("calls", "fail")
        self.fresh()

    def title_of(self, n, *cards):
        self.board({c: "Staged" for c in cards})
        return next((c["title"] for c in self.overview()["projects"][0]["cards"] if c["issue"] == n), "<no card>")

    def reads(self):
        return sum("issueOrPullRequest" in l for l in self.calls())

    def test_failed_reads(self):
        "a failed title read is not remembered: the next poll asks again and fills them, the card endpoint too; known titles survive a later failure"
        self.titles((41, "Forty-one"), (42, "Forty-two"))
        self.gh("fail", ""); self.title_of(41, 41, 42)
        self.gh_rm("fail"); self.gh("calls", "")
        self.assertEqual(self.title_of(41, 41, 42), "Forty-one", "AC-1/AC-3 one poll after a failed first read")
        self.assertGreaterEqual(self.reads(), 1, "AC-3 asked again on the next poll")
        self.assertEqual(self.title_of(42, 41, 42), "Forty-two")
        self.titles((41, "Forty-one"), (42, "Forty-two"))
        self.gh("fail", ""); self.title_of(41, 41, 42); self.gh_rm("fail")
        self.assertEqual(self.get("/api/card/shop/41").json["title"], "Forty-one", "AC-6 the card endpoint after a failed first read")
        self.titles((41, "Forty-one"), (42, "Forty-two"), (43, "Forty-three"))
        self.assertEqual(self.title_of(41, 41, 42), "Forty-one")
        self.gh("fail", "")
        self.assertEqual((self.title_of(41, 41, 42, 43), self.title_of(42, 41, 42, 43)), ("Forty-one", "Forty-two"), "AC-2 a failed read keeps the known titles")

    def test_reads_by_number_once_per_window(self):
        "one read for all cards, by number (a card past the 300 newest issues too), not repeated inside the cache window"
        self.titles((41, "Forty-one"), (42, "Forty-two"), (4321, "Far away"))
        self.title_of(41, 41, 42)
        self.assertEqual(self.reads(), 1)
        self.title_of(41, 41, 42); self.title_of(42, 41, 42)
        self.assertEqual(self.reads(), 1, "AC-4 polls inside the window do not ask again")
        self.titles((41, "Forty-one"), (4321, "Far away"))
        self.assertEqual(self.title_of(4321, 41, 4321), "Far away", "AC-5")

    def test_gh_down(self):
        "AC-7: gh failing on every read: the overview and the card still answer 200, with empty titles"
        self.titles((41, "Forty-one"), (42, "Forty-two"))
        self.gh("fail", "")
        self.board({41: "Staged", 42: "Staged"})
        r = self.get("/api/overview")
        self.assertEqual(r.code, 200)
        self.assertEqual([c["title"] for c in r.json["projects"][0]["cards"]], ["", ""])
        r = self.get("/api/card/shop/41")
        self.assertEqual((r.code, r.json["title"]), (200, ""))


class BlockLine(ds.Dash):
    def test_block_line(self):
        "a blocked card's line in the list: the owner's call, else the failed gate, else nothing; a cost block's figures; none for infrastructure"
        os.makedirs(os.path.join(self.P, "cost"))
        self.board({n: "Coding" for n in range(7, 14)})
        self.gh("label-blocked", '[{"number":7},{"number":8},{"number":9},{"number":10},{"number":13}]')
        self.gh("label-blocked-infra", '[{"number":11}]')
        notes = {7: "**Develop blocked** at step 4: the API answers 410.\n- **The owner must decide:** keep the `v1` endpoint or drop it\nTried: two rounds.",
                 8: "**Develop blocked** at step 3: the tests timed out twice.",
                 9: "**Validate blocked.** Failed gates: **acceptance-intact**. The test files changed after QA.",
                 10: "Cost limit: blocked. The card spent $7.50 est.",
                 11: "**Validate blocked (infrastructure)**: the stack did not come up.",
                 13: "**Develop blocked.** Needs you to: " + "pick one " * 80}
        for n, t in notes.items():
            self.gh("comments-%d" % n, json.dumps([{"body": "Spec ready"}, {"body": t}]))
        self.write("shome/projects/shop/cost/10.json", '{"total": 7.5, "baseline": 2.5, "limit": 5, "stages": {"develop": 5.0}}')
        c = self.cards()
        got = lambda n: (c[n].get("blocked"), c[n].get("block_line", "<missing>"), c[n].get("block_cost", "<missing>"))
        self.assertEqual(got(7), ("owner", "Keep the v1 endpoint or drop it", None), "AC-1 the owner's call, label and marks off, capitalized")
        self.assertTrue(100 < len(c[13]["block_line"]) <= 500, "AC-1 a long call is bounded at 500 characters")
        self.assertEqual(got(8), ("owner", "", None), "AC-2 no reason, no line")
        self.assertEqual(got(9), ("owner", "Failed gate: acceptance-intact", None))
        self.assertEqual(got(12), (None, "", None))
        self.assertEqual(got(10), ("owner", "", {"baseline": 2.5, "limit": 5, "total": 5.0}), "AC-2 a cost block carries its figures")
        self.assertEqual(got(11), ("infra", "", None), "AC-3 an infrastructure block has no line")


class Weight(ds.Dash):
    SPEC = "docs/superpowers/specs/2026-10-12-the-thing-design.md"

    def git(self, *a, cwd=None):
        return subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True).stdout.strip()

    def setUp(self):
        super().setUp()
        os.environ.update(GIT_CONFIG_COUNT="3", GIT_CONFIG_KEY_0="init.defaultBranch", GIT_CONFIG_VALUE_0="main",
                          GIT_CONFIG_KEY_1="maintenance.auto", GIT_CONFIG_VALUE_1="false", GIT_CONFIG_KEY_2="gc.auto", GIT_CONFIG_VALUE_2="0",
                          GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        repo, self.W, self.origin = self.path("repo"), self.path("wt"), self.path("origin")
        self.git("init", "-q", "-b", "main", repo)
        self.write("repo/README.md", "base\n")
        self.git("add", "-A", cwd=repo); self.git("commit", "-qm", "base", cwd=repo)
        self.write("shome/registry.tsv", "shop\t%s\t%s\tmain\n" % (repo, self.W))
        self.git("init", "-q", "--bare", self.origin)
        w7 = self.w7 = os.path.join(self.W, "7")
        self.git("clone", "-q", repo, w7); self.git("checkout", "-q", "-b", "feat/7-the-thing", cwd=w7)
        self.write(os.path.relpath(os.path.join(w7, self.SPEC), self.tmp),
                   "# The thing — spec\n\n**Issue:** #7 · **Branch:** `feat/7-the-thing` · **Date:** 2026-10-12\n**Roles:** PO, Tech Lead\n\n"
                   "## Product\n- **AC-1** — x\n\n## Decisions\n- **Weight:** kept out of the header on purpose\n")
        self.git("add", "-A", cwd=w7); self.git("commit", "-qm", "docs(the-thing): spec for #7", cwd=w7)
        self.git("remote", "set-url", "origin", self.origin, cwd=w7); self.git("push", "-q", "-u", "origin", "feat/7-the-thing", cwd=w7)
        self.git("clone", "-q", repo, os.path.join(self.W, "8")); self.git("checkout", "-q", "-b", "feat/8-other", cwd=os.path.join(self.W, "8"))
        self.board({7: "Spec Review", 8: "Technical Refinement"})
        self.items((7, "👤 Spec Review"), (8, "🤖 Technical Refinement"))
        self.page = self.write("shome/projects/shop/reviews/7.html", "<html><head></head><body>review</body></html>")
        self.marks = self.write("shome/projects/shop/reviews/7.marks.json", '{"rev":"r1","marks":{"a":{"s":"ok","n":""}}}')
        self.fresh()

    def card(self, n):
        return self.get("/api/card/shop/%d" % n).json

    def weight_of(self, n):
        env = dict(os.environ, FACTORY_CONFIG=os.path.join(self.P, "factory.yml"), FACTORY_HOME=self.P, FACTORY_WT_ROOT=self.W)
        return subprocess.run(["bash", "-c", "source '%s/lib/project.sh'; shipfloor_card_weight %d" % (ds.support.SCRIPTS, n)],
                              env=env, capture_output=True, text=True).stdout.strip()

    def spec_lines(self):
        with open(os.path.join(self.w7, self.SPEC), encoding="utf-8") as f:
            return f.read().split("\n")

    def test_weight_and_models_on_the_card(self):
        "#133 AC-8: the card shows its weight (standard when the spec has none), the model per weight, and each session's model, stepped-up ones with the gate"
        from datetime import datetime, timedelta, timezone
        at = lambda m: (datetime.now(timezone.utc) - timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%S+00:00")
        day = datetime.now().strftime("%Y-%m-%d")
        self.log("%s-7-develop.log" % day, "== start /sf:develop 7 %s pid=11 model=sonnet weight=standard\n== end /sf:develop 7 exit=0 %s\n"
                 "== step-up /sf:develop 7 sonnet -> opus: gate build failed %s\n== start /sf:develop 7 %s pid=12 model=opus weight=standard\n"
                 "== end /sf:develop 7 exit=0 %s\n" % (at(180), at(170), at(170), at(120), at(110)))
        for sid, m, model in (("s1", 179, "claude-sonnet-5-5"), ("s2", 119, "claude-opus-5-5")):
            self.transcript(sid, slash("develop", 7, at(m)), ds.ast("m-" + sid, model, {"input_tokens": 1000, "output_tokens": 10}, at(m)))
        c = self.card(7)
        self.assertEqual((c["weight"], c["weight_set"]), ("standard", False))
        self.assertEqual(c["weight_models"], {"light": "sonnet", "standard": "sonnet", "heavy": "opus"})
        self.assertEqual(((self.card(8)["weight"], self.card(8)["weight_set"]), self.card(9)["weight"]), ((None, False), None), "no spec, no worktree: no weight")
        stepped = {"from": "sonnet", "to": "opus", "gates": ["build"]}
        self.assertEqual([(s["model"], s["stepped"]) for s in c["sessions"]], [("sonnet", None), ("opus", stepped)])
        self.assertEqual([(r["model"], r["again"]) for r in c["runs"]], [("sonnet", "opus"), ("opus", None)])
        feed = [(e.get("model"), e.get("stepped"), e.get("again")) for e in self.get("/api/feed").json["events"] if e.get("issue") == 7]
        self.assertEqual(feed, [("sonnet", None, "opus"), ("opus", stepped, None)], "the Feed names both models and the gate")
        self.log("%s-7-validate.log" % day, "== start /sf:validate 7 %s pid=13\n" % at(60))
        self.transcript("v1", slash("validate", 7, at(59)), ds.ast("m-v", "claude-haiku-5-5", {"input_tokens": 5, "output_tokens": 1}, at(59)))
        self.fresh()
        self.assertEqual([s["model"] for s in self.card(7)["sessions"] if s["stage"] == "validate"], ["claude-haiku-5-5"], "no model on the start line: the transcript's")

    def test_set_weight(self):
        "#133 AC-6: the owner's weight is one header line, one commit, pushed; refused for another value, outside Spec Review, a live run; a failed push undoes it"
        r = self.card_post(7, "weight", {"weight": "heavy"})
        self.assertEqual((r.code, r.json), (200, {"weight": "heavy", "model": "opus"}))
        lines = self.spec_lines()
        self.assertEqual(sum(l.startswith("**Weight:**") for l in lines), 1)
        self.assertEqual(lines[4], "**Weight:** heavy", "under the header's last field")
        self.assertEqual(self.git("log", "-1", "--format=%s", cwd=self.w7), "docs(the-thing): weight heavy for #7")
        self.assertEqual(self.git("log", "-1", "--format=%s", "feat/7-the-thing", cwd=self.origin), "docs(the-thing): weight heavy for #7", "pushed")
        self.assertEqual(self.git("status", "--porcelain", cwd=self.w7), "")
        self.assertEqual((self.card(7)["weight"], self.card(7)["weight_set"]), ("heavy", True))
        self.assertEqual(self.weight_of(7), "heavy", "the next run reads it")
        self.card_post(7, "weight", {"weight": "light"})
        self.assertEqual(sum(l.startswith("**Weight:**") for l in self.spec_lines()), 1, "a second change replaces the line")
        self.assertEqual(self.weight_of(7), "light")
        self.assertEqual(sum("weight" in l and "for #7" in l for l in self.git("log", "--format=%s", cwd=self.w7).splitlines()), 2, "one commit per change")
        with open(self.page) as f:
            self.assertEqual(f.read(), "<html><head></head><body>review</body></html>", "the review page is not rebuilt")
        with open(self.marks) as f:
            self.assertEqual(f.read(), '{"rev":"r1","marks":{"a":{"s":"ok","n":""}}}', "the owner's marks stay")
        self.assertEqual(self.card_post(7, "weight", {"weight": "medium"}).code, 400)
        head = self.git("rev-parse", "HEAD", cwd=self.w7)
        self.items((7, "👤 Ready for Dev"))
        r = self.card_post(7, "weight", {"weight": "heavy"})
        self.assertEqual((r.code, r.json), (409, {"error": "the card is no longer in Spec Review.", "errors": [{"key": "err.not_spec_review", "params": {}}]}))
        self.items((7, "👤 Spec Review"))
        self.lock("refine-7", 7, pid=os.getpid())
        self.assertEqual(self.card_post(7, "weight", {"weight": "heavy"}).code, 409, "a live run")
        self.unlock("refine-7")
        self.git("remote", "set-url", "origin", self.origin + ".gone", cwd=self.w7)
        r = self.card_post(7, "weight", {"weight": "heavy"})
        self.assertEqual(r.code, 500)
        self.assertIn("could not push feat/7-the-thing", r.text)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.w7), head, "a failed push undoes the commit")
        self.assertEqual(self.weight_of(7), "light")
        self.git("remote", "set-url", "origin", self.origin, cwd=self.w7)
        self.assertEqual(self.card(7)["weight"], "light")

    def test_cli(self):
        "#133 AC-6: shipfloor weight sets it from the command line, refuses another value with exit 2, and its usage lists it"
        sf = os.path.join(ds.support.SCRIPTS, "shipfloor")
        run = lambda *a: subprocess.run(["bash", sf, *a], capture_output=True, text=True)
        self.assertEqual(run("weight", "shop", "7", "huge").returncode, 2)
        r = run("weight", "shop", "7", "standard")
        self.assertEqual((r.returncode, (r.stdout + r.stderr).strip()), (0, "weight standard"))
        self.assertIn("weight <slug> <n> <light|standard|heavy>", run().stdout + run().stderr)


class Marks(ds.Dash):
    PROJECTS = ("shop", "blog")

    def page(self, p, title, n):
        self.write("shome/projects/%s/reviews/%d.html" % (p, n), "<html><head><title>%s</title></head><body>review %s</body></html>" % (title, title))
        with open(self.pdir(p, "reviews", "%d.html" % n), "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]

    def save(self, p, n, body, token=True):
        return self.req("POST", "/api/card/%s/%s/marks" % (p, n), body, token=token).code

    def embed(self, p, n):
        return self.get("/review/%s/%d?embed=1&t=%s" % (p, n, self.token), token=False).text

    def marks(self, p, n):
        h = self.embed(p, n)
        k = "window.__shipfloorMarks="
        i = h.find(k)
        if i < 0:
            return None
        d = json.loads(h[i + len(k):h.find("</script>", i)])
        return {"rev": d["rev"], "marks": d["marks"]}

    def test_marks(self):
        "the review page's Keep/Change marks are kept per card and project, handed back inside the embedded page, escaped, and dropped when the page is rebuilt"
        r7, r8, rb7 = self.page("shop", "spec seven", 7), self.page("shop", "spec eight", 8), self.page("blog", "spec seven of blog", 7)
        m7 = {"intro": {"s": "ok", "n": ""}, "ac-1": {"s": "chg", "n": "rename the field"}}
        self.assertEqual(self.save("shop", 7, {"rev": r7, "marks": m7}), 200)
        self.assertEqual(self.marks("shop", 7), {"rev": r7, "marks": m7}, "AC-2 what was saved comes back")
        h = self.embed("shop", 7)
        self.assertRegex(h, r"(?s)<title>spec seven</title>.*window\.__shipfloorMarks=.*</head>", "AC-2 injected in the head, the page kept")
        self.assertEqual(self.marks("shop", 7)["marks"], m7, "as many times as it is opened")
        self.save("shop", 7, {"rev": r7, "marks": {"ac-2": {"s": "ok", "n": ""}}})
        self.assertEqual(self.marks("shop", 7)["marks"], {"ac-2": {"s": "ok", "n": ""}}, "the last save wins")
        self.assertTrue(os.path.isfile(self.pdir("shop", "reviews", "7.marks.json")))
        note = 'close </script><script>alert(1)</script> & <b>"quoted"</b> \\ line'
        self.assertEqual(self.save("shop", 7, {"rev": r7, "marks": {"ac-3": {"s": "chg", "n": note}}}), 200)
        self.assertEqual(self.marks("shop", 7)["marks"]["ac-3"]["n"], note, "AC-3 the note comes back intact")
        import re
        h = self.embed("shop", 7)
        self.assertEqual(len(re.findall(r"<script\b", h, re.I)), len(re.findall(r"</script>", h, re.I)), "AC-3 every script closed once")
        self.assertNotIn("alert(1)</script>", h)
        i = h.find("window.__shipfloorMarks="); block = h[i:h.find("</script>", i)]
        self.assertTrue(all(e in block for e in ("\\u003c", "\\u003e", "\\u0026")) and not any(c in block[24:] for c in "<>&"), "AC-3 <, > and & escaped")
        self.save("shop", 7, {"rev": r7, "marks": m7})
        self.assertEqual(self.marks("shop", 8), {"rev": r8, "marks": {}}, "AC-5 another card has none")
        self.assertEqual(self.marks("blog", 7)["marks"], {}, "AC-5 the same number in another project has none")
        self.save("shop", 8, {"rev": r8, "marks": {"x": {"s": "chg", "n": "only eight"}}})
        self.save("blog", 7, {"rev": rb7, "marks": {"y": {"s": "ok", "n": ""}}})
        self.assertEqual((self.marks("shop", 7)["marks"], self.marks("shop", 8)["marks"], self.marks("blog", 7)["marks"]),
                         (m7, {"x": {"s": "chg", "n": "only eight"}}, {"y": {"s": "ok", "n": ""}}))
        r7b = self.page("shop", "spec seven reworked", 7)
        self.assertEqual(self.marks("shop", 7), {"rev": r7b, "marks": {}}, "AC-6 a rebuilt page starts unmarked")
        self.assertEqual(self.save("shop", 7, {"rev": r7, "marks": m7}), 409, "AC-6 a save on the old page")
        self.assertEqual(self.marks("shop", 7)["marks"], {})
        self.assertEqual(self.save("shop", 7, {"rev": r7b, "marks": {"z": {"s": "ok", "n": ""}}}), 200)
        self.assertEqual(self.marks("shop", 7)["marks"], {"z": {"s": "ok", "n": ""}})
        self.write("shome/projects/shop/reviews/7.marks.json", json.dumps({"rev": r7, "marks": {"old": {"s": "ok", "n": ""}}}))
        self.assertEqual(self.marks("shop", 7)["marks"], {}, "a marks file of another rev is not served")
        self.write("shome/projects/shop/reviews/7.marks.json", "not json")
        self.assertEqual(self.marks("shop", 7)["marks"], {}, "an unreadable marks file gives none")
        self.save("shop", 7, {"rev": r7b, "marks": m7})
        self.assertEqual(self.save("shop", 7, {"rev": r7b, "marks": {}}), 200)
        self.assertFalse(os.path.exists(self.pdir("shop", "reviews", "7.marks.json")), "AC-7 an empty save deletes the file")
        self.assertEqual(self.marks("shop", 7)["marks"], {})
        self.assertEqual(self.save("shop", 7, {"rev": r7b, "marks": {}}), 200, "clearing nothing is fine")

    def test_refusals(self):
        "the marks contract: ids, states, notes up to 2000, 500 ids, 256 KB, unknown project or page, the token; a refusal stores nothing"
        rev = self.page("shop", "spec seven", 7)
        ok = {"s": "ok", "n": ""}
        for marks in ({"BAD_ID": ok}, {"": ok}, {"a" * 81: ok}, {"a": {"s": "maybe", "n": ""}}, {"a": {"s": "chg", "n": 5}},
                      {"a": {"s": "chg", "n": "x" * 2001}}, {"i%d" % k: ok for k in range(501)}):
            self.assertEqual(self.save("shop", 7, {"rev": rev, "marks": marks}), 400, str(marks)[:60])
        self.assertEqual(self.save("shop", 7, {"rev": rev, "marks": {"a": {"s": "chg", "n": "x" * 2000}}}), 200)
        self.assertEqual(self.save("shop", 7, {"rev": rev, "marks": {"i%d" % k: ok for k in range(500)}}), 200)
        huge = {"rev": rev, "marks": {"a": {"s": "chg", "n": "x" * 2000}}, "pad": "p" * 262144}
        self.assertEqual(self.save("shop", 7, huge), 400, "a body over 256 KB")
        self.save("shop", 7, {"rev": rev, "marks": {}})
        self.assertEqual(self.save("shop", 7, {"rev": rev, "marks": {"BAD": ok}}), 400)
        self.assertEqual(self.marks("shop", 7)["marks"], {}, "a refused save stores nothing")
        self.assertEqual(self.save("nope", 7, {"rev": rev, "marks": {"a": ok}}), 404)
        self.assertEqual(self.save("shop", 99, {"rev": rev, "marks": {"a": ok}}), 404, "a card with no review page")
        self.assertEqual(self.save("shop", 7, {"rev": rev, "marks": {"a": ok}}, token=False), 403)
        self.assertEqual(self.req("POST", "/api/card/shop/7/marks?t=" + self.token, {"rev": rev, "marks": {"a": ok}}, token=False).code, 403)
        self.assertFalse(os.path.exists(self.pdir("shop", "reviews", "7.marks.json")), "refused saves left no file")


class Amend(ds.Dash):
    """#204 AC-7: a card blocked by qa-amend carries the acceptance-test diff of its newest QA commit and can be approved."""
    OWNER_DECIDES = ("Factory validate, step 2 (gates): blocked.\nqa-amend failed: qa-amend: the acceptance tests of #7 were already "
                     "amended 2 times; the owner decides now. To allow one more amendment, add the label qa-amend-ok to the issue, "
                     'or press "Approve this amendment" on the card in the dashboard.\nTried: nothing.')
    TEST = "api/src/test/ATest.kt"

    def git(self, *a):
        return subprocess.run(["git", *a], cwd=self.w7, capture_output=True, text=True)

    def setUp(self):
        super().setUp()
        os.environ.update(GIT_CONFIG_COUNT="3", GIT_CONFIG_KEY_0="init.defaultBranch", GIT_CONFIG_VALUE_0="main",
                          GIT_CONFIG_KEY_1="maintenance.auto", GIT_CONFIG_VALUE_1="false", GIT_CONFIG_KEY_2="gc.auto", GIT_CONFIG_VALUE_2="0",
                          GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        self.W = self.path("wt")
        self.w7 = os.path.join(self.W, "7")
        os.makedirs(self.w7)
        self.git("init", "-q", "-b", "main")
        self.write("wt/7/README.md", "base\n")
        self.git("add", "-A"); self.git("commit", "-qm", "base")
        self.git("checkout", "-q", "-b", "feat/7-x")
        self.write("wt/7/" + self.TEST, "fun a() {\n  assertEquals(1, one())\n}\n")
        self.git("add", "-A"); self.git("commit", "-qm", "test(x): acceptance tests for #7")
        self.write("wt/7/api/Impl.kt", "impl\n")
        self.git("add", "-A"); self.git("commit", "-qm", "feat(api): impl")
        self.write("wt/7/" + self.TEST, "fun a() {\n  assertEquals(1, oneTrimmed())\n  assertTrue(ok())\n}\n")
        self.git("add", "-A"); self.git("commit", "-qm", "test(x): acceptance tests for #7")
        self.write("shome/registry.tsv", "shop\t/x/shop\t%s\tmain\n" % self.W)
        self.items((7, "🤖 Validation"), (8, "🤖 Validation"))
        self.gh("labels-7", "blocked\n")
        self.gh("issue-comments", json.dumps([{"body": self.OWNER_DECIDES}]))
        self.fresh()

    def block(self):
        return self.get("/api/decide/shop/7").json["block"]

    def test_block_note_carries_the_amendment_diff(self):
        "AC-7: a qa-amend block shows the diff of the acceptance tests against the previous QA commit; other blocks do not"
        b = self.block()
        self.assertEqual(b["gate"], "qa-amend")
        self.assertIn("-  assertEquals(1, one())", b["diff"])
        self.assertIn("+  assertEquals(1, oneTrimmed())", b["diff"])
        self.assertIn("+  assertTrue(ok())", b["diff"])
        self.assertNotIn("Impl.kt", b["diff"])
        self.gh("issue-comments", json.dumps([{"body": "Factory validate, step 2 (gates): blocked.\nqa-amend failed: the amendment "
                                                       "switches a test off.\nTried: nothing."}]))
        self.fresh()
        self.assertNotEqual(self.block()["gate"], "qa-amend", "only 'the owner decides now' is the extra-amendment block")

    def test_approve_amend_adds_the_label_then_unblocks(self):
        "AC-7: approve-amend adds qa-amend-ok, then removes blocked; a card that is not blocked is refused and nothing is written"
        self.assertEqual(self.card_post(7, "approve-amend", {}, p="shop").code, 200)
        calls = self.calls()
        add = next(i for i, l in enumerate(calls) if "issues/7/labels" in l and "qa-amend-ok" in l and "DELETE" not in l)
        rm = next(i for i, l in enumerate(calls) if "DELETE" in l and l.endswith("issues/7/labels/blocked"))
        self.assertLess(add, rm, "the label is written before the card is unblocked")
        self.assertEqual(self.post("/api/card/shop/7/approve-amend", {}, token=False).code, 403)
        self.gh("calls", "")
        self.assertEqual(self.card_post(8, "approve-amend", {}).code, 409)
        self.assertFalse(any("qa-amend-ok" in l for l in self.calls()))
