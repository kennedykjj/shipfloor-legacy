"""The belt (#181): the lifecycle band becomes a line of tokens, one per card, in the segment of its board column, that moves
only while the dispatcher is alive. The page's own script runs in node on a fake DOM (belt_page.py), is fed overviews from
the real dashboard server over fake-gh and over the demo's gh stand-in, and the tests read what it drew, how the page's CSS
styles it, what it animated and where it put the focus. BeltRender is AC-1, AC-2, AC-5 and AC-6; BeltMotion is AC-3, AC-4
and AC-7 (dashboard-belt.test.sh and dashboard-belt-motion.test.sh)."""
import copy
import os
import re
import shutil
import stat
import sys
import time
from datetime import datetime, timedelta

import belt_page as bp
import dashboard_support as ds

NOW = datetime.now().astimezone().replace(microsecond=0)
MIDNIGHT = NOW.replace(hour=0, minute=0, second=0)
KEY = "shop/%d"

# the board's columns in order, each with the names its segment may carry: a stage column is named by its stage
BOARD = [("Inbox", ("Inbox",)), ("Ready for Refinement", ("Ready for Refinement",)), ("Technical Refinement", ("Refine", "Technical Refinement")),
         ("Spec Review", ("Spec Review",)), ("Ready for Dev", ("Ready for Dev",)), ("Coding", ("Develop", "Coding")),
         ("Validation", ("Validate", "Validation")), ("Staged", ("Staged",)), ("Ready for Prod", ("Deploy", "Ready for Prod")), ("Done", ("Done",))]
GATES = ("Spec Review", "Staged")
# the cards: Inbox 11-13 (queued), 14 queued, 20 refining, 21-22 and 50-51 wait at the gates, 30 queued, 31 develops (step 4 of 7),
# 40 validates (step 2 of 5), 41 is blocked by infrastructure, 42 is blocked for the owner, 60 queued to deploy, 70-71 done today
CARDS = ((11, "Inbox"), (12, "Inbox"), (13, "Inbox"), (14, "Ready for Refinement"), (20, "Technical Refinement"), (21, "Spec Review"),
         (22, "Spec Review"), (30, "Ready for Dev"), (31, "Coding"), (40, "Validation"), (41, "Validation"), (42, "Validation"),
         (50, "Staged"), (51, "Staged"), (60, "Ready for Prod"), (70, "Done"), (71, "Done"))
META = {"Inbox": "3", "Ready for Refinement": "1", "Technical Refinement": "1 of 1", "Spec Review": "2 for you", "Ready for Dev": "1",
        "Coding": "1 of 2", "Validation": "1 of 1", "Staged": "2 for you", "Ready for Prod": "0 of 1", "Done": "2 today"}
NAMES = {50: "#50 Title 50, Staged, waits for you", 31: "#31 Title 31, Develop, running, step 4 of 7", 11: "#11 Title 11, Inbox, queued",
         41: "#41 Title 41, Validate, blocked by infrastructure", 42: "#42 Title 42, Validate, blocked", 70: "#70 Title 70, Done, done today",
         20: "#20 Title 20, Refine, running, step 3 of 7", 40: "#40 Title 40, Validate, running, step 2 of 5"}
SENTENCE = "Running · %s%d of 6 sessions · $1.36 today"
ACCENT = r"accent|--sand"  # the accent token is --sand, and its tints --accent-soft / --accent-line


def ago(minutes):
    return (NOW - timedelta(minutes=minutes)).isoformat(timespec="seconds")


def today_ago(minutes):
    """a moment of today, however early the test runs"""
    return max(NOW - timedelta(minutes=minutes), MIDNIGHT).isoformat(timespec="seconds")


class Scene(ds.Dash):
    """The shop project on fake-gh with the cards above; self.ov is the server's overview of it, as the page reads it"""

    def setUp(self):
        super().setUp()
        self.config("pool: 6\nstages:\n  refine: 1\n  develop: 2\n  validate: 1\n  deploy: 1\n")
        self.board(list(CARDS))
        self.gh("titles.tsv", "".join("%d\tTitle %d\n" % (n, n) for n, _ in CARDS))
        self.gh("label-blocked", '[{"number": 42}]')
        self.gh("label-blocked-infra", '[{"number": 41}]')
        for name, n, step in (("refine-20", 20, 3), ("develop-31", 31, 4), ("validate-40", 40, 2)):
            d = self.lock(name, n)
            self.write(os.path.relpath(os.path.join(d, "step"), self.tmp), "%d\t%d\n" % (step, time.time()))
        self.fresh()
        self.ov = self.overview()
        p = self.ov["projects"][0]
        for c in p["cards"]:  # how long each card has been where it is: Inbox 13 the longest, 11 the shortest
            c["since"] = ago({11: 60, 12: 120, 13: 180, 21: 30, 22: 90, 50: 20, 51: 80}.get(c["issue"], 45))
            if c["column"] == "Done":  # deployed clean today: the server's done_at (#B2)
                c["since"] = c["done_at"] = today_ago({70: 5, 71: 10}[c["issue"]])
        p["done_today"] = 2
        self.ov["today"]["cost"] = 1.36

    def card(self, ov, n):
        return next(c for c in ov["projects"][0]["cards"] if c["issue"] == n)

    def only(self, *cols):
        """the overview without the cards of these columns"""
        ov = copy.deepcopy(self.ov)
        p = ov["projects"][0]
        p["cards"] = [c for c in p["cards"] if c["column"] not in cols]
        p["done_today"] = sum(1 for c in p["cards"] if c["column"] == "Done")
        return ov

    def moved(self, n, column, **fields):
        """the overview after card n moved to column (and stopped running)"""
        ov = copy.deepcopy(self.ov)
        c = self.card(ov, n)
        was = c["running"]
        c.update(column=column, running=None, lock=None, awaiting=column in ("Spec Review", "Staged"), since=today_ago(0), **fields)
        if was:
            ov["runs"] = [r for r in ov["runs"] if r["issue"] != n]
            ov["pool"]["used"] -= 1
            ov["pool"]["stages"][was]["running"] -= 1
        return ov


def keys_of(snap):
    return [bp.attr(n, "data-key") for n in bp.tokens(snap)]


def segment_names(snap):
    """for each board column, the index of the segment that carries it (None when there is none)"""
    segs, out = bp.segments(snap), {}
    for col, alts in BOARD:
        out[col] = next((i for i, (parts, _) in enumerate(segs) if parts and parts[0] in alts), None)
    return segs, out


def meta_of(snap, col):
    segs, idx = segment_names(snap)
    parts = segs[idx[col]][0] if idx[col] is not None else []
    return parts[1] if len(parts) > 1 else None


def only_one(case, snap, keys, what):
    got = keys_of(snap)
    case.assertEqual(sorted(got), sorted(keys), "%s: the belt's tokens (by data-key) are not the board's cards, once each: %s" % (what, got))


def check_columns(case, snap, columns, what):
    """every token sits in the segment of its card's column and the segments come in board order"""
    segs, idx = segment_names(snap)
    case.assertTrue(all(i is not None for i in idx.values()), "%s: a board column has no segment; the segments are %s" % (what, [p for p, _ in segs]))
    order = [idx[c] for c, _ in BOARD]
    case.assertEqual(order, sorted(order), "%s: the segments are not in board order: %s" % (what, [p for p, _ in segs]))
    for n, col in columns.items():
        parts = bp.segment_of(snap, KEY % n)
        case.assertTrue(parts and parts[0] in dict(BOARD)[col], "%s: card #%d (%s) is in the segment %s" % (what, n, col, parts))


def rail_of(snap):
    """the rail: an element of the belt whose class says so"""
    return next((n for n, _ in bp.walk(snap["cells"]) if "rail" in bp.attr(n, "class", "").lower()), None)


def anim_css(node):
    return bp.css_of(node, "animation", "animation-name", "animation-duration", "animation-timing-function", "animation-iteration-count", "animation-play-state")


def rings(snap):
    """the nodes of the belt a 1.1 s animation is styled onto: the gate's ring"""
    return [n for n, _ in bp.walk(snap["cells"]) if re.search(r"\b1\.1s\b|\b1100ms\b", anim_css(n))]


def in_status_header(hit):
    """the hit sits inside <header>, in or under an element with role=status"""
    tags = [c["tag"] for c in hit["chain"]]
    if "header" not in tags:
        return False
    return any(c["attrs"].get("role") == "status" for c in hit["chain"][:tags.index("header")])


# ------------------------------------------------------------------------------------------------------ AC-1, AC-2, AC-5, AC-6

class BeltRender(Scene):
    def read(self, ov=None, **kw):
        return bp.run([{"op": "read", "overview": ov or self.ov}], **kw)

    def test_ac1_each_card_once_in_its_column_segment(self):
        "AC-1 (fake-gh): the belt shows each card once, as a token in its column's segment, segments in board order, each with its meta"
        r = self.read()
        self.assertEqual(r["errors"], [], "the page threw")
        snap = r["results"][0]
        self.assertTrue(snap["cells"], "no #cells")
        only_one(self, snap, [KEY % n for n, _ in CARDS], "AC-1")
        check_columns(self, snap, dict(CARDS), "AC-1")
        for col, want in META.items():
            self.assertEqual(meta_of(snap, col), want, "AC-1 the meta of %s" % col)
        queue = [bp.attr(n, "data-key") for n in bp.tokens(snap) if bp.segment_of(snap, bp.attr(n, "data-key")) and bp.segment_of(snap, bp.attr(n, "data-key"))[0] == "Inbox"]
        self.assertEqual(queue, [KEY % 13, KEY % 12, KEY % 11], "AC-1 tokens wait in a segment oldest first")

    def test_ac1_empty_metas(self):
        "AC-1: an empty queue says empty, a gate nothing for you, Done nothing today"
        snap = self.read(self.only("Inbox", "Staged", "Done"))["results"][0]
        self.assertEqual((meta_of(snap, "Inbox"), meta_of(snap, "Staged"), meta_of(snap, "Done")), ("empty", "nothing for you", "nothing today"))
        self.assertEqual(meta_of(snap, "Spec Review"), "2 for you")

    def test_ac1_demo_snapshot(self):
        "AC-1 (demo-gh): the demo's cards, every kind of them, are in the belt once each, in their column's segment"
        sys.path.insert(0, ds.TEST)
        import demo_home
        demo = self.path("demo")
        old, sys.argv = sys.argv, ["demo_home.py", demo]
        try:
            demo_home.main()
        finally:
            sys.argv = old
        gh = os.path.join(demo, "gh", "demo-gh")
        with open(os.path.join(ds.TEST, "demo-gh"), "rb") as f, open(gh, "wb") as g:
            g.write(f.read().replace(b"\r\n", b"\n"))
        os.chmod(gh, os.stat(gh).st_mode | stat.S_IXUSR)
        os.environ.update(FACTORY_GH=gh, SHIPFLOOR_DEMO_GH=os.path.join(demo, "gh"), SHIPFLOOR_DEMO_STATE=demo,
                          CLAUDE_CONFIG_DIR=os.path.join(demo, "claude"), SHIPFLOOR_SCHEDULER="none", SHIPFLOOR_HOME=os.path.join(demo, "home"))
        self.H = os.path.join(demo, "home")
        os.environ.pop("FAKE_GH_DIR", None)
        self.fresh()
        ov = self.overview()
        mine = ov["projects"][0]
        self.assertEqual(mine["slug"], "atlas")
        snap = bp.run([{"op": "read", "overview": ov}])["results"][0]
        want = {c["issue"]: c["column"] for c in mine["cards"]}
        self.assertEqual(len(want), 10)
        self.assertEqual(sorted(n for n, col in want.items() if col == "Done"), [96, 101])
        self.assertEqual(mine["done_today"], 0, "the demo's Done cards shipped days ago")
        want = {n: col for n, col in want.items() if col != "Done"}  # Done shows only what was done today: those two are in the whole line
        only_one(self, snap, ["atlas/%d" % n for n in want], "AC-1 demo")
        segs, idx = segment_names(snap)
        for n, col in want.items():
            parts = bp.segment_of(snap, "atlas/%d" % n)
            self.assertTrue(parts and parts[0] in dict(BOARD)[col], "AC-1 demo: #%d (%s) is in %s" % (n, col, parts))

    def test_ac2_token_looks(self):
        "AC-2: each state has the look of the design's token table (queued dashed, running raised with a bar, waits accent, infra striped warn, done ok)"
        snap = self.read()["results"][0]
        tok = {n: bp.token(snap, KEY % n) for n in (11, 31, 40, 50, 42, 41, 70)}
        self.assertTrue(all(tok.values()), "a token is missing: %s" % [n for n, t in tok.items() if not t])
        lk = {n: bp.look(t) for n, t in tok.items()}
        q, run, wait, infra, done = lk[11], lk[31], lk[50], lk[41], lk[70]
        self.assertTrue(re.search(r"dashed", q["border"]) and re.search(r"var\(--edge-hi\)", q["border"]), "queued border: %s" % q["border"])
        self.assertTrue(re.search(r"var\(--muted\)", q["color"]) and "raise" not in q["background"] and not re.search(ACCENT, q["background"]), "queued: %s" % q)
        self.assertTrue(re.search(r"var\(--raise\)", run["background"]) and re.search(r"var\(--edge\)", run["border"]), "running: %s" % run)
        bar = [n for n, _ in bp.walk(tok[31]) if bp.css_of(n, "height") == "2px" and "var(--text)" in bp.css_of(n, "background", "background-color")]
        self.assertTrue(bar, "a running token has a 2px bar in --text at its bottom: %s" % [(n["tag"], n["css"]) for n, _ in bp.walk(tok[31])][:4])
        for n, pct in ((31, r"57(\.\d+)?%|0\.57\d*"), (40, r"(?<![\d#])40(\.0+)?%|0\.4(0+)?(?!\d)")):
            blob = " ".join(str(v) for t, _ in bp.walk(tok[n]) for v in list(t["attrs"].values()) + list(t["css"].values()))
            self.assertTrue(re.search(pct, blob), "AC-2 the bar of #%d is as wide as its step over its steps (%s): %s" % (n, pct, blob[:300]))
        self.assertEqual(bp.attr(tok[31], "title"), "#31 Title 31 · step 4 of 7")
        self.assertTrue(all(re.search(ACCENT, wait[g]) for g in ("background", "border", "color")) and "dashed" not in wait["border"], "waits for you (#50): %s" % wait)
        self.assertTrue(all(re.search(r"--bad", lk[42][g]) for g in ("background", "border", "color")), "m3 a blocked card has its own look, in --bad: %s" % lk[42])
        self.assertTrue(re.search(r"gradient", infra["background"]) and all(re.search(r"warn", infra[g]) for g in ("background", "border", "color")), "blocked by infrastructure: %s" % infra)
        self.assertTrue(all(re.search(r"var\(--ok\)|\bok\b", done[g]) for g in ("background", "border", "color")), "done today: %s" % done)
        self.assertEqual(len({str(sorted(v.items())) for v in (q, run, wait, infra, done, lk[42])}), 6, "the six states look alike")
        for n in (11, 31, 40, 50, 41, 42, 70):
            self.assertIn("#%d" % n, bp.text(tok[n]), "a token shows its number")

    def test_ac2_free_slots_are_dashed_ghost_tokens(self):
        "AC-2: each free slot of a stage is a dashed 'free' token, aria-hidden and not focusable"
        snap = self.read()["results"][0]
        ghosts = [(n, up) for n, up in bp.walk(snap["cells"]) if bp.squash(bp.text(n)) == "free" and not (up and bp.squash(bp.text(up[-1])) == "free")]
        self.assertEqual(len(ghosts), 2, "one free slot in Develop (1 of 2) and one in Deploy (0 of 1): %d" % len(ghosts))
        for n, up in ghosts:
            self.assertEqual(bp.attr(n, "aria-hidden"), "true", "a ghost token is aria-hidden")
            focusable = n["tag"] in ("button", "a", "input") and bp.attr(n, "tabindex") != "-1" and "disabled" not in n["attrs"]
            self.assertFalse(focusable or bp.attr(n, "tabindex") in ("0", "1"), "a ghost token is not focusable")
            border = bp.look(n)["border"]
            self.assertTrue("dashed" in border and re.search(r"var\(--edge\)", border), "a ghost token has a dashed --edge border: %s" % border)
        segs, idx = segment_names(snap)
        for col, want in (("Coding", 1), ("Technical Refinement", 0), ("Validation", 0), ("Ready for Prod", 1)):
            seg = segs[idx[col]][1]
            got = sum(1 for n, up in bp.walk(seg) if bp.squash(bp.text(n)) == "free" and not (up and up[-1] is not seg and bp.squash(bp.text(up[-1])) == "free"))
            self.assertEqual(got, want, "the free tokens of %s" % col)

    def test_ac5_status_sentence_and_rail(self):
        "AC-5: alive, the header reads 'Running · n decisions wait for you · a of b sessions · $cost today' and the rail moves; silent, the belt stopped"
        live = bp.run([{"op": "read", "overview": self.ov}, {"op": "find", "needle": SENTENCE % ("5 decisions wait for you · ", 3)}, {"op": "find", "needle": "Restart"}])
        snap, hits, restart = live["results"]
        self.assertEqual(live["errors"], [])
        self.assertTrue(hits, "no element reads '%s'" % (SENTENCE % ("5 decisions wait for you · ", 3)))
        self.assertTrue(in_status_header(hits[0]), "the sentence is in the header, in a role=status element: %s" % [(c["tag"], c["attrs"].get("role")) for c in hits[0]["chain"]])
        self.assertFalse([h for h in restart if h["tag"] == "button"], "no Restart while the dispatcher is alive")
        rail = rail_of(snap)
        self.assertTrue(rail, "no rail in the belt")
        self.assertEqual(bp.attr(rail, "aria-hidden"), "true")
        live_css = anim_css(rail)
        self.assertTrue(all(w in live_css for w in ("1.8s", "linear", "infinite")) and "paused" not in live_css, "the live rail slides, 1.8s linear infinite: %s" % live_css)
        self.assertNotIn("--bad", bp.css_of(rail, "background", "background-color", "background-image"))
        silent = copy.deepcopy(self.ov)
        silent["silent"] = {"min": 14, "every": 10, "check": "bash install-dispatcher.sh --status", "reinstall": "bash install-dispatcher.sh"}
        dead = bp.run([{"op": "read", "overview": silent}, {"op": "find", "needle": "The belt stopped. Last cycle 14 min ago."}, {"op": "find", "needle": "Restart"}])
        snap, hits, restart = dead["results"]
        self.assertTrue(hits, "no element reads 'The belt stopped. Last cycle 14 min ago.'")
        self.assertTrue(in_status_header(hits[0]), "the stopped sentence is in the header's role=status")
        self.assertTrue([h for h in restart if h["tag"] == "button" and h["text"] == "Restart" and any(c["tag"] == "header" for c in h["chain"])], "a Restart button in the header")
        rail = rail_of(snap)
        stopped_css = anim_css(rail)
        self.assertIn("paused", stopped_css, "the stopped rail is paused where it is: %s" % stopped_css)
        self.assertIn("--bad", bp.css_of(rail, "background", "background-color", "background-image"), "the stopped rail is filled bad")
        self.assertEqual(len(keys_of(snap)), len(CARDS), "the belt still shows every card while stopped")

    def test_ac5_sentence_parts(self):
        "AC-5: one decision waits for you; none leaves the part out; hours read '2 h 5 min'"
        one = copy.deepcopy(self.ov)
        for c in one["projects"][0]["cards"]:
            if c["issue"] != 50:
                c.update(awaiting=False, blocked=None)
        none = copy.deepcopy(one)
        self.card(none, 50).update(awaiting=False)
        late = copy.deepcopy(self.ov)
        late["silent"] = {"min": 125, "every": 10, "check": "x", "reinstall": "y"}
        r = bp.run([{"op": "read", "overview": one}, {"op": "find", "needle": SENTENCE % ("1 decision waits for you · ", 3)},
                    {"op": "read", "overview": none}, {"op": "find", "needle": SENTENCE % ("", 3)},
                    {"op": "read", "overview": late}, {"op": "find", "needle": "The belt stopped. Last cycle 2 h 5 min ago."}])
        self.assertEqual(r["errors"], [])
        for i, what in ((1, "'1 decision waits for you' in the sentence"), (3, "the sentence without the decisions part at zero"), (5, "'Last cycle 2 h 5 min ago' for 125 minutes")):
            self.assertTrue(r["results"][i], "AC-5 the header does not read %s" % what)

    def test_ac6_tokens_are_reachable_and_named(self):
        "AC-6: the belt is one labelled group of lists, each token a button that announces '#n title, column, state', one tab stop"
        snap = bp.run([{"op": "read", "overview": self.ov}])["results"][0]
        grp = bp.group(snap)
        self.assertTrue(grp, "no role=group in the belt")
        self.assertEqual(bp.attr(grp, "aria-label"), "The belt")
        lists = bp.segments(snap)
        self.assertTrue(lists and all(bp.attr(seg, "aria-labelledby") for _, seg in lists), "each segment is a role=list labelled by its name and meta")
        toks = bp.tokens(snap)
        self.assertEqual(len(toks), len(CARDS))
        for n in toks:
            self.assertNotIn("disabled", n["attrs"])
            self.assertIn(bp.attr(n, "tabindex"), ("0", "-1"), "a token is a roving-tabindex stop")
        self.assertEqual(sum(1 for n in toks if bp.attr(n, "tabindex") == "0"), 1, "the belt is one tab stop")
        for n, name in NAMES.items():
            self.assertEqual(bp.attr(bp.token(snap, KEY % n), "aria-label"), name)

    def test_ac6_arrows_home_end_and_focus_ring(self):
        "AC-6: Left/Right walk the tokens across segments, Home and End go to the ends, one token holds the tab stop, :focus-visible draws a 2px accent outline"
        first = bp.run([{"op": "read", "overview": self.ov}])["results"][0]
        order = keys_of(first)
        self.assertEqual(len(order), len(CARDS), "AC-6 every card is a token in the belt to walk through (%d of %d)" % (len(order), len(CARDS)))
        cut = next(i for i in range(len(order) - 1) if bp.segment_of(first, order[i]) != bp.segment_of(first, order[i + 1]))
        ops = [{"op": "read", "overview": self.ov}, {"op": "focus", "key": order[0]}, {"op": "press", "key": "End"}, {"op": "press", "key": "ArrowLeft"},
               {"op": "press", "key": "ArrowRight"}, {"op": "press", "key": "Home"}, {"op": "focus", "key": order[cut]}, {"op": "press", "key": "ArrowRight"},
               {"op": "focuslook", "key": order[0]}]
        r = bp.run(ops)
        self.assertEqual(r["errors"], [])
        got = [s["active"]["key"] if s["active"] else None for s in r["results"][1:8]]
        self.assertEqual(got, [order[0], order[-1], order[-2], order[-1], order[0], order[cut], order[cut + 1]],
                         "focus after: focus, End, Left, Right, Home, focus (last of a segment), Right (the next segment's first)")
        after = r["results"][7]
        self.assertEqual(after["active"]["key"], order[cut + 1])
        self.assertEqual(after["active"]["tabindex"], "0", "the focused token holds the tab stop")
        self.assertEqual(sum(1 for n in bp.tokens(after) if bp.attr(n, "tabindex") == "0"), 1)
        ring = r["results"][8]
        self.assertTrue(re.search(r"2px", ring.get("outline", "") + ring.get("outline-width", "")) and re.search(ACCENT, ring.get("outline", "") + ring.get("outline-color", "")),
                        "the focused token has a 2px accent outline: %s" % {k: v for k, v in ring.items() if "outline" in k})

    def test_ac6_enter_and_click_pick_the_card_in_the_work_area(self):
        "AC-6: a click or Enter on a token picks that card in the work area (#182) and opens no drawer; the picked token clicked again lets it go"
        tok = lambda n, **more: dict({"within": "cells", "sel": 'button[data-key="%s"]' % (KEY % n)}, **more)
        r = bp.run([{"op": "readw", "overview": self.ov}, tok(50, op="clickx"), tok(21, op="keyx", key="Enter"), tok(31, op="clickx"), tok(31, op="clickx")])
        self.assertEqual(r["errors"], [])
        picked = [s["S"]["work"]["key"] for s in r["results"][1:]]
        self.assertEqual(picked, [KEY % 50, KEY % 21, KEY % 31, None], "AC-6 the picked card after a click on #50, Enter on #21, a click on #31 and another on #31")
        self.assertEqual([s["S"]["open"] for s in r["results"][1:]], [None] * 4, "no drawer opens")

    def test_blocked_for_the_owner_can_be_sent_back_or_accepted(self):
        "#182 AC-7: a card blocked for the owner offers send-back (and, at the acceptance-intact gate, accept) in the work area: both need the note and go after 5 s"
        card = {"project": "shop", "issue": 42, "title": "Title 42", "column": "Validation", "review": False, "sessions": [], "runs": [], "reports": [], "weight": "standard"}
        decide = {"block": {"gate": "acceptance-intact", "kind": "gate"}}
        tok = {"op": "clickx", "within": "cells", "sel": 'button[data-key="%s"]' % (KEY % 42)}
        by = lambda text: {"op": "clickx", "within": "work", "text": text}
        setup = [{"op": "route", "path": "/api/card/shop/42", "body": card}, {"op": "route", "path": "/api/decide/shop/42", "body": decide}, {"op": "readw", "overview": self.ov}, tok]
        for label, action in (("Send back to Coding", "send-back"), ("Accept the tests and continue", "accept")):
            r = bp.run(setup + [{"op": "typex", "within": "work", "sel": "#wk-bnote", "value": "the edits are right"}, by(label), {"op": "advancew", "ms": 4900},
                                {"op": "advancew", "ms": 200}])
            self.assertEqual(r["errors"], [])
            shown, _typed, _held, early, sent = r["results"][3:]
            labels = [bp.squash(bp.text(n)) for n, _ in bp.walk(shown["work"]) if n["tag"] == "button"]
            self.assertIn("Send back to Coding", labels)
            self.assertIn("Accept the tests and continue", labels)
            posts = [p for p in sent["posts"] if p["path"].endswith("/42/" + action)]
            self.assertEqual([p["body"] for p in posts], [{"column": "Validation", "text": "the edits are right", "move_only": False}], action)
            self.assertEqual(early["posts"], [], "nothing leaves inside the 5 s")
        empty = bp.run(setup + [{"op": "clickx", "within": "work", "text": "Send back to Coding"}, {"op": "advancew", "ms": 6000}])
        self.assertEqual(empty["results"][-1]["posts"], [], "without the note nothing is sent")


# ------------------------------------------------------------------------------------------------------ AC-3, AC-4, AC-7

def place(snap, key):
    """where the page's fake layout puts a token: 200 per segment, 60 per token in it"""
    for i, (_, seg) in enumerate(bp.segments(snap)):
        mates = [n for n, _ in bp.walk(seg) if "data-key" in n["attrs"]]
        for j, n in enumerate(mates):
            if n["attrs"]["data-key"] == key and n["tag"] == "button":
                return 200 * i + 60 * j
    return None


def x_of(value):
    m = re.search(r"translate(?:3d|X)?\(\s*(-?[\d.]+)px", value) or re.match(r"\s*(-?[\d.]+)px", value)
    return float(m.group(1)) if m else None


def first_x(keyframes):
    frames = keyframes
    if isinstance(keyframes, dict):
        frames = [{k: (v[0] if isinstance(v, list) else v)} for k, v in keyframes.items()]
    for f in frames[:1] if isinstance(frames, list) else []:
        for k in ("transform", "translate"):
            if isinstance(f, dict) and isinstance(f.get(k), str) and x_of(f[k]) is not None:
                return x_of(f[k])
    return None


def travels(snap, key, dx):
    """the page moved the token from its old place: an animate() of 950ms ease (cubic-bezier(.4,0,.2,1)) starting dx away, or the same as an inline transform and transition"""
    ease = lambda s: s.replace(" ", "").replace("0.", ".")
    for a in snap["anim"]:
        if a["el"]["key"] == key and a["options"].get("duration") == 950 and ease(str(a["options"].get("easing", ""))) == "cubic-bezier(.4,0,.2,1)":
            x = first_x(a["keyframes"])
            if x is not None and abs(x - dx) < 1:
                return True
    writes = [s for s in snap["styles"] if s["el"]["key"] == key]
    moved = any(s["prop"] == "transform" and x_of(s["value"]) is not None and abs(x_of(s["value"]) - dx) < 1 for s in writes)
    timed = any(s["prop"] == "transition" and re.search(r"\b950ms\b|\b0?\.95s\b", s["value"]) and "cubic-bezier(.4,0,.2,1)" in ease(s["value"]) for s in writes)
    return moved and timed


def travelled(snap, key):
    """anything that moves this token: an animation of 950ms or an inline translate"""
    if any(a["el"]["key"] == key and a["options"].get("duration") == 950 for a in snap["anim"]):
        return True
    return any(s["el"]["key"] == key and s["prop"] in ("transform", "translate") and s["value"].strip() not in ("", "none") for s in snap["styles"])


class BeltMotion(Scene):
    def two_reads(self, **kw):
        after = self.moved(40, "Staged")  # 40 leaves Validate for the Staged gate
        ops = [{"op": "read", "overview": self.ov}, {"op": "focus", "key": KEY % 40}, {"op": "read", "overview": after},
               {"op": "advance", "ms": 3000}, {"op": "read", "overview": after}]
        return bp.run(ops, **kw), after

    def test_ac3_a_card_that_changes_column_travels_and_the_gate_rings_once(self):
        "AC-3: a card that changed column travels from its old place (950ms), the others re-flow instantly, the gate it reaches rings once, never on first load"
        r, after = self.two_reads()
        self.assertEqual(r["errors"], [])
        first, second, _, third = r["results"][0], r["results"][2], r["results"][3], r["results"][4]
        self.assertTrue(place(first, KEY % 40) is not None and place(second, KEY % 40) is not None, "AC-3 #40 is a token of the belt before and after it moves")
        dx = place(first, KEY % 40) - place(second, KEY % 40)
        self.assertNotEqual(dx, 0, "the fixture moves the card to another segment")
        self.assertTrue(travels(second, KEY % 40, dx), "#40 should travel %spx over 950ms: anim=%s styles=%s" % (dx, second["anim"], second["styles"][:4]))
        for n, _ in CARDS:
            if n != 40:
                self.assertFalse(travelled(second, KEY % n), "#%d did not change column, it re-flows instantly" % n)
        self.assertEqual(second["active"] and second["active"]["key"], KEY % 40, "focus stays on the token that travels")
        self.assertFalse(first["anim"] or rings(first), "nothing animates on the first load: %s" % first["anim"])
        ring_calls = [a for a in second["anim"] if a["options"].get("duration") == 1100]
        gate = [n for n in rings(second)]
        self.assertTrue(ring_calls or gate, "the Staged gate rings (1.1s) when #40 arrives: anim=%s" % second["anim"])
        self.assertFalse(ring_calls and len(ring_calls) != 1, "one ring")
        self.assertFalse(any("infinite" in anim_css(n) for n in gate), "the ring plays once")
        self.assertFalse([a for a in third["anim"] if a["options"].get("duration") in (950, 1100)], "a read with nothing moved neither travels nor rings again")

    def test_ac4_reduced_motion_nothing_animates(self):
        "AC-4: under prefers-reduced-motion: reduce a card jumps (no travel), the gate does not ring, the rail does not move"
        live, _ = self.two_reads()
        self.assertTrue(rail_of(live["results"][0]), "AC-4 the belt has a rail (class 'rail') that moves while the dispatcher is alive")
        alive_rail = anim_css(rail_of(live["results"][0]))
        self.assertTrue("1.8s" in alive_rail and "infinite" in alive_rail and "paused" not in alive_rail, "the rail moves without the preference: %s" % alive_rail)
        r, after = self.two_reads(reduced=True)
        self.assertEqual(r["errors"], [])
        for snap in r["results"]:
            if not snap or "anim" not in snap:
                continue
            self.assertEqual(snap["anim"], [], "nothing is animated under reduced motion")
            self.assertFalse([s for s in snap["styles"] if "translate" in s["value"] or re.search(r"\d(ms|s)\b", s["value"])], "no inline travel: %s" % snap["styles"][:4])
            self.assertEqual(rings(snap), [], "no gate ring")
            rail = rail_of(snap)
            self.assertTrue(rail, "AC-4 the rail is still drawn, static")
            css = anim_css(rail)
            self.assertTrue("1.8s" not in css or "none" in css or "paused" in css, "the rail is static: %s" % css)
        self.assertEqual(sorted(keys_of(r["results"][2])), sorted(keys_of(r["results"][0])), "the card is still shown, jumped to its new place")
        self.assertEqual((bp.segment_of(r["results"][2], KEY % 40) or [None])[0], "Staged", "AC-4 #40 is in the Staged segment after the second read")

    def test_ac7_narrow_belt_scrolls_inside_its_container(self):
        "AC-7: under 1020px the belt scrolls horizontally inside its panel (segments min 96px, gates 132px) and the focused token is scrolled into view"
        first = bp.run([{"op": "read", "overview": self.ov}], width=1000)["results"][0]
        last = keys_of(first)[-1]
        r = bp.run([{"op": "read", "overview": self.ov}, {"op": "focus", "key": last}], width=1000)
        snap, focused = r["results"]
        grp = bp.group(snap)
        path = next((list(up) + [n] for n, up in bp.walk(snap["cells"]) if n is grp), [snap["cells"]])
        segs, _ = segment_names(snap)
        self.assertGreaterEqual(len(segs), len(BOARD), "AC-7 the belt has its segments (role=list): %d" % len(segs))
        scrollers = [n for n in path if re.search(r"auto|scroll", bp.css_of(n, "overflow-x", "overflow"))]
        self.assertTrue(bp.group(snap) and scrollers, "the belt group (or its container inside the panel) has overflow-x: auto at 1000px; overflow of %s" % [(n["tag"], bp.css_of(n, "overflow-x", "overflow")) for n in path])
        for parts, seg in segs:
            holders = [seg] + next((list(up[-1:]) for n, up in bp.walk(snap["cells"]) if n is seg), [])
            width = max([float(m.group(1)) for h in holders for m in [re.match(r"([\d.]+)px", bp.css_of(h, "min-width"))] if m] or [0])
            self.assertGreaterEqual(width, 132 if parts[0] in GATES else 96, "min-width of the %s segment" % parts[0])
        self.assertTrue([s for s in focused["scrolls"] if (s["opts"] or {}).get("inline") == "nearest"], "a focused token is scrolled into view, inline nearest: %s" % focused["scrolls"])
