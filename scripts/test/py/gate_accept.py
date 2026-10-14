"""The gates around QA's acceptance tests (shipfloor_core/gate/acceptance.py) on temp repos: acceptance-intact and its
allow paths (unchanged, only what main brought, both sides kept, the owner's record, acceptance_assertions),
acceptance-own's key, qa-commit and qa-amend."""
import os
import subprocess

import gate_support as gs

TF = "api/src/test/SharedTest.kt"
BLOCKED = ("acceptance-intact: acceptance tests changed after the QA commit (beyond what merges from main brought):\n")
OFFER = "acceptance-intact: the owner can review these files and record them as they stand: shipfloor accept <project> <n> <reason>\n"


class AcceptCase(gs.GateCase):
    def shared(self, *lines):
        self.lines(TF, "class SharedTest {", *lines, "}")

    def intact(self, qa, want, **env):
        return self.expect(want, "acceptance-intact", qa, **env)

    def accept(self, path, key):
        """The owner's record (what shipfloor accept writes) in FACTORY_HOME/accepted.tsv."""
        self.write("home/accepted.tsv", "%s\t%s\t#8\t2026-10-10\treviewed\n" % (path, key))

    def merged_card(self):
        """feat/7-x (QA adds acceptance7) merged with main (which added fromMain); sets self.qa, self.c_base, self.c_main."""
        self.repo()
        self.shared("  fun old1() {}", "", "  fun old2() {}", "", "  fun old3() {}")
        self.c_base = self.commit("shared")
        self.git("checkout", "-q", "-b", "feat/7-x")
        self.shared("  fun old1() {}", "", "  fun old2() {}", "", "  fun old3() {}", "", "  fun acceptance7() { check() }")
        self.qa = self.commit("test(x): acceptance tests for #7", add=False)
        self.git("checkout", "-q", "main")
        self.shared("  fun old1() {}", "", "  fun fromMain() {}", "", "  fun old2() {}", "", "  fun old3() {}")
        self.c_main = self.commit("main adds a test", add=False)
        self.git("checkout", "-q", "feat/7-x")
        self.git("merge", "-q", "--no-edit", "main")

    def conflicted_card(self, n, qa_line, main_line, resolved):
        """QA and main edit the same spot; the merge is resolved by hand into `resolved` lines. Sets self.qa."""
        self.repo()
        self.shared("  fun a() { one() }" if n == 8 else "  fun old() {}")
        self.commit("shared")
        self.git("checkout", "-q", "-b", "feat/%d-x" % n)
        self.shared(*qa_line)
        self.qa = self.commit("test(x): acceptance tests for #%d" % n, add=False)
        self.git("checkout", "-q", "main")
        self.shared(*main_line)
        self.commit("main edits the same spot", add=False)
        self.git("checkout", "-q", "feat/%d-x" % n)
        self.git("merge", "-q", "--no-edit", "main", check=False)
        self.shared(*resolved)
        self.commit("resolved")


class Intact(AcceptCase):
    def test_plain_cases(self):
        "acceptance-intact: intact passes; an uncommitted edit, a staged delete or a change restored on disk blocks, named"
        self.repo()
        self.put("api/src/test/ATest.kt", "test\n")
        qa = self.commit("qa")
        self.put("api/Impl.kt", "impl\n")
        self.commit("impl")
        self.intact(qa, 0)
        self.put("api/src/test/ATest.kt", "weakened\n")
        r = self.intact(qa, 1)
        self.assertEqual(r.err, BLOCKED + "api/src/test/ATest.kt\n" + OFFER + "gate acceptance-intact: FAIL (exit 1)\n")
        self.git("checkout", "-q", "--", "api/src/test/ATest.kt")
        self.git("rm", "-q", "api/src/test/ATest.kt")
        self.intact(qa, 1)
        self.git("reset", "-q", "--hard", "HEAD")
        self.git("commit", "-q", "--allow-empty", "-m", "empty")
        self.intact(qa, 0)
        self.git("commit", "-q", "--allow-empty", "-m", "test(x): acceptance tests for #50")
        empty = self.head()
        self.assertIn("acceptance-intact: QA commit %s has no files" % empty, self.intact(empty, 1).err)
        self.repo()
        self.put("api/src/test/ATest.kt", "good\n")
        qa = self.commit("qa")
        self.put("api/src/test/ATest.kt", "weak\n")
        self.commit("weaken")
        self.put("api/src/test/ATest.kt", "good\n")
        self.intact(qa, 1)
        self.expect(2, "acceptance-intact", "")
        self.expect(2, "acceptance-intact", "deadbeef")

    def test_main_merge(self):
        "acceptance-intact: what a clean merge from main brought is not the card's edit; origin/main first, then FACTORY_MAIN"
        self.merged_card()
        self.assertIn("fromMain", open(TF).read())
        self.intact(self.qa, 0)
        cases = []
        self.git("update-ref", "refs/remotes/origin/main", self.c_main)
        cases.append(("origin/main at the same commit", 0, {}))
        got = [(label, want, self.gate("acceptance-intact", self.qa, **env).code) for label, want, env in cases]
        self.git("update-ref", "refs/remotes/origin/main", self.c_base)
        got.append(("a stale origin/main is preferred to the local main: main brought nothing", 1,
                    self.gate("acceptance-intact", self.qa).code))
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.git("branch", "-q", "-m", "main", "trunk")
        got.append(("no branch called main: the merge is not recognized", 1, self.gate("acceptance-intact", self.qa).code))
        got.append(("FACTORY_MAIN=trunk: the local trunk is main", 0,
                    self.gate("acceptance-intact", self.qa, FACTORY_MAIN="trunk").code))
        self.git("update-ref", "refs/remotes/origin/trunk", self.c_main)
        got.append(("FACTORY_MAIN=trunk: origin/trunk is found too", 0,
                    self.gate("acceptance-intact", self.qa, FACTORY_MAIN="trunk").code))
        got.append(("FACTORY_MAIN=other: no such branch", 1, self.gate("acceptance-intact", self.qa, FACTORY_MAIN="other").code))
        self.assertEqual([g for g in got if g[1] != g[2]], [])

    def test_own_edit_after_merge(self):
        "acceptance-intact: the card's own edit on top of a merge from main still blocks, the file named"
        self.merged_card()
        self.put(TF, open(TF).read().replace("fun acceptance7() { check() }", "fun acceptance7() { }"))
        self.commit("weaken")
        self.assertIn("SharedTest.kt", self.intact(self.qa, 1).err)

    def test_both_sides_kept(self):
        "acceptance-intact: a hand resolution keeping both appended hunks whole passes in either order; changing either side does not"
        qa_side = ("  fun old() {}", "", "  fun acceptance12() { check() }")
        main_side = ("  fun old() {}", "", "  fun fromMain() { other() }")
        for resolved in [("  fun old() {}", "", "  fun acceptance12() { check() }", "", "  fun fromMain() { other() }"),
                         ("  fun old() {}", "", "  fun fromMain() { other() }", "", "  fun acceptance12() { check() }")]:
            self.conflicted_card(12, qa_side, main_side, resolved)
            self.intact(self.qa, 0)
        bad = []
        for label, lines in [("a changed line of QA's side", ("  fun old() {}", "", "  fun fromMain() { other() }", "", "  fun acceptance12() { }")),
                             ("a changed line of main's side", ("  fun old() {}", "", "  fun fromMain() { }", "", "  fun acceptance12() { check() }")),
                             ("a line both sides had dropped", ("  fun fromMain() { other() }", "", "  fun acceptance12() { check() }"))]:
            self.shared(*lines)
            self.commit(label)
            if self.gate("acceptance-intact", self.qa).code != 1:
                bad.append(label)
        self.assertFalse(bad, "passed: %s" % bad)

    def test_owner_record(self):
        "acceptance-intact: a hand-resolved merge passes only with the owner's record of that exact blob in FACTORY_HOME"
        self.conflicted_card(8, ("  fun a() { qa() }",), ("  fun a() { main() }",), ("  fun a() { main() }",))
        self.intact(self.qa, 1)
        self.accept(TF, self.head("HEAD:" + TF))
        self.intact(self.qa, 0)
        r = self.intact(self.qa, 1, FACTORY_HOME=None)
        self.assertIn(TF, r.err)
        self.assertEqual(r.last, "gate acceptance-intact: FAIL (exit 1)")
        self.accept("api/src/test/Gone.kt", "deleted")
        self.intact(self.qa, 1)
        self.accept(TF, self.head("HEAD:" + TF))
        self.shared("  fun a() { edited-later() }")
        self.commit("edit after")
        self.intact(self.qa, 1)

    def test_deleted_stub(self):
        "acceptance-intact: a QA file the card deleted blocks until the owner records the deletion; an uncommitted delete still blocks"
        self.repo()
        self.put("api/src/test/ATest.kt", "test\n")
        self.put("api/src/test/RedStubs.kt", "stub\n")
        qa = self.commit("qa")
        self.git("rm", "-q", "api/src/test/RedStubs.kt")
        self.commit("the real class replaces the stub", add=False)
        self.assertIn("api/src/test/RedStubs.kt", self.intact(qa, 1).err)
        self.accept("api/src/test/RedStubs.kt", "deleted")
        self.intact(qa, 0)
        os.unlink("api/src/test/ATest.kt")
        self.intact(qa, 1)

    def test_acceptance_assertions(self):
        "acceptance-intact: with acceptance_assertions an edit that moves no assertion line passes and says why; others block"
        self.repo()
        self.git("checkout", "-q", "-b", "feat/10-x")
        self.shared("  fun a() {", "    val s = Service(repo)", "    assertEquals(1, s.count())", "  }")
        qa = self.commit("test(x): acceptance tests for #10")
        self.shared("  fun a() {", "    val s = Service(repo, clock)", "    assertEquals(1, s.count())", "  }")
        self.commit("adapt to the constructor main changed")
        self.intact(qa, 1)
        cfg = self.config("acceptance_assertions: 'assert|expect\\('", use=False)
        r = self.intact(qa, 0, FACTORY_CONFIG=cfg)
        self.assertIn("acceptance-intact: %s changed, but no assertion line did (acceptance_assertions); passed" % TF, r.err)
        self.intact(qa, 1, FACTORY_CONFIG=self.config("acceptance_assertions: '('", use=False))
        self.shared("  fun a() {", "    val s = Service(repo, clock)", "    assertEquals(0, s.count())", "  }")
        self.commit("weaken the assertion")
        self.intact(qa, 1, FACTORY_CONFIG=cfg)
        self.shared("  fun a() {", "    val s = Service(repo, clock)", "  }")
        self.commit("drop the assertion")
        self.intact(qa, 1, FACTORY_CONFIG=cfg)

    def test_every_qa_commit(self):
        "acceptance-intact: the newest QA commit is the baseline, and files only an earlier QA commit wrote stay protected"
        self.repo()
        self.git("checkout", "-q", "-b", "feat/5-x")
        self.put("api/src/test/ATest.kt", "a\n")
        self.put("api/src/test/BTest.kt", "b\n")
        self.commit("test(x): acceptance tests for #5")
        self.put("api/src/test/ATest.kt", "a\nmore\n")
        qa5 = self.commit("test(x): acceptance tests for #5")
        self.intact(qa5, 0)
        self.put("api/src/test/BTest.kt", "c\n")
        self.commit("edit a file the amendment did not touch")
        self.assertIn("api/src/test/BTest.kt", self.intact(qa5, 1).err)


class Own(AcceptCase):
    def test_own_key(self):
        "acceptance-own: 'own:' + the hash of the card's own diff lines; a record of it passes, a merge from main elsewhere keeps it"
        self.repo()
        self.shared("  fun a() { one() }", "", "  fun m() {}", "", "  fun z() {}")
        self.commit("shared")
        self.git("checkout", "-q", "-b", "feat/11-x")
        self.shared("  fun a() { qa() }", "", "  fun m() {}", "", "  fun z() {}")
        qa = self.commit("test(x): acceptance tests for #11", add=False)
        self.shared("  fun a() { adapted() }", "", "  fun m() {}", "", "  fun z() {}")
        self.commit("the card adapts its own test", add=False)
        want = "own:" + subprocess.run(["git", "hash-object", "--stdin"], input=b"<   fun a() { qa() }\n>   fun a() { adapted() }\n",
                                       stdout=subprocess.PIPE).stdout.decode().strip()
        self.assertEqual(self.expect(0, "acceptance-own", qa, TF).out, want + "\n")
        self.intact(qa, 1)
        self.accept(TF, want)
        self.intact(qa, 0)
        self.git("checkout", "-q", "main")
        self.shared("  fun a() { one() }", "", "  fun m() {}", "", "  fun z() {}", "", "  fun fromMain() {}")
        self.commit("main adds a test", add=False)
        self.git("checkout", "-q", "feat/11-x")
        self.git("merge", "-q", "--no-edit", "main")
        self.assertIn("fromMain", open(TF).read())
        self.intact(qa, 0)
        self.assertEqual(self.gate("acceptance-own", qa, TF).out, want + "\n")
        self.put(TF, open(TF).read().replace("adapted()", "weakened()"))
        self.commit("edit after the owner accepted")
        self.intact(qa, 1)
        other = self.gate("acceptance-own", qa, TF).out
        self.assertTrue(other.startswith("own:") and other != want + "\n", other)
        r = self.gate("acceptance-own", qa, "api/src/test/Nope.kt")
        self.assertEqual((r.code, r.out), (1, ""))


class QaCommit(AcceptCase):
    def test_qa_commit(self):
        "qa-commit prints the newest 'acceptance tests for #<n>' (#142 is not #14); --head wants it last; a rework replaces it"
        self.repo()
        self.git("checkout", "-q", "-b", "feat/14-x")
        self.table([("no number", 2, ("qa-commit",)), ("not a number", 2, ("qa-commit", "x"), "usage: gate.sh qa-commit <n> [--head]")])
        self.put("api/src/test/OtherTest.kt")
        self.commit("test(x): acceptance tests for #142")
        r = self.expect(1, "qa-commit", "14")
        self.assertIn('qa-commit: no commit message with "acceptance tests for #14"', r.err)
        self.put("api/src/test/ATest.kt", "t\n")
        q1 = self.commit("test(x): acceptance tests for #14")
        self.assertEqual(self.expect(0, "qa-commit", "14").out, q1 + "\n")
        self.assertEqual(self.expect(0, "qa-commit", "14", "--head").out, q1 + "\n")
        self.put("api/Impl.kt", "impl\n")
        self.commit("impl")
        self.assertEqual(self.expect(0, "qa-commit", "14").out, q1 + "\n")
        r = self.expect(1, "qa-commit", "14", "--head")
        self.assertIn('qa-commit: the last commit is not the QA commit: no commit message with "acceptance tests for #14" at HEAD', r.err)
        self.put("api/src/test/ATest.kt", "t2\n")
        q2 = self.commit("test(x): acceptance tests for #14", add=False)
        self.assertEqual(self.expect(0, "qa-commit", "14", "--head").out, q2 + "\n")
        self.put("api/src/test/ATest.kt", "t3\n")
        self.commit("test(x): one world per state for #14", add=False)
        self.assertIn("acceptance tests for #14", self.expect(1, "qa-commit", "14", "--head").err)


ATEST = "api/src/test/ATest.kt"
MARKS = ['describe.only("a", fn)', 'it.skip("a", fn)', 'test.fixme("a", fn)', 'it.todo("a")', "@Ignore", "@Disabled",
         'xit("a") {}', 'xdescribe("a") {}', 'xtest("a") {}', 't.Skip("later")', "@pytest.mark.skip"]


class QaAmend(AcceptCase):
    def setUp(self):
        super().setUp()
        self.repo()
        self.git("checkout", "-q", "-b", "feat/5-x")
        self.lines(ATEST, "fun a() {", "  assertEquals(1, one())", "  assertTrue(ok())", "}")
        self.put("api/src/test/BTest.kt", "fun b() { assertTrue(b()) }\n")
        self.commit("test(x): acceptance tests for #5")

    def impl(self):
        self.put("api/Impl.kt", "impl\n")
        self.pre = self.commit("feat(api): impl")

    def amend(self, *lines, edit=None):
        """QA commits again: lines appended to ATest.kt, or edit(text) -> text."""
        text = open(ATEST).read()
        text = edit(text) if edit else text + "".join(l + "\n" for l in lines)
        self.put(ATEST, text)
        return self.commit("test(x): acceptance tests for #5", add=False)

    def back(self):
        self.git("reset", "-q", "--hard", self.pre)

    def says(self, want_code, text, **env):
        r = self.gate("qa-amend", "5", **env)
        return r if (r.code != want_code or text not in r.err) else None

    def test_needs_an_amendment(self):
        "qa-amend: one QA commit is nothing amended; a last commit that is not QA's is refused"
        self.assertIn("qa-amend: #5 has one QA commit, so nothing was amended", self.expect(1, "qa-amend", "5").err)
        self.impl()
        self.assertIn('qa-amend: the last commit is not a QA commit ("acceptance tests for #5")', self.expect(1, "qa-amend", "5").err)

    def test_checks_differently_not_less(self):
        "qa-amend: an amendment may check differently (the keep regex counts lines), never less"
        self.impl()
        bad = []
        cases = [
            ("checks differently", lambda t: t.replace("assertEquals(1, one())", "assertEquals(1, oneTrimmed())"), (), 0,
             "qa-amend: ok, 1 assertion lines replaced by 1"),
            ("drops an assertion", lambda t: t.replace("  assertTrue(ok())\n", ""), (), 1,
             "qa-amend: the amendment removes 1 assertion lines and adds 0; an amended test may check differently, not less"),
            ("verify( expect( should count", None, ("verify(repo).save(x)", "expect(a).toBe(1)", "it should work"), 0,
             "qa-amend: ok, 0 assertion lines replaced by 3"),
            ("no assertion line at all", None, ("// plain comment",), 0, "qa-amend: ok, 0 assertion lines replaced by 0"),
            ("mentions of skipping", None, ("val skipped = 1", "// xit is a switched-off test in some runners"), 0, "qa-amend: ok"),
        ]
        for label, edit, lines, code, text in cases:
            self.amend(*lines, edit=edit)
            r = self.says(code, text)
            if r:
                bad.append("%s: %r" % (label, r))
            self.back()
        swap = lambda t: t.replace("  assertTrue(ok())\n", "") + "  check(ok())\n"
        self.amend(edit=swap)
        r = self.says(1, "removes 1 assertion lines and adds 0")
        if r:
            bad.append("an assertion swapped for a line the default regex misses: %r" % r)
        r = self.says(0, "qa-amend: ok, 0 assertion lines replaced by 1", FACTORY_CONFIG=self.config("acceptance_assertions: 'check\\('", use=False))
        if r:
            bad.append("acceptance_assertions is the keep regex: %r" % r)
        self.assertFalse(bad, "\n".join(bad))

    def test_amended_baseline(self):
        "qa-amend: a passing amendment is the QA commit acceptance-intact protects from then on"
        self.impl()
        self.amend(edit=lambda t: t.replace("assertEquals(1, one())", "assertEquals(1, oneTrimmed())"))
        self.expect(0, "qa-amend", "5")
        qa = self.gate("qa-commit", "5").out.strip()
        self.assertEqual(qa, self.head())
        self.intact(qa, 0)
        self.put("api/src/test/BTest.kt", "fun b() { }\n")
        self.commit("feat(api): edits a test the amendment did not touch", add=False)
        self.intact(qa, 1)

    def test_only_tests_and_none_switched_off(self):
        "qa-amend: an amendment touching a file that is no test, or switching a test off (every runner's way), is refused"
        self.impl()
        self.put("api/Impl.kt", "impl\nx\n")
        self.amend("// note")
        r = self.expect(1, "qa-amend", "5")
        self.assertIn("qa-amend: the amendment touches files that are not tests:\napi/Impl.kt\n", r.err)
        self.back()
        bad = []
        for mark in MARKS:
            self.amend(mark)
            r = self.gate("qa-amend", "5")
            if r.code != 1 or "qa-amend: the amendment switches a test off:\n" not in r.err or mark not in r.err:
                bad.append("%s: %r" % (mark, r))
            self.back()
        self.assertFalse(bad, "\n".join(bad))

    def test_at_most_twice(self):
        "qa-amend: a card is amended at most FACTORY_QA_AMEND_MAX times (2 by default); then the owner decides"
        self.impl()
        self.amend("// one")
        rows = [("one, default", 0, {}), ("one, MAX=1", 0, {"FACTORY_QA_AMEND_MAX": "1"}),
                ("one, MAX=0", 1, {"FACTORY_QA_AMEND_MAX": "0"}, "the acceptance tests of #5 were already amended 0 times; the owner decides now")]
        got = []
        for row in rows:
            r = self.gate("qa-amend", "5", **row[2])
            got.append(r.code == row[1] and (len(row) < 4 or row[3] in r.err) or (row[0], r))
        self.amend("// two")
        for env, code, text in [({}, 0, ""), ({"FACTORY_QA_AMEND_MAX": "1"}, 1, "already amended 1 times")]:
            r = self.gate("qa-amend", "5", **env)
            got.append((r.code == code and text in r.err) or ("two", env, r))
        self.amend("// three")
        r = self.gate("qa-amend", "5")
        got.append((r.code == 1 and "qa-amend: the acceptance tests of #5 were already amended 2 times; the owner decides now" in r.err) or ("three", r))
        got.append(self.gate("qa-amend", "5", FACTORY_QA_AMEND_MAX="3").code == 0 or "three, MAX=3")
        r = self.gate("qa-amend", "5", FACTORY_LANGUAGE="pt-BR")
        got.append((r.code == 1 and "agora o owner decide" in r.err) or ("pt-BR", r))
        self.assertEqual([g for g in got if g is not True], [])

    def test_usage(self):
        "qa-amend: a number that is no number, or none, is a usage error (exit 2) naming gate.sh"
        self.table([("x", 2, ("qa-amend", "x"), "usage: gate.sh qa-amend <n>"), ("5x", 2, ("qa-amend", "5x")),
                    ("none", 2, ("qa-amend",))])
        self.assertEqual(self.gate("qa-amend", "x").last, "gate qa-amend: FAIL (exit 2)")
