"""shipfloor_notify.cycle, what a dispatcher cycle tells the owner: a card that waits (once per wait, one reminder),
a blocked run, the factory stuck (usage limit, a skipped project, nothing moved for an hour), a card in production,
and the quiet hours that hold it all for one digest."""
from notify_support import TOAST, NotifyCase

T = "\t"


def rows(*cards):
    return "".join("%s\t%s\tI%s\n" % (n, col, n) for n, col in cards)


class Waits(NotifyCase):
    def test_once_per_wait(self):
        "AC-1 a card that starts waiting (Spec Review, Staged, a blocked run) is told once to each channel, and again only after it left and came back"
        self.conf("notify: {channels: {toast: true, ntfy: true}, ntfy_topic: abc_123}")
        self.board(rows((7, "Spec Review"), (8, "Staged"), (9, "Coding"), (10, "Coding")))
        self.health("false", "9")
        self.cycle("2026-10-11T10:00:00")
        self.n_is(6)
        for ch in ("toast", "ntfy"):
            self.has(ch + T + "shop · #7 waits for you" + T + "Seven|Spec Review · spec to review")
            self.has(ch + T + "shop · #8 waits for you" + T + "Eight|Staged · ready to ship")
            self.has(ch + T + "shop · #9 is blocked" + T + "Nine|Stopped in develop")
        self.assertEqual(set(self.topics), {"abc_123"})
        self.cycle("2026-10-11T10:05:00")
        self.cycle("2026-10-11T10:10:00")
        self.n_is(6)
        self.board(rows((7, "Ready for Dev"), (8, "Staged"), (9, "Coding"), (10, "Coding")))
        self.cycle("2026-10-11T10:15:00")
        self.board(rows((7, "Spec Review"), (8, "Staged"), (9, "Coding"), (10, "Coding")))
        self.cycle("2026-10-11T10:20:00")
        self.n_is(8)

    def test_blocked_stage(self):
        "AC-1 the stage a blocked card stopped in comes from its column (refine, validate, deploy)"
        self.conf(TOAST)
        self.board(rows((7, "Technical Refinement"), (8, "Validation"), (9, "Ready for Prod")))
        self.health("false", "7,8,9")
        self.cycle("2026-10-11T10:00:00")
        self.has("toast" + T + "shop · #7 is blocked" + T + "Seven|Stopped in refine")
        self.has("toast" + T + "shop · #8 is blocked" + T + "Eight|Stopped in validate")
        self.has("toast" + T + "shop · #9 is blocked" + T + "Nine|Stopped in deploy")

    def test_pt_br(self):
        "AC-1 the copy follows the machine's language (notify.pt-BR.json); the card's title is not translated"
        self.conf("language: pt-BR\nnotify: {channels: {toast: true}}")
        self.board(rows((7, "Spec Review")))
        self.cycle("2026-10-11T10:00:00")
        self.has_part("toast" + T + "shop · #7 espera você" + T + "Seven|")

    def test_titles_read_once(self):
        "the titles of a project's cards come from one gh read of its repository per cycle"
        self.conf(TOAST)
        self.board(rows((7, "Spec Review"), (8, "Staged")))
        self.cycle("2026-10-11T10:00:00")
        self.assertEqual(len(self.gh_calls), 1)
        self.assertEqual(self.gh_calls[0][:4], ("issue", "list", "--repo", "acme/shop"))

    def test_reminder_60(self):
        "AC-2 one reminder per wait at reminder_min (60), repeating the first body, never once per cycle"
        self.conf("notify: {channels: {toast: true}, reminder_min: 60}")
        self.board(rows((7, "Spec Review")))
        for at in ("10:00", "10:30", "10:59"):
            self.cycle("2026-10-11T%s:00" % at)
        self.n_is(1)
        self.cycle("2026-10-11T11:00:00")
        self.n_is(2)
        self.has("toast" + T + "shop · #7 still waits for you" + T + "Seven|Spec Review · spec to review")
        for at in ("11:01", "11:30", "13:00"):
            self.cycle("2026-10-11T%s:00" % at)
        self.n_is(2)

    def test_reminder_15(self):
        "AC-2 a reminder of 15 minutes is not sent at 14, and is at 15"
        self.conf("notify: {channels: {toast: true}, reminder_min: 15}")
        self.board(rows((8, "Staged")))
        self.cycle("2026-10-11T10:00:00")
        self.cycle("2026-10-11T10:14:00")
        self.n_is(1)
        self.cycle("2026-10-11T10:15:00")
        self.has("toast" + T + "shop · #8 still waits for you" + T + "Eight|Staged · ready to ship")

    def test_invalid_config(self):
        "an invalid config.yml sends nothing and says why in one log line"
        self.conf("notify: {reminder_min: 5, channels: {toast: true}}")
        self.board(rows((7, "Spec Review")))
        self.cycle("2026-10-11T10:00:00")
        self.n_is(0)
        self.assertIn("shipfloor: notify: config.yml is invalid, nothing is sent: ", self.err)
        self.assertIn("The reminder takes 15 to 720 minutes.", self.err)


class Stuck(NotifyCase):
    def test_usage_limit(self):
        "AC-3 the usage limit is told once, and again once it cleared and came back"
        self.conf(TOAST)
        self.board("")
        self.health("true")
        self.cycle("2026-10-11T10:00:00")
        self.cycle("2026-10-11T10:05:00")
        self.n_is(1)
        self.has("toast" + T + "Shipfloor · the factory is stuck" + T + "The Claude usage limit was hit. New runs wait for it to reset.")
        self.health("false")
        self.cycle("2026-10-11T10:10:00")
        self.health("true")
        self.cycle("2026-10-11T10:15:00")
        self.n_is(2)

    def test_last_health_line(self):
        "the last health line read is the newest whole one: a line cut short by a dying cycle is skipped"
        self.conf(TOAST)
        self.board("")
        self.health("true")
        with open(self.P + "/../../logs/health-2026-10.jsonl", "a") as f:
            f.write('{"ts":"2026-10-11T10:0')
        self.cycle("2026-10-11T10:00:00")
        self.has_part("The Claude usage limit was hit.")

    def test_skipped(self):
        "AC-3 a skipped project is told once, without its reason; a skip that clears and comes back is told again"
        self.conf(TOAST)
        self.board("")
        self.write("h/projects/shop/SKIPPED", "2026-10-11T09:00:00\tcannot bring the control checkout to origin/main: fatal: /secret/dir/.git/index.lock exists\n")
        self.cycle("2026-10-11T10:00:00")
        self.cycle("2026-10-11T10:05:00")
        self.n_is(1)
        self.has("toast" + T + "shop · the factory is stuck" + T + "The dispatcher skips this project. The dashboard says why.")
        import os
        os.remove(self.P + "/SKIPPED")
        self.cycle("2026-10-11T10:10:00")
        self.write("h/projects/shop/SKIPPED", "2026-10-11T10:12:00\tinvalid .shipfloor/factory.yml on origin/main\n")
        self.cycle("2026-10-11T10:15:00")
        self.n_is(2)

    def test_idle_hour(self):
        "AC-3 no card moved for an hour while one sits in a factory column: told once, not under an hour, not again while it holds"
        self.conf(TOAST)
        self.board(rows((12, "Coding")))
        for at in ("10:00", "10:30", "10:59"):
            self.cycle("2026-10-11T%s:00" % at)
        self.n_is(0)
        self.cycle("2026-10-11T11:01:00")
        self.n_is(1)
        self.has("toast" + T + "shop · the factory is stuck" + T + "No card moved for an hour and nothing is paused.")
        self.cycle("2026-10-11T11:30:00")
        self.cycle("2026-10-11T14:00:00")
        self.n_is(1)

    def test_idle_counts_from_last_move(self):
        "AC-3 a card that moved 40 minutes ago keeps the factory from being stuck; an hour after the last move it is"
        self.conf(TOAST)
        self.board(rows((12, "Coding")))
        self.cycle("2026-10-11T10:00:00")
        self.board(rows((12, "Validation")))
        self.cycle("2026-10-11T10:50:00")
        self.cycle("2026-10-11T11:30:00")
        self.n_is(0)
        self.cycle("2026-10-11T11:51:00")
        self.n_is(1)

    def test_paused(self):
        "AC-3 a paused project, or a paused factory, is not stuck"
        for pause in ("h/projects/shop/PAUSE", "h/PAUSE"):
            with self.subTest(pause=pause):
                self.setUp()
                self.conf(TOAST)
                self.board(rows((12, "Coding")))
                self.write(pause, "")
                self.cycle("2026-10-11T10:00:00")
                self.cycle("2026-10-11T12:00:00")
                self.n_is(0)

    def test_outside_columns(self):
        "AC-3 cards outside the factory's columns are never stuck (only the one waiting for the owner is told)"
        self.conf("notify: {channels: {toast: true}, events: {reminder: false}}")
        self.board(rows((1, "Inbox"), (2, "Done"), (3, "Spec Review")))
        self.cycle("2026-10-11T10:00:00")
        self.cycle("2026-10-11T12:00:00")
        self.n_is(1)

    def test_blocked_not_stuck(self):
        "AC-3 a blocked card is told as blocked, not as a stuck factory"
        self.conf("notify: {channels: {toast: true}, events: {reminder: false}}")
        self.board(rows((12, "Coding")))
        self.health("false", "12")
        self.cycle("2026-10-11T10:00:00")
        self.cycle("2026-10-11T12:00:00")
        self.n_is(1)
        self.has_part("shop · #12 is blocked")


class Done(NotifyCase):
    def test_off_by_default(self):
        "AC-4 reached production is off by default"
        self.conf(TOAST)
        self.board(rows((8, "Coding"), (9, "Done")))
        self.cycle("2026-10-11T10:00:00")
        self.board(rows((8, "Done"), (9, "Done")))
        self.cycle("2026-10-11T10:05:00")
        self.n_is(0)

    def test_told_once(self):
        "AC-4 with done on, a card that reaches Done is told once with number and title; one already there on the first cycle is not"
        self.conf("notify: {channels: {toast: true}, events: {done: true}}")
        self.board(rows((8, "Coding"), (9, "Done")))
        self.cycle("2026-10-11T10:00:00")
        self.n_is(0)
        self.board(rows((8, "Done"), (9, "Done")))
        self.cycle("2026-10-11T10:05:00")
        self.n_is(1)
        self.has("toast" + T + "shop · #8 reached production" + T + "Eight")
        self.cycle("2026-10-11T10:10:00")
        self.n_is(1)


QUIET = 'notify: {channels: {toast: true}, events: {reminder: false}, quiet: "23:00-08:00"}'


class Quiet(NotifyCase):
    def setUp(self):
        super().setUp()
        self.health("false", ts="2026-10-10T23:00:00-03:00")

    def start(self, conf=QUIET, board=""):
        self.conf(conf)
        self.board(board)
        self.cycle("2026-10-10T23:30:00")

    def test_held_then_digest(self):
        "AC-5 a wait at 01:00 is held until 08:00, then one digest names it; it is not sent again, and later waits are told at once"
        self.start()
        self.board(rows((7, "Spec Review")))
        for at in ("01:00", "03:00", "07:59"):
            self.cycle("2026-10-11T%s:00" % at)
        self.n_is(0)
        self.cycle("2026-10-11T08:00:00")
        self.n_is(1)
        self.has("toast" + T + "Shipfloor · 1 card needs you" + T + "shop #7 Seven · Spec Review")
        self.cycle("2026-10-11T08:01:00")
        self.cycle("2026-10-11T09:00:00")
        self.n_is(1)
        self.board(rows((7, "Spec Review"), (8, "Staged")))
        self.cycle("2026-10-11T12:00:00")
        self.has("toast" + T + "shop · #8 waits for you" + T + "Eight|Staged · ready to ship")

    def test_oldest_first_and_causes(self):
        "AC-5 a stuck cause is held too; the digest lists the oldest wait first, then the causes that still hold"
        self.start()
        self.board(rows((7, "Spec Review")))
        self.cycle("2026-10-11T01:00:00")
        self.board(rows((7, "Spec Review"), (8, "Staged")))
        self.write("h/projects/shop/SKIPPED", "2026-10-11T02:00:00\tcannot bring the control checkout to origin/main\n")
        self.cycle("2026-10-11T02:00:00")
        self.n_is(0)
        self.cycle("2026-10-11T08:00:00")
        self.n_is(1)
        self.has("toast" + T + "Shipfloor · 2 cards need you" + T + "shop #7 Seven · Spec Review|shop #8 Eight · Staged|shop · project skipped")

    def test_causes_only(self):
        "AC-5 a digest of causes only says the factory is stuck"
        self.start()
        self.write("h/projects/shop/SKIPPED", "2026-10-11T02:00:00\tcannot bring the control checkout to origin/main\n")
        self.cycle("2026-10-11T02:00:00")
        self.cycle("2026-10-11T08:00:00")
        self.has("toast" + T + "Shipfloor · the factory is stuck" + T + "shop · project skipped")

    def test_blocked_in_digest(self):
        "AC-5 a blocked card is listed in the digest with the stage it stopped in"
        self.start()
        self.board(rows((9, "Coding")))
        self.health("false", "9")
        self.cycle("2026-10-11T02:00:00")
        self.cycle("2026-10-11T08:00:00")
        self.has("toast" + T + "Shipfloor · 1 card needs you" + T + "shop #9 Nine · blocked in develop")

    def test_four_lines(self):
        "AC-5 six waiting cards are one notification: four lines, then 'and 2 more'"
        self.start()
        cards = []
        for i, n in enumerate(range(7, 13)):
            cards.append((n, "Spec Review"))
            self.board(rows(*cards))
            self.cycle("2026-10-11T0%d:%d0:00" % ((i + 1) // 6, (i + 1) % 6))
        self.cycle("2026-10-11T08:00:00")
        self.n_is(1)
        self.has("toast" + T + "Shipfloor · 6 cards need you" + T + "shop #7 Seven · Spec Review|shop #8 Eight · Spec Review|"
                 "shop #9 Nine · Spec Review|shop #10 Ten · Spec Review|and 2 more")

    def test_decided_not_listed(self):
        "AC-5 a card the owner already decided is not listed, and with nothing left nothing is sent"
        self.start('notify: {channels: {toast: true}, events: {reminder: false, stuck: false}, quiet: "23:00-08:00"}')
        self.board(rows((7, "Spec Review")))
        self.cycle("2026-10-11T01:00:00")
        self.board(rows((7, "Ready for Dev")))
        self.cycle("2026-10-11T03:00:00")
        self.cycle("2026-10-11T08:00:00")
        self.cycle("2026-10-11T09:00:00")
        self.n_is(0)

    def test_done_dropped(self):
        "AC-5 a card that reached production in the quiet hours is dropped, not listed"
        self.conf('notify: {channels: {toast: true}, events: {done: true, reminder: false}, quiet: "23:00-08:00"}')
        self.board(rows((7, "Coding")))
        self.cycle("2026-10-10T23:30:00")
        self.board(rows((7, "Done")))
        self.cycle("2026-10-11T02:00:00")
        self.cycle("2026-10-11T08:00:00")
        self.cycle("2026-10-11T09:00:00")
        self.n_is(0)

    def test_in_quiet(self):
        "in_quiet: a window over midnight and one inside a day, start included and end excluded; none when empty"
        import shipfloor_notify
        from datetime import datetime
        at = lambda hm: datetime.fromisoformat("2026-10-11T%s:00" % hm)
        self.assertFalse(shipfloor_notify.in_quiet("", at("03:00")))
        for quiet, hm, want in (("23:00-08:00", "23:00", True), ("23:00-08:00", "07:59", True), ("23:00-08:00", "08:00", False),
                                ("23:00-08:00", "12:00", False), ("12:00-14:00", "12:00", True), ("12:00-14:00", "14:00", False),
                                ("12:00-14:00", "11:59", False)):
            self.assertEqual(shipfloor_notify.in_quiet(quiet, at(hm)), want, (quiet, hm))
