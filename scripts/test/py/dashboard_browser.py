"""The dashboard's JavaScript in a real browser (Playwright, headless Chromium) on the demo's sample factory: one dashboard.py
server in a thread (as dashboard_support does) whose Factory each test swaps for a fresh sample home (demo_home.py), with the
demo's gh stand-in as gh. The owner's flows are asserted on what they leave behind: the page's state, localStorage, the gh
stand-in's board and comments. A move leaves as soon as it is made (no hold, no Undo).

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
    def open_page(self, token=TOKEN, width=1400, height=900, clock=False):
        """a new context and its page on the dashboard; clock: Playwright's clock in charge of the page's timers"""
        ctx = self.browser.new_context(viewport={"width": width, "height": height})
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
    def test_ac3_keyboard_move_leaves_at_once(self):
        """AC-3 a move by keyboard is sent as soon as the digit is pressed: no hold, no Undo, the toast confirms it"""
        page = self.open_page()
        self.open_lanes(page)
        self.assertEqual(self.column(120), "Staged")
        self.pick_up_and_press(page, "atlas/120", "2")  # Staged takes Coding (1) and Ready for Prod (2), in board order
        expect(page.locator("#ltoast")).to_contain_text("#120 moved to")
        self.until("the move to reach the board", lambda: self.column(120) == "Ready for Prod")
        self.assertEqual(page.locator('[data-lt="undo"], [data-f="undo"], [data-w="undo"]').count(), 0, "no Undo anywhere")
        self.assertEqual(page.evaluate("typeof S.pending"), "undefined", "no pending moves held by the page")

    def test_ac3_drag_move_leaves_at_once_and_the_card_shows_in_its_column(self):
        """AC-3 a move by drag is sent on the drop: the card is in the new column at once and nothing offers Undo"""
        page = self.open_page()
        self.open_lanes(page)
        self.chip(page, "atlas/120").drag_to(page.locator('#lanes .lcol[data-col="Ready for Prod"]'))
        expect(page.locator('#lanes .lcol[data-col="Ready for Prod"] .chip[data-key="atlas/120"]')).to_be_visible()
        self.assertEqual(page.locator('#ltoast [data-lt="undo"]').count(), 0)
        self.until("the move to reach the board", lambda: self.column(120) == "Ready for Prod")

    def test_ac3_a_refused_move_is_rolled_back_with_its_reason(self):
        """AC-3 a move the board refuses puts the card back and shows the reason on the page"""
        page = self.open_page()
        self.open_lanes(page, project="beacon")  # its board cannot be read now: the stand-in answers HTTP 502
        self.pick_up_and_press(page, "beacon/8", "1")  # an Inbox card goes to Ready for Refinement
        expect(page.locator("#lnote")).to_contain_text("board cannot be read now", timeout=SLOW)
        expect(page.locator('#lanes .lcol[data-col="Inbox"] .chip[data-key="beacon/8"]')).to_be_visible()  # back where it was
        expect(page.locator("#ltoast")).to_be_hidden()
        self.assertEqual(self.column(8, project="2"), "Inbox")

    def test_ac3_a_reorder_leaves_at_once_and_a_refused_one_is_rolled_back(self):
        """AC-3 a queue's reorder is sent on Enter, not after a hold; the board refusing it puts the order back and says why"""
        page = self.open_page()
        self.open_lanes(page, project="beacon")  # its board cannot be read now: the stand-in answers HTTP 502
        keys = lambda: page.eval_on_selector_all('#lanes .lcol[data-col="Inbox"] .chip', "els => els.map(e => e.dataset.key)")
        before = keys()
        self.assertEqual(before[:2], ["beacon/8", "beacon/9"])
        self.chip(page, "beacon/8").focus()
        page.keyboard.press("m")
        page.keyboard.press("ArrowDown")
        page.keyboard.press("Enter")
        expect(page.locator("#lnote")).to_contain_text("board cannot be read now", timeout=SLOW)
        self.assertEqual(keys(), before, "the order the board has")
        self.assertEqual(page.locator('[data-lt="undo"]').count(), 0)

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
