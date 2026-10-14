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
from datetime import datetime

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
        return page.eval_on_selector_all("#list .pass", "els => els.map(e => e.dataset.key)")

    def open_lanes(self, page, project=None):
        """the lifecycle line maximized: the owner's cards as chips in their columns"""
        expect(page.locator("#list .pass").first).to_be_visible(timeout=SLOW)
        if project:
            page.select_option("#proj", project)
        page.click("#band > button[data-max]")

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
        expect(page.locator("#list .pass").first).to_be_visible(timeout=SLOW)
        self.assertFalse(page.evaluate("document.body.classList.contains('refused')"))
        expect(page.locator("#cols")).to_be_visible()

        bad = self.open_page(token="not-the-token")
        expect(bad.locator("#msg.refusal")).to_be_visible(timeout=SLOW)
        self.assertTrue(bad.evaluate("document.body.classList.contains('refused')"))
        expect(bad.locator("#cols")).to_be_hidden()
        expect(bad.locator("#list .pass")).to_have_count(0)

    # ---- AC-2
    def test_ac2_waiting_list_in_order_and_a_card_opens_with_its_tabs(self):
        """AC-2 the waiting list shows the cards waiting for the owner, oldest first, and a card opens with its tabs"""
        page = self.open_page()
        expect(page.locator("#list .pass").first).to_be_visible(timeout=SLOW)
        overview = page.evaluate("async t => (await fetch('/api/overview', {headers: {'X-Shipfloor-Token': t}})).json()", TOKEN)
        cards = next(p for p in overview["projects"] if p["slug"] == "atlas")["cards"]
        want = ["atlas/%d" % c["issue"] for c in sorted((c for c in cards if c.get("awaiting") or c.get("blocked") == "owner"),
                                                         key=lambda c: c.get("since") or "~")]
        keys = self.waiting_keys(page)
        self.assertEqual(keys, want)
        self.assertTrue({"atlas/120", "atlas/127", "atlas/129"} <= set(keys), keys)  # Staged and Spec Review wait for the owner
        self.assertFalse({"atlas/124", "atlas/131"} & set(keys), keys)  # a queued card and a card in the factory's hands do not

        page.click('#list .pass[data-key="atlas/127"] .ptitle')
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
        page = self.open_page()
        expect(page.locator("#list .pass").first).to_be_visible(timeout=SLOW)
        page.click('#list .pass[data-key="atlas/129"] .ptitle')
        expect(page.locator("#drawer.open")).to_be_visible()
        note = "Say which time zone the last sync time is shown in."
        page.fill("#changes", note)
        page.click("#request")
        self.until("the note on the card", lambda: any(note in c for c in self.comments(129)))
        self.until("the card back in refinement", lambda: self.column(129) == "Ready for Refinement")
        self.assertEqual(self.column(127), "Spec Review")  # the other spec stayed

    def test_ac4_approving_a_spec_moves_it_to_ready_for_dev(self):
        """AC-4 approving a spec moves the card to Ready for Dev, with no note"""
        page = self.open_page()
        expect(page.locator("#list .pass").first).to_be_visible(timeout=SLOW)
        page.click('#list .pass[data-key="atlas/129"] .ptitle')
        expect(page.locator("#drawer.open")).to_be_visible()
        expect(page.locator("#approve")).to_be_enabled()
        page.click("#approve")
        self.until("the card in Ready for Dev", lambda: self.column(129) == "Ready for Dev")
        self.assertEqual(self.comments(129), [])
        self.assertEqual(self.column(127), "Spec Review")

    # ---- AC-5
    def test_ac5_theme_and_language_persist_across_a_reload(self):
        """AC-5 the chosen theme (localStorage) and language (config.yml, shown as html lang) survive a reload"""
        page = self.open_page()
        expect(page.locator("#list .pass").first).to_be_visible(timeout=SLOW)
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
        expect(page.locator("#list .pass").first).to_be_attached(timeout=SLOW)
        self.assertTrue(page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"),
                        page.evaluate("[document.documentElement.scrollWidth, window.innerWidth]"))

    def machine_config(self):
        with open(os.path.join(self.home, "config.yml"), encoding="utf-8") as f:
            return f.read()
