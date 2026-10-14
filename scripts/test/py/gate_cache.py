"""The pass cache of build and green (shipfloor_core/gate/run.py: pass_key, pass_reused, pass_record, code_hash): a pass
recorded on a clean tree answers the same gate on the same inputs. Whether a command ran is counted by marks it leaves
outside the repository, never read from the output."""
import os
import re
import shutil
import subprocess
import time
from unittest import mock

import gate_support as gs
from shipfloor_core.gate import run as run_mod

REUSED = re.compile(r"^(build|green): reused the pass on ([0-9a-f]{12}) recorded "
                    r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z); nothing ran$")
STAMP = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


def hash_object(data=None, path=None):
    argv = ["git", "hash-object"] + (["--no-filters", "--", path] if path else ["--stdin"])
    return subprocess.run(argv, input=data, stdout=subprocess.PIPE).stdout.decode().strip()


class CacheCase(gs.GateCase):
    def setUp(self):
        super().setUp()
        del os.environ["SHIPFLOOR_GATE_FRESH"]  # this suite tests the cache
        fail = os.path.join(self.tmp, "failflag")
        self.failflag = fail
        self.config(replace=[
            ("""    build: '"${FACTORY_PNPM:-pnpm}" exec tsc --noEmit && "${FACTORY_PNPM:-pnpm}" test'\n""",
             "    build: '%s; [ ! -e \"%s\" ]'\n" % (self.mark("build"), fail)),
            ("""    test: '"${FACTORY_PNPM:-pnpm}" exec vitest run {selector}'\n""",
             "    test: '%s; echo \" Tests  1 passed (1)\"'\n" % self.mark("green"))])
        self.repo()
        self.base = self.head()
        self.put("web/a.ts")
        self.put("web/a.test.ts", "t\n")
        self.c1 = self.commit("c1")
        self.put("web/c.ts", "y\n")
        self.headsha = self.commit("c2")

    def store(self):
        d = os.path.join(os.environ["FACTORY_HOME"], "gate-passes")
        return sorted(n for n in os.listdir(d) if n != ".code") if os.path.isdir(d) else []

    def build(self, base=None, **env):
        return self.gate("build", base or self.base, **env)

    def green(self, sel="web/a.test.ts", **env):
        return self.gate("green", "web", sel, **env)


class Reuse(CacheCase):
    def test_same_call_reuses(self):
        "the same build on the same commit answers from the recorded pass: it says so with the commit and time, then passes"
        r1 = self.build()
        self.assertEqual((r1.code, self.count("build")), (0, 1))
        self.assertNotIn("reused the pass", r1.err)
        r2 = self.build()
        self.assertEqual((r2.code, self.count("build"), r2.out), (0, 1, ""))
        first, verdict = r2.err.rstrip("\n").split("\n")
        m = REUSED.match(first)
        self.assertTrue(m and m.group(1) == "build" and m.group(2) == self.headsha[:12], r2)
        self.assertEqual(verdict, "gate build: pass")
        (rec,) = self.store()
        fields = open(os.path.join(os.environ["FACTORY_HOME"], "gate-passes", rec)).read().rstrip("\n").split("\t")
        self.assertEqual(fields[1:3], [self.headsha, "build"])
        self.assertEqual(m.group(3), fields[0])

    def test_fresh(self):
        "SHIPFLOOR_GATE_FRESH=1 runs the command although a pass is recorded, and records nothing"
        self.green()
        n = len(self.store())
        self.assertNotIn("reused", self.green(SHIPFLOOR_GATE_FRESH="1").err)
        self.assertEqual((self.count("green"), len(self.store())), (2, n))

    def test_inputs_in_the_key(self):
        "another commit, another base, a moved origin/main or a changed config makes the build run again"
        self.build()
        self.put("web/d.ts", "z\n")
        self.commit("c3")
        self.build()
        self.assertEqual(self.count("build"), 2, "another commit")
        self.build(self.c1)
        self.assertEqual(self.count("build"), 3, "another base")
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.build()
        self.git("update-ref", "refs/remotes/origin/main", self.headsha)
        self.build()
        self.assertEqual(self.count("build"), 5, "origin/main moved")
        self.build()
        self.assertEqual(self.count("build"), 5, "origin/main unchanged reuses")
        with open(os.environ["FACTORY_CONFIG"], "a") as f:
            f.write("# changed\n")
        self.build()
        self.assertEqual(self.count("build"), 6, "the config changed")

    def test_failure_never_reused(self):
        "a failed build records nothing and is never reused; once the command passes the build passes"
        open(self.failflag, "w").close()
        self.assertEqual([self.build().code, self.build().code], [1, 1])
        self.assertEqual((self.count("build"), self.store()), (2, []))
        os.unlink(self.failflag)
        self.assertEqual((self.build().code, self.count("build")), (0, 3))

    def test_green_per_selector(self):
        "green reuses per selector: another selector runs its own tests and records its own pass"
        self.green()
        r = self.green()
        self.assertEqual((r.code, self.count("green")), (0, 1))
        self.assertRegex(r.err, r"^green: reused the pass on %s recorded " % self.headsha[:12])
        self.green("web/other.test.ts")
        self.green("web/other.test.ts")
        self.assertEqual(self.count("green"), 2)

    def test_dirty_worktree(self):
        "a tracked change or an untracked file runs the gate every time and records nothing"
        self.build()
        self.put("web/a.ts", "x\nmore\n")
        self.build()
        self.assertEqual(self.count("build"), 2)
        self.git("checkout", "-q", "--", "web/a.ts")
        self.put("web/new.ts")
        n = len(self.store())
        self.build()
        self.assertEqual((self.count("build"), len(self.store())), (3, n))
        os.unlink("web/new.ts")
        shutil.rmtree(os.path.join(os.environ["FACTORY_HOME"], "gate-passes"))
        self.put("web/a.ts", "x\nmore\n")
        self.build()
        self.assertEqual(self.store(), [])
        self.git("checkout", "-q", "--", "web/a.ts")
        self.build()
        self.assertEqual(self.count("build"), 5, "a dirty run recorded a pass")

    def test_store_outside_the_worktree(self):
        "passes copied inside the worktree are not believed; a store inside it (even through a symlink) is never used"
        self.build()
        legit = os.path.join(os.environ["FACTORY_HOME"], "gate-passes")
        os.environ["FACTORY_HOME"] = self.path("home2")
        exclude = open(".git/info/exclude", "a")
        for d in ("gate-passes", ".shipfloor/gate-passes", ".shipfloor/projects/x/gate-passes"):
            shutil.copytree(legit, d)
            exclude.write("/%s/\n" % d.split("/")[0])
        exclude.write("/.home/\n/.home2/\n")
        exclude.close()
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.build()
        self.assertEqual((self.count("build"), len(self.store())), (2, 1))
        inside = os.path.join(os.getcwd(), ".home")
        os.makedirs(inside)
        self.build(FACTORY_HOME=inside)
        self.build(FACTORY_HOME=inside)
        self.assertEqual(self.count("build"), 4)
        self.assertFalse(os.listdir(os.path.join(inside, "gate-passes")) if os.path.isdir(os.path.join(inside, "gate-passes")) else [])
        os.makedirs(".home2")
        link = os.path.join(self.tmp, "link-to-repo")
        os.symlink(os.getcwd(), link)
        self.green(FACTORY_HOME=os.path.join(link, ".home2"))
        self.assertFalse(os.path.isdir(".home2/gate-passes") and os.listdir(".home2/gate-passes"))

    def test_no_home(self):
        "with FACTORY_HOME unset or empty the gate runs every time, never reuses, records nothing and still says its verdict"
        for env in ({"FACTORY_HOME": None}, {"FACTORY_HOME": ""}):
            r1, r2 = self.build(**env), self.build(**env)
            self.assertEqual((r1.code, r2.code, r2.last), (0, 0, "gate build: pass"), env)
            self.assertNotIn("reused", r2.err)
            self.assertEqual(self.green(**env).code, 0)
        self.assertEqual(self.count("build"), 4)
        self.assertEqual(self.store(), [])
        self.assertFalse(os.path.exists("gate-passes") or os.path.exists("/gate-passes"))

    def test_static_gates_never_cache(self):
        "fast and forbidden run every time and record nothing; a build on a commit with no record runs"
        r1 = self.gate("fast", self.base, "/dev/null")
        r2 = self.gate("fast", self.base, "/dev/null")
        self.assertEqual(r1.code, r2.code)
        self.assertNotIn("reused", r2.err)
        self.gate("forbidden", self.base)
        r = self.gate("forbidden", self.base)
        self.assertEqual(r.code, 0)
        self.assertNotIn("reused", r.err)
        self.assertEqual(self.store(), [])
        self.put("docs/engineering/x.md", "f\n")
        self.commit("forbidden")
        self.expect(1, "forbidden", self.base)
        self.expect(0, "build", self.base)
        self.assertEqual(self.count("build"), 1)


class OnAStack(CacheCase):
    def test_reuse_before_install_and_stack(self):
        "a reused green on a needs_stack layer with an install runs no install and takes no slot"
        self.sh("lsof", "exit 0")
        self.write("shome/config.yml", "stacks: 1\nports: {base: 26400, span: 10}\nstack_wait: 5\nstack_stale: 90\nstack_hold_max: 2700\n")
        cfg = os.environ["FACTORY_CONFIG"]
        text = open(cfg).read().replace('stack: {url: "http://localhost:3000"}\n',
                                        "stack: {up: '%s', down: 'true', ports: [web], url: 'http://localhost:{web}'}\n" % self.mark("up"))
        text = text.replace("""    test: '"${FACTORY_PNPM:-pnpm}" exec playwright test {selector}'\n""",
                            "    test: '%s; echo \" 1 passed\"'\n    install: '%s'\n" % (self.mark("e2e"), self.mark("install")))
        with open(cfg, "w") as f:
            f.write(text)
        self.green()
        self.gate("green", "e2e", "web/e2e/a.spec.ts")
        self.build()
        before = [self.count(m) for m in ("build", "green", "e2e", "install", "up")]
        self.assertEqual(before, [1, 1, 1, 1, 1])
        for argv in (("green", "web", "web/a.test.ts"), ("green", "e2e", "web/e2e/a.spec.ts"), ("build", self.base)):
            r = self.expect(0, *argv)
            self.assertRegex(r.err, r"^%s: reused the pass on %s recorded [^\n]*; nothing ran\ngate %s: pass\n$"
                             % (argv[0], self.headsha[:12], argv[0]))
            self.assertEqual(r.out, "")
        self.assertEqual([self.count(m) for m in ("build", "green", "e2e", "install", "up")], before)
        self.assertRegex(self.gate("stack", "status").out, r"^0\tfree")


class Record(CacheCase):
    def test_key_and_record(self):
        "a record is one line '<UTC time> <HEAD> <gate> <args>' in a file named by the hash of HEAD, gate, inputs, config and gate.sh"
        self.build()
        self.green()
        self.assertEqual(len(self.store()), 2)
        cfg_h = hash_object(path=os.environ["FACTORY_CONFIG"])
        me_h = hash_object(path=os.path.join(gs.support.SCRIPTS, "gate.sh"))
        key_build = hash_object(("\n".join([self.headsha, "build", self.base, "", cfg_h, me_h]) + "\n").encode())
        key_green = hash_object(("\n".join([self.headsha, "green", "web", "web/a.test.ts", cfg_h, me_h]) + "\n").encode())
        self.assertEqual(sorted([key_build, key_green]), self.store())
        store = os.path.join(os.environ["FACTORY_HOME"], "gate-passes")
        b = open(os.path.join(store, key_build)).read()
        g = open(os.path.join(store, key_green)).read()
        self.assertEqual(b.count("\n"), 1)
        t, *rest = b.rstrip("\n").split("\t")
        self.assertRegex(t, STAMP)
        self.assertEqual(rest, [self.headsha, "build", self.base])
        self.assertEqual(g.rstrip("\n").split("\t")[1:], [self.headsha, "green", "web web/a.test.ts"])

    def test_moved_into_place(self):
        "the record is written whole to <record>.<pid>.tmp in the store, then moved into place with mv; no .tmp is left"
        log = os.path.join(self.tmp, "mv.log")
        self.sh("mv", 'case "$1" in *.tmp) printf "%%s\\t%%s\\t%%s\\t%%s\\n" "$1" "$2" "$([ -e "$2" ] && echo yes || echo no)" '
                '"$(wc -c < "$1" | tr -d " ")" >> "%s" ;; esac\nexec "%s" "$@"' % (log, shutil.which("mv")))
        self.build()
        src, dst, existed, size = open(log).read().rstrip("\n").split("\t")
        (rec,) = self.store()
        store = os.path.join(os.environ["FACTORY_HOME"], "gate-passes")
        self.assertRegex(src, r"/gate-passes/[0-9a-f]+\.[0-9]+\.tmp$")
        self.assertEqual(re.sub(r"\.[0-9]+\.tmp$", "", src), dst)
        self.assertTrue(os.path.samefile(dst, os.path.join(store, rec)))
        self.assertEqual(existed, "no")
        self.assertGreater(int(size), 40)
        self.assertFalse([n for n in os.listdir(store) if n.endswith(".tmp")])

    def test_prune(self):
        "recording a pass removes records older than 14 days; a failing gate or a reused pass prunes nothing"
        store = self.path("home", "gate-passes")
        now = time.time()
        for name, days in (("old15", 15), ("old40", 40), ("new13", 13), ("new1", 1)):
            p = os.path.join(store, name)
            open(p, "w").write("x\n")
            os.utime(p, (now - days * 86400 - 60, now - days * 86400 - 60))
        open(self.failflag, "w").close()
        self.build()
        self.assertEqual(self.store(), ["new1", "new13", "old15", "old40"])
        self.gate("green", "api", "NoSuchTest", FACTORY_MVN="false")
        self.assertEqual(len(self.store()), 4)
        os.unlink(self.failflag)
        self.build()
        left = self.store()
        self.assertEqual([n for n in left if not re.fullmatch("[0-9a-f]{40}", n)], ["new1", "new13"])
        self.assertEqual(len(left), 3)
        p = os.path.join(store, "old20")
        open(p, "w").write("old\n")
        os.utime(p, (now - 20 * 86400, now - 20 * 86400))
        self.build()
        self.assertEqual(self.count("build"), 2, "the second passing build was answered from the store")
        self.assertIn("old20", self.store())
        self.green()
        self.assertNotIn("old20", self.store())


class CodeKey(CacheCase):
    """The key covers the gate's code: every file under shipfloor_core/ and sf.py (code_hash) and gate.sh. A copy of
    scripts/ stands for an installed factory; the gate is pointed at it."""

    def copy(self, name):
        d = os.path.join(self.tmp, name)
        os.makedirs(d)
        shutil.copytree(os.path.join(gs.support.SCRIPTS, "shipfloor_core"), os.path.join(d, "shipfloor_core"),
                        ignore=shutil.ignore_patterns("__pycache__"))
        for f in ("sf.py", "gate.sh"):
            shutil.copy(os.path.join(gs.support.SCRIPTS, f), d)
        return d

    def steps(self, d):
        """build and green through the copy at d; (build runs, green runs) so far."""
        with mock.patch.object(run_mod, "_SCRIPTS", d), mock.patch.object(run_mod, "_CORE", os.path.join(d, "shipfloor_core")):
            self.build()
            self.green()
        return self.count("build"), self.count("green")

    def test_upgrades_invalidate(self):
        "a pass recorded before an upgrade is not reused once a file under shipfloor_core/, sf.py or gate.sh changes"
        d = self.copy("factory")
        core = os.path.join(d, "shipfloor_core")

        def append(path, text="\n# an upgrade\n"):
            with open(path, "a") as f:
                f.write(text)

        got = [("first", self.steps(d)), ("unchanged", self.steps(d))]
        append(os.path.join(core, "text.py"))
        got += [("a changed module", self.steps(d)), ("...then reused", self.steps(d))]
        append(os.path.join(core, "gate", "context.py"))
        got.append(("a changed sub-package module", self.steps(d)))
        open(os.path.join(core, "added.py"), "w").write('"""a new module"""\n')
        got.append(("an added module", self.steps(d)))
        os.unlink(os.path.join(core, "added.py"))
        got.append(("a removed module", self.steps(d)))
        append(os.path.join(d, "sf.py"))
        got.append(("a changed sf.py", self.steps(d)))
        append(os.path.join(d, "gate.sh"))
        got.append(("a changed gate.sh", self.steps(d)))
        os.makedirs(os.path.join(core, "__pycache__"))
        open(os.path.join(core, "__pycache__", "text.cpython-311.pyc"), "w").write("junk\n")
        got.append(("a __pycache__ is not the code", self.steps(d)))
        want = [(1, 1), (1, 1), (2, 2), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (7, 7)]
        self.assertEqual([g for g, w in zip(got, want) if g[1] != w], [])
        second = os.path.join(self.tmp, "second")
        shutil.copytree(d, second)
        self.steps(second)
        self.assertEqual(self.count("build"), 7, "a same-content copy elsewhere ran the build again")
        self.assertEqual(self.count("green"), 7)

    def test_old_store(self):
        "a store stamped by other code is emptied before recording; one with no stamp yet keeps its records"
        store = self.path("home", "gate-passes")
        open(os.path.join(store, "legacy"), "w").write("x\n")
        self.build()
        self.assertIn("legacy", self.store())
        open(os.path.join(store, ".code"), "w").write("other\n")
        self.put("web/e.ts")
        self.commit("c3")
        self.build()
        self.assertNotIn("legacy", self.store())
        self.assertEqual(len(self.store()), 1)
