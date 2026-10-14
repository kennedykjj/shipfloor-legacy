"""brief.sh build in process (shipfloor_core/brief.py, #178): <reviews>/<n>.brief.json, its verdict, flags, proven and
facts computed from the spec, the diff against origin/main and the home's records; the notes give prose only; any
failure is one `brief: skipped: <reason>` line and exit 0."""
import json
import os

from report_support import ReportCase, git
from shipfloor_core import brief

N = "7"
CLEAN_ARCH = "Files: `src/a.txt`."
M = "api/src/main/resources/db/migration"
FIELDS = {"card", "column", "built", "verdict", "what", "flags", "since_request", "proven", "facts", "rest"}


def spec_text(arch, questions="- none", security="n/a"):
    return ("# Spec\n\n## Product\n\n- AC-1 something\n\n## Architecture\n_Tech Lead_\n\n%s\n\n## Security\n_Cybersec_ — %s\n\n"
            "## Rollback\nn/a\n\n## Open questions\n%s\n" % (arch, security, questions))


class Brief(ReportCase):
    def setUp(self):
        super().setUp()
        self.double("gh", "sys.exit(1)")  # gh pr view answers nothing: facts.pr stays empty
        self.home = os.environ["FACTORY_HOME"]
        os.makedirs(os.path.join(self.home, "reviews"))
        self.notes('{"what":"w"}')

    def wt(self, files):
        """A clone of a fresh origin with feat/7-x carrying the files ({path: content})."""
        o = self.fresh("origin")
        git("clone", "-q", "--bare", self.repo(), o)
        w = self.fresh("wt")
        git("clone", "-q", o, w)
        git("-C", w, "checkout", "-q", "-b", "feat/7-x")
        for k, v in files.items():
            self.write(os.path.join(w, k), v + "\n")
        git("-C", w, "add", "-A")
        git("-C", w, "commit", "-qm", "change")
        return w

    def spec(self, *a, **k):
        return self.write("spec-%d.md" % self.n, spec_text(*a, **k))

    def notes(self, text):
        self.notes_path = self.write("home/tmp/%s/brief-notes.json" % N, text)

    def build(self, w, spec, out=None, column="Spec Review", head=None, *more):
        argv = ["build", N, "--column", column, "--spec", spec, "--head", head or git("-C", w, "rev-parse", "HEAD"),
                "--notes", self.notes_path] + (["--out", out] if out else []) + list(more)
        rc, o, err = self.call(brief.main, argv, cwd=w)
        self.assertEqual(rc, 0)
        self.err = err
        p = out or os.path.join(self.home, "reviews", N + ".brief.json")
        return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None

    def pass_record(self, head, gate, name):
        self.write("home/gate-passes/" + name, "2026-10-14T10:00:00Z\t%s\t%s\tmain\n" % (head, gate))

    def kinds(self, b):
        return sorted(f["id"] for f in b["flags"])

    def test_clean_card(self):
        "a clean card gets a routine brief at <reviews>/<n>.brief.json: card, column, what from the notes, proven for the head only, facts from the diff, every field, no temp file"
        w = self.wt({"src/a.txt": "one"})
        head = git("-C", w, "rev-parse", "HEAD")
        self.notes('{"what":"Adds a.txt.","suggestions":{}}')
        self.pass_record(head, "build", "p1")
        self.pass_record("0" * 40, "forbidden", "p2")
        b = self.build(w, self.spec("Files: `src/a.txt`."))
        self.assertIsNotNone(b, self.err)
        self.assertEqual((b["card"], b["column"], b["verdict"]), (7, "Spec Review", "routine"))
        self.assertEqual((b["flags"], b["since_request"]), ([], []))
        self.assertEqual(b["what"], {"text": "Adds a.txt.", "by": "agent"})
        self.assertEqual(b["proven"], ["build"])
        self.assertEqual([b["facts"][k] for k in ("pr", "files", "added", "removed")], ["", 1, 1, 0])
        self.assertTrue(FIELDS <= set(b), FIELDS - set(b))
        self.assertEqual(os.listdir(os.path.join(self.home, "reviews")), [N + ".brief.json"])

    def test_staged_since(self):
        "a Staged card with since_request: column Staged, verdict look, since_request as given, no flag from it"
        w = self.wt({"src/a": "one"})
        since = self.write("since.json", '[{"old":"must be fast","new":"must be fast and cheap"}, 3]')
        b = self.build(w, self.spec("Files: `src/a`."), self.path("o") + "/staged.json", "Staged", None, "--since", since)
        self.assertEqual((b["column"], b["verdict"], b["flags"]), ("Staged", "look", []))
        self.assertEqual(b["since_request"], [{"old": "must be fast", "new": "must be fast and cheap"}])

    def test_each_flag(self):
        "each initial flag type alone raises exactly that flag and the verdict look"
        cases = {
            "migration": ({M + "/V2__add.sql": "ALTER TABLE a ADD COLUMN b text;"},
                          dict(arch="Files: `%s/V2__add.sql`." % M), None),
            "outside-architecture": ({"src/a": "one", "src/b": "two"}, dict(arch="Files: `src/a`."), None),
            "qa-amended": ({"src/a": "one"}, dict(arch="Files: `src/`."), "qa"),
            "open-question": ({"src/a": "one"}, dict(arch="Files: `src`.", questions="- Should the limit be 10 or 20?"), None),
            "security": ({"src/a": "one"}, dict(arch="Files: `src/a`.", security="Tokens are stored hashed; the endpoint checks the owner."), None),
            "infra-retry": ({"src/a": "one"}, dict(arch="Files: `src/a`."), "infra"),
        }
        for kind, (files, spec, extra) in cases.items():
            for d in ("tmp/%s/report.json" % N, "infra/" + N):
                p = os.path.join(self.home, d)
                if os.path.exists(p):
                    os.remove(p)
            if extra == "qa":
                self.write("home/tmp/%s/report.json" % N, '{"issue":7,"amendments":["scripts/test/x.test.sh: asked for an element"]}')
            if extra == "infra":
                self.write("home/infra/" + N, "")
            w = self.wt(files)
            b = self.build(w, self.spec(**spec), self.path("o") + "/%s.json" % kind)
            self.assertIsNotNone(b, kind + ": " + self.err)
            self.assertEqual((self.kinds(b), b["verdict"]), ([kind], "look"), kind)
            if kind == "outside-architecture":
                self.assertIn("src/b", json.dumps(b["flags"]))
                self.assertNotIn("src/a,", json.dumps(b["flags"]))

    def test_red_security_marker(self):
        "a security section of n/a still flags when it carries the red marker"
        w = self.wt({"src/a": "one"})
        b = self.build(w, self.spec("Files: `src/a`.", security="n/a \U0001F534"), self.path("o") + "/r.json")
        self.assertEqual(self.kinds(b), ["security"])

    def test_notes_are_prose_only(self):
        "verdict, flags, proven and since_request in the notes are ignored; a what over 280 characters is cut; unknown flag ids appear nowhere"
        self.notes(json.dumps({"what": "w" * 400, "verdict": "look", "flags": [{"id": "security", "kind": "security"}],
                               "proven": ["fake-gate"], "since_request": [{"old": "a", "new": "b"}],
                               "suggestions": {"bogus-flag": "do it", "security": "do it"}}))
        b = self.build(self.wt({"src/a": "one"}), self.spec("Files: `src/a`."), self.path("o") + "/n1.json")
        self.assertEqual((b["verdict"], b["flags"], b["since_request"]), ("routine", [], []))
        self.assertNotIn("fake-gate", b["proven"])
        self.assertEqual(b["what"]["text"], "w" * 280)
        self.notes(json.dumps({"what": "w", "verdict": "routine", "flags": [], "proven": ["fake-gate"],
                               "suggestions": {"bogus-flag": "x", "open-question": "s" * 300}}))
        b = self.build(self.wt({"src/a": "one"}), self.spec("Files: `src/a`.", questions="- Should the limit be 10 or 20?"),
                       self.path("o") + "/n2.json")
        self.assertEqual((self.kinds(b), b["verdict"]), (["open-question"], "look"))
        self.assertNotIn("fake-gate", b["proven"])
        self.assertEqual(b["flags"][0]["suggestion"], "s" * 120)
        self.assertNotIn("bogus-flag", json.dumps(b))

    def test_bad_notes(self):
        "notes that are missing or not an object give an empty what, never a failure"
        w = self.wt({"src/a": "one"})
        self.notes("[1, 2]")
        self.assertEqual(self.build(w, self.spec("Files: `src/a`."), self.path("o") + "/a.json")["what"]["text"], "")
        self.notes_path = self.path("o") + "/none.json"
        self.assertEqual(self.build(w, self.spec("Files: `src/a`."), self.path("o") + "/b.json")["what"]["text"], "")

    def skipped(self, label, out):
        self.assertEqual(len(self.err.splitlines()), 1, label + ": " + self.err)
        self.assertRegex(self.err, r"^brief: skipped: \S", label)
        self.assertFalse(os.path.exists(out), label)

    def test_failures_are_one_line(self):
        "a failing run is one 'brief: skipped: <reason>' line on stderr and exit 0, and writes nothing"
        w = self.wt({"src/a": "one"})
        good = self.spec("Files: `src/a`.")
        out = self.path("o") + "/f.json"
        self.build(w, self.path("o") + "/does-not-exist.md", out)
        self.skipped("a missing spec", out)
        self.build(w, good, out, "No Such Column")
        self.skipped("an unknown column", out)
        self.assertIn("unknown column No Such Column", self.err)
        self.build(w, good, out, "Staged", "abc")
        self.skipped("an unknown head (git diff fails)", out)
        self.build(self.path("nogit"), good, out, "Staged", "abc")
        self.skipped("outside a git repository", out)
        self.build(w, good, self.write("is-a-file", "") + "/x/y.json", "Staged")
        self.skipped("an unwritable --out", os.path.join(self.tmp, "is-a-file", "x", "y.json"))
        self.assertIn("cannot write", self.err)
        b = self.build(w, good, self.path("o") + "/s.json", "Staged", None, "--since", self.path("o") + "/does-not-exist.json")
        self.assertEqual((self.err, b["since_request"]), ("", []))
        for argv in ([], ["nope"], ["build"], ["build", N, "--column"], ["build", N, "--bogus", "x"],
                     ["build", N, "--column", "Staged", "--spec", good]):
            rc, o, err = self.call(brief.main, argv, cwd=w)
            self.assertEqual(rc, 0, argv)
            self.assertRegex(err, r"^brief: skipped: \S[^\n]*\n$", argv)
        del os.environ["FACTORY_HOME"]
        self.build(w, good, out, "Staged")
        self.skipped("no FACTORY_HOME", out)
