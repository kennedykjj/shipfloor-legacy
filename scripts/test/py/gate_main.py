"""gate.sh's dispatch (shipfloor_core/gate/main.py): usage, -C, the project, the verdict line and <lock>/last-gate, the
project's language for what a gate says, stdout as data only; and the config checks the gates rely on."""
import os
import re

import gate_support as gs
import importlib
main_mod = importlib.import_module("shipfloor_core.gate.main")

USAGE = main_mod.USAGE


class Verdict(gs.GateCase):
    def setUp(self):
        super().setUp()
        self.repo()
        self.base = self.head()
        self.put("good.md", "**Weight:** light\n\n## Product\n")
        self.put("bad.md", "# no weight\n")
        self.lock = self.path("lock")
        self.last_gate = os.path.join(self.lock, "last-gate")

    def in_run(self, *argv, **env):
        """The gate in a factory run (SHIPFLOOR_RUN_LOCK), its last-gate cleared first."""
        if os.path.exists(self.last_gate):
            os.unlink(self.last_gate)
        return self.gate(*argv, SHIPFLOOR_RUN_LOCK=self.lock, **env)

    def recorded(self):
        return open(self.last_gate).read() if os.path.exists(self.last_gate) else None

    def test_verdicts(self):
        "a gate ends stderr with 'gate <name>: pass' or 'FAIL (exit N)' (exit 2 too) and leaves it in last-gate"
        bad = []
        for argv, code, line, rec in [
            (("weight", "good.md"), 0, "gate weight: pass", "weight\tpass\n"),
            (("weight", "bad.md"), 1, "gate weight: FAIL (exit 1)", "weight\tFAIL\n"),
            (("forbidden", "deadbeef"), 2, "gate forbidden: FAIL (exit 2)", "forbidden\tFAIL\n"),
            (("scope", "nobody", self.base), 2, "gate scope: FAIL (exit 2)", "scope\tFAIL\n"),
            (("qa-commit",), 2, "gate qa-commit: FAIL (exit 2)", "qa-commit\tFAIL\n"),
            (("test-plan", "nothing.md"), 2, "gate test-plan: FAIL (exit 2)", "test-plan\tFAIL\n"),
        ]:
            r = self.in_run(*argv)
            if (r.code, r.last, self.recorded(), r.out) != (code, line, rec, ""):
                bad.append("%s: %r, last-gate %r" % (" ".join(argv), r, self.recorded()))
        self.assertFalse(bad, "\n".join(bad))

    def test_last_gate_only_in_a_run(self):
        "last-gate is overwritten by each gate of the run; outside a run, or with a lock that is no directory, none is written"
        self.in_run("weight", "good.md")
        r = self.gate("weight", "bad.md", SHIPFLOOR_RUN_LOCK=self.lock)
        self.assertEqual((r.code, self.recorded()), (1, "weight\tFAIL\n"))
        os.unlink(self.last_gate)
        r = self.gate("weight", "good.md")
        self.assertEqual((r.code, r.last, self.recorded()), (0, "gate weight: pass", None))
        gone = os.path.join(self.lock, "gone")
        self.expect(0, "weight", "good.md", SHIPFLOOR_RUN_LOCK=gone)
        self.assertFalse(os.path.exists(gone))

    def test_usage(self):
        "help, -h and --help print the usage on stdout and exit 0; with no argument it goes to stderr, exit 2, no verdict"
        for word in ("help", "-h", "--help"):
            r = self.gate(word)
            self.assertEqual((r.code, r.out, r.err), (0, USAGE, ""), word)
        self.assertTrue(USAGE.startswith("usage: gate.sh [-C <worktree>] <gate> ...\n"))
        self.assertIn("\n  green <layer> <selector>                 the tests ran and pass (reuses a pass recorded on this commit)\n", USAGE)
        self.assertIn("\n  weight <spec>                            the spec's header names one weight: light, standard or heavy\n", USAGE)
        self.assertTrue(USAGE.endswith("In a factory run (SHIPFLOOR_RUN_LOCK), the verdict is also written to <lock>/last-gate for the dispatcher.\n"))
        r = self.in_run()
        self.assertEqual((r.code, r.out, r.err, self.recorded()), (2, "", USAGE, None))

    def test_unknown_command(self):
        "an unknown command prints the usage, then 'gate bogus: FAIL (exit 2)', and records it"
        r = self.in_run("bogus")
        self.assertEqual((r.code, r.out, r.err, self.recorded()), (2, "", USAGE + "gate bogus: FAIL (exit 2)\n", "bogus\tFAIL\n"))

    def test_no_project(self):
        "a directory in no registered project, or a broken config, is exit 2; a failed resolve says so and gives no verdict"
        r = self.in_run("weight", "good.md", FACTORY_CONFIG=None)
        self.assertEqual(r.code, 2)
        self.assertIn("is not in a registered project", r.err)
        self.assertNotIn("gate weight:", r.err)
        self.assertIsNone(self.recorded())
        broken = self.write("bad.yml", "project: [this is not valid\n")
        self.expect(2, "scope", "api", self.base, FACTORY_CONFIG=broken)

    def test_dash_c(self):
        "-C runs the gate in that worktree from anywhere; a folder it cannot enter is exit 2 with no verdict"
        r = self.repo("other")
        base = self.head()
        self.put("web/a.ts")
        os.chdir(self.path("elsewhere"))
        self.expect(0, "-C", r, "scope", "web", base)
        self.expect(1, "-C", r, "scope", "api", base)
        self.assertEqual(self.expect(0, "-C", r, "weight", os.path.join(self.tmp, "repos", "r0", "good.md")).last, "gate weight: pass")
        missing = os.path.join(self.tmp, "does-not-exist")
        res = self.in_run("-C", missing, "weight", "good.md")
        self.assertEqual((res.code, res.err, self.recorded()), (2, "gate: cannot enter '%s'\n" % missing, None))

    def test_no_verdict_for_data_gates(self):
        "acceptance-own and stack print their data and no verdict line, and leave no last-gate (a bad revision too)"
        self.git("checkout", "-q", "-b", "feat/14-x")
        self.put("web/b.test.ts", "t\n")
        qa = self.commit("test(x): acceptance tests for #14")
        self.put("web/b.test.ts", "edited\n")
        self.commit("the card edits a test")
        r = self.in_run("acceptance-own", qa, "web/b.test.ts")
        self.assertRegex(r.out, r"^own:[0-9a-f]{40,64}\n$")
        self.assertEqual((r.code, r.err, self.recorded()), (0, "", None))
        r = self.in_run("acceptance-own", "deadbeef", "web/b.test.ts")
        self.assertEqual(r.code, 2)
        self.assertNotIn("gate acceptance-own:", r.err)
        self.assertIsNone(self.recorded())
        self.write("shome/config.yml", "stacks: 1\nports: {base: 26900, span: 10}\n")
        r = self.in_run("stack", "status")
        self.assertEqual((r.code, r.err, self.recorded()), (0, "", None))
        self.assertEqual(r.out.splitlines()[-1], "queue\t0")
        r = self.gate("stack", "nonsense")
        self.assertEqual((r.code, r.out, r.err), (2, "", "stack: up <owner> | down <owner> | status\n"))
        self.assertEqual(self.gate("stack", "up").code, 2)


EN_MSG = "acceptance-intact: acceptance tests changed after the QA commit"
PT_MSG = "acceptance-intact: os testes de aceitação mudaram depois do commit do QA"


class Language(gs.GateCase):
    """What a gate says on stderr goes through the catalog of the project's language: FACTORY_LANGUAGE (the run's),
    then `language:` in overrides.yml beside the config, then in the config. The verdict and stdout stay as they are."""

    def setUp(self):
        super().setUp()
        self.repo()
        self.git("checkout", "-q", "-b", "feat/13-x")
        self.put("api/src/test/ATest.kt", "test\n")
        self.qa = self.commit("test(x): acceptance tests for #13")
        self.put("api/src/test/ATest.kt", "weakened\n")
        self.commit("weaken")

    def says(self, want, **env):
        r = self.gate("acceptance-intact", self.qa, **env)
        other = PT_MSG if want == EN_MSG else EN_MSG
        return (r.code == 1 and want in r.err and other not in r.err and r.last == "gate acceptance-intact: FAIL (exit 1)"
                and r.out == "") or r

    def test_precedence(self):
        "the language: no setting is English; the config's (quoted too); overrides.yml over it; FACTORY_LANGUAGE over both"
        pt = self.config("language: pt-BR", use=False)
        ptq = self.config('language: "pt-BR"', use=False)
        od = self.path("od")
        cfg_od = os.path.join(od, "factory.yml")
        with open(gs.FIX) as f, open(cfg_od, "w") as g:
            g.write(f.read())
        before = open(cfg_od, "rb").read()
        self.write("od/overrides.yml", "language: pt-BR\n")
        od2 = self.path("od2")
        with open(pt) as f, open(os.path.join(od2, "factory.yml"), "w") as g:
            g.write(f.read())
        self.write("od2/overrides.yml", "language: en\n")
        cases = [
            ("no language anywhere: English", EN_MSG, {}),
            ("language: pt-BR in the config", PT_MSG, {"FACTORY_CONFIG": pt}),
            ('a quoted language: "pt-BR"', PT_MSG, {"FACTORY_CONFIG": ptq}),
            ("overrides.yml pt-BR over a config with none", PT_MSG, {"FACTORY_CONFIG": cfg_od}),
            ("overrides.yml en over the config's pt-BR", EN_MSG, {"FACTORY_CONFIG": os.path.join(od2, "factory.yml")}),
            ("FACTORY_LANGUAGE=en over overrides.yml pt-BR", EN_MSG, {"FACTORY_CONFIG": cfg_od, "FACTORY_LANGUAGE": "en"}),
            ("FACTORY_LANGUAGE=en over the config's pt-BR", EN_MSG, {"FACTORY_CONFIG": pt, "FACTORY_LANGUAGE": "en"}),
            ("FACTORY_LANGUAGE=pt-BR over a config with none", PT_MSG, {"FACTORY_LANGUAGE": "pt-BR"}),
            ("an unknown FACTORY_LANGUAGE: English", EN_MSG, {"FACTORY_LANGUAGE": "klingon"}),
        ]
        bad = ["%s: %r" % (label, r) for label, want, env in cases for r in [self.says(want, **env)] if r is not True]
        os.unlink(os.path.join(od, "overrides.yml"))
        r = self.says(PT_MSG, FACTORY_CONFIG=cfg_od, FACTORY_LANGUAGE="pt-BR")
        if r is not True:
            bad.append("FACTORY_LANGUAGE=pt-BR once overrides.yml is gone: %r" % r)
        self.assertFalse(bad, "\n".join(bad))
        self.assertEqual(open(cfg_od, "rb").read(), before, "factory.yml changed")

    def test_other_messages(self):
        "other gates' messages are translated too, the verdict stays English; a pass in pt-BR is still a pass"
        r = self.gate("scope", "e2e", self.head(), FACTORY_LANGUAGE="pt-BR")
        self.assertIn("scope: papel desconhecido 'e2e'", r.err)
        self.assertEqual(r.last, "gate scope: FAIL (exit 2)")
        r = self.gate("qa-amend", "13", FACTORY_LANGUAGE="pt-BR")
        self.assertNotIn("qa-amend: the last commit is not a QA commit", r.err)
        self.assertTrue(r.err.startswith("qa-amend: "), r)
        self.expect(0, "acceptance-intact", self.head(), FACTORY_LANGUAGE="pt-BR")

    def test_stdout_is_data(self):
        "stdout carries only data in every language: the qa-commit sha, '' for --head off HEAD, the own: key, nothing when blocked"
        own = self.gate("acceptance-own", self.qa, "api/src/test/ATest.kt").out
        self.assertRegex(own, r"^own:[0-9a-f]{40,64}\n$")
        for lang in ("en", "pt-BR"):
            got = [self.gate(*argv, FACTORY_LANGUAGE=lang).out for argv in
                   [("qa-commit", "13"), ("qa-commit", "13", "--head"), ("acceptance-own", self.qa, "api/src/test/ATest.kt"),
                    ("acceptance-intact", self.qa)]]
            self.assertEqual(got, [self.qa + "\n", "", own, ""], lang)


class ConfigForGates(gs.GateCase):
    """shipfloor_config's checks the gates count on: patterns grep -E takes, real path prefixes, the run's language."""

    HEADER = "project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\n"
    LAYER = 'layers:\n  - {name: app, path: app/, test: "echo ok", ran: ok, tests: ["app/**/*_test.go"]}\n'

    def _validate(self, text):
        """shipfloor-config.sh validate (cli._validate): the config's own checks, then every pattern through grep -E."""
        from shipfloor_core import cli
        os.environ["FACTORY_CONFIG"] = self.write("v.yml", text)
        return 0 if gs.quiet(cli._validate)[0] else 1

    def test_invalid_shapes(self):
        "validate refuses (exit 1, never a crash) empty path allow-lists, wrong shapes and patterns grep -E cannot run"
        H, L = self.HEADER, self.LAYER
        texts = [H + "paths: {specs: }\n" + L, H + "paths: {plans: docs/plans}\n" + L]
        texts += [H + extra + "\n" + L for extra in ("stack: http://localhost:3000", "deploy: CI", "paths: docs/",
                                                     "review_criteria: [a]", "limits: {refine: 3}",
                                                     "limits: {develop: {parallel: 1}}", "context: PRODUCT.md",
                                                     "language: klingon")]
        texts += [H + "layers:\n  - {name: a, path: 3, test: t, ran: ok, tests: [a/**]}\n",
                  H + 'layers:\n  - {name: a, path: a/, test: t, ran: ok, tests: [a/**], migrations: {glob: "a/*.sql", comment: 3}}\n']
        texts += [H + 'layers:\n  - {name: a, path: a/, test: t, ran: "%s", tests: [a/**]}\n' % p
                  for p in ("[[:foo:]]", "\\\\d+ passed", "(?i)ok")]
        got = [self._validate(t) for t in texts]
        self.assertEqual(got, [1] * len(texts), [t.splitlines()[2:] for t, c in zip(texts, got) if c != 1])
        self.assertEqual(self._validate(H + L), 0)

    def test_layer_of(self):
        "layer-of takes repo-relative paths, with or without ./"
        r = gs.config_here("layer-of", "./web/a.ts")
        self.assertEqual((r.returncode, r.stdout), (0, b"web\n"))

    def test_run_language(self):
        "a run keeps the language it started with (FACTORY_LANGUAGE) over overrides.yml; one outside the factory's is ignored"
        d = self.path("od")
        with open(gs.FIX) as f, open(os.path.join(d, "factory.yml"), "w") as g:
            g.write(f.read())
        self.write("od/overrides.yml", "language: pt-BR\n")
        os.environ["FACTORY_CONFIG"] = os.path.join(d, "factory.yml")
        os.environ["FACTORY_LANGUAGE"] = "en"
        self.assertIn("language: English (en)", gs.config_here("describe").stdout.decode())
        self.assertEqual(gs.config_here("get", "language").stdout, b"en\n")
        os.unlink(os.path.join(d, "overrides.yml"))
        os.environ["FACTORY_LANGUAGE"] = "klingon"
        self.assertEqual(gs.config_here("get", "language").stdout, b"en\n")
