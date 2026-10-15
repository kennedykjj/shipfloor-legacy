"""The dashboard's JavaScript in a real browser (Playwright, headless Chromium) on the demo's sample factory: one dashboard.py
server in a thread (as dashboard_support does) whose Factory each test swaps for a fresh sample home (demo_home.py), with the
demo's gh stand-in as gh. The owner's flows are asserted on what they leave behind: the page's state, localStorage, the gh
stand-in's board and comments. Playwright's clock stands in for the 5 s a move waits, so nothing here sleeps for it.

Playwright absent (or no Chromium): every test is skipped, unless BROWSER_TESTS=required, which is one FAIL line."""
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import unittest
from datetime import datetime, timedelta

import dashboard_support
import support

try:
    from playwright.sync_api import expect, sync_playwright
except ImportError:  # the factory's own runtime has no Playwright: it lives in a test-only venv
    sync_playwright = expect = None

TOKEN = "browser-token-0123456789"
SLOW = 20000  # ms: the first overview of the sample reads every transcript and log
REQUIRED = os.environ.get("BROWSER_TESTS") == "required"


class Browser(support.Case):
    broken = None  # why no browser is available, or None
    reported = False  # the one FAIL of a required run that has no browser

    @classmethod
    def setUpClass(cls):
        if sync_playwright is None:
            cls.broken = "playwright not installed"
            return
        try:
            cls.pw = sync_playwright().start()
            cls.addClassCleanup(cls.pw.stop)
            cls.browser = cls.pw.chromium.launch(headless=True)
            cls.addClassCleanup(cls.browser.close)
        except Exception as e:  # no Chromium downloaded, or no system libraries for it
            cls.broken = "chromium does not start: %s" % str(e).splitlines()[0]

    def setUp(self):
        cls = type(self)
        if cls.broken:
            if REQUIRED and not cls.reported:
                cls.reported = True
                self.fail(cls.broken)
            self.skipTest(cls.broken)
        super().setUp()
        self.dash, self.port = dashboard_support.server()
        state = self.path("demo")
        subprocess.run([sys.executable, "-I", os.path.join(support.SCRIPTS, "test", "demo_home.py"), state], check=True)
        self.home, self.claude = os.path.join(state, "home"), os.path.join(state, "claude")
        self.gh_dir = os.path.join(state, "gh")
        gh = os.path.join(self.gh_dir, "demo-gh")  # an LF copy of the stand-in, as the demo stack makes it
        with open(os.path.join(support.SCRIPTS, "test", "demo-gh"), "rb") as f, open(gh, "wb") as out:
            out.write(f.read().replace(b"\r\n", b"\n"))
        os.chmod(gh, os.stat(gh).st_mode | stat.S_IXUSR)
        os.environ.update(SHIPFLOOR_HOME=self.home, CLAUDE_CONFIG_DIR=self.claude, FACTORY_GH=gh, SHIPFLOOR_DEMO_GH=self.gh_dir,
                          SHIPFLOOR_DEMO_STATE=state, SHIPFLOOR_BASH=shutil.which("bash"))
        self.dash.Handler.factory = self.dash.Factory(self.home, self.claude)
        self.dash.Handler.token = TOKEN

    # ---- the page
    def open_page(self, token=TOKEN, width=1400, height=900, clock=False, **context):
        """a new context and its page on the dashboard; clock: Playwright's clock in charge of the page's timers"""
        ctx = self.browser.new_context(viewport={"width": width, "height": height}, **context)
        self.addCleanup(ctx.close)
        page = ctx.new_page()
        if clock:
            page.clock.install(time=datetime.now())
        page.goto("http://127.0.0.1:%d/?t=%s" % (self.port, token))
        return page

    def waiting_keys(self, page):
        """the work area's decision queue: the cards that wait for the owner, the oldest first"""
        return page.evaluate("workView().queue.map((c) => c.key)")

    def ready(self, page):
        """the first overview is read: the work area shows a card (Decide) or Calm"""
        expect(page.locator("#wk-title")).to_be_visible(timeout=SLOW)

    def pick(self, page, key):
        """a click on a card's token on the belt: the work area shows that card"""
        self.ready(page)
        page.click('#cells button[data-key="%s"]' % key)
        expect(page.locator("#wk-title")).to_be_visible()

    def open_lanes(self, page, project=None):
        """the lifecycle line maximized: the owner's cards as chips in their columns"""
        self.ready(page)
        if project:
            page.select_option("#proj", project)
        page.click("#band > button[data-max]")
        # the panel grows out of its place in 280 ms: a chip is dragged where it will stay, not where the animation passes
        page.evaluate("Promise.all(document.getAnimations().filter((a) => a.effect.getComputedTiming().iterations !== Infinity).map((a) => a.finished))")

    def chip(self, page, key):
        return page.locator('#lanes .chip[data-key="%s"]' % key)

    def pick_up_and_press(self, page, key, digit):
        """keyboard move: focus the chip, M picks it up, the digit names the column"""
        self.chip(page, key).focus()
        page.keyboard.press("m")
        expect(page.locator("#lanes.holding")).to_be_visible()
        page.keyboard.press(digit)

    # ---- what the gh stand-in kept
    def state(self):
        with open(os.path.join(self.gh_dir, "state.json"), encoding="utf-8") as f:
            return json.load(f)

    def column(self, n, project="1"):
        row = next((r for r in self.state()["projects"][project]["items"] if r[0] == n), None)
        return row and re.sub(r"^[^A-Za-z]+ ", "", row[1])

    def comments(self, n, repo="demo/atlas"):
        return [c["body"] for c in self.state()["repos"][repo]["comments"].get(str(n), [])]

    def until(self, what, check, secs=15):
        end = time.time() + secs
        while time.time() < end:
            if check():
                return
            time.sleep(0.1)
        self.fail("timed out waiting for " + what)

    # ---- AC-1
    def test_ac1_token_link_loads_and_a_bad_token_shows_the_expired_screen(self):
        """AC-1 the token link loads the dashboard; an invalid token shows the expired-link screen"""
        page = self.open_page()
        self.ready(page)
        self.assertFalse(page.evaluate("document.body.classList.contains('refused')"))
        expect(page.locator("#cols")).to_be_visible()

        bad = self.open_page(token="not-the-token")
        expect(bad.locator("#msg.refusal")).to_be_visible(timeout=SLOW)
        self.assertTrue(bad.evaluate("document.body.classList.contains('refused')"))
        expect(bad.locator("#cols")).to_be_hidden()
        expect(bad.locator("#wk-title")).to_have_count(0)

    # ---- AC-2
    def test_ac2_waiting_queue_in_order_and_a_card_opens_with_its_tabs(self):
        """AC-2 the work area queues the cards waiting for the owner, oldest first, shows the oldest, and a card opens with its tabs"""
        page = self.open_page()
        self.ready(page)
        overview = page.evaluate("async t => (await fetch('/api/overview', {headers: {'X-Shipfloor-Token': t}})).json()", TOKEN)
        cards = next(p for p in overview["projects"] if p["slug"] == "atlas")["cards"]
        owed = lambda c: c["column"] != "Done" and not c.get("running") and (c.get("awaiting") or c.get("blocked") == "owner" or c.get("stopped"))  # M4 needsOwner
        want = ["atlas/%d" % c["issue"] for c in sorted((c for c in cards if owed(c)), key=lambda c: c.get("since") or "~")]
        keys = self.waiting_keys(page)
        self.assertEqual(keys, want)
        self.assertTrue({"atlas/120", "atlas/127", "atlas/129", "atlas/118"} <= set(keys), keys)  # Staged and Spec Review wait for the owner, and so does a card blocked for them
        self.assertFalse({"atlas/124", "atlas/131"} & set(keys), keys)  # a queued card and a card in the factory's hands do not
        self.assertIn("#%s" % keys[0].split("/")[1], page.inner_text("#work .wk-id"))  # Decide opens on the oldest

        self.pick(page, "atlas/127")
        page.click('#work [data-full][data-go="review"]')
        expect(page.locator("#drawer.open")).to_be_visible()
        expect(page.locator('#d-tabs [role="tab"][aria-selected="true"]')).to_have_attribute("data-tab", "review")
        tabs = page.eval_on_selector_all('#d-tabs [role="tab"]', "els => els.map(e => e.dataset.tab)")
        self.assertTrue({"review", "gates", "sessions", "log"} <= set(tabs), tabs)
        page.click('#d-tabs [data-tab="gates"]')
        expect(page.locator('#d-tabs [data-tab="gates"]')).to_have_attribute("aria-selected", "true")

    # ---- AC-3
    def test_ac3_keyboard_move_commits_after_the_delay(self):
        """AC-3 a move by keyboard commits after the 5 s delay, not before"""
        page = self.open_page(clock=True)
        self.open_lanes(page)
        self.assertEqual(self.column(120), "Staged")
        self.pick_up_and_press(page, "atlas/120", "2")  # Staged takes Coding (1) and Ready for Prod (2), in board order
        expect(page.locator('#ltoast [data-lt="undo"]')).to_be_visible()
        self.assertEqual(self.column(120), "Staged")  # nothing has left yet
        page.clock.fast_forward(5000)
        self.until("the move to reach the board", lambda: self.column(120) == "Ready for Prod")

    def test_ac3_drag_move_undone_within_the_delay_never_leaves(self):
        """AC-3 a move by drag can be undone within the delay, and then nothing is sent"""
        page = self.open_page(clock=True)
        self.open_lanes(page)
        before = self.state()["projects"]
        self.chip(page, "atlas/120").drag_to(page.locator('#lanes .lcol[data-col="Ready for Prod"]'))
        expect(page.locator('#ltoast [data-lt="undo"]')).to_be_visible()
        page.click('#ltoast [data-lt="undo"]')
        expect(page.locator('#ltoast [data-lt="undo"]')).to_have_count(0)
        page.clock.fast_forward(6000)
        page.wait_for_timeout(1000)  # a request the undo failed to stop would have landed by now
        self.assertEqual(self.state()["projects"], before)  # no card moved or reordered

    def test_ac3_a_refused_move_shows_its_reason(self):
        """AC-3 a move the board refuses shows the reason on the page"""
        page = self.open_page(clock=True)
        self.open_lanes(page, project="beacon")  # its board cannot be read now: the stand-in answers HTTP 502
        self.pick_up_and_press(page, "beacon/8", "1")  # an Inbox card goes to Ready for Refinement
        expect(page.locator('#ltoast [data-lt="undo"]')).to_be_visible()
        page.clock.fast_forward(5000)
        expect(page.locator("#lnote")).to_contain_text("board cannot be read now", timeout=SLOW)
        self.assertEqual(self.column(8, project="2"), "Inbox")

    # ---- AC-4
    def test_ac4_request_changes_reaches_the_api_with_its_note_and_target(self):
        """AC-4 requesting changes on a spec sends the note and moves the card back to refinement"""
        page = self.open_page(clock=True)
        self.pick(page, "atlas/129")
        page.click("#request")
        note = "Say which time zone the last sync time is shown in."
        page.fill("#wk-note", note)
        page.click("#wk-send")
        expect(page.locator("#work .itoast")).to_be_visible()  # the 5 s window, with Undo
        page.clock.fast_forward(5000)
        self.until("the note on the card", lambda: any(note in c for c in self.comments(129)))
        self.until("the card back in refinement", lambda: self.column(129) == "Ready for Refinement")
        self.assertEqual(self.column(127), "Spec Review")  # the other spec stayed

    def test_ac4_approving_a_spec_moves_it_to_ready_for_dev(self):
        """AC-4 approving a spec moves the card to Ready for Dev, with no note"""
        page = self.open_page(clock=True)
        self.pick(page, "atlas/129")
        expect(page.locator("#approve")).to_be_enabled()
        page.click("#approve")
        expect(page.locator("#work .itoast")).to_be_visible()  # the 5 s window, with Undo
        page.clock.fast_forward(5000)
        self.until("the card in Ready for Dev", lambda: self.column(129) == "Ready for Dev")
        self.assertEqual(self.comments(129), [])
        self.assertEqual(self.column(127), "Spec Review")

    # ---- AC-5
    def test_ac5_theme_and_language_persist_across_a_reload(self):
        """AC-5 the chosen theme (localStorage) and language (config.yml, shown as html lang) survive a reload"""
        page = self.open_page()
        self.ready(page)
        page.click('[data-view="settings"]')
        page.click('[data-setsec="themes"]')
        page.click('[data-theme-pick="paper"]')
        self.assertEqual(page.evaluate("localStorage.getItem('shipfloor.theme')"), "paper")
        page.click('[data-setsec="language"]')
        page.select_option("#lang", "pt-BR")
        page.click('[data-set="save"]')
        self.until("the language saved", lambda: "pt-BR" in self.machine_config())
        page.reload()
        expect(page.locator("html")).to_have_attribute("lang", "pt-BR", timeout=SLOW)
        self.assertEqual(page.evaluate("localStorage.getItem('shipfloor.theme')"), "paper")
        self.assertEqual(page.evaluate("document.documentElement.dataset.theme"), "paper")

    def test_ac5_phone_width_has_no_horizontal_scroll(self):
        """AC-5 at a phone-width viewport the page does not scroll sideways"""
        page = self.open_page(width=375, height=667)
        expect(page.locator("#cols")).to_be_visible(timeout=SLOW)
        expect(page.locator("#wk-title")).to_be_attached(timeout=SLOW)
        self.assertTrue(page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"),
                        page.evaluate("[document.documentElement.scrollWidth, window.innerWidth]"))

    # ---- the UI review: the belt never hides the work area (B1, B2), the phone (M11), the header's state (M3)
    def many_done(self, n=80):
        """n more cards in atlas's Done, each with a clean deploy that ended today: the belt's done today"""
        now = datetime.now().astimezone().replace(microsecond=0)
        start = max(now - timedelta(hours=2), now.replace(hour=0, minute=2, second=0))
        logs = os.path.join(self.home, "projects", "atlas", "logs")
        with open(os.path.join(self.home, "projects", "atlas", "board.tsv"), "a", encoding="utf-8") as board:
            for i in range(n):
                k, at = 500 + i, start + timedelta(seconds=60 * i)
                board.write("%d\tDone\tPVTI_atlas_%d\n" % (k, k))
                with open(os.path.join(logs, "%s-%d-deploy.log" % (at.date().isoformat(), k)), "w", encoding="utf-8") as f:
                    f.write("== start /sf:deploy %d %s pid=1\n== end /sf:deploy %d exit=0 %s\n"
                            % (k, (at - timedelta(seconds=50)).isoformat(), k, at.isoformat()))
        state = self.state()  # the stand-in's board too: the dashboard reads it again once board.tsv is 10 s old
        state["projects"]["1"]["items"] += [[500 + i, "\U0001F916 Done", "PVTI_atlas_%d" % (500 + i)] for i in range(n)]
        with open(os.path.join(self.gh_dir, "state.json"), "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False)

    def test_ui_review_work_area_stays_reachable_with_80_done_cards(self):
        """B1/B2 at 1440x900 with 80 cards done today the band stays under 45% of the screen, Done shows today's newest five and
        +75 (which opens the whole line), and the work area and its decision are on the screen"""
        self.many_done()
        page = self.open_page(width=1440, height=900)
        self.ready(page)
        done = page.locator("#cells .seg.done")
        expect(done.locator("button.tok[data-key]")).to_have_count(5)
        self.assertEqual(done.locator("button.tok[data-key]").first.get_attribute("data-key"), "atlas/579", "the newest first")
        expect(done.locator("button.tok.more")).to_have_text("+75")
        expect(done.locator(".smeta")).to_have_text("80 today")
        band, work = page.locator("#band").bounding_box(), page.locator("#work").bounding_box()
        self.assertLessEqual(band["height"], 900 * 0.45 + 1, band)
        self.assertGreater(work["height"], 200, work)
        self.assertLess(work["y"], 900 - 200, "the work area starts on the screen: %s" % work)
        decide = page.locator("#wk-dec")
        expect(decide).to_be_visible()
        decide.scroll_into_view_if_needed()
        box = decide.bounding_box()
        self.assertTrue(box["y"] >= 0 and box["y"] + 40 <= 900, "the decision is reachable: %s" % box)
        done.locator("button.tok.more").click()
        expect(page.locator("#band.maxed")).to_be_visible()
        expect(page.locator('#lanes .lcol[data-col="Done"] .chip')).to_have_count(82)  # every Done card, the demo's two of last week too
        self.assertEqual(page.locator('#lanes .lcol[data-col="Done"]').evaluate("(el) => getComputedStyle(el).overflowY"), "auto")

    def test_ui_review_phone_puts_the_work_area_first(self):
        """M11 under 600px the work area comes before the belt, the segments stack and the band keeps no 80px right padding"""
        page = self.open_page(width=375, height=667)
        self.ready(page)
        self.assertLess(page.locator("#cols").bounding_box()["y"], page.locator("#band").bounding_box()["y"])
        segs = page.locator("#cells .seg")
        a, b = segs.nth(0).bounding_box(), segs.nth(1).bounding_box()
        self.assertEqual(round(a["x"]), round(b["x"]))
        self.assertGreater(b["y"], a["y"])
        self.assertEqual(page.locator("#band").evaluate("(el) => getComputedStyle(el).paddingRight"), "16px")
        self.assertTrue(page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"))

    def test_ui_review_header_says_why_the_belt_holds(self):
        """M3 usage-limited, the header says so (its own word and dot) instead of Running, and the rail stops; paused outranks it"""
        def limited(paused):
            def handle(route):
                body = route.fetch().json()
                body.update(usage_limited=True, paused=paused)
                route.fulfill(json=body)
            return handle
        for paused, word, cls in ((False, "Waiting for the usage limit", "st-usage"), (True, "Paused", "st-paused")):
            ctx = self.browser.new_context(viewport={"width": 1440, "height": 900})
            self.addCleanup(ctx.close)
            page = ctx.new_page()
            page.route("**/api/overview", limited(paused))
            page.goto("http://127.0.0.1:%d/?t=%s" % (self.port, TOKEN))
            self.ready(page)
            expect(page.locator("#status")).to_contain_text(word)
            self.assertNotIn("Running", page.inner_text("#status"))
            self.assertIn(cls, page.get_attribute("#stat", "class"))
            self.assertIn("paused", page.get_attribute("#cells .rail", "class"))

    def test_codex_stage_model_is_a_text_field_kept_literal(self):
        """#150 a stage on Codex has a text field (placeholder, trimmed, dirty, saved under runtime.models, name shown literally, unpriced warned); claude-code stages keep their select"""
        with open(os.path.join(self.home, "config.yml"), "a", encoding="utf-8") as f:
            f.write("\nruntime:\n  stages: {develop: codex}\n")
        page = self.open_page()
        expect(page.locator("#wk-title")).to_be_visible(timeout=SLOW)  # the work area is drawn: the page has read the factory
        page.click('[data-view="settings"]')
        page.click('[data-setsec="models"]')
        field = page.locator('input[data-model="m|stages|develop|heavy"]')
        expect(field).to_be_visible()
        self.assertEqual([field.get_attribute("autocomplete"), field.get_attribute("spellcheck"), field.get_attribute("placeholder")], ["off", "false", "Default (Codex's)"])
        self.assertTrue(field.get_attribute("aria-label"))
        expect(page.locator('select[data-model="m|stages|validate|heavy"]')).to_be_visible()
        field.fill("  gpt-6-sol ")
        expect(page.locator(".cin.model.dirty")).to_have_count(1)
        self.assertEqual(field.input_value(), "gpt-6-sol")
        expect(page.locator("small.warn")).to_contain_text("gpt-6-sol")
        page.click('[data-set="save"]')
        self.until("the model saved", lambda: "gpt-6-sol" in self.machine_config())
        self.assertIn("models:", self.machine_config().split("runtime:")[1])

    # ---- #261: the Logbook's two day charts, on the demo's atlas. Hooks the page offers (the spec names no ids): the day chart is
    # svg[data-fd="day"][data-date], the belt svg[data-fd="belt"][data-date]; a cycle is [data-cycle], a limit stripe [data-limit]
    # (github | usage), the pool line [data-pool], a stage's area [data-area=<stage>], the now line [data-now]; a PR mark is
    # [data-pr="<n> <n>"][data-kind]; a belt row [data-row=<issue>], a bar [data-run][data-stage][data-exit] (+ data-running,
    # data-open, data-log); each chart's readout is a .cap[aria-live=polite] next to its svg's section.
    def factory_day(self, page, date=None):
        return page.evaluate("async ([t, q]) => (await fetch('/api/factory-day/atlas' + q, {headers: {'X-Shipfloor-Token': t}})).json()",
                             [TOKEN, "?date=" + date if date else ""])

    def logbook(self, page):
        self.ready(page)
        page.select_option("#proj", "atlas")
        page.click('[data-view="feed"]')
        expect(page.locator('svg[data-fd="day"]')).to_be_visible(timeout=SLOW)
        expect(page.locator('svg[data-fd="belt"]')).to_be_visible(timeout=SLOW)

    def readout(self, page, kind):
        return page.locator('svg[data-fd="%s"]' % kind).locator("xpath=ancestor::*[.//*[@aria-live='polite']][1]").locator("[aria-live='polite']")

    def token_color(self, page, token):
        return page.evaluate("t => { const e = document.createElement('i'); e.style.color = 'var(--' + t + ')'; document.body.append(e); const c = getComputedStyle(e).color; e.remove(); return c }", token)

    def test_261_ac2_the_charts_show_today_and_the_period_controls_move_them(self):
        "#261 AC-2 today by default; Previous redraws both charts for the day before; a many-day period has neither chart"
        page = self.open_page()
        self.logbook(page)
        today = self.factory_day(page)
        self.assertTrue(today["present"] and today["cycles"] and today["runs"], "the demo has a day to draw")
        expect(page.locator('svg[data-fd="day"]')).to_have_attribute("data-date", today["date"])
        expect(page.locator('svg[data-fd="belt"]')).to_have_attribute("data-date", today["date"])
        expect(page.locator("svg[data-fd=day] [data-cycle]")).to_have_count(len(today["cycles"]))
        expect(page.locator("svg[data-fd=belt] [data-run]")).to_have_count(len(today["runs"]))
        before = (datetime.fromisoformat(today["date"]) - timedelta(days=1)).strftime("%Y-%m-%d")
        page.click('[data-hstep="prev"]')
        prev = self.factory_day(page, before)
        for kind in ("day", "belt"):
            expect(page.locator('svg[data-fd="%s"]' % kind)).to_have_attribute("data-date", before)
        expect(page.locator("svg[data-fd=day] [data-cycle]")).to_have_count(len(prev["cycles"]))
        expect(page.locator("svg[data-fd=belt] [data-run]")).to_have_count(len(prev["runs"]))
        page.click('[data-hp="7"]')
        expect(page.locator("svg[data-fd]")).to_have_count(0)

    def test_261_ac3_cycles_stack_by_stage_with_the_pool_line_and_limit_stripes(self):
        "#261 AC-3 a step per cycle, an area per stage that ran, a dashed pool line, a stripe for each limited cycle"
        page = self.open_page()
        self.logbook(page)
        day = self.factory_day(page)
        cycles = day["cycles"]
        expect(page.locator("svg[data-fd=day] [data-cycle]")).to_have_count(len(cycles))
        ran = sorted({s for c in cycles for s, n in c["running"].items() if n})
        self.assertEqual(sorted(page.eval_on_selector_all("svg[data-fd=day] [data-area]", "els => [...new Set(els.map(e => e.dataset.area))]")), ran)
        self.assertIn("4", (page.locator("svg[data-fd=day] [data-pool]").first.get_attribute("stroke-dasharray") or "").split())
        self.assertEqual(sum(1 for c in cycles if c["github_limited"]) + sum(1 for c in cycles if c["usage_limited"]) > 1, True, "the fixture has both limits")
        for kind, flag in (("github", "github_limited"), ("usage", "usage_limited")):
            expect(page.locator('svg[data-fd=day] [data-limit="%s"]' % kind)).to_have_count(sum(1 for c in cycles if c[flag]))
        stripe = page.locator("svg[data-fd=day] [data-limit]").first
        self.assertIn("var(--warn)", (stripe.get_attribute("fill") or "") + (stripe.get_attribute("style") or ""))

    def test_261_ac4_pr_marks_by_kind_and_the_readouts_of_pr_and_cycle(self):
        "#261 AC-4 every merged PR is on a mark of its kind; pointing at a mark names the PR; pointing at a cycle gives its counts and pool"
        page = self.open_page()
        self.logbook(page)
        day = self.factory_day(page)
        self.assertTrue(day["prs"] and not day["prs_error"], "the demo's gh answers with merged PRs")
        marks = page.eval_on_selector_all("svg[data-fd=day] [data-pr]", "els => els.map(e => [e.dataset.pr.split(' ').map(Number), e.dataset.kind])")
        self.assertEqual(sorted(n for ns, _ in marks for n in ns), sorted(p["number"] for p in day["prs"]))
        kinds = {p["number"]: p["kind"] for p in day["prs"]}
        for ns, kind in marks:
            if len(ns) == 1:
                self.assertEqual(kind, kinds[ns[0]])
        one = next(p for p in day["prs"] if any(ns == [p["number"]] for ns, _ in marks))
        page.locator('svg[data-fd=day] [data-pr="%d"]' % one["number"]).hover()
        text = self.readout(page, "day").inner_text()
        self.assertIn("PR #%d" % one["number"], text)
        self.assertIn(one["title"], text)
        page.locator("svg[data-fd=day] [data-cycle]").nth(len(day["cycles"]) // 2).hover()
        self.assertRegex(self.readout(page, "day").inner_text(), r"Refine \d+ · Develop \d+ · Validate \d+ · Deploy \d+ · pool \d+ of \d+")

    def test_261_ac5_the_belt_has_a_row_per_card_a_bar_per_run_and_a_readout_per_bar(self):
        "#261 AC-5 rows per card, bars per run, failed ones outlined in the bad token, the running one reaching now, the readout names the run"
        page = self.open_page()
        self.logbook(page)
        day = self.factory_day(page)
        runs = day["runs"]
        expect(page.locator("svg[data-fd=belt] [data-row]")).to_have_count(len({r["issue"] for r in runs}))
        expect(page.locator("svg[data-fd=belt] [data-run]")).to_have_count(len(runs))
        bad = self.token_color(page, "bad")
        failed = page.locator("svg[data-fd=belt] [data-run]:not([data-exit='0']):not([data-running])")
        self.assertTrue(any(r["exit"] not in (0, None) for r in runs))
        self.assertEqual(failed.first.evaluate("e => getComputedStyle(e).stroke"), bad)
        ok = page.locator("svg[data-fd=belt] [data-run][data-exit='0']").first
        self.assertNotEqual(ok.evaluate("e => getComputedStyle(e).stroke"), bad)
        running = [r for r in runs if r["running"]]
        self.assertTrue(running)
        live = page.locator("svg[data-fd=belt] [data-run][data-running]")
        expect(live).to_have_count(len(running))
        edge = live.first.evaluate("e => e.getBoundingClientRect().right")
        now = page.locator("svg[data-fd=day] [data-now]").first.evaluate("e => e.getBoundingClientRect().left")
        self.assertLess(abs(edge - now), 3)
        bad_run = next(r for r in runs if r["exit"] not in (0, None))
        page.locator('svg[data-fd=belt] [data-run][data-log="%s"]' % bad_run["log"]).first.hover()
        text = self.readout(page, "belt").inner_text()
        self.assertIn(bad_run["stage"].capitalize(), text)
        self.assertIn("exit %d" % bad_run["exit"], text)
        if bad_run["model"]:
            self.assertIn(bad_run["model"], text)
        live.first.hover()
        self.assertIn("running", self.readout(page, "belt").inner_text())

    def test_261_ac6_the_stage_filter_leaves_only_that_stage(self):
        "#261 AC-6 choosing a stage hides the other stages' bars; All brings them back; an empty stage says so"
        page = self.open_page()
        self.logbook(page)
        runs = self.factory_day(page)["runs"]
        group = page.locator('[role="group"][aria-label="Stage"]')
        expect(group).to_be_visible()
        self.assertEqual([b.inner_text() for b in group.locator("button").all()], ["All", "Refine", "Develop", "Validate", "Deploy"])
        stages = sorted({r["stage"] for r in runs})
        self.assertGreater(len(stages), 1)
        for st in stages:
            group.get_by_role("button", name=st.capitalize(), exact=True).click()
            expect(group.get_by_role("button", name=st.capitalize(), exact=True)).to_have_attribute("aria-pressed", "true")
            expect(page.locator("svg[data-fd=belt] [data-run]")).to_have_count(sum(1 for r in runs if r["stage"] == st))
            self.assertEqual(page.eval_on_selector_all("svg[data-fd=belt] [data-run]", "els => els.map(e => e.dataset.stage)"), [st] * sum(1 for r in runs if r["stage"] == st))
        for st in {"refine", "develop", "validate", "deploy"} - set(stages):
            group.get_by_role("button", name=st.capitalize(), exact=True).click()
            expect(page.locator("svg[data-fd=belt] [data-run]")).to_have_count(0)
            expect(page.get_by_text("No %s run on this day." % st.capitalize())).to_be_visible()
        group.get_by_role("button", name="All", exact=True).click()
        expect(page.locator("svg[data-fd=belt] [data-run]")).to_have_count(len(runs))

    def test_261_ac7_a_bar_opens_the_card_on_the_log_of_that_run(self):
        "#261 AC-7 clicking a bar opens the card maximized on its Log tab, on the clicked run's log file; Escape returns the focus to the bar"
        page = self.open_page()
        self.logbook(page)
        runs = [r for r in self.factory_day(page)["runs"] if r["log"]]
        again = lambda r: any(x["issue"] == r["issue"] and x["log"] != r["log"] for x in runs)  # prefer a card that ran more than once: the clicked run, not the card's last
        run = next((r for r in runs if again(r)), runs[0])
        bar = page.locator('svg[data-fd=belt] [data-run][data-log="%s"]' % run["log"]).first
        self.assertEqual(bar.get_attribute("data-open"), "atlas/%d" % run["issue"])
        bar.click()
        expect(page.locator("#drawer.open")).to_be_visible()
        expect(page.locator('#d-tabs [role="tab"][aria-selected="true"]')).to_have_attribute("data-tab", "log")
        expect(page.locator("#drawer.full")).to_be_visible()
        expect(page.locator("#logsel")).to_have_value(run["log"], timeout=SLOW)
        page.keyboard.press("Escape")
        expect(page.locator("#drawer.open")).to_have_count(0)
        self.assertTrue(page.evaluate("document.activeElement?.closest('svg[data-fd=belt]') !== null"))

    def test_261_ac8_themes_language_narrow_width_and_motion(self):
        "#261 AC-8 tokens only and recolored by the theme; the legend in pt-BR; 375px without overflow, 12px text and no PR marks overlapping; no animation; no external request"
        page = self.open_page(reduced_motion="reduce")
        self.logbook(page)
        paint = "els => els.flatMap(e => [e.getAttribute('fill'), e.getAttribute('stroke'), e.getAttribute('style')]).filter(Boolean)"
        for kind in ("day", "belt"):
            for v in page.eval_on_selector_all('svg[data-fd="%s"] *' % kind, paint):
                self.assertFalse(re.search(r"#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(", re.sub(r"var\([^)]*\)", "", v)), v)
        area = page.locator("svg[data-fd=day] [data-area]").first
        fills = {}
        for theme in ("paper", "graphite"):
            page.evaluate("t => { document.documentElement.dataset.theme = t }", theme)
            fills[theme] = area.evaluate("e => getComputedStyle(e).fill")
        self.assertNotEqual(fills["paper"], fills["graphite"])
        self.assertEqual(page.evaluate("document.getAnimations().filter(a => a.effect.target?.closest?.('svg[data-fd]')).length"), 0)
        self.assertEqual(page.eval_on_selector_all("svg[data-fd] *", "els => els.filter(e => parseFloat(getComputedStyle(e).transitionDuration) > 0).length"), 0)
        urls = page.evaluate("performance.getEntriesByType('resource').map(e => e.name)")
        self.assertTrue(all(u.startswith("http://127.0.0.1:%d/" % self.port) or u.startswith("data:") for u in urls), urls)

        narrow = self.open_page(width=375, height=667)
        self.logbook(narrow)
        self.assertTrue(narrow.evaluate("document.documentElement.scrollWidth <= window.innerWidth"))
        self.assertTrue(narrow.evaluate("[...document.querySelectorAll('svg[data-fd]')].every(s => s.getBoundingClientRect().right <= innerWidth + 1 && !s.hasAttribute('viewBox'))"))
        self.assertEqual(set(narrow.eval_on_selector_all("svg[data-fd] text", "els => els.map(e => getComputedStyle(e).fontSize)")), {"12px"})
        boxes = narrow.eval_on_selector_all("svg[data-fd=day] [data-pr]", "els => els.map(e => { const r = e.getBoundingClientRect(); return [r.left, r.right, r.top, r.bottom] })")
        for i, a in enumerate(boxes):
            for b in boxes[i + 1:]:
                self.assertTrue(a[1] <= b[0] + .5 or b[1] <= a[0] + .5 or a[3] <= b[2] or b[3] <= a[2], (a, b))

        pt = self.open_page()
        self.ready(pt)
        pt.click('[data-view="settings"]')
        pt.click('[data-setsec="language"]')
        pt.select_option("#lang", "pt-BR")
        pt.click('[data-set="save"]')
        self.until("the language saved", lambda: "pt-BR" in self.machine_config())
        pt.reload()
        expect(pt.locator("html")).to_have_attribute("lang", "pt-BR", timeout=SLOW)
        self.logbook(pt)
        expect(pt.get_by_text("O dia da fábrica")).to_be_visible()
        expect(pt.get_by_text("Cards na esteira")).to_be_visible()
        self.assertEqual([b.inner_text() for b in pt.locator('[role="group"][aria-label="Etapa"] button').all()], ["Todas", "Refine", "Develop", "Validate", "Deploy"])

    # ---- UI review (M6, M7, M9)
    def test_palette_pause_asks_first_and_resume_is_offered(self):
        """M6 Ctrl K: Pause the factory comes after the cards and asks before it pauses (Enter twice changes nothing); paused, Resume the factory is offered"""
        pause = os.path.join(self.home, "PAUSE")
        page = self.open_page()
        self.ready(page)
        page.keyboard.press("Control+k")
        expect(page.locator("#pal-in")).to_be_focused()
        rows = page.eval_on_selector_all("#pal-list [data-pal]", "els => els.map(e => e.textContent)")
        self.assertEqual(rows[-1], "Pause the factory", rows)
        self.assertNotEqual(page.inner_text("#pal-list [aria-selected=true]"), "Pause the factory")
        page.keyboard.type("pause")
        page.keyboard.press("Enter")
        expect(page.locator("#pal-ask")).to_be_visible()
        expect(page.locator("#pal-list [aria-selected=true]")).to_have_text("No, keep it running")
        page.keyboard.press("Enter")
        expect(page.locator("#pal-ask")).to_be_hidden()
        self.assertFalse(os.path.exists(pause), "Enter, Enter: nothing paused")
        page.keyboard.press("Enter")
        expect(page.locator("#pal-ask")).to_be_visible()
        page.keyboard.press("Escape")
        expect(page.locator("#pal-ask")).to_be_hidden()
        expect(page.locator("#pal")).to_be_visible()
        page.keyboard.press("Enter")
        page.keyboard.press("ArrowDown")
        expect(page.locator("#pal-list [aria-selected=true]")).to_have_text("Yes, pause the factory")
        page.keyboard.press("Enter")
        self.until("the PAUSE file", lambda: os.path.exists(pause))
        expect(page.locator("#pal")).to_be_hidden()
        page.wait_for_function("S.overview && S.overview.paused", timeout=SLOW)
        page.keyboard.press("Control+k")
        page.keyboard.type("resume")
        expect(page.locator("#pal-list [aria-selected=true]")).to_have_text("Resume the factory")
        page.keyboard.press("Enter")
        self.until("the PAUSE file gone", lambda: not os.path.exists(pause))

    def test_health_banner_in_the_pages_language(self):
        """M7 a health alert is worded by the catalog: in pt-BR it says what is wrong and what to do, with the stage's name, no English"""
        with open(os.path.join(self.home, "config.yml"), encoding="utf-8") as f:
            text = f.read()
        with open(os.path.join(self.home, "config.yml"), "w", encoding="utf-8") as f:
            f.write(text.replace("language: en", "language: pt-BR"))
        log = sorted(os.listdir(os.path.join(self.home, "logs")))
        log = os.path.join(self.home, "logs", next(n for n in log if n.startswith("health-")))
        ts = datetime.now().astimezone().isoformat(timespec="seconds")
        with open(log, "a", encoding="utf-8") as f:
            for _ in range(3):
                f.write(json.dumps({"ts": ts, "cycle": {"s": 5, "exit": 0, "overlap": True}, "idle": ["atlas/develop"], "over": ["pool 7/6"]}) + "\n")
        page = self.open_page()
        expect(page.locator("html")).to_have_attribute("lang", "pt-BR", timeout=SLOW)
        alerts = page.locator("#alerts")
        expect(alerts).to_contain_text("uma vaga livre e cards esperando há 3 ciclos seguidos", timeout=SLOW)
        text = alerts.inner_text()
        for want in ("atlas · Desenvolver", "shipfloor doctor", "dois ciclos do dispatcher rodaram ao mesmo tempo", "7 execuções ao mesmo tempo, o pool permite 6"):
            self.assertIn(want, text)
        for english in ("a free slot", "more runs than the limit", "ran at once"):
            self.assertNotIn(english, text)

    def test_settings_shows_the_pace_the_registration_runs_at(self):
        """M9 Settings shows the pace the installed registration runs at (30 s here, config.yml says 3), no Windows-only reason on Linux"""
        status = os.path.join(self.tmp, "status.sh")
        with open(status, "w", encoding="utf-8") as f:
            f.write("#!/usr/bin/env bash\nprintf 'registered: systemd\\nlimits: none\\npace: every 30 seconds\\n'\n")
        os.environ["SHIPFLOOR_INSTALLER_STATUS"] = '"%s" "%s"' % (shutil.which("bash"), status)
        os.environ["SHIPFLOOR_SCHEDULER"] = '"%s" -c "exit 0" stub' % shutil.which("bash")  # never the real installer
        page = self.open_page()
        self.ready(page)
        page.click('[data-view="settings"]')
        sel = page.locator("#every")
        expect(sel).to_be_enabled(timeout=SLOW)
        self.assertEqual(sel.input_value(), "0.5")
        self.assertEqual(sel.locator("option:checked").inner_text(), "30 seconds")
        self.assertNotIn("Windows only", page.inner_text("#disp"))

    def machine_config(self):
        with open(os.path.join(self.home, "config.yml"), encoding="utf-8") as f:
            return f.read()
