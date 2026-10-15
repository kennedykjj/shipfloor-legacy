"""The work area (#182): below the belt, one panel decides what the owner sees: Decide on the oldest waiting card (or the one
selected on the belt), Run for a running card, Card for any other, Calm when nothing waits. The page's own script runs in node
on a fake DOM (belt_page.py), fed overviews shaped like the real server's (the belt's fixture, dashboard_belt.Scene) and the
cards' payloads as /api/card/<project>/<n> answers them; the tests read what the work area drew, what the keys did, which POSTs
left and when (the page's timers are advanced; a decision leaves at once, nothing holds it). Area is AC-1, AC-4, AC-5, AC-6 and AC-7,
Keys is AC-2, Quick is AC-3 and Design is AC-8; dashboard-views.test.sh runs them all."""
import copy
import json
import re
from datetime import datetime, timedelta

import belt_page as bp
import dashboard_belt as db
import support
import dashboard_v4 as v4

KEY = "shop/%d"
BRIEF = {"what": {"text": "Adds the work area below the belt.", "by": "po"}, "flags": [{"title": "Touches the drawer", "detail": "It goes away.", "suggestion": "Keep the Log tab."}],
         "proven": ["lint passed"], "rest": ["a minor point"], "verdict": "look"}
REGEX_MS = re.compile(r"\b(?:260|400)ms\b|\b0?\.(?:26|4)0?s\b")


def stamp(minutes):
    """a moment 'minutes' ago, ten seconds short of it: it still reads as that many minutes when the page draws it a moment later"""
    return (datetime.now().astimezone() - timedelta(minutes=minutes, seconds=-10)).isoformat(timespec="seconds")


def payload(n, column, brief=None, review=True, **more):
    """what /api/card/shop/<n> answers"""
    d = {"project": "shop", "issue": n, "title": "Title %d" % n, "column": column, "review": review, "sessions": [], "runs": [], "reports": [],
         "weight": "standard", "weight_set": True, "weight_models": {"light": "haiku", "standard": "sonnet", "heavy": "opus"}}
    if brief:
        d["brief"] = brief
    d.update(more)
    return d


def wtext(snap):
    return bp.squash(bp.text(snap["work"])) if snap and snap.get("work") else ""


def ptext(snap):
    """everything the page shows (outside scripts and hidden elements): the toast and the status lines may sit beside the work area"""
    return snap.get("page", "") if snap else ""


def nodes(snap, tag=None):
    return [n for n, _ in bp.walk(snap["work"]) if tag is None or n["tag"] == tag] if snap and snap.get("work") else []


def labels(snap):
    """the text of every button and link of the work area"""
    return [bp.squash(bp.text(n)) for n in nodes(snap) if n["tag"] in ("button", "a")]


def has_label(snap, label, prefix=False):
    return any(x.startswith(label) if prefix else x == label for x in labels(snap))


def token(n):
    return {"op": "clickx", "within": "cells", "sel": 'button[data-key="%s"]' % (KEY % n)}


def click(text, prefix=False, within="work"):
    return {"op": "clickx", "within": within, "text": text, "prefix": prefix}  # within=None: anywhere on the page


def key(k, **kw):
    return dict({"op": "keyx", "key": k}, **kw)


def posts(snap, tail):
    return [p for p in snap["posts"] if p["path"].endswith(tail)]


class WorkScene(db.Scene):
    """The belt's shop project, with the four cards that wait for the owner (22 and 21 in Spec Review, 51 and 50 in Staged, the
    oldest first), the blocked ones made plain and the payloads of the cards the page reads"""

    def setUp(self):
        super().setUp()
        base = copy.deepcopy(self.ov)
        p = base["projects"][0]
        for c in p["cards"]:
            c["since"] = {22: stamp(90), 51: stamp(80), 21: stamp(30), 50: stamp(20)}.get(c["issue"], c["since"])
            if c["issue"] in (11, 31):
                c["cost"] = {11: 1.2, 31: 0.42}[c["issue"]]
        self.blocked = copy.deepcopy(base)
        c42 = next(c for c in p["cards"] if c["issue"] == 42)
        c42.update(blocked=None, awaiting=False)
        for n in (22, 51):
            next(c for c in p["cards"] if c["issue"] == n)["review"] = True
        run = next(r for r in base["runs"] if r["issue"] == 31)
        run["activity"] = [{"kind": "says", "text": "Planning the swap.", "ts": stamp(9)}] + [
            {"kind": ("Bash", "Edit", "Read")[i % 3], "text": "src/alpha-%d.py" % i, "ts": stamp(8 - i)} for i in range(1, 8)]
        p["shipped"] = [{"issue": 70, "title": "Title 70", "pr": 64, "at": stamp(5), "cost": 0.84}, {"issue": 71, "title": "Title 71", "pr": 65, "at": stamp(10), "cost": None}]
        self.base = base

    # ---- overviews
    def card_of(self, ov, n):
        return next(c for c in ov["projects"][0]["cards"] if c["issue"] == n)

    def waiting_only(self, *keep):
        """base, with only these cards of the four still waiting (the others have moved on)"""
        ov = copy.deepcopy(self.base)
        for c in ov["projects"][0]["cards"]:
            if c["issue"] in (21, 22, 50, 51) and c["issue"] not in keep:
                c.update(column="Ready for Dev" if c["column"] == "Spec Review" else "Ready for Prod", awaiting=False)
        return ov

    def nothing_waits(self):
        return self.waiting_only()

    def without_runs(self, ov):
        ov = copy.deepcopy(ov)
        for c in ov["projects"][0]["cards"]:
            c.update(running=None, lock=None)
        ov["runs"] = []
        ov["projects"][0]["shipped"] = []
        return ov

    # ---- the page
    def routes(self, extra=None):
        out = []
        for n, col in ((22, "Spec Review"), (21, "Spec Review"), (51, "Staged"), (50, "Staged"), (42, "Validation"), (31, "Coding"), (11, "Inbox"), (70, "Done")):
            brief = BRIEF if n == 22 else None
            out.append({"op": "route", "path": "/api/card/shop/%d" % n, "body": payload(n, col, brief=brief, review=n in (22, 51))})
            out.append({"op": "route", "path": "/api/decide/shop/%d" % n, "body": {"spec": None, "block": None, "pr": None, "report": None}})
        return out + (extra or [])

    def page(self, *ops, ov=None, routes=None, **kw):
        """the page read once on ov (default: base), then ops; the snapshots, the first being the read's"""
        setup = self.routes(routes)
        r = bp.run(setup + [{"op": "readw", "overview": ov or self.base}] + list(ops), **kw)
        self.assertEqual(r["errors"], [], "the page threw")
        return r["results"][len(setup):]

    def assert_work(self, snap, what):
        self.assertTrue(snap and snap.get("work"), "%s: there is no #work panel under the belt" % what)


class Area(WorkScene):
    def test_ac1_decide_on_the_oldest_waiting_card(self):
        "AC-1: cards wait for the owner: the work area, below the belt, shows Decide on the oldest: number, column, wait, 1 of N, the next card, title, the brief and a sticky Your decision"
        s = self.page()[0]
        self.assert_work(s, "AC-1")
        name = bp.attr(s["work"], "aria-label")
        self.assertEqual(name, "The work area", "AC-1 the panel is a region labelled 'The work area': %s" % s["work"]["attrs"])
        txt = wtext(s)
        self.assertRegex(txt, r"#22\b", "AC-1 the oldest waiting card is #22")
        self.assertIn("Spec Review", txt)
        self.assertIn("Title 22", txt)
        self.assertRegex(txt, r"waiting 1 h (?:29|30|31) min", "AC-1 how long it has waited")
        self.assertIn("1 of 4 decisions", txt)
        self.assertIn("next: #51", txt, "AC-1 the next card is the next oldest")
        self.assertIn("Adds the work area below the belt.", txt, "AC-1 the brief")
        for b in ("Approve", "Request changes", "Skip for now"):
            self.assertTrue(has_label(s, b, prefix=True), "AC-1 no %s button in %s" % (b, labels(s)))
        sticky = [n for n in nodes(s) if n["css"].get("position") == "sticky" and "Your decision" in bp.text(n) and "Skip for now" in bp.text(n)]
        self.assertTrue(sticky, "AC-1 Your decision (with its buttons) is a sticky panel")
        gone = bp.run([{"op": "readw", "overview": self.base}, {"op": "eval", "expr": '["list","tiles","hy","hw"].filter((i) => document.getElementById(i)).concat(document.querySelector(".yours, .tile") ? ["yours"] : [])'}])
        self.assertEqual(gone["results"][1]["value"], [], "AC-1 the Yours list and the In progress tiles are gone")

    def test_ac1_without_a_brief_the_review_page_is_in_its_place(self):
        "AC-1: selecting a waiting card on the belt decides it; with no brief the sandboxed review page takes the brief's place"
        s = self.page(token(51))[1]
        self.assertEqual(s["S"]["work"]["key"], KEY % 51, "AC-1 a belt token selects the card instead of opening a drawer")
        self.assertIn("Title 51", wtext(s))
        self.assertFalse(s["S"]["open"], "AC-1 no drawer opens")
        self.assertTrue(nodes(s, "iframe"), "AC-1 the review iframe is in the work area when there is no brief")

    def test_ac1_decision_queue_is_the_owner_columns_oldest_first_skipped_last(self):
        "AC-1: decisionQueue(cards, skipped) lists the owner-column cards oldest first and puts the skipped ones last"
        def card(n, col, mins):
            return {"key": KEY % n, "issue": n, "column": col, "since": stamp(mins), "awaiting": col in ("Spec Review", "Staged")}
        cards = [card(1, "Spec Review", 60), card(2, "Coding", 300), card(3, "Spec Review", 120), card(4, "Staged", 90), card(5, "Inbox", 400)]
        r = bp.run([{"op": "readw", "overview": self.base},
                    {"op": "eval", "expr": "decisionQueue(%s, new Set([]))" % json.dumps(cards)},
                    {"op": "eval", "expr": "decisionQueue(%s, new Set([%s]))" % (json.dumps(cards), json.dumps(KEY % 3))}])
        self.assertEqual(r["errors"], [])
        keys = lambda v: [x if isinstance(x, str) else x.get("key") or KEY % x["issue"] for x in v]
        self.assertEqual(keys(r["results"][1]["value"]), [KEY % 3, KEY % 4, KEY % 1], "AC-1 oldest first, the cards the factory holds left out")
        self.assertEqual(keys(r["results"][2]["value"]), [KEY % 4, KEY % 1, KEY % 3], "AC-1 a skipped card goes to the end")

    def test_ac4_calm_when_nothing_waits(self):
        "AC-4: nothing waits and nothing is selected: 'Nothing waits for you' and three columns: next decisions, running now, shipped today"
        ov = self.nothing_waits()
        for n in (21, 22, 50, 51):
            self.assertFalse(self.card_of(ov, n)["awaiting"])
        ov["runs"] = [r for r in ov["runs"] if r["issue"] in (20, 31, 40)]
        s = self.page(ov=ov)[0]
        self.assert_work(s, "AC-4")
        txt = wtext(s)
        self.assertIn("Nothing waits for you", txt)
        for head in ("Next decisions", "Running now", "Shipped today"):
            self.assertIn(head, txt, "AC-4 the column %s" % head)
        rows = labels(s)
        find = lambda rx: next((x for x in rows if re.search(rx, x)), None)
        self.assertTrue(find(r"#31\s*·\s*Develop\s*·\s*step 4 of 7"), "AC-4 a running card reads '#31 · Develop · step 4 of 7': %s" % rows)
        near = [x for x in rows if re.search(r"then (?:Spec Review|Staged)", x)]
        order = [re.search(r"#(\d+)", x).group(1) for x in near]
        self.assertTrue("40" in order and "20" in order and order.index("40") < order.index("20"), "AC-4 the run nearest a gate (#40, 3 steps from Staged) comes before #20 (4 from Spec Review): %s" % near)
        self.assertTrue(find(r"#40\s*·\s*Validate, then Staged"), "AC-4 a next decision reads '#40 · Validate, then Staged': %s" % near)
        self.assertTrue(find(r"#70\s*·\s*PR #64\s*·\s*\S.*\d.*·\s*\$0\.84 est\."), "AC-4 what shipped reads '#70 · PR #64 · time · $0.84 est.': %s" % rows)
        picked = self.page(click(find(r"#31\s*·\s*Develop")), ov=ov)[1]
        self.assertEqual(picked["S"]["work"]["key"], KEY % 31, "AC-4 a row selects its card")
        self.assertIn("Step 4 of 7", wtext(picked), "AC-4 and the work area shows it")

    def test_ac4_empty_columns_say_so(self):
        "AC-4: an empty column says so in one line"
        s = self.page(ov=self.without_runs(self.nothing_waits()))[0]
        txt = wtext(s)
        for line in ("No run is near a gate.", "Nothing runs.", "Nothing shipped today yet."):
            self.assertIn(line, txt)

    def test_ac4_overview_lists_what_shipped_today(self):
        "AC-4: the overview carries, per project, the cards that reached Done today with their PR and cost estimate"
        p = self.overview()["projects"][0]
        self.assertIsInstance(p.get("shipped"), list, "AC-4 the project has no 'shipped' list in the overview")

    def test_ac5_run_mode_for_a_running_card(self):
        "AC-5: a running card selected on the belt: the stage's steps, the last five tool calls, the field to message the run, step, cost estimate, Log and GitHub"
        s = self.page(token(31))[1]
        self.assertEqual(s["S"]["work"]["key"], KEY % 31)
        txt = wtext(s)
        self.assertIn("Step 4 of 7", txt)
        self.assertIn("$0.42 est.", txt)
        self.assertTrue(any(len([c for c in n["kids"] if isinstance(c, dict) and c["tag"] == "li"]) == 7 for n in nodes(s, "ol") + nodes(s, "ul")), "AC-5 the stage's 7 steps are a list")
        for i in (3, 4, 5, 6, 7):
            self.assertIn("src/alpha-%d.py" % i, txt, "AC-5 tool call %d is among the last five" % i)
        for i in (1, 2):
            self.assertNotIn("src/alpha-%d.py" % i, txt, "AC-5 only the last five tool calls")
        self.assertTrue(nodes(s, "textarea") or nodes(s, "input"), "AC-5 a field to message the run")
        for b in ("Log", "GitHub"):
            self.assertTrue(has_label(s, b, prefix=True), "AC-5 no %s link in %s" % (b, labels(s)))
        self.assertFalse(has_label(s, "Approve", prefix=True), "AC-5 a running card is not decided")

    def test_ac5_card_mode_for_any_other_card_and_a_run_that_ends(self):
        "AC-5: any other card: Card mode with its state in words and cost estimate; a run that ends while shown turns into Card mode"
        s = self.page(token(11))[1]
        txt = wtext(s)
        self.assertIn("#11", txt)
        self.assertIn("Title 11", txt)
        self.assertIn("$1.20 est. from Inbox to now", txt, "AC-5 the card's cost estimate")
        self.assertRegex(txt, r"in line|Waiting for|Queued for", "AC-5 its state in words")
        for b in ("Sessions", "Log", "Gates", "GitHub"):
            self.assertTrue(has_label(s, b, prefix=True), "AC-5 no %s link in %s" % (b, labels(s)))
        self.assertFalse(has_label(s, "Approve", prefix=True))
        ended = copy.deepcopy(self.base)
        ended["runs"] = [r for r in ended["runs"] if r["issue"] != 31]
        self.card_of(ended, 31).update(running=None, lock=None)
        a, b = self.page(token(31), {"op": "readw", "overview": ended})[1:]
        self.assertIn("Step 4 of 7", wtext(a))
        self.assertNotIn("Step 4 of 7", wtext(b), "AC-5 the ended run is a Card now")
        self.assertEqual(b["S"]["work"]["key"], KEY % 31, "AC-5 the same card stays selected")
        self.assertIn("Title 31", wtext(b))

    def test_ac6_reduced_motion_swaps_with_no_slide(self):
        "AC-6: prefers-reduced-motion: the work area's swap has no transition or animation of the slide (260/400 ms); without it, it has"
        def slides(snaps):
            hits = [n for s in snaps if s and s.get("work") for n, _ in bp.walk(s["work"]) if REGEX_MS.search(bp.css_of(n, "transition", "transition-duration", "animation", "animation-duration"))]
            moved = [a for s in snaps if s for a in s["anim"] if a["options"].get("duration") in (260, 400)]
            return hits, moved
        plain = self.page(token(21), token(31))
        self.assert_work(plain[0], "AC-6")
        hits, moved = slides(plain)
        self.assertTrue(hits or moved, "AC-6 without the preference the swap slides (260 ms out, 400 ms in)")
        reduced = self.page(token(21), token(31), reduced=True)
        self.assertNotEqual(wtext(reduced[0]), wtext(reduced[2]), "AC-6 the content still swaps")
        hits, moved = slides(reduced)
        self.assertEqual((len(hits), moved), (0, []), "AC-6 under reduced motion the swap is instant: %s" % [(n["tag"], bp.css_of(n, "transition", "animation")) for n in hits][:3])

    def test_ac7_decide_reaches_the_review_sessions_log_gates_and_the_weight(self):
        "AC-7: on a waiting Spec Review card: Full review, Sessions, Log, Gates and GitHub are one click away, and the weight is chosen in the work area"
        s = self.page()[0]
        for b in ("Full review", "Sessions", "Log", "Gates", "GitHub"):
            self.assertTrue(has_label(s, b, prefix=True), "AC-7 no %s link in %s" % (b, labels(s)))
        for link, tab in (("Full review", "review"), ("Sessions", "sessions"), ("Log", "log"), ("Gates", "gates")):
            opened = self.page(click(link, prefix=True))[1]
            self.assertEqual((opened["S"]["open"], opened["S"]["full"], opened["S"]["tab"]), (KEY % 22, True, tab), "AC-7 %s opens the maximized card view on %s" % (link, tab))
        sel = nodes(s, "select")
        self.assertTrue(sel, "AC-7 the weight select is in Your decision on Spec Review")
        self.assertEqual(sorted(bp.squash(bp.text(o)) for o in bp.kids(sel[0])), ["Heavy", "Light", "Standard"])
        picked = self.page({"op": "typex", "within": "work", "sel": "select", "value": "heavy", "change": True})[1]
        self.assertEqual([p["body"] for p in posts(picked, "/api/card/shop/22/weight")], [{"weight": "heavy"}], "AC-7 choosing a weight posts it, as today")
        staged = self.page(token(51))[1]
        self.assertFalse(nodes(staged, "select"), "AC-7 only Spec Review has a weight")

    def test_ac7_message_to_a_run(self):
        "AC-7: a message to a running card is sent from the work area"
        sent = self.page(token(31), {"op": "typex", "sel": "textarea, input", "within": "work", "value": "keep the footer"}, key("Enter"))
        got = posts(sent[-1], "/api/card/shop/31/message")
        if not got:  # the Send button, when Enter is not what sends
            sent = self.page(token(31), {"op": "typex", "sel": "textarea, input", "within": "work", "value": "keep the footer"}, click("Send", prefix=True))
            got = posts(sent[-1], "/api/card/shop/31/message")
        self.assertEqual([p["body"] for p in got], [{"text": "keep the footer"}], "AC-7 the message reaches the run")

    def test_ac7_blocked_card_unblock_and_retry(self):
        "AC-7: a card blocked for the owner shows its block and Unblock & retry in the work area"
        s = self.page(token(42), ov=self.blocked)[1]
        self.assertEqual(s["S"]["work"]["key"], KEY % 42)
        self.assertTrue(has_label(s, "Unblock", prefix=True), "AC-7 no Unblock & retry in %s" % labels(s))
        done = self.page(token(42), click("Unblock", prefix=True), ov=self.blocked)[2]
        self.assertEqual(len(posts(done, "/api/card/shop/42/unblock")), 1, "AC-7 Unblock & retry posts the unblock")
        for b in ("Sessions", "Log", "Gates", "GitHub"):
            self.assertTrue(has_label(s, b, prefix=True), "AC-7 no %s link on a blocked card" % b)


class Keys(WorkScene):
    def test_ac2_n_skips_to_the_next_waiting_card(self):
        "AC-2: N skips to the next waiting card; with one card waiting it does nothing and says 'Only #50 waits.'"
        a, b = self.page(key("n"))
        self.assertIn("Title 22", wtext(a))
        self.assertIn("Title 51", wtext(b), "AC-2 N shows the next waiting card")
        self.assertNotIn("Title 22", wtext(b))
        self.assertEqual(len(b["S"]["work"]["skipped"]), 1, "AC-2 the skip is the page's memory")
        self.assertEqual(b["posts"], [], "AC-2 skipping sends nothing")
        one = self.page(key("n"), ov=self.waiting_only(50))[1]
        self.assertIn("Title 50", wtext(one), "AC-2 the only card stays")
        self.assertIn("Only #50 waits.", ptext(one))

    def test_ac2_a_approves_and_r_opens_request_changes(self):
        "AC-2: A approves (the decision leaves at once); R opens Request changes with the note focused and Send disabled while it is empty"
        a = self.page(key("a"))[1]
        self.assertEqual(len(posts(a, "/api/card/shop/22/approve")), 1)
        r = self.page(key("r"))[1]
        areas = nodes(r, "textarea")
        self.assertTrue(areas, "AC-2 R unfolds the note")
        self.assertEqual((r["active"] or {}).get("tag"), "textarea", "AC-2 the note has the focus")
        send = [n for n in nodes(r, "button") if bp.squash(bp.text(n)) == "Send"]
        self.assertTrue(send and "disabled" in send[0]["attrs"], "AC-2 Send waits for a note")

    def test_ac2_keys_type_text_in_a_field_and_trigger_nothing(self):
        "AC-2: with the focus in a text field or a select the keys A, R and N type and trigger nothing"
        w = self.page(key("r"), key("a"), key("n"), key("r"), {"op": "advancew", "ms": 6000})
        last = w[-1]
        self.assertEqual(last["posts"], [], "AC-2 nothing was sent")
        self.assertNotIn("Approving", ptext(last))
        self.assertIn("Title 22", wtext(last), "AC-2 the card is still #22")
        self.assertTrue(nodes(last, "textarea"), "AC-2 the note is still open")
        sel = self.page({"op": "focusx", "within": "work", "sel": "select"}, key("a"), key("n"), {"op": "advancew", "ms": 6000})
        self.assertTrue(sel[1]["hit"], "AC-2 a select to focus")
        self.assertEqual(sel[-1]["posts"], [])
        self.assertIn("Title 22", wtext(sel[-1]))
        self.assertNotIn("Approving", ptext(sel[-1]))

    def test_ac2_enter_sends_the_note_and_shift_enter_is_a_new_line(self):
        "AC-2: in the note Enter sends (not while it is empty), Shift+Enter makes a new line"
        w = self.page(key("r"), key("Enter"), {"op": "typex", "value": "fix the header"}, key("Enter", shift=True), key("Enter"))
        self.assertEqual(posts(w[2], "/api/card/shop/22/request-changes"), [], "AC-2 an empty note sends nothing")
        self.assertEqual(posts(w[4], "/api/card/shop/22/request-changes"), [], "AC-2 Shift+Enter is a new line")
        self.assertEqual(len(posts(w[5], "/api/card/shop/22/request-changes")), 1, "AC-2 Enter sends the note")

    def test_ac2_esc_folds_then_closes_the_view_then_clears_the_selection(self):
        "AC-2: Esc, in order: the note (kept for the card), the maximized view, the selection; the selected token clicked again clears it too"
        w = self.page(key("r"), {"op": "typex", "value": "keep me"}, key("Escape"), key("r"))
        self.assertFalse(nodes(w[3], "textarea"), "AC-2 Esc folds Request changes")
        self.assertEqual((w[4]["active"] or {}).get("value"), "keep me", "AC-2 the typed note is kept for the card")
        s = self.page(token(21), click("Sessions", prefix=True), key("a"), key("Escape"), key("Escape"))
        self.assertEqual(s[1]["S"]["work"]["key"], KEY % 21)
        self.assertTrue(s[2]["S"]["full"], "AC-2 Sessions opens the maximized view")
        self.assertEqual(s[3]["posts"], [], "AC-2 with the view open A decides nothing")
        self.assertNotIn("Approving", ptext(s[3]))
        self.assertEqual((s[4]["S"]["open"], s[4]["S"]["work"]["key"]), (None, KEY % 21), "AC-2 the first Esc closes the view and keeps the selection")
        self.assertIsNone(s[5]["S"]["work"]["key"], "AC-2 the next Esc clears the selection")
        self.assertIn("Title 22", wtext(s[5]), "AC-2 and Decide goes back to the oldest")
        c = self.page(token(21), token(21))
        self.assertEqual(c[1]["S"]["work"]["key"], KEY % 21)
        self.assertIsNone(c[2]["S"]["work"]["key"], "AC-2 a second click on the selected token clears it")

    def test_ac2_the_keys_act_only_in_decide(self):
        "AC-2: A, R and N do nothing on a running card or a calm board"
        run = self.page(token(31), key("a"), key("r"), key("n"), {"op": "advancew", "ms": 6000})
        self.assertEqual(run[-1]["posts"], [])
        self.assertEqual(run[-1]["S"]["work"]["key"], KEY % 31)
        self.assertNotIn("Approving", ptext(run[-1]))
        self.assertFalse(has_label(run[-1], "Request changes"), "AC-2 R did not open Request changes on a run")
        calm = self.page(key("a"), key("n"), ov=self.nothing_waits())
        self.assertIn("Nothing waits for you", wtext(calm[-1]))
        self.assertEqual(calm[-1]["posts"], [])

    def test_ac2_the_footer_names_the_keys(self):
        "AC-2: the footer reads 'A approve · R request changes · N skip'"
        r = bp.run([{"op": "readw", "overview": self.base}, {"op": "find", "needle": "A approve · R request changes · N skip"}])
        self.assertTrue(r["results"][1], "AC-2 no element reads the keys footer")


class Quick(WorkScene):
    def hold(self, *ops, routes=None, ov=None):
        return self.page(key("a"), *ops, routes=routes, ov=ov)

    def after(self, *moved):
        """base once these cards have moved on"""
        ov = copy.deepcopy(self.base)
        for n in moved:
            c = self.card_of(ov, n)
            c.update(column={"Spec Review": "Ready for Dev", "Staged": "Ready for Prod"}[c["column"]], awaiting=False, since=stamp(0))
        return ov

    def test_ac3_approve_is_sent_at_once_and_the_next_card_slides_in(self):
        "AC-3: Approve sends the decision at once, with no hold and no Undo; the next waiting card comes in with the focus on its title"
        h = self.hold({"op": "readw", "overview": self.after(22)}, {"op": "find", "needle": "#51 waits for you"})
        started, next_card, status = h[1:]
        self.assertEqual([(p["body"]["column"], p["keepalive"]) for p in posts(started, "/api/card/shop/22/approve")], [("Spec Review", False)], "AC-3 sent on the click")
        self.assertFalse(has_label(started, "Undo"), "AC-3 there is no Undo")
        self.assertIn("Title 51", wtext(next_card), "AC-3 the next waiting card slides in")
        self.assertNotIn("Title 22", wtext(next_card))
        self.assertTrue((next_card["active"] or {}).get("inWork") and "Title 51" in next_card["active"]["text"], "AC-3 focus moves to its title: %s" % next_card["active"])
        self.assertTrue(status and any(c["attrs"].get("role") == "status" or c["attrs"].get("aria-live") == "polite" for c in status[0]["chain"]), "AC-3 a polite status announces '#51 waits for you, i of k'")

    def test_ac3_nothing_is_held_and_nothing_is_sent_twice(self):
        "AC-3: time passing sends nothing more: the decision left once, and no timer of the page holds a move"
        h = self.hold({"op": "advancew", "ms": 6000})
        self.assertEqual(len(posts(h[-1], "/api/card/shop/22/approve")), 1)
        self.assertEqual(h[-1]["posts"], h[1]["posts"])

    def test_ac3_unreviewed_items_ask_twice(self):
        "AC-3: with unreviewed items the first A arms Approve in place and sends nothing; the second sends; the arming lapses after 4 s"
        arm = {"op": "eval", "expr": 'S.review["shop/22"] = {total: 3, done: 1, changes: []}, 1'}
        h = self.page(arm, key("a"), {"op": "advancew", "ms": 5000})
        first, later = h[2], h[3]
        self.assertTrue(has_label(first, "Approve with 2 not reviewed", prefix=True), "AC-3 Approve is armed in place: %s" % labels(first))
        self.assertIn("Approve with 2 not reviewed", (first["active"] or {}).get("text", ""), "AC-3 the focus is on it")
        self.assertEqual(first["posts"], [])
        self.assertTrue(has_label(later, "Approve", prefix=True) and not has_label(later, "Approve with", prefix=True), "AC-3 the arming lapses after 4 s: %s" % labels(later))
        self.assertEqual(later["posts"], [])
        twice = self.page(arm, key("a"), key("a"), {"op": "advancew", "ms": 5000})
        self.assertEqual(posts(twice[2], "/api/card/shop/22/approve"), [], "AC-3 the first press only arms")
        self.assertEqual(len(posts(twice[3], "/api/card/shop/22/approve")), 1, "AC-3 the second press confirms and sends")
        self.assertEqual(len(posts(twice[4], "/api/card/shop/22/approve")), 1)

    def test_ac3_request_changes_is_sent_at_once(self):
        "AC-3: Request changes sends the note and moves the card back as soon as Send is clicked"
        h = self.page(key("r"), {"op": "typex", "value": "fix the header"}, click("Send"))
        self.assertFalse(has_label(h[3], "Undo"))
        self.assertEqual([p["body"] for p in posts(h[3], "/api/card/shop/22/request-changes")],
                         [{"column": "Spec Review", "text": "fix the header", "move_only": False}], "AC-3 the note and the column, as today")

    def test_ac3_a_failed_send_brings_the_card_back(self):
        "AC-3: a send that fails brings the card back as current with '#22 was not approved: <reason>'"
        h = self.page({"op": "route", "post": {"status": 409, "body": {"error": "the card moved"}}}, key("a"), {"op": "advancew", "ms": 100})
        self.assertIn("#22 was not approved: the card moved", ptext(h[-1]))
        self.assertIn("Title 22", wtext(h[-1]))

    def test_ac3_after_the_last_decision_calm_appears(self):
        "AC-3: after the last waiting card is decided the Calm mode appears"
        only = self.waiting_only(50)
        h = self.page(key("a"), {"op": "advancew", "ms": 100}, {"op": "readw", "overview": self.nothing_waits()}, ov=only)
        self.assertEqual(len(posts(h[2], "/api/card/shop/50/approve")), 1)
        self.assertIn("Nothing waits for you", wtext(h[3]))


class Design(support.Case):
    def test_ac8_design_doc_has_the_work_area(self):
        "AC-8: DESIGN.md has a section The Work Area in place of Your, In Progress, Tooltip Drawer and How a Card Opens"
        d = v4.doc()
        heads = re.findall(r"^#{2,3}[ \t]*(.+?)[ \t]*$", d.design, flags=re.M)
        self.assertIn("The Work Area", heads)
        for old in ("Your", "In Progress", "Tooltip Drawer", "How a Card Opens"):
            self.assertNotIn(old, heads, "AC-8 DESIGN.md still has a section %s" % old)
        section = d.section("The Work Area", 3) or d.section("The Work Area", 2)
        for word in ("Decide", "Run", "Card", "Calm"):
            self.assertRegex(section, r"\b%s\b" % word, "AC-8 The Work Area never names the %s mode" % word)
        self.assertRegex(section, r"reduced motion|prefers-reduced-motion", "AC-8 The Work Area never says how it moves under reduced motion")
        keys = d.section("Keyboard and Live Updates", 3) or d.section("Keyboard and Live Updates", 2)
        self.assertRegex(keys, r"\bN\b[^\n]*skip|skip[^\n]*\bN\b", "AC-8 Keyboard says N skips")
        self.assertNotRegex(keys, r"\bYours\b|Your list", "AC-8 Keyboard still names the Your list")
