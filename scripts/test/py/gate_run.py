"""The gates that run a layer's commands (shipfloor_core/gate/run.py): build, red, green, the layer's install, retry,
and red/green on a layer with needs_stack, with doubles for the runners (mvn, pnpm) and the stack's commands."""
import os

import gate_support as gs

RAN = "    ran: 'Tests +[1-9][0-9]* passed'\n"


def lines(text, n):
    return "".join("%s %d\n" % (text, i) for i in range(1, n + 1))


class Build(gs.GateCase):
    def test_changed_layers_only(self):
        "build runs each changed implementer layer's build from its folder; a layer with no change is not built"
        self.repo()
        base = self.head()
        self.put("api/A.kt")
        os.makedirs("web")
        self.runner("mvn", "BUILD SUCCESS")
        self.runner("pnpm", "ok")
        r = self.expect(0, "build", base)
        self.assertEqual((r.out, r.err), ("BUILD SUCCESS\n", "gate build: pass\n"))
        self.assertEqual(self.argv_log("mvn"), "-q test\n")
        self.assertEqual(self.argv_log("pnpm"), "")
        self.runner("mvn", "Tests run: 3, Failures: 1", 1)
        r = self.expect(1, "build", base)
        self.assertEqual(r.err, "build: api build failed\ngate build: FAIL (exit 1)\n")
        self.expect(2, "build", "")

    def test_any_layers(self):
        "build follows the project's layers: only the changed one, from the layer's own folder"
        self.own_config(LAYERS)
        os.environ["CALLS"] = calls = os.path.join(self.tmp, "calls")
        self.repo()
        base = self.head()
        for d in ("services/a", "services/b/migrations", "packages/lib"):
            os.makedirs(d)
        self.put("services/b/y.go")
        self.expect(0, "build", base)
        got = open(calls).read()
        self.assertIn("svc-b %s/services/b" % os.path.realpath(os.getcwd()), got)
        self.assertNotIn("svc-a", got)

    def test_output_and_flaky(self):
        "build: the builds' stdout is the gate's; with retry: 1 a build that passes the second time is flaky, else it blocks"
        self.repo()
        base = self.head()
        self.put("web/c.ts")
        self.commit()
        self.sh("pnpm", 'echo "building $*"')
        self.assertEqual(self.expect(0, "build", base).out, "building exec tsc --noEmit\nbuilding test\n")
        once = os.path.join(self.tmp, "once")
        self.sh("pnpm", '[ -e "%s" ] && { echo "building $*"; exit 0; }\ntouch "%s"; echo boom; exit 1' % (once, once))
        retry = self.config(replace=[(RAN, RAN + "    retry: 1\n")], use=False)
        for lang in ("en", "pt-BR"):
            if os.path.exists(once):
                os.unlink(once)
            r = self.expect(0, "build", base, FACTORY_CONFIG=retry, FACTORY_LANGUAGE=lang)
            self.assertEqual(r.out, "boom\nbuilding exec tsc --noEmit\nbuilding test\nflaky: web build\n", lang)
        os.unlink(once)
        self.expect(1, "build", base)

    def test_install(self):
        "a layer's install runs before its tests once per content of its folder, outside the worktree; a failing one is exit 3"
        installs = os.path.join(self.tmp, "installs")
        broken = os.path.join(self.tmp, "broken")
        inst = self.sh("install", 'echo ran >> "%s"; [ ! -e "%s" ]' % (installs, broken))
        self.sh("pnpm", '[ -s "%s" ] || { echo "pnpm: command not found"; exit 127; }\necho " Tests  1 passed (1)"' % installs)
        self.config(replace=[(RAN, RAN + "    install: 'bash \"%s\"'\n" % inst)])
        self.repo()
        self.put("web/a.test.ts")
        self.commit("web")
        self.expect(0, "green", "web", "web/a.test.ts")
        self.expect(0, "green", "web", "web/a.test.ts")
        self.assertEqual(self.count_lines(installs), 1)
        self.put("web/package.json", "b\n")
        self.commit("deps")
        self.expect(0, "green", "web", "web/a.test.ts")
        self.assertEqual(self.count_lines(installs), 2)
        self.assertEqual(self.git("status", "--porcelain"), "")
        open(broken, "w").close()
        self.put("web/package.json", "c\n")
        self.commit("deps2")
        lock = self.path("lock")
        r = self.expect(3, "green", "web", "web/a.test.ts", SHIPFLOOR_RUN_LOCK=lock)
        self.assertIn("gate: install failed in web/: bash", r.err)
        self.assertEqual((r.last, r.out, open(os.path.join(lock, "last-gate")).read()),
                         ("gate green: INFRA (exit 3)", "", "green\tINFRA\n"))

    def count_lines(self, p):
        return len(open(p).read().splitlines()) if os.path.exists(p) else 0


class Red(gs.GateCase):
    def setUp(self):
        super().setUp()
        self.repo()
        os.makedirs("api")
        os.makedirs("web")

    def test_decision_table(self):
        "red passes only on an assertion failure: not on passing tests, setup, compile or connection errors"
        bad = []
        for layer, runner, out, code, want in [
            ("api", "mvn", "org.opentest4j.AssertionFailedError: expected: <429> but was: <200>", 1, 0),
            ("api", "mvn", "[ERROR] COMPILATION ERROR : unresolved reference: Foo", 1, 1),
            ("api", "mvn", "BUILD SUCCESS", 0, 1),
            ("api", "mvn", "org.opentest4j.AssertionFailedError: expected: <429> but was: <200>\nTests run: 4, Failures: 1, Errors: 3, Skipped: 0", 1, 1),
            ("api", "mvn", "java.lang.IllegalStateException: Failed to load ApplicationContext", 1, 1),
            ("web", "pnpm", "AssertionError: expected 'a' to be 'b'", 1, 0),
            ("web", "pnpm", "Error: Cannot find module './missing'", 1, 1),
            ("web", "pnpm", 'ERROR: Expected ";" but found "b"', 1, 1),
            ("web", "pnpm", "TypeError: x is not a function\n  > 5 | expect(x()).toBe(1)", 1, 1),
            ("e2e", "pnpm", "Error: page.goto: net::ERR_CONNECTION_REFUSED at http://localhost:3000/\n"
                            "  > 9 | await expect(page.getByText('x')).toBeVisible()", 1, 1),
            ("web", "pnpm", 'AssertionError: expected \'a\' to be \'b\'\nExpected: "b"\nReceived: "a"', 1, 0),
        ]:
            self.runner(runner, out, code)
            r = self.gate("red", layer, "x.test")
            if r.code != want:
                bad.append("%s %r: want %s, %r" % (layer, out, want, r))
        self.assertFalse(bad, "\n".join(bad))
        self.runner("mvn", "BUILD SUCCESS")
        self.assertIn("red: tests passed before implementation; they prove nothing", self.gate("red", "api", "T").err)

    def test_what_red_prints(self):
        "red prints the assertion lines (20 at most) on stdout; on setup errors it shows the first 5 on stderr"
        self.runner("mvn", "[INFO] running\n" + lines("org.opentest4j.AssertionFailedError: expected: <429> but was: <200> at", 25)
                    + "[INFO] done", 1)
        r = self.expect(0, "red", "api", "RateLimitFilterTest")
        self.assertEqual(r.out, lines("org.opentest4j.AssertionFailedError: expected: <429> but was: <200> at", 20))
        self.runner("pnpm", lines("src/a.ts: error TS2304: Cannot find name", 7) + "AssertionError: expected 1 to be 2", 1)
        r = self.expect(1, "red", "web", "lib/a.test.ts")
        self.assertEqual(r.err, "red: tests fail for setup/compile reasons, not behavior:\n"
                         + lines("src/a.ts: error TS2304: Cannot find name", 5) + "gate red: FAIL (exit 1)\n")
        self.runner("pnpm", "setup chatter\nAssertionError: expected 1 to be 2\n Tests  1 failed (1)", 1)
        for lang in ("en", "pt-BR"):
            self.assertEqual(self.gate("red", "web", "web/a.test.ts", FACTORY_LANGUAGE=lang).out, "AssertionError: expected 1 to be 2\n")
        self.runner("pnpm", "nothing to see", 1)
        self.assertIn("red: no assertion failure found in test output", self.expect(1, "red", "web", "x").err)

    def test_selector_is_one_argument(self):
        "red hands the selector to the runner as one argument, never as shell code"
        sel = 'a b;$(touch pwned) "q"'
        log = os.path.join(self.tmp, "args")
        self.sh("pnpm", 'echo "$# ${@: -1}" >> "%s"\necho "AssertionError: expected \'a\' to be \'b\'"\nexit 1' % log)
        self.expect(0, "red", "web", sel)
        self.assertEqual(open(log).read(), "4 %s\n" % sel)
        self.assertFalse(os.path.exists("pwned") or os.path.exists("web/pwned"))

    def test_usage_and_layers(self):
        "red: no selector is exit 2 and says so; an unknown layer or a layer pattern grep -E refuses is exit 2"
        r = self.expect(2, "red", "api")
        self.assertEqual(r.err, "red: selector required\ngate red: FAIL (exit 2)\n")
        self.assertEqual(self.expect(2, "red").err, "red: selector required\ngate red: FAIL (exit 2)\n")
        self.assertIn("gate: unknown layer 'nope'", self.expect(2, "red", "nope", "x").err)
        self.own_config('project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n'
                        '  - {name: a, path: a/, test: "echo boom; exit 1", ran: ok, setup_errors: "[[:foo:]]", tests: [a/**]}\n')
        os.makedirs("a")
        self.assertIn("gate: layer 'a' has an invalid grep -E pattern: [[:foo:]]", self.expect(2, "red", "a", "x").err)

    def test_any_layers(self):
        "red and green use the project's layer runner and patterns (assertions, ran)"
        self.own_config(LAYERS)
        os.environ["CALLS"] = calls = os.path.join(self.tmp, "calls")
        for d in ("services/a", "services/b", "packages/lib"):
            os.makedirs(d)
        self.expect(0, "red", "svc-a", "a; touch PWNED")
        self.assertEqual(open(calls + ".sel").read(), "a; touch PWNED\n")
        self.assertFalse(os.path.exists("services/a/PWNED") or os.path.exists("PWNED"))
        self.table([("svc-b ./...", 0, ("green", "svc-b", "./...")), ("lib ran nothing", 1, ("green", "lib", "x")),
                    ("green nope", 2, ("green", "nope", "x"))])


class Green(gs.GateCase):
    def setUp(self):
        super().setUp()
        self.repo()
        os.makedirs("api")
        os.makedirs("web")

    def test_ran_and_passed(self):
        "green passes only when the tests ran (the layer's `ran` pattern) and passed"
        bad = []
        for layer, runner, out, code, want in [
            ("api", "mvn", "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0", 0, 0),
            ("api", "mvn", "Tests run: 0, Failures: 0, Errors: 0, Skipped: 0", 0, 1),
            ("api", "mvn", "Tests run: 3, Failures: 1", 1, 1),
            ("web", "pnpm", "Tests  4 passed (4)", 0, 0),
            ("web", "pnpm", "No test files found", 0, 1),
            ("e2e", "pnpm", "  2 passed (3.1s)", 0, 0),
        ]:
            self.runner(runner, out, code)
            if self.gate("green", layer, "ATest").code != want:
                bad.append("%s %r: want %s" % (layer, out, want))
        self.assertFalse(bad, bad)
        self.runner("pnpm", "No test files found")
        self.assertIn("green: no acceptance test ran for 'lib/a.test.ts'", self.gate("green", "web", "lib/a.test.ts").err)

    def test_failure_shows_the_tail(self):
        "green shows the last 20 lines of a failing run, in the project's language with the verdict in English"
        self.runner("pnpm", lines("failing line", 30), 1)
        r = self.expect(1, "green", "web", "web/a.test.ts")
        self.assertEqual(r.err, "green: acceptance tests fail:\n" + "".join(lines("failing line", 30).splitlines(True)[-20:])
                         + "gate green: FAIL (exit 1)\n")
        r = self.expect(1, "green", "web", "web/a.test.ts", FACTORY_LANGUAGE="pt-BR")
        self.assertTrue(r.err.startswith("green: os testes de aceitação falham:\n") and r.last == "gate green: FAIL (exit 1)", r)

    def test_layer_problems(self):
        "green: a missing layer folder blocks (said); a `ran` pattern grep -E refuses or no selector is exit 2"
        os.rmdir("web")
        self.runner("pnpm", " Tests  1 passed (1)")
        self.assertIn("gate: layer directory web/ not found", self.expect(1, "green", "web", "x").err)
        os.makedirs("web")
        self.expect(2, "green", "web", "x", FACTORY_CONFIG=self.config(replace=[(RAN, "    ran: 'a('\n")], use=False))
        self.assertEqual(self.expect(2, "green", "web").err, "green: selector required\ngate green: FAIL (exit 2)\n")

    def test_no_color(self):
        "green and red run the runner with NO_COLOR=1 and FORCE_COLOR=0, so its patterns match plain text"
        self.sh("pnpm", 'if [ "${NO_COLOR:-}" = 1 ] && [ "${FORCE_COLOR:-}" = 0 ]; then echo " Tests  4 passed (4)"; '
                        "else printf ' \\033[2mTests\\033[22m  \\033[1m\\033[32m4 passed\\033[39m\\033[22m (4)\\n'; fi")
        self.expect(0, "green", "web", "lib/a.test.ts")

    def test_retry(self):
        "with retry: 1 a failed selector runs once more in green (flaky, on stdout); red never retries"
        once = os.path.join(self.tmp, "once")
        self.sh("pnpm", '[ -e "%s" ] && { echo " Tests  1 passed (1)"; exit 0; }\n'
                        'touch "%s"; echo "AssertionError: expected 1 to be 2"; echo " Tests  1 failed (1)"; exit 1' % (once, once))
        self.config(replace=[(RAN, RAN + "    retry: 1\n")])
        for lang in ("en", "pt-BR"):
            if os.path.exists(once):
                os.unlink(once)
            r = self.expect(0, "green", "web", "web/a.test.ts", FACTORY_LANGUAGE=lang)
            self.assertEqual(r.out, "flaky: web web/a.test.ts\n")
        os.unlink(once)
        self.expect(0, "red", "web", "web/a.test.ts")


class OnAStack(gs.GateCase):
    """red and green on a needs_stack layer (e2e) take a stack slot of their own around the run (stack.py's commands
    are doubles here; the slot queue, signals and heartbeat are gate-stack.test.sh's)."""

    def setUp(self):
        super().setUp()
        self.sh("lsof", "exit 0")  # the slot's port clean-up never touches a real process
        self.write("shome/config.yml", "stacks: 2\nports: {base: 23000, span: 10}\nstack_wait: 3\nstack_stale: 90\nstack_hold_max: 2700\n")
        self.calls = os.path.join(self.tmp, "calls")
        self.stack_config("'echo \"up $SHIPFLOOR_SLOT $SHIPFLOOR_PORT_WEB\" >> \"%s\"'" % self.calls)
        self.mode = os.path.join(self.tmp, "mode")
        self.sh("pnpm", 'if [ "$(cat "%s")" = pass ]; then echo "  1 passed (1s)"; exit 0; fi\n'
                        'echo "AssertionError: expected 1 to be 2"; echo "  1 failed"; exit 1' % self.mode)
        self.repo()
        os.makedirs("web")
        self.lock = self.path("lock")

    def stack_config(self, up):
        return self.config(replace=[('stack: {url: "http://localhost:3000"}\n', "")],
                           extra="stack:\n  up: %s\n  down: 'echo \"down $SHIPFLOOR_SLOT\" >> \"%s\"'\n  ports: [web, api]\n"
                                 '  url: "http://localhost:{web}"\n' % (up, self.calls))

    def run_gate(self, lang, gate, mode):
        with open(self.mode, "w") as f:
            f.write(mode + "\n")
        r = self.gate(gate, "e2e", "web/e2e/a.spec.ts", FACTORY_LANGUAGE=lang, SHIPFLOOR_RUN_LOCK=self.lock)
        return r.code, r.last, open(os.path.join(self.lock, "last-gate")).read()

    def test_verdict_last(self):
        "on a needs_stack layer red and green run on their own slot and still say their verdict last and in last-gate, in en and pt-BR"
        want = {("green", "pass"): (0, "gate green: pass", "green\tpass\n"),
                ("green", "fail"): (1, "gate green: FAIL (exit 1)", "green\tFAIL\n"),
                ("red", "fail"): (0, "gate red: pass", "red\tpass\n"),
                ("red", "pass"): (1, "gate red: FAIL (exit 1)", "red\tFAIL\n")}
        got = {(lang, g, m): self.run_gate(lang, g, m) for lang in ("en", "pt-BR") for g, m in want}
        self.assertEqual({k: v for k, v in got.items() if v != want[k[1:]]}, {})
        calls = open(self.calls).read().splitlines()
        self.assertIn("up 0 23000", calls)
        self.assertEqual(calls[-1], "down 0", calls)
        self.assertNotIn("busy", self.gate("stack", "status").out)

    def test_stack_that_does_not_come_up(self):
        "a needs_stack layer whose stack does not come up is infrastructure: exit 3, the up log's tail, the INFRA verdict"
        self.stack_config("'echo up exploded; false'")
        with open(self.mode, "w") as f:
            f.write("pass\n")
        r = self.expect(3, "green", "e2e", "web/e2e/a.spec.ts", SHIPFLOOR_RUN_LOCK=self.lock)
        self.assertIn("stack: up failed:", r.err)
        self.assertIn("up exploded", r.err)
        self.assertEqual((r.last, open(os.path.join(self.lock, "last-gate")).read()), ("gate green: INFRA (exit 3)", "green\tINFRA\n"))


LAYERS = """project: {name: mono, repo: acme/mono}
board: {owner: acme, number: 1}
layers:
  - name: svc-a
    path: services/a/
    build: 'echo "svc-a $PWD" >> "$CALLS"'
    test: 'printf "%s\\n" {selector} > "$CALLS.sel"; echo "--- FAIL: TestX"; exit 1'
    ran: '^ok '
    assertions: '--- FAIL'
    tests: ['services/a/**/*_test.go']
  - name: svc-b
    path: services/b/
    build: 'echo "svc-b $PWD" >> "$CALLS"'
    test: 'echo "ok  pkg 0.1s"'
    ran: '^ok '
    tests: ['services/b/**/*_test.go']
  - name: lib
    path: packages/lib/
    test: 'echo "no tests"'
    ran: '^ok '
    tests: ['packages/lib/test/**']
"""
