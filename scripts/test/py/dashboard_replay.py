"""The day in replay (#184), on the page: the scrubber under the belt with its sourced marks (AC-3), the needle that shows the
belt as it was and turns every decide control off (AC-4, AC-5, AC-6), the motion (AC-7) and the Logbook that absorbs History
(AC-8). The page's own script runs in node on belt_page.py's fake DOM, fed an overview of the shop project and, at
/api/day/shop, the day the server would answer (dashboard_day.py is the server side). The needle is driven the way the
design says an owner can: the slider's keys (Home = today's first history line, Left/Right = 5 minutes, PageUp/PageDown =
an hour, End = live) and the Back to live button; the clock of the page is fixed at 14:00.

Marks, the slider (role=slider, label "Time shown", aria-valuetext "Now" or "09:40"), the status sentence and the decide
controls are found by what the design names them, not by an id or a class."""
import json
import os
import re
from datetime import datetime

import belt_page as bp
import dashboard_belt as db
import dashboard_work as dw
import support

CLOCK = datetime.now().astimezone().replace(hour=14, minute=0, second=0, microsecond=0)
NOW_MS = int(CLOCK.timestamp() * 1000)
SLIDER = '[role="slider"]'
DENIED = "Back to live to decide."
SEP = "·"
DOCS = os.path.join(os.path.dirname(support.SCRIPTS), "docs")


def hm(h, m=0):
    return CLOCK.replace(hour=h, minute=m).isoformat(timespec="seconds")


# the board at three moments of the day: card 12 appears at 09:30, card 40 reaches the Staged gate at 10:15
EARLY = {"11": "Inbox", "21": "Spec Review", "40": "Validation", "70": "Done"}
MID = dict(EARLY, **{"12": "Inbox"})
LATE = dict(MID, **{"40": "Staged", "71": "Done"})
LINES = [{"t": hm(8), "cards": EARLY}, {"t": hm(9, 30), "cards": MID}, {"t": hm(10, 15), "cards": LATE}]


def day(lines=LINES, marks=()):
    return {"date": CLOCK.date().isoformat(), "now": hm(14), "board": list(lines), "marks": list(marks)}


def press(key, times=1):
    return [{"op": "keysel", "sel": SLIDER, "key": key}] * times


# from "now": Home is today's first line (08:00), PageUp an hour, ArrowRight five minutes
TO_0940 = press("Home") + press("PageUp") + press("ArrowRight", 8)
TO_1010 = press("Home") + press("PageUp", 2) + press("ArrowRight", 2)


class Replay(db.Scene):
    def page(self, ops, shown=None, **kw):
        """(the live belt, the results of ops): the overview read, the day made available, then ops"""
        pre = self.card_routes() + [{"op": "day", "day": day() if shown is None else (None if shown is False else shown)},
                                    {"op": "read", "overview": self.ov}, {"op": "settle"}]
        r = bp.run(pre + list(ops), now=NOW_MS, **kw)
        self.assertEqual(r["errors"], [], "the page threw")
        return r["results"][len(pre) - 1], r["results"][len(pre):]

    def card_routes(self):
        """what the work area reads of the card it decides (the oldest that waits, #22): its page, and what blocks it (nothing)"""
        return [{"op": "route", "path": "/api/card/shop/22", "body": dw.payload(22, "Spec Review", brief=dw.BRIEF, review=False)},
                {"op": "route", "path": "/api/decide/shop/22", "body": {"spec": None, "block": None, "pr": None, "report": None}}]

    def slider(self, found):
        self.assertTrue(found, "no role=slider")
        return found[0]["attrs"]

    def posts(self, fetches, needle="/api/card/"):
        return [f for f in fetches if f["method"] == "POST" and needle in f["path"]]

    # ---------------------------------------------------------------------------------------------------------- AC-3
    def test_ac3_marks_on_the_line_are_titled_ticks_and_diamonds(self):
        "AC-3 the line under the belt has an ok tick per finished run, a taller bad tick per block and an accent diamond per decision, each titled; hours in mono, the future hatched"
        marks = [{"t": hm(9), "kind": "ok", "n": 40, "stage": "validate", "what": "ended"},
                 {"t": hm(9, 30), "kind": "bad", "n": 41, "stage": "validate", "what": "blocked"},
                 {"t": hm(13, 5), "kind": "decision", "n": 121, "what": "approved-pr"}]
        ok, bad, you = ("09:00 %s #40 Validate ended" % SEP, "09:30 %s #41 Validate blocked" % SEP, "13:05 %s #121 you approved the PR" % SEP)
        _, res = self.page([{"op": "advance_settle", "ms": 6000}, {"op": "advance_settle", "ms": 6000}, {"op": "query", "sel": "[title]"},
                            {"op": "query", "sel": "*"}, {"op": "find", "needle": ok}, {"op": "find", "needle": you}],
                           shown=day(marks=marks), intervals=True)
        titled = {e["attrs"]["title"]: e for e in res[2]}
        for title in (ok, bad, you):
            self.assertIn(title, titled, "no mark titled %r among %s" % (title, sorted(titled)))
            self.assertNotIn(titled[title]["tag"], ("button", "a", "input"), "a mark is not focusable")
            self.assertIn(titled[title]["attrs"].get("tabindex"), (None, "-1"))
        self.assertTrue(res[4] and res[5], "each mark carries an off-screen label with its words")

        def css(title, *props):
            return " ".join(titled[title]["css"].get(p, "") for p in props)

        def size(title, prop, px):
            return any(css(title, p).strip() == px for p in (prop, "min-" + prop, "max-" + prop, "inline-size" if prop == "width" else "block-size"))
        self.assertTrue(size(ok, "width", "2px") and size(ok, "height", "10px"), "ok tick 2px x 10px: %s" % titled[ok]["css"])
        self.assertTrue(size(bad, "width", "2px") and size(bad, "height", "18px"), "bad tick 2px x 18px: %s" % titled[bad]["css"])
        self.assertRegex(css(ok, "background", "background-color", "border-color"), r"var\(--ok\)")
        self.assertRegex(css(bad, "background", "background-color", "border-color"), r"var\(--bad\)")
        self.assertTrue(size(you, "width", "8px") and size(you, "height", "8px"), "diamond 8px: %s" % titled[you]["css"])
        self.assertRegex(css(you, "background", "background-color", "border-color"), db.ACCENT)
        self.assertRegex(css(you, "transform", "rotate"), r"45deg|rotate")
        self.assertNotRegex(css(you, "border-radius"), r"[1-9]")
        everything = res[3]
        hatched = [e for e in everything if "repeating-linear-gradient(45deg" in e["css"].get("background-image", e["css"].get("background", ""))
                   and "--track" in e["css"].get("background-image", e["css"].get("background", ""))]
        self.assertTrue(hatched, "the time after now is hatched: 45 degree --track stripes")
        for hour in ("00:00", "03:00", "06:00", "09:00", "12:00", "15:00", "18:00", "21:00"):
            labels = [e for e in everything if e["text"] == hour]
            self.assertTrue(labels, "no hour label %s" % hour)
            self.assertRegex(labels[0]["css"].get("font-family", ""), r"(?i)mono", "hour labels are mono")

    # ---------------------------------------------------------------------------------------------------------- AC-4
    def test_ac4_the_needle_at_0940_shows_the_belt_as_it_was(self):
        "AC-4 with the needle at 09:40 the belt shows the cards in the columns of the last line at or before it, says so, and does not advance"
        n = len(TO_0940)
        live, res = self.page(TO_0940 + [{"op": "query", "sel": SLIDER}, {"op": "hash"}, {"op": "find", "needle": "Replay at 09:40. The belt is as it was."},
                                       {"op": "find", "needle": "Back to live"}, {"op": "read", "overview": self.moved(40, "Staged")}, {"op": "settle"}])
        snap, attrs = res[n - 1], self.slider(res[n])
        self.assertEqual((attrs.get("aria-label"), attrs.get("aria-valuetext")), ("Time shown", "09:40"))
        self.assertEqual(res[n + 1], "#@0940", "the time is in the address")
        said = res[n + 2]
        self.assertTrue(said and db.in_status_header(said[0]), "the status sentence reads 'Replay at 09:40. The belt is as it was.' in the header's status")
        self.assertTrue([h for h in res[n + 3] if h["tag"] == "button"], "a Back to live button")
        for k in (snap, res[n + 5]):  # the last line at or before 09:40 is the 09:30 one, and a card that moved since changes nothing
            db.only_one(self, k, ["shop/%s" % c for c in MID], "AC-4")
            for c, col in MID.items():
                parts = bp.segment_of(k, "shop/" + c)
                self.assertTrue(parts and parts[0] in dict(db.BOARD)[col], "#%s is in %s: %s" % (c, col, parts))
        for tok in bp.tokens(snap):
            self.assertTrue(bp.attr(tok, "aria-label", "").endswith(", as at 09:40"), bp.attr(tok, "aria-label"))
        self.assertEqual([m for m in (db.meta_of(snap, "Inbox"), db.meta_of(snap, "Validation"), db.meta_of(snap, "Spec Review"))], ["2", "1", "1"],
                         "segment meta is the count only")
        self.assertEqual([n_ for n_, _ in bp.walk(snap["cells"]) if bp.squash(bp.text(n_)) == "free"], [], "no free ghosts in the past")
        self.assertEqual(bp.look(bp.token(snap, "shop/21")), bp.look(bp.token(live, "shop/21")), "a gate token in the waiting look")
        self.assertEqual(bp.look(bp.token(snap, "shop/70")), bp.look(bp.token(live, "shop/70")), "a Done token in the done look")
        self.assertEqual(bp.look(bp.token(snap, "shop/40")), bp.look(bp.token(live, "shop/11")), "all others in the queued look")
        self.assertIn("paused", db.anim_css(db.rail_of(snap)), "the rail is paused")

    def test_ac4_every_decide_control_is_off_while_replaying(self):
        "AC-4 in replay the work area's Approve, the maximize that opens moves and the key A are aria-disabled, titled and send nothing"
        _, res = self.page([{"op": "keyx", "key": "a"}, {"op": "advance_settle", "ms": 6000}, {"op": "fetches"}]
                           + TO_0940
                           + [{"op": "query", "sel": '[data-w="approve"], #band > button[data-max]'},
                              {"op": "keyx", "key": "a"},
                              {"op": "clicksel", "sel": '[data-w="approve"]'},
                              {"op": "clicksel", "sel": "#band > button[data-max]"},
                              {"op": "advance_settle", "ms": 6000}, {"op": "fetches"}, {"op": "eval", "code": "return !!(W.hold || W.flight)"}])
        self.assertTrue(self.posts(res[2], "/api/card/shop/22/approve"), "live, key A approves the card in the work area after its moment (control)")
        n = 3 + len(TO_0940)
        controls = res[n]
        self.assertTrue([c for c in controls if c["attrs"].get("data-w") == "approve"], "the work area has its Approve button")
        self.assertTrue([c for c in controls if c["attrs"].get("data-max") is not None], "the belt panel has its maximize button")
        for c in controls:
            self.assertEqual(c["attrs"].get("aria-disabled"), "true", c["attrs"])
            self.assertEqual(c["attrs"].get("title"), DENIED)
            self.assertNotIn("disabled", c["attrs"], "still focusable")
        self.assertEqual(self.posts(res[n + 5]), [], "no decision leaves while replaying")
        self.assertFalse(res[n + 6], "nothing is waiting to be sent")
        self.assertFalse(res[n + 3]["S"]["full"], "the maximize did not open the moves")

    # ---------------------------------------------------------------------------------------------------------- AC-5
    def test_ac5_before_the_first_line_there_is_no_history_for_that_hour(self):
        "AC-5 (UI review m9) before today's first line there is nothing to replay: the lane is hatched up to 08:00 and the needle stops there"
        _, res = self.page(press("Home") + press("ArrowLeft") + [{"op": "query", "sel": SLIDER}, {"op": "query", "sel": "#pre"},
                           {"op": "find", "needle": "No history for 07:55."}])
        n = 2
        self.assertEqual(self.slider(res[n])["aria-valuetext"], "08:00", "the needle stops at the first record")
        self.assertTrue(bp.tokens(res[n - 1]), "the belt shows the first record's cards")
        pre = res[n + 1]
        self.assertEqual(len(pre), 1, "one hatch before the first record")
        self.assertNotIn("hidden", pre[0]["attrs"])
        self.assertEqual(pre[0]["css"].get("width"), "33.33%", "08:00 is a third of the day")
        self.assertFalse(res[n + 2], "no 'No history' sentence: the needle never stands before the first record")

    def test_ac5_with_no_history_today_the_belt_says_so(self):
        "AC-5 with no line at all today the belt says there is no board history for today yet"
        _, res = self.page(press("ArrowLeft") + [{"op": "find", "needle": "No board history for today yet."}], shown=day(lines=[]))
        self.assertEqual(bp.tokens(res[0]), [])
        self.assertTrue(res[1])

    # ---------------------------------------------------------------------------------------------------------- AC-6
    def test_ac6_back_to_live_returns_to_the_snapshot_and_decides_again(self):
        "AC-6 Back to live shows the current snapshot, moves the needle to now, clears the address, re-enables decide and focuses the needle"
        _, res = self.page(TO_0940 + [{"op": "clicktext", "text": "Back to live"}, {"op": "query", "sel": SLIDER}, {"op": "hash"},
                                      {"op": "find", "needle": db.SENTENCE % ("5 decisions wait for you · ", 3)},
                                      {"op": "query", "sel": '[data-w="approve"], #band > button[data-max]'}, {"op": "active"},
                                      {"op": "keyx", "key": "a"}, {"op": "advance_settle", "ms": 6000}, {"op": "fetches"}])
        n = len(TO_0940)
        db.only_one(self, res[n], [db.KEY % c for c, _ in db.CARDS], "AC-6")
        self.assertEqual(self.slider(res[n + 1])["aria-valuetext"], "Now")
        self.assertFalse(str(res[n + 2]).startswith("#@"), "the address is live again: %r" % res[n + 2])
        self.assertTrue(res[n + 3], "the status sentence is the live one")
        for c in res[n + 4]:
            self.assertNotEqual(c["attrs"].get("aria-disabled"), "true", c["attrs"])
            self.assertNotEqual(c["attrs"].get("title"), DENIED)
        self.assertEqual((res[n + 5] or {}).get("attrs", {}).get("role"), "slider", "focus goes to the playhead")
        self.assertTrue(self.posts(res[n + 8], "/api/card/shop/22/approve"), "decide works again")

    # ---------------------------------------------------------------------------------------------------------- AC-7
    def test_ac7_cards_travel_when_the_needle_steps_unless_motion_is_reduced(self):
        "AC-7 stepping the needle across 10:15 moves card 40 to the gate with a travel; with reduced motion it swaps with no animation"
        ops = TO_1010 + press("ArrowRight")
        n = len(ops)
        _, moving = self.page(ops)
        before, after = moving[n - 2], moving[n - 1]
        self.assertIn((bp.segment_of(before, "shop/40") or [None])[0], dict(db.BOARD)["Validation"], "at 10:10 card 40 still validates")
        self.assertIn((bp.segment_of(after, "shop/40") or [None])[0], dict(db.BOARD)["Staged"], "at 10:15 card 40 is at the Staged gate")
        self.assertTrue(db.travelled(after, "shop/40"), "the card travels: anim=%s styles=%s" % (after["anim"], after["styles"][:3]))
        _, still = self.page(ops, reduced=True)
        after = still[n - 1]
        self.assertIn((bp.segment_of(after, "shop/40") or [None])[0], dict(db.BOARD)["Staged"], "reduced: the card is where it was at 10:15")
        self.assertEqual(after["anim"], [], "reduced motion: nothing animates")
        self.assertFalse(db.travelled(after, "shop/40"), "reduced motion: the card swaps, it does not travel")

    # ---------------------------------------------------------------------------------------------------------- AC-8
    def test_ac8_the_feed_is_the_logbook_and_history_lives_in_it(self):
        "AC-8 the nav says Logbook, History is no separate view but the Totals panel at the top of the Logbook, not in the Factory view"
        r = bp.run([{"op": "query", "sel": "nav.views [data-view]"}, {"op": "query", "sel": "#feed"}, {"op": "query", "sel": "#ht"},
                    {"op": "eval", "code": "const h = document.getElementById('history'); return h && {feed: !!h.closest('#feed'), cols: !!h.closest('#cols')}"}])
        views, feed, heading, where = r["results"]
        names = [v["text"] for v in views]
        self.assertIn("Logbook", names)
        self.assertNotIn("Feed", names)
        self.assertNotIn("History", names)
        self.assertEqual([v["attrs"]["data-view"] for v in views].count("history"), 0)
        self.assertEqual(feed and feed[0]["attrs"].get("aria-label"), "Logbook")
        self.assertTrue(heading and heading[0]["text"].startswith("Totals"), "the History panel's heading is Totals + the period: %s" % heading)
        self.assertEqual(where, {"feed": True, "cols": False}, "#history is in the Logbook and no longer in the Factory view")

    def test_ac8_the_copy_is_in_the_catalogs(self):
        "AC-8 the Logbook and replay copy is in the English and the Portuguese catalogs"
        copy = {"en": ["Logbook", "Totals", "Time shown", "Now", "Back to live", DENIED, "Reading the board history…", "No board history for today yet.",
                       "Could not read the board history.", "Validate ended", "Validate blocked", "you approved the PR", "you approved the spec", "you requested changes"],
                "pt-BR": ["Diário", "Totais", "Hora mostrada", "Agora", "Voltar ao vivo", "Volte ao vivo para decidir.", "Lendo o histórico do board…",
                          "Ainda não há histórico do board hoje.", "Não foi possível ler o histórico do board.", "Validate terminou",
                          "Validate bloqueou", "você aprovou o PR", "você aprovou a spec", "você pediu mudanças"]}
        for code, texts in copy.items():
            with open(os.path.join(support.SCRIPTS, "lang", "dashboard.%s.json" % code), encoding="utf-8") as f:
                have = set(json.load(f)["messages"].values())
            self.assertEqual([t for t in texts if t not in have], [], code)

    def test_ac8_the_docs_say_what_was_added(self):
        "AC-8 contracts.md documents the board history file and /api/day; operation.md explains the scrubber and replay"
        with open(os.path.join(DOCS, "contracts.md"), encoding="utf-8") as f:
            contracts = f.read()
        with open(os.path.join(DOCS, "operation.md"), encoding="utf-8") as f:
            operation = f.read()
        self.assertRegex(contracts, r"board-<YYYY-MM>\.jsonl")
        self.assertIn("/api/day", contracts)
        self.assertRegex(contracts, r'"cards"')
        self.assertRegex(operation, r"(?i)replay")
        self.assertRegex(operation, r"(?i)back to live")

    def test_a_time_hash_still_moves_the_replay_from_the_address(self):
        "#183 fromAddress keeps its `else if` (time hash moves the needle) as code, not inside a // comment"
        with open(os.path.join(support.SCRIPTS, "dashboard.html"), encoding="utf-8") as f:
            lines = [l for l in f.read().splitlines() if "if (m == null) { if (R.at" in l]
        self.assertEqual(len(lines), 1)
        self.assertNotIn("//", lines[0])
        self.assertIn("else if (!R.at || atMin() !== m) needle(m, \"key\", true);", lines[0])
