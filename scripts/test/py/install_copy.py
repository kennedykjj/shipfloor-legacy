"""shipfloor install and doctor, in process (shipfloor_core/cli.py): every file goes in by rename (a running script
keeps the old text, a reader never sees half a file, a killed or refused install leaves each file old or new and
.source untouched), the counts, what is dropped or never copied (test/, __pycache__, .pyc); the source check
(branch, detached HEAD, tracked changes, behind/ahead, no remote, --force, .origin) and what doctor says of the copy
and of the Python running it. cli.HERE points at the source tree a test builds, as the wrapper beside it would."""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from unittest import mock

from support import Case, SCRIPTS
from shipfloor_core import cli

TAB = "\t"


def git(*args, cwd=None):
    r = subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "core.autocrlf=false", *args],
                       cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise AssertionError("git %s: %s" % (" ".join(args), r.stderr))
    return r.stdout.rstrip("\n")


class Killed(BaseException):
    """The install dying on the spot: nothing after it runs, no except clause of the install catches it."""


class InstallCase(Case):
    def setUp(self):
        super().setUp()
        self.home = os.environ["SHIPFLOOR_HOME"]
        self.inst = os.path.join(self.home, "factory")
        self.double("gh", "")
        self.double("claude", "")

    def put(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def tree(self, d, files):
        for rel, text in files.items():
            self.put(os.path.join(d, rel), text)
        return d

    def v1(self, name="src"):
        """a small plugin: gate.sh (what install looks for), scripts and templates, two of each to be dropped later"""
        return self.tree(self.path(name), {
            "scripts/gate.sh": "#!/usr/bin/env bash\necho gate\n", "scripts/zz-a.sh": "a v1\n",
            "scripts/lib/zz-b.sh": "b v1\n", "scripts/zz-gone.sh": "gone v1\n", "scripts/old-dir/x.sh": "x v1\n",
            "templates/zz-t1.md": "t1 v1\n", "templates/zz-tgone.md": "tgone v1\n", "templates/old-sub/y.md": "y v1\n"})

    def v2(self, name="B"):
        """v1 with 3 files changed, 2 new and 4 no longer shipped"""
        d = self.v1(name)
        self.tree(d, {"scripts/zz-a.sh": "a v2\n", "scripts/lib/zz-b.sh": "b v2\n", "templates/zz-t1.md": "t1 v2\n",
                      "scripts/zz-new.sh": "new v2\n", "templates/zz-tnew.md": "tnew v2\n"})
        for rel in ("scripts/zz-gone.sh", "scripts/old-dir/x.sh", "templates/zz-tgone.md", "templates/old-sub/y.md"):
            os.remove(os.path.join(d, rel))
        os.rmdir(os.path.join(d, "scripts/old-dir"))
        os.rmdir(os.path.join(d, "templates/old-sub"))
        return d

    def sf(self, src, *args, here=None):
        """cli.main(args) for the plugin at src (as its scripts/shipfloor runs it, or the copy's at `here`)"""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(cli, "HERE", here or os.path.join(src, "scripts")), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.rc = cli.main(list(args))
        self.out, self.err = out.getvalue(), err.getvalue()
        return self.rc

    def faulty(self, src, kill_at=0, fail_for="", watch=""):
        """install with os.replace counted (self.calls), dying on rename number kill_at, refusing a rename onto a
        path ending in fail_for, and noting in self.missing every rename or delete that ran while watch was absent"""
        self.calls, self.missing = [], []
        real = {"replace": os.replace, "unlink": os.unlink, "remove": os.remove}

        def note(op, args):
            if watch and not os.path.isfile(watch):
                self.missing.append((op, args))

        def replace(s, d, *a, **k):
            note("replace", (s, d))
            self.calls.append((s, d))
            if kill_at and len(self.calls) == kill_at:
                raise Killed()
            if fail_for and str(d).replace("\\", "/").endswith(fail_for):
                raise PermissionError(13, "refused to replace", str(d))
            return real["replace"](s, d, *a, **k)

        def deleter(name):
            return lambda p, *a, **k: (note(name, (p,)), real[name](p, *a, **k))[1]

        with mock.patch("os.replace", replace), mock.patch("os.unlink", deleter("unlink")), \
                mock.patch("os.remove", deleter("remove")):
            try:
                return self.sf(src, "install")
            except Killed:
                self.rc = 137
                return 137

    def counts(self):
        line = [l for l in self.out.splitlines() if l.startswith("installed ")][-1]
        return line.rsplit(": ", 1)[1]

    def same_tree(self, src):
        """the installed copy equals the source, what doctor compares (test/, .source, .origin, templates apart)"""
        return cli._same_tree(os.path.join(src, "scripts"), self.inst, {"test", ".source", ".origin", "templates"}) \
            and cli._same_tree(os.path.join(src, "templates"), os.path.join(self.inst, "templates"), set())

    def tmp_left(self):
        return [f for f in cli._files(self.inst) if f.rsplit("/", 1)[-1].endswith(".install-tmp")]

    def source(self):
        p = os.path.join(self.inst, ".source")
        return self.read(p) if os.path.exists(p) else None

    def doctor(self, src):
        self.sf(src, "doctor")
        return self.out


class Atomic(InstallCase):
    def test_running_script(self):
        "AC-1: install over a running script: it finishes as the old version, the next start runs the new one"
        src, run1, run2 = self.v1(), self.path("run1"), self.path("run2")
        long_v1 = ('#!/usr/bin/env bash\n: > "$1/started"\nn=0\n'
                   'while [ ! -e "$1/go" ] && [ "$n" -lt 150 ]; do sleep 0.1; n=$((n+1)); done\necho old > "$1/out"\nexit 0\n')
        self.put(os.path.join(src, "scripts/zz-long.sh"), long_v1)
        self.assertEqual(self.sf(src, "install"), 0)
        p = subprocess.Popen(["bash", os.path.join(self.inst, "zz-long.sh"), run1])
        self.addCleanup(p.kill)
        for _ in range(100):
            if os.path.exists(os.path.join(run1, "started")):
                break
            time.sleep(0.1)
        self.assertTrue(os.path.exists(os.path.join(run1, "started")), "the long-running script never started")
        longer = "".join("# a second version of this script that is longer and has other text on every line (%d) ......\n"
                         % i for i in range(8))
        self.put(os.path.join(src, "scripts/zz-long.sh"), "#!/usr/bin/env bash\n" + longer + 'echo new > "$1/out"\nexit 0\n')
        self.assertEqual(self.sf(src, "install"), 0, self.err)
        open(os.path.join(run1, "go"), "w").close()
        self.assertEqual(p.wait(), 0, "it read the new text in the middle of the old one")
        self.assertEqual(self.read(os.path.join(run1, "out")), "old\n")
        open(os.path.join(run2, "go"), "w").close()
        subprocess.run(["bash", os.path.join(self.inst, "zz-long.sh"), run2])
        self.assertEqual(self.read(os.path.join(run2, "out")), "new\n")

    def test_unchanged_source(self):
        "AC-2: installing an unchanged source touches no file's mtime and reports 0 replaced, 0 added, 0 removed"
        src = self.v1()
        self.assertEqual(self.sf(src, "install"), 0, self.err)

        def stamps():
            return {f: os.stat(os.path.join(self.inst, f)).st_mtime_ns for f in cli._files(self.inst)}
        before = stamps()
        time.sleep(0.02)
        self.assertEqual(self.sf(src, "install"), 0, self.err)
        self.assertEqual(stamps(), before)
        self.assertEqual(self.counts(), "0 replaced, 0 added, 0 removed")

    def test_reader_never_sees_half_a_file(self):
        "AC-3: a reader of a template being replaced six times never finds it missing or partial, at any step"
        src = self.v1()
        a, b = "A" * 110 + "\n", "B" * 110 + "\n"
        a, b = a * 3000, b * 3000
        target = os.path.join(src, "templates/zz-t1.md")
        self.put(target, a)
        self.sf(src, "install")
        seen, stop, n = [], threading.Event(), [0]
        installed = os.path.join(self.inst, "templates/zz-t1.md")

        def reader():
            while not stop.is_set():
                n[0] += 1
                try:
                    with open(installed) as f:
                        data = f.read()
                except OSError:
                    seen.append("missing")
                    continue
                if data not in (a, b):
                    seen.append("partial")
        t = threading.Thread(target=reader)
        t.start()
        missing = []
        try:
            for i in range(6):
                self.put(target, b if i % 2 == 0 else a)
                self.assertEqual(self.faulty(src, watch=installed), 0, self.err)
                self.assertTrue(self.calls, "the install never renamed a file into place")
                missing += self.missing
        finally:
            stop.set()
            t.join()
        self.assertEqual(seen, [], "in %d reads" % n[0])
        self.assertEqual(missing, [], "the installed template was missing during the install")

    def test_dropped_files(self):
        "AC-4: what the plugin no longer ships (scripts, templates) goes, emptied dirs too; the copy equals the source"
        src, b = self.v1(), self.v2()
        self.sf(src, "install")
        self.assertTrue(os.path.isfile(os.path.join(self.inst, "zz-gone.sh")))
        self.assertTrue(os.path.isfile(os.path.join(self.inst, "templates/zz-tgone.md")))
        self.assertEqual(self.sf(b, "install"), 0, self.err)
        for rel in ("zz-gone.sh", "old-dir/x.sh", "templates/zz-tgone.md", "templates/old-sub/y.md", "old-dir",
                    "templates/old-sub"):
            self.assertFalse(os.path.exists(os.path.join(self.inst, rel)), rel)
        self.assertTrue(self.same_tree(b))

    def test_counts_and_leftovers(self):
        "AC-6: 3 replaced, 2 added, 4 removed, then the next: line; .install-tmp leftovers of a killed install go"
        src, b = self.v1(), self.v2()
        self.sf(src, "install")
        self.put(os.path.join(self.inst, ".zz-a.sh.install-tmp"), "")
        self.put(os.path.join(self.inst, "templates/.zz-t1.md.install-tmp"), "")
        self.assertEqual(self.sf(b, "install"), 0, self.err)
        self.assertEqual(self.counts(), "3 replaced, 2 added, 4 removed")
        last = self.out.splitlines()[-2:]
        self.assertEqual(last[0], "installed %s → %s: 3 replaced, 2 added, 4 removed" % (b, self.inst))
        self.assertEqual(last[1], 'next: shipfloor add <repo>; then bash "%s/installer/install-dispatcher.sh"' % b)
        self.assertEqual(self.tmp_left(), [])
        self.assertTrue(self.same_tree(b))

    def test_never_shipped(self):
        "test/, __pycache__ and .pyc are never copied, and one left in the copy goes without being counted"
        src = self.tree(self.v1(), {"scripts/test/t.test.sh": "t\n", "scripts/__pycache__/sf.cpython-311.pyc": "junk",
                                    "scripts/shipfloor_core/__pycache__/proc.cpython-311.pyc": "junk",
                                    "scripts/shipfloor_core/x.pyc": "junk", "scripts/shipfloor_core/__init__.py": ""})
        self.assertEqual(self.sf(src, "install"), 0, self.err)
        self.assertTrue(os.path.isfile(os.path.join(self.inst, "shipfloor_core/__init__.py")))
        self.assertEqual([f for f in cli._files(self.inst) if f.startswith("test/") or "pyc" in f], [])
        self.put(os.path.join(self.inst, "__pycache__/old.pyc"), "old")
        self.assertEqual(self.sf(src, "install"), 0)
        self.assertEqual(self.counts(), "0 replaced, 0 added, 0 removed")
        self.assertFalse(os.path.exists(os.path.join(self.inst, "__pycache__")))

    def test_AC7_runtimes_package_is_shipped(self):
        "AC-7 scripts/runtimes/ is in the installed copy, with no __pycache__"
        real = os.path.join(SCRIPTS, "runtimes")
        self.assertTrue(os.path.isdir(real), "the plugin has scripts/runtimes/")
        src = self.v1()
        shutil.copytree(real, os.path.join(src, "scripts", "runtimes"), ignore=shutil.ignore_patterns("__pycache__"))
        self.put(os.path.join(src, "scripts/runtimes/__pycache__/claude_code.cpython-311.pyc"), "junk")
        self.assertEqual(self.sf(src, "install"), 0, self.err)
        for f in ("__init__.py", "claude_code.py"):
            self.assertTrue(os.path.isfile(os.path.join(self.inst, "runtimes", f)), f)
        self.assertEqual([f for f in cli._files(self.inst) if f.startswith("runtimes/") and "pycache" in f], [])

    def test_killed_halfway(self):
        "AC-5/AC-7: an install killed halfway leaves each file old or new and .source unchanged; doctor sees no match"
        src, b = self.v1(), self.v2()
        self.sf(src, "install")
        before = self.source()
        self.faulty(b, kill_at=2)
        self.assertEqual(len(self.calls), 2, "the install puts files in place by rename")
        for f in cli._files(self.inst):
            name = f.rsplit("/", 1)[-1]
            if name == ".source" or name.endswith(".install-tmp"):
                continue
            rel = f if f.startswith("templates/") else "scripts/" + f
            data = open(os.path.join(self.inst, f), "rb").read()
            versions = [open(os.path.join(d, rel), "rb").read() for d in (src, b) if os.path.isfile(os.path.join(d, rel))]
            self.assertIn(data, versions, f)
        self.assertEqual(self.source(), before)
        self.assertNotIn("installed copy matches", self.doctor(b))
        self.assertEqual(self.sf(b, "install"), 0, self.err)
        self.assertTrue(self.same_tree(b))
        self.assertEqual(self.tmp_left(), [])
        self.assertEqual(self.source(), b + "\n")
        self.sf(None, "doctor", here=self.inst)  # the installed copy's doctor finds its source through .source
        self.assertIn("ok   installed copy matches " + b, self.out)

    def test_first_install_killed(self):
        "AC-7: a first install killed halfway leaves no .source; the next one completes the copy and writes it"
        a = self.v1()
        self.faulty(a, kill_at=2)
        self.assertTrue(self.calls)
        self.assertIsNone(self.source())
        self.assertEqual(self.sf(a, "install"), 0, self.err)
        self.assertEqual(self.source(), a + "\n")
        self.assertTrue(self.same_tree(a))

    def test_refused_rename(self):
        "AC-8: a file that cannot be replaced: exit 1, named on stderr, kept whole, the rest installed, .source kept"
        src, b = self.v1(), self.v2()
        self.sf(src, "install")
        before = self.source()
        self.assertEqual(self.faulty(b, fail_for="/lib/zz-b.sh"), 1)
        self.assertIn("shipfloor: could not replace lib/zz-b.sh", self.err.splitlines())
        self.assertEqual(self.read(os.path.join(self.inst, "zz-a.sh")), "a v2\n")
        self.assertEqual(self.read(os.path.join(self.inst, "zz-new.sh")), "new v2\n")
        self.assertEqual(self.read(os.path.join(self.inst, "templates/zz-t1.md")), "t1 v2\n")
        self.assertEqual(self.read(os.path.join(self.inst, "lib/zz-b.sh")), "b v1\n")
        self.assertEqual(self.tmp_left(), [])
        self.assertEqual(self.source(), before)
        self.assertNotIn("installed copy matches", self.doctor(b))
        self.assertEqual(self.sf(b, "install"), 0, self.err)
        self.assertTrue(self.same_tree(b))
        self.assertEqual(self.source(), b + "\n")

    def test_usage_and_no_plugin(self):
        "install --bogus exits 2 with its usage line; a source without scripts/gate.sh is refused, nothing written"
        src = self.v1()
        self.assertEqual(self.sf(src, "install", "--bogus"), 2)
        self.assertEqual(self.err, "shipfloor: usage: shipfloor install [--force]\n")
        self.assertFalse(os.path.exists(self.inst))
        os.remove(os.path.join(src, "scripts/gate.sh"))
        self.assertEqual(self.sf(src, "install"), 1)
        self.assertEqual(self.err, "shipfloor: cannot find the plugin at %s\n" % src)
        self.assertFalse(os.path.exists(self.inst))


class Source(InstallCase):
    """the source must be a clean main level with its remote; each test a clone pushed to a bare remote"""

    def clone(self):
        src = self.v1("clone")
        self.tree(src, {"scripts/f%02d.sh" % i: "f\n" for i in range(12)})
        self.put(os.path.join(src, "templates/spec-template.md"), "spec\n")
        remote = self.path("remote.git")
        git("init", "-q", "--bare", "-b", "main", remote)
        git("init", "-q", "-b", "main", src)
        git("-C", src, "add", "-A")
        git("-C", src, "commit", "-qm", "plugin")
        git("-C", src, "remote", "add", "origin", remote)
        git("-C", src, "push", "-q", "origin", "main")
        git("-C", src, "remote", "set-head", "origin", "main")
        return src

    def brk(self, src, kind, n=1):
        if kind == "branch":
            git("-C", src, "checkout", "-q", "-b", "work")
        elif kind == "detached":
            git("-C", src, "checkout", "-q", "--detach")
        elif kind == "dirty":
            with open(os.path.join(src, "scripts/gate.sh"), "a") as f:
                f.write("# edited\n")
        elif kind == "remote":
            git("-C", src, "remote", "set-url", "origin", self.path("gone") + "/does-not-exist")
        elif kind == "ahead":
            for i in range(n):
                git("-C", src, "commit", "-q", "--allow-empty", "-m", "local %d" % i)
        elif kind == "behind":
            c = self.path("other")
            git("clone", "-q", git("-C", src, "remote", "get-url", "origin"), c + "/c")
            for i in range(n):
                git("-C", c + "/c", "commit", "-q", "--allow-empty", "-m", "remote %d" % i)
            git("-C", c + "/c", "push", "-q", "origin", "main")

    def refused(self, *says):
        self.assertEqual(self.rc, 1, self.err)
        for d in ("factory", "projects", "logs"):
            self.assertFalse(os.path.exists(os.path.join(self.home, d)), "wrote under the home: " + d)
        for s in says:
            self.assertIn(s, self.err)
        self.assertIn("shipfloor: not installing from %s:" % self.src, self.err)
        self.assertTrue(self.err.rstrip("\n").endswith("install anyway: shipfloor install --force"))

    def origin(self):
        p = os.path.join(self.inst, ".origin")
        return self.read(p) if os.path.exists(p) else None

    def setUp(self):
        super().setUp()
        self.src = self.clone()

    def test_branch_and_detached(self):
        "AC-1: a work branch or a detached HEAD is refused with the checkout to run, and nothing is copied"
        self.brk(self.src, "branch")
        self.sf(self.src, "install")
        self.refused("on branch work, not main", "git -C %s checkout main" % self.src)
        git("-C", self.src, "checkout", "-q", "main")
        self.brk(self.src, "detached")
        short = git("-C", self.src, "rev-parse", "--short", "HEAD")
        self.sf(self.src, "install")
        self.refused("on a detached HEAD at %s, not main" % short)

    def test_installed_copy_left_alone(self):
        "AC-1: a refused install leaves an installed copy as it was"
        self.assertEqual(self.sf(self.src, "install"), 0, self.err)
        self.put(os.path.join(self.inst, "gate.sh"), "old\n")
        self.brk(self.src, "branch")
        self.assertEqual(self.sf(self.src, "install"), 1)
        self.assertEqual(self.read(os.path.join(self.inst, "gate.sh")), "old\n")

    def test_tracked_changes(self):
        "AC-2: tracked changes block (the first 10 named, the rest counted); untracked files are copied as usual"
        self.brk(self.src, "dirty")
        self.sf(self.src, "install")
        self.refused("1 tracked file(s) with uncommitted changes: scripts/gate.sh", "commit or stash them")
        for i in range(11):
            with open(os.path.join(self.src, "scripts/f%02d.sh" % i), "a") as f:
                f.write("# edited\n")
        self.sf(self.src, "install")
        self.refused("12 tracked file(s) with uncommitted changes", ", and 2 more")
        git("-C", self.src, "checkout", "-q", "--", ".")
        self.put(os.path.join(self.src, "scripts/brand-new.sh"), "echo new\n")
        self.put(os.path.join(self.src, "notes.txt"), "x\n")
        self.assertEqual(self.sf(self.src, "install"), 0, self.err)
        self.assertTrue(os.path.isfile(os.path.join(self.inst, "brand-new.sh")))
        self.assertTrue(os.path.isfile(os.path.join(self.inst, "templates/spec-template.md")))
        self.assertEqual(self.origin().split(TAB)[2], "verified\n")

    def test_behind_ahead_remote(self):
        "AC-3/AC-4: behind or ahead of origin/main, or a remote that cannot be fetched, is refused with what to do"
        self.brk(self.src, "behind", 2)
        self.sf(self.src, "install")
        self.refused("2 commit(s) behind origin/main: git -C %s pull" % self.src)
        self.assertNotIn("ahead of", self.err)
        src = self.src
        git("-C", src, "pull", "-q", "--ff-only", "origin", "main")
        self.brk(src, "ahead", 3)
        self.sf(src, "install")
        self.refused("3 commit(s) ahead of origin/main: they are not merged; push and merge them first")
        self.assertNotIn("behind origin", self.err)
        self.brk(src, "remote")
        self.sf(src, "install")
        self.refused("could not check the remote (git fetch origin main failed): check the network and the origin remote")
        self.assertNotIn("behind origin", self.err)
        self.assertNotIn("ahead of origin", self.err)

    def test_every_reason(self):
        "AC-3: every reason that applies is listed"
        for k in ("branch", "dirty", "ahead"):
            self.brk(self.src, k)
        self.sf(self.src, "install")
        self.refused("on branch work, not main", "1 tracked file(s) with uncommitted changes",
                     "1 commit(s) ahead of origin/main")

    def test_force(self):
        "AC-5: --force installs anyway, one WARN line last naming branch, commit and why; .origin says forced"
        for kind in ("branch", "dirty", "behind", "ahead", "remote"):
            with self.subTest(kind=kind):
                self.setUp()
                self.brk(self.src, kind)
                br = git("-C", self.src, "symbolic-ref", "-q", "--short", "HEAD")
                short = git("-C", self.src, "rev-parse", "--short", "HEAD")
                self.assertEqual(self.sf(self.src, "install", "--force"), 0, self.err)
                self.assertTrue(os.path.isfile(os.path.join(self.inst, "gate.sh")))
                lines = self.out.splitlines()
                self.assertEqual(len([l for l in lines if "not a verified main" in l]), 1)
                self.assertTrue(lines[-1].startswith("WARN installed copy is not a verified main: branch %s, commit %s ("
                                                     % (br, short)), lines[-1])
                self.assertEqual(self.origin(), "%s\t%s\tforced\n" % (git("-C", self.src, "rev-parse", "HEAD"), br))

    def test_force_on_clean_main(self):
        "AC-5: --force over a clean main is a plain install, recorded as verified"
        self.assertEqual(self.sf(self.src, "install", "--force"), 0, self.err)
        self.assertNotIn("not a verified", self.out)
        self.assertTrue(self.origin().endswith("\tverified\n"))

    def test_clean_main(self):
        "AC-6/AC-8: a clean main installs, .source and a one-line .origin (commit, main, verified); doctor names it"
        self.assertEqual(self.sf(self.src, "install"), 0, self.err)
        self.assertIn("installed %s → %s" % (self.src, self.inst), self.out)
        self.assertIn("next: shipfloor add", self.out)
        self.assertNotIn("WARN", self.out)
        self.assertEqual(self.err, "")
        self.assertEqual(self.source(), self.src + "\n")
        want = "%s\tmain\tverified\n" % git("-C", self.src, "rev-parse", "HEAD")
        self.assertEqual(self.origin(), want)
        self.assertEqual(self.sf(self.src, "install"), 0)
        self.assertEqual(self.origin(), want)
        out = self.doctor(self.src)
        self.assertIn("ok   installed from main at %s" % git("-C", self.src, "rev-parse", "--short", "HEAD"), out)
        self.assertIn("ok   installed copy matches " + self.src, out)
        self.assertNotIn("WARN installed copy", out)

    def test_doctor_forced_and_unrecorded(self):
        "AC-8: doctor WARNs on a forced copy (branch, commit) and on one with no recorded commit, never FAILs on them"
        self.brk(self.src, "branch")
        short = git("-C", self.src, "rev-parse", "--short", "HEAD")
        self.sf(self.src, "install", "--force")
        out = self.doctor(self.src)
        self.assertIn("WARN installed copy was forced from branch work at %s, not a verified main (shipfloor install "
                      "from a clean main)" % short, out)
        self.assertIn("installed copy matches", out)
        self.assertNotIn("ok   installed from", out)
        self.assertNotIn("FAIL installed", out)
        self.assertNotIn("FAIL not installed", out)
        os.remove(os.path.join(self.inst, ".origin"))
        out = self.doctor(self.src)
        self.assertIn("WARN installed copy has no recorded commit (not a git clone, or installed before this check)", out)
        self.assertNotIn("FAIL installed", out)

    def test_not_a_clone(self):
        "AC-7: a plain copy (even inside a dirty clone on a branch) installs unchecked; an older .origin goes"
        self.brk(self.src, "branch")
        self.brk(self.src, "dirty")
        plain = self.v1("clone/vendored")
        self.put(os.path.join(self.inst, ".origin"), "oldcommit\tmain\tverified\n")
        self.assertEqual(self.sf(plain, "install"), 0, self.err)
        self.assertNotIn("not installing", self.err)
        self.assertNotIn("WARN", self.out)
        self.assertIsNone(self.origin())
        self.assertEqual(self.sf(plain, "install", "--force"), 0)
        self.assertNotIn("WARN", self.out)
        self.assertIn("WARN installed copy has no recorded commit", self.doctor(plain))


class Doctor(InstallCase):
    def test_pycache_is_no_difference(self):
        "doctor: a __pycache__ on either side is no difference, an edited script is"
        src = self.tree(self.v1(), {"scripts/shipfloor_core/__init__.py": ""})
        self.sf(src, "install")
        self.put(os.path.join(src, "scripts/shipfloor_core/__pycache__/text.cpython-311.pyc"), "more")
        self.put(os.path.join(self.inst, "__pycache__/sf.cpython-311.pyc"), "old")
        out = self.doctor(src)
        self.assertIn("ok   installed copy matches " + src, out)
        self.assertNotIn("installed copy differs", out)
        with open(os.path.join(src, "scripts/gate.sh"), "a") as f:
            f.write("# edited\n")
        self.assertIn("WARN installed copy differs from %s (shipfloor install)" % src, self.doctor(src))

    def test_not_installed(self):
        "doctor with no installed copy FAILs (exit 1) and says to run shipfloor install"
        src = self.v1()
        self.assertEqual(self.sf(src, "doctor"), 1)
        self.assertIn("FAIL not installed (shipfloor install)", self.out)

    def test_python_version(self):
        "doctor on Python 3.10 FAILs with one line naming 3.10.12 and the 3.11 minimum; 3.11 or later is ok"
        src = self.v1()
        self.sf(src, "install")
        with mock.patch.object(sys, "version_info", (3, 10, 12, "final", 0)):
            rc = self.sf(src, "doctor")
        self.assertNotEqual(rc, 0)
        fails = [l for l in self.out.splitlines() if l.startswith("FAIL") and "3.11" in l]
        self.assertEqual(fails, ["FAIL python 3.10.12 is too old: Shipfloor needs Python 3.11 or later (set "
                                 "FACTORY_PYTHON to one)"])
        self.doctor(src)
        self.assertEqual([l for l in self.out.splitlines() if l.startswith("FAIL") and "3.11" in l], [])
        self.assertIn("ok   python %d.%d.%d (3.11 or later)" % sys.version_info[:3], self.out)

    def test_real_plugin_warnings(self):
        "doctor on the real plugin: a health alert and a bad models entry come out as WARN lines, else ok   models"
        src = self.path("real")
        shutil.copytree(SCRIPTS, os.path.join(src, "scripts"), ignore=shutil.ignore_patterns("test", "__pycache__"))
        shutil.copytree(os.path.join(os.path.dirname(SCRIPTS), "templates"), os.path.join(src, "templates"))
        self.sf(src, "install")
        self.doctor(src)
        self.assertIn("ok   models", self.out.splitlines())
        self.assertNotIn("WARN health", self.out)
        cycle = {"ts": "2026-01-01T00:00:00+00:00", "idle": [], "over": ["develop"], "cycle": {"overlap": False}}
        self.put(os.path.join(self.home, "logs", "health-2026-01.jsonl"), json.dumps(cycle) + "\n")
        self.put(os.path.join(self.home, "config.yml"), "models:\n  stages:\n    nosuch: sonnet\n")
        out = self.doctor(src).splitlines()
        self.assertIn("WARN health: develop: more runs than the limit (~/.shipfloor/logs/health-*.jsonl)", out)
        self.assertIn("WARN models: models.stages.nosuch: not a stage or an agent here", out)
        self.assertNotIn("ok   models", out)
