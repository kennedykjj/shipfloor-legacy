"""review-page.sh in process (shipfloor_core/review_page.py, review-template.html): the spec turned into the review
page (sections, read-only flags, order, key, date, placeholders, LF), the arguments it refuses, and the incremental
re-review (#177): the baseline files, the marks, the removed and previous texts, the request quote, the count, --diff;
plus the template's demoted rows and theme variables and the catalogs' labels the page shows."""
import json
import os
import re
import sys
from datetime import date

from report_support import ReportCase
from shipfloor_core import review_page
import support

USAGE = "usage: review-page.sh <spec.md> <issue> <branch> <out.html> [--request-file F]"
SPEC = """# [A1] Update Next.js — spec

**Issue:** #25 · **Branch:** `feat/25-x` · **Date:** 2026-10-08

## Product
_Product Owner_

**Problem:** versions with CVEs.
**Acceptance criteria**
- **AC-1** — Given package.json, when I inspect it, then next ≥ 16.3.3.
- **AC-2** — Given web/, when I list it, then only pnpm-lock.yaml exists.

## UX
_UX/UI Designer_ — n/a

## Test plan
_Tech Lead_

| AC | Layer | Test file |
|---|---|---|
| AC-1 | web | command: pnpm list |

## Security
_Security_ — n/a
- none

## Open questions
- **Target versions:** use the latest patch?
"""
LEGACY = """# [A1] Atualizar Next.js — spec

## Produto
_Product Owner_

- **CA-1** — Dado o package.json, então next ≥ 16.3.3.

## UX
_UX/UI Designer_ — não se aplica

## Dúvidas
- **Versões alvo:** usar o patch mais recente?
"""
V1 = """# [A1] Thing — spec

## Product
_Product Owner_

- alpha stays the same
- beta says one thing
- gamma goes away

## Open questions
- **Q:** which one?
"""
V2 = """# [A1] Thing — spec

## Product
_Product Owner_

- alpha stays the same
- beta says another thing

## Security
_Cybersec_

- delta is brand new

## Open questions
- **Q:** which one?
"""
PLACEHOLDERS = ("__DATA__", "__SINCE__", "__ISSUE__", "__TITLE__", "__BRANCH__", "__SPEC__", "__DATE__", "__KEY__")


def data(html):
    return json.loads(re.search(r"const S=(\[.*?\]);", html, re.S).group(1))


def ids(html):
    return ";".join("%s=%s" % (x["id"], x["ro"]) for x in data(html))


def marks(html):
    """Every value under a "mark" key of the page's data, in document order ('' for none)."""
    out = []

    def walk(x):
        if isinstance(x, dict):
            for k, v in x.items():
                if k == "mark":
                    out.append("" if v in (None, False) else str(v))
                else:
                    walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(data(html))
    return out


def since_has(html, n):
    """A line of the page that speaks of "since" and holds the count n as a number."""
    return any(re.search(r"(?i)since[^\n]*(?<![\w.])%d(?![\w.])" % n, line) for line in html.splitlines())


class Page(ReportCase):
    def gen(self, *argv):
        return self.call(review_page.main, argv)

    def page(self, spec_text, issue="25", branch="feat/25-x", name=None, *more):
        spec = self.write("spec/%s.md" % (name or issue), spec_text)
        out = self.path("out", (name or issue) + ".html")
        rc, o, err = self.gen(spec, issue, branch, out, *more)
        self.assertEqual(rc, 0, err)
        with open(out, encoding="utf-8", newline="") as f:
            return f.read()

    def test_spec_to_page(self):
        "the spec's statements become rows: title, plain text of bold and tables, n/a sections skipped, open questions editable and first"
        html = self.page(SPEC)
        for want in ("<!doctype html>", "Spec review #25", "AC-1 — Given package.json", "Problem: versions with CVEs.",
                     "AC-1 · web · command: pnpm list", "Target versions: use the latest patch?"):
            self.assertIn(want, html)
        self.assertEqual(ids(html), "open-questions=False;product=True;test-plan=True")
        for p in PLACEHOLDERS:
            self.assertNotIn(p, html)

    def test_page_frame(self):
        "the key is <project>-spec-<n>-review (factory unless FACTORY_PROJECT), the date today dd/mm/yyyy, branch and spec path shown, LF only from a CRLF spec, parent folder made"
        html = self.page(SPEC)
        self.assertIn('const KEY="factory-spec-25-review";', html)
        self.assertIn("<span>%s</span>" % date.today().strftime("%d/%m/%Y"), html)
        self.assertIn("<span>branch <code>feat/25-x</code></span>", html)
        self.assertIn("<code>%s</code>" % os.path.join(self.tmp, "spec", "25.md"), html)
        os.environ["FACTORY_PROJECT"] = "shop"
        shop = self.page(SPEC, name="shop")
        self.assertIn('const KEY="shop-spec-25-review";', shop)
        self.assertNotIn('"factory-spec-25-review"', shop)
        del os.environ["FACTORY_PROJECT"]
        crlf = self.page(SPEC.replace("\n", "\r\n"), name="crlf")
        self.assertNotIn("\r", crlf)
        self.assertIn("Spec review #25", crlf)

    def test_order(self):
        "open questions come first whatever their place; the other sections keep the spec's order (Dúvidas too, legacy titles)"
        self.assertEqual(ids(self.page(LEGACY, "26", "feat/26-x")), "d-vidas=False;produto=True")
        order = "# [A2] Order — spec\n\n## Product\n- **AC-1** — Given x, then y.\n\n## Open questions\n- **Q:** which one?\n\n## Security\n- a rule\n\n## Architecture\n- a contract\n"
        self.assertEqual(ids(self.page(order, "27")), "open-questions=False;product=True;security=True;architecture=True")
        pt = "# [A2] Ordem — spec\n\n## Produto\n- **CA-1** — Dado x, então y.\n\n## Dúvidas\n- **P:** qual?\n\n## Segurança\n- uma regra\n"
        self.assertEqual(ids(self.page(pt, "28")), "d-vidas=False;produto=True;seguran-a=True")

    def test_refusals(self):
        "a wrong argument count or a --request-file without a value exits 2 with the usage; a missing spec exits 2 naming it; no page either way"
        spec = self.write("spec/s.md", SPEC)
        out = self.path("o") + "/x.html"
        for argv in ([], [spec, "25", "feat/25-x"], [spec, "25", "feat/25-x", out, "extra"], [spec, "25", "feat/25-x", out, "--request-file"]):
            rc, o, err = self.gen(*argv)
            self.assertEqual((rc, o), (2, ""), argv)
            self.assertIn(USAGE, err)
            self.assertIn("review-page.sh --diff <old.md> <new.md>", err)
        rc, o, err = self.gen(self.path("o") + "/nope.md", "25", "feat/25-x", out)
        self.assertEqual(rc, 2)
        self.assertIn("review-page: spec not found: ", err)
        self.assertFalse(os.path.exists(out))


class ReReview(ReportCase):
    def setUp(self):
        super().setUp()
        self.v1 = self.write("v1.md", V1)
        self.v2 = self.write("v2.md", V2)
        self.req = self.write("request.txt", "please make beta clearer and drop gamma\n")

    def build(self, spec, folder, issue="31", *more):
        out = os.path.join(self.path(folder), issue + ".html")
        rc, o, err = self.call(review_page.main, [spec, issue, "feat/%s-x" % issue, out, *more])
        self.assertEqual(rc, 0, err)
        return open(out, encoding="utf-8").read()

    def f(self, folder, name):
        return os.path.join(self.tmp, folder, name)

    def same(self, a, b):
        return open(a, encoding="utf-8").read() == open(b, encoding="utf-8").read()

    def test_first_review(self):
        "a first review keeps the published spec as the baseline, has no read version, no marks, no quote, no count"
        first = self.build(self.v1, "first", "31", "--request-file", self.req)
        self.assertTrue(self.same(self.v1, self.f("first", "31.published.md")))
        self.assertFalse(os.path.exists(self.f("first", "31.read.md")))
        self.assertEqual([m for m in marks(first) if m], [])
        self.assertNotIn("drop gamma", first)
        self.assertNotIn("__SINCE__", first)
        self.assertNotIn("__DATA__", first)
        self.assertFalse(since_has(first, 0))

    def test_back_in_review(self):
        "back in Spec Review: the read version kept, three distinct marks, removed and previous texts listed, the request quoted, the count 3; a rebuild changes nothing"
        self.build(self.v1, "first", "31", "--request-file", self.req)
        back = self.build(self.v2, "first", "31", "--request-file", self.req)
        self.assertTrue(self.same(self.v1, self.f("first", "31.read.md")))
        self.assertTrue(self.same(self.v2, self.f("first", "31.published.md")))
        m = marks(back)
        self.assertGreaterEqual(len(set(m)), 3, m)
        self.assertIn("gamma goes away", back)
        self.assertIn("beta says one thing", back)
        self.assertIn("drop gamma", back)
        self.assertTrue(since_has(back, 3))
        again = self.build(self.v2, "first", "31", "--request-file", self.req)
        self.assertEqual(again, back)
        self.assertTrue(self.same(self.v1, self.f("first", "31.read.md")))
        # an identical spec: every statement is untouched, the empty mark alpha and the question had above
        self.write("same/33.read.md", V2)
        self.write("same/33.published.md", V2)
        sm = marks(self.build(self.v2, "same", "33", "--request-file", self.req))
        self.assertEqual([x for x in sm if x], [])
        self.assertEqual(m.count(""), 2, m)
        self.assertTrue(since_has(open(self.f("same", "33.html")).read(), 0))
        self.assertTrue(self.same(self.v2, self.f("same", "33.read.md")))

    def test_no_request(self):
        "with no request file the summary still counts, and nothing is quoted"
        self.write("norq/32.published.md", V1)
        norq = self.build(self.v2, "norq", "32")
        self.assertTrue(since_has(norq, 3))
        self.assertNotIn("drop gamma", norq)

    def test_diff(self):
        "--diff prints the {section, status, old, new} entries as JSON (the same as statement_diff), writes nothing; a wrong count or a missing file exits 2"
        rc, out, err = self.call(review_page.main, ["--diff", self.v1, self.v2], cwd=self.path("cwd"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(os.listdir(self.path("cwd")), [])
        e = json.loads(out)
        self.assertEqual(e, review_page.statement_diff(V1, V2))
        self.assertEqual(e, [
            {"section": "product", "status": "untouched", "old": "alpha stays the same", "new": "alpha stays the same"},
            {"section": "product", "status": "changed", "old": "beta says one thing", "new": "beta says another thing"},
            {"section": "product", "status": "removed", "old": "gamma goes away", "new": None},
            {"section": "security", "status": "new", "old": None, "new": "delta is brand new"},
            {"section": "open-questions", "status": "untouched", "old": "Q: which one?", "new": "Q: which one?"}])
        rc, out, err = self.call(review_page.main, ["--diff", self.v1])
        self.assertEqual(rc, 2)
        self.assertIn(USAGE, err)
        rc, out, err = self.call(review_page.main, ["--diff", self.v1, self.path("x") + "/missing.md"])
        self.assertEqual(rc, 2)
        self.assertIn("review-page: not a file: ", err)

    def test_section_only_in_old(self):
        "a section the new spec dropped is listed with its statements as removed"
        self.write("drop/34.published.md", V2)
        html = self.build(self.v1, "drop", "34")
        sec = [s for s in data(html) if s["id"] == "security"]
        self.assertEqual(sec[0]["gone"], [{"t": "delta is brand new", "mark": "removed"}])


class Template(support.Case):
    def test_template_and_catalogs(self):
        "untouched rows are demoted by the --muted color, never hidden; the new styles use only theme variables; en and pt-BR carry the labels, other languages show the English"
        tpl = open(os.path.join(support.SCRIPTS, "review-template.html"), encoding="utf-8").read()
        rules = re.findall(r"([^{}]*\.same[^{}]*)\{([^{}]*)\}", tpl)
        body = " ".join(r[1] for r in rules)
        self.assertTrue(rules)
        self.assertIn("color:var(--muted)", body.replace(" ", ""))
        self.assertNotRegex(body, r"opacity|display\s*:\s*none|visibility")
        style = re.search(r"<style>(.*?)</style>", tpl, re.S).group(1)
        added = [l for l in style.splitlines()
                 if re.match(r"^\s*(\.tag|\.item\.same|\.item\.gone|\.item \.was|details\.ro li\.gone|section \.res)\b", l)]
        self.assertGreaterEqual(len(added), 8)
        used = set(re.findall(r"var\(--([a-z-]+)\)", "\n".join(added)))
        self.assertTrue(used and used <= {"page", "sheet", "surface", "ink", "muted", "rule", "body", "mono", "display"}, used)
        self.assertNotRegex("\n".join(l for l in added if "{" in l and ":" in l), r"#[0-9a-fA-F]{3,8}\b|rgba?\(")
        sys.path.insert(0, support.SCRIPTS)
        import dashboard
        en, pt = dashboard.catalog("en"), dashboard.catalog("pt-BR")
        self.assertTrue(all(t in en.values() for t in ("New", "Changed", "Removed", "Before", "Your request")))
        self.assertTrue(any("statements changed since your request" in v for v in en.values()))
        self.assertTrue(any("1 statement changed since your request" in v or ("plural" in v and "statement changed since your request" in v)
                            for v in en.values()))
        self.assertTrue(all(t in pt.values() for t in ("Nova", "Alterada", "Removida", "Antes", "Seu pedido")))
        for n in ("desde o seu pedido", "afirmações mudaram", "afirmação mudou"):
            self.assertTrue(any(n in v for v in pt.values()), n)
        keys = {k for k, v in en.items() if v in ("Your request", "New", "Changed", "Removed")}
        self.assertEqual(len(keys), 4)
        self.assertTrue(all(k in pt for k in keys))
        for code in ("de", "ja", "ru"):
            cat = dashboard.catalog(code)
            self.assertEqual({k: cat.get(k, en[k]) for k in keys}, {k: en[k] for k in keys}, code)
