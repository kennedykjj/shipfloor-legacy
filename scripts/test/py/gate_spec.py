"""The gates that read the spec (shipfloor_core/gate/spec.py): weight and test-plan, their messages and exit codes."""
import os

import gate_support as gs
from shipfloor_core.gate import spec as spec_mod

SCRIPTS = gs.support.SCRIPTS
NO_WEIGHT = "weight: the spec header has no '**Weight:** light|standard|heavy' line (spec.md)\ngate weight: FAIL (exit 1)\n"


def unknown_weight(value):
    return ("weight: '**Weight:** %s' names no weight the factory knows (light, standard, heavy)\n"
            "gate weight: FAIL (exit 1)\n" % value)


class Weight(gs.GateCase):
    def spec(self, *header):
        """A spec with these header lines; its ## Decisions mentions a weight line too (not the header's)."""
        self.write_spec("# x - spec\n\n**Issue:** #7 · **Branch:** `feat/7-x`\n**Roles:** PO, Tech Lead\n"
                        + "".join(h + "\n" for h in header)
                        + "\n## Product\n**Acceptance criteria**\n- **AC-1** - Given a, when b, then c\n\n"
                          "## Decisions\n- **Weight:** heavy was discussed, standard kept\n")

    def write_spec(self, text):
        with open("spec.md", "w", encoding="utf-8", newline="") as f:
            f.write(text)

    def setUp(self):
        super().setUp()
        self.repo()

    def test_header_weights(self):
        "weight: one header line naming light, standard or heavy passes (backticks and a CRLF line too); the verdict is all it says"
        bad = []
        for header in ["**Weight:** light", "**Weight:** standard", "**Weight:** heavy", "**Weight:** `heavy`",
                       "**Weight:** light\r"]:
            self.spec(header)
            r = self.gate("weight", "spec.md")
            if (r.code, r.err, r.out) != (0, "gate weight: pass\n", ""):
                bad.append("%r: %r" % (header, r))
        self.write_spec("**Weight:** standard\r\n\r\n## Product\r\n")
        r = self.gate("weight", "spec.md")
        if (r.code, r.err) != (0, "gate weight: pass\n"):
            bad.append("a whole CRLF spec: %r" % r)
        self.assertFalse(bad, "\n".join(bad))

    def test_no_weight_or_two(self):
        "weight: no header line (the one in Decisions does not count) or two lines block with their messages"
        self.spec()
        r = self.expect(1, "weight", "spec.md")
        self.assertEqual(r.err, NO_WEIGHT)
        self.spec("**Weight:** light", "**Weight:** heavy")
        r = self.expect(1, "weight", "spec.md")
        self.assertEqual(r.err, "weight: the spec header has more than one weight line:\n**Weight:** light\n"
                                "**Weight:** heavy\ngate weight: FAIL (exit 1)\n")

    def test_unknown_values(self):
        "weight: a value the factory does not know blocks with the same English message in en and pt-BR, a \\r stripped"
        bad = []
        for value in ["medium", "light | standard | heavy", "Heavy", "", "heavy, light"]:
            self.spec("**Weight:** %s" % value)
            for lang in ("en", "pt-BR"):
                r = self.gate("weight", "spec.md", FACTORY_LANGUAGE=lang)
                if (r.code, r.err, r.out) != (1, unknown_weight(value), ""):
                    bad.append("%r (%s): %r" % (value, lang, r))
        self.spec("**Weight:** medium\r")
        r = self.expect(1, "weight", "spec.md")
        self.assertEqual(r.err, unknown_weight("medium"))
        self.assertFalse(bad, "\n".join(bad))

    def test_missing_spec(self):
        "weight: a missing spec or none at all is exit 2, never a pass"
        self.assertEqual(self.expect(2, "weight", "missing.md").err,
                         "weight: spec 'missing.md' not found\ngate weight: FAIL (exit 2)\n")
        self.assertEqual(self.expect(2, "weight").err, "weight: spec '' not found\ngate weight: FAIL (exit 2)\n")

    def test_asks_no_config(self):
        "weight asks the config nothing: it passes with a config file that is not there, or one that does not parse"
        self.spec("**Weight:** light")
        r = self.expect(0, "weight", "spec.md", FACTORY_CONFIG=os.path.join(self.tmp, "not-there.yml"))
        self.assertEqual(r.err, "gate weight: pass\n")
        self.expect(0, "weight", "spec.md", FACTORY_CONFIG=self.write("broken.yml", "layers: [this is not\n"))

    def test_template_has_the_line(self):
        "the spec template's header carries the weight line Refine fills in (after Roles, before ## Product)"
        with open(os.path.join(SCRIPTS, "..", "templates", "spec-template.md"), encoding="utf-8") as f:
            tpl = f.read()
        roles, line, product = tpl.find("**Roles:**"), tpl.find("\n**Weight:** light | standard | heavy\n"), tpl.find("\n## Product")
        self.assertTrue(0 <= roles < line < product, "no **Weight:** header line in the template")


PLAN_HEAD = ("# x - spec\n\n## Product\n**Acceptance criteria**\n- **AC-1** - Given a, when b, then c\n"
             "- **AC-2** - Given d, when e, then f\n\n## Architecture\nx\n\n## Test plan\n_Tech Lead_\n\n"
             "| AC | Layer | Test file |\n|---|---|---|\n")
CANNOT = "test-plan: the pipeline cannot run these acceptance tests (paths are repo-relative):\n"
A1 = "| AC-1 | api | `api/src/test/A.kt` |"


class TestPlan(gs.GateCase):
    def setUp(self):
        super().setUp()
        self.repo()

    def plan(self, *rows):
        """A spec with AC-1 and AC-2 in the Product and these Test plan rows."""
        with open("spec.md", "w", encoding="utf-8", newline="") as f:
            f.write(PLAN_HEAD + "".join(r + "\n" for r in rows) + "\n## Security\nn/a\n")

    def check(self, cases):
        """cases of (label, rows, exit wanted[, exact stderr | text in stderr]); each in en, and again in pt-BR when
        the stderr is exact and only a verdict (nothing to translate)."""
        bad = []
        for case in cases:
            label, rows, want = case[:3]
            self.plan(*rows)
            r = self.gate("test-plan", "spec.md")
            msg = case[3] if len(case) > 3 else None
            ok = r.code == want and r.out == ""
            if msg is not None:
                ok = ok and (r.err == msg if msg.endswith("\n") else msg in r.err)
            if ok and msg == "gate test-plan: pass\n":
                ok = self.gate("test-plan", "spec.md", FACTORY_LANGUAGE="pt-BR").err == msg
            if not ok:
                bad.append("%s: want exit %s %r, got %r" % (label, want, msg, r))
        self.assertFalse(bad, "\n".join(bad))

    def test_runnable_plans_pass(self):
        "test-plan: plans whose every AC has a row with a test file its layer runs pass, in many shapes"
        P = "gate test-plan: pass\n"
        self.check([
            ("api and e2e rows", ["| AC-1 | api | `api/src/test/kotlin/AuthTest.kt` (wrong password -> 400) |",
                                  "| AC-2 | e2e | `web/e2e/login.spec.ts` |"], 0, P),
            ("several ACs in one row", ["| AC-1, AC-2 | web | `web/lib/auth.test.ts` |"], 0, P),
            ("a manual row is checked by hand", [A1, "| AC-2 | manual | `docs/ci.md` (reviewed in the PR) |"], 0, P),
            ("a manual row with no path", ["| AC-1 | manual | n/a |", "| AC-2 | e2e | `web/e2e/a.spec.ts` |"], 0, P),
            ("web and e2e rows", ["| AC-1 | web | `web/lib/a.test.ts` |", "| AC-2 | e2e | `web/e2e/x.spec.ts` |"], 0, P),
            ("a | in a cell after the file cell", [A1, "| AC-2 | api | `api/src/test/B.kt` (a|b) |"], 0, P),
            ("an escaped \\| in a cell", [A1, "| AC-2 | api | `api/src/test/B.kt` (a\\|b) | a\\|b |"], 0, P),
            ("rows with no spaces", ["|AC-1|api|`api/src/test/A.kt`|", "|AC-2|api|`api/src/test/B.kt`|"], 0, P),
            ("two paths in one cell: the first counts", ["| AC-1 | api | `api/src/test/A.kt` and `api/src/main/B.kt` |",
                                                         "| AC-2 | api | `api/src/test/B.kt` |"], 0, P),
        ])

    def test_crlf_spec(self):
        "test-plan: a CRLF spec passes"
        with open("spec.md", "w", newline="") as f:
            f.write("# x\r\n\r\n## Product\r\n- **AC-1** - a\r\n\r\n## Test plan\r\n\r\n| AC | Layer | Test file |\r\n"
                    "|---|---|---|\r\n| AC-1 | api | `api/src/test/A.kt` |\r\n")
        self.assertEqual(self.expect(0, "test-plan", "spec.md").err, "gate test-plan: pass\n")

    def test_rows_the_pipeline_cannot_run(self):
        "test-plan: an unknown layer, a file of no or another layer, no path and an AC with no row block, each named"
        self.check([
            ("a layer the config does not have (#40)", [A1, "| AC-2 | script | `scripts/security/selftest.sh` |"], 1,
             "unknown layer 'script'"),
            ("a file that is no test of its layer", [A1, "| AC-2 | api | `scripts/security/selftest.sh` |"], 1,
             "'scripts/security/selftest.sh' is not a test file of layer 'api'"),
            ("a file of another layer (green would run the wrong runner)", [A1, "| AC-2 | web | `web/e2e/login.spec.ts` |"], 1),
            ("no backticked path", [A1, "| AC-2 | api | AuthTest |"], 1),
            ("an abbreviated path", [A1, "| AC-2 | api | `.../AuthTest.kt` |"], 1),
            ("an AC with no row", [A1], 1, CANNOT + "AC-2: no row in '## Test plan'\ngate test-plan: FAIL (exit 1)\n"),
            ("a row with no path", [A1, "| AC-2 | api | |"], 1,
             CANNOT + " AC-2 : 'no path' is not a test file of layer 'api' (its tests: api/src/test/**)\n"
                      "gate test-plan: FAIL (exit 1)\n"),
            ("a | inside the path splits the cell: no path", [A1, "| AC-2 | api | `api/src/test/B|C.kt` |"], 1,
             "'no path' is not a test file of layer 'api'"),
            ("a row for an AC the Product does not have", [A1, "| AC-2 | web | `api/src/test/B.kt` |", "| AC-3 | api | `x` |"], 1,
             CANNOT + " AC-2 : 'api/src/test/B.kt' is not a test file of layer 'web' (its tests: web/**/*.test.ts web/**/*.test.tsx)\n"
                      " AC-3 : 'x' is not a test file of layer 'api' (its tests: api/src/test/**)\ngate test-plan: FAIL (exit 1)\n"),
        ])

    def test_messages_list_tests_and_layers(self):
        "test-plan: the wrong-path message lists the layer's tests, the unknown-layer one the layers"
        self.plan("| AC-1 | api | `web/a.test.ts` |", "| AC-2 | nope | `x` |")
        r = self.expect(1, "test-plan", "spec.md")
        self.assertIn("\n AC-1 : 'web/a.test.ts' is not a test file of layer 'api' (its tests: api/src/test/**)\n", r.err)
        self.assertIn("\n AC-2 : unknown layer 'nope' (layers: api web e2e, or manual)\n", r.err)

    def test_header_in_pt_br(self):
        "test-plan: in pt-BR the header line is translated, the rows and the verdict are not"
        self.plan(A1, "| AC-2 | web | `api/src/test/B.kt` |", "| AC-3 | api | `x` |")
        r = self.expect(1, "test-plan", "spec.md", FACTORY_LANGUAGE="pt-BR")
        self.assertEqual(r.err, "test-plan: o pipeline não consegue rodar estes testes de aceitação (caminhos relativos ao repositório):\n"
                                " AC-2 : 'api/src/test/B.kt' is not a test file of layer 'web' (its tests: web/**/*.test.ts web/**/*.test.tsx)\n"
                                " AC-3 : 'x' is not a test file of layer 'api' (its tests: api/src/test/**)\ngate test-plan: FAIL (exit 1)\n")

    def test_no_rows_no_section_no_spec(self):
        "test-plan: an empty table or no section blocks; a missing spec or none is exit 2"
        self.plan()
        self.expect(1, "test-plan", "spec.md")
        with open("nosection.md", "w") as f:
            f.write("# x\n\n## Product\n- **AC-1** - x\n")
        self.expect(1, "test-plan", "nosection.md")
        with open("spec.md", "w") as f:
            f.write("# x\n\n## Product\n- **AC-1** - a\n\n## Test plan\n\nnone\n")
        self.assertEqual(self.expect(1, "test-plan", "spec.md").err,
                         "test-plan: '## Test plan' has no rows in spec.md\ngate test-plan: FAIL (exit 1)\n")
        self.assertEqual(self.expect(2, "test-plan", "nothing.md").err,
                         "test-plan: spec 'nothing.md' not found\ngate test-plan: FAIL (exit 2)\n")
        self.assertEqual(self.expect(2, "test-plan").err, "test-plan: spec '' not found\ngate test-plan: FAIL (exit 2)\n")

    def test_percent_b(self):
        "test-plan's message expands backslash escapes as printf %b: \\t \\x41 \\101 \\0101, an unknown escape kept, \\c stops"
        cases = [("a\\tb", "a\tb"), ("\\x41\\x4a2", "AJ2"), ("\\xq", "\\xq"), ("\\101", "A"), ("\\0101", "A"),
                 ("\\0", "\0"), ("a\\qb", "a\\qb"), ("a\\cb", "a"), ("end\\", "end\\"), ("\\\\n", "\\n")]
        self.assertEqual([spec_mod._percent_b(s) for s, _ in cases], [want for _, want in cases])
