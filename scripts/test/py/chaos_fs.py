"""AC-6 of #173 (RES-01): a write that fails as if the disk were full, during an install or a report.

In process: the write is made to fail by a double (ENOSPC raised after half of the bytes went out), never by filling a
disk. When the write fails the previous installed files / report stay whole, no temp file is left, and ~/.shipfloor
still loads in the dashboard's readers (chaos_invariant.py, the same check the other chaos tests use).
"""
import builtins
import contextlib
import errno
import io
import os
import shutil
import subprocess
import unittest
from unittest import mock

import chaos_invariant
import support
from shipfloor_core import cli, report


class HalfFile:
    """A file that takes half of what it is given, then reports a full disk."""

    def __init__(self, f):
        self.f = f

    def write(self, data):
        self.f.write(data[:len(data) // 2])
        self.f.flush()
        raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.f.close()
        return False

    def __getattr__(self, name):
        return getattr(self.f, name)


@contextlib.contextmanager
def full_disk(part):
    """Every write to a file whose name contains `part` (a copy, or a plain open) stops half way with ENOSPC."""
    real_open, real_copyfile = builtins.open, shutil.copyfile

    def opener(file, mode="r", *a, **k):
        f = real_open(file, mode, *a, **k)
        if isinstance(file, (str, os.PathLike)) and part in os.path.basename(os.fspath(file)) and ("w" in mode or "a" in mode):
            return HalfFile(f)
        return f

    def copyfile(src, dst, *a, **k):  # copy2 goes through here too
        if part in os.path.basename(os.fspath(dst)):
            with real_open(src, "rb") as s, real_open(dst, "wb") as d:
                d.write(s.read()[:max(1, os.path.getsize(src) // 2)])
            raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC), os.fspath(dst))
        return real_copyfile(src, dst, *a, **k)

    with mock.patch("builtins.open", opener), mock.patch.object(shutil, "copyfile", copyfile):
        yield


def git(*args, cwd=None):
    subprocess.run(["git", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))


def tree_files(root):
    out = {}
    for top, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            p = os.path.join(top, name)
            with open(p, "rb") as f:
                out[os.path.relpath(p, root).replace(os.sep, "/")] = f.read()
    return out


class Home(support.Case):
    """A ~/.shipfloor with one registered project, as the dashboard's readers see it."""

    def setUp(self):
        super().setUp()
        self.shome = self.path("shome")
        self.pdir = self.path("shome", "projects", "shop")
        with open(os.path.join(self.shome, "registry.tsv"), "w", encoding="utf-8", newline="\n") as f:
            f.write("shop\t/x/shop\t/x/wt\tmain\n")
        os.environ["SHIPFLOOR_HOME"] = self.shome
        os.environ["FACTORY_HOME"] = self.pdir

    def loads(self, what):
        found = chaos_invariant.violations([self.shome])
        self.assertEqual(found, [], "%s: %s" % (what, "; ".join(found)))


class InstallDiskFull(Home):
    def setUp(self):
        super().setUp()
        self.v1 = self.src("v1", "v1")
        self.v2 = self.src("v2", "v2 with a longer text")
        self.out = io.StringIO()
        with self.installing(self.v1):
            self.assertEqual(cli.cmd_install(["--force"]), 0)
        self.before = tree_files(os.path.join(self.shome, "factory"))

    def src(self, name, version):
        root = self.path(name)
        for rel, text in (("scripts/gate.sh", "#!/usr/bin/env bash\n"), ("scripts/a.sh", "a " + version + "\n"),
                          ("scripts/lib/b.sh", "b " + version + "\n"), ("templates/t.md", "t " + version + "\n")):
            self.write(os.path.join(name, rel), text)
        git("init", "-q", "-b", "main", cwd=root)
        git("-c", "user.email=t@t", "-c", "user.name=t", "add", "-A", cwd=root)
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x", cwd=root)
        return root

    @contextlib.contextmanager
    def installing(self, src):
        with mock.patch.object(cli, "source_dir", lambda: src), contextlib.redirect_stdout(self.out), \
                contextlib.redirect_stderr(io.StringIO()):
            yield

    def failed_install(self, part):
        """Install v2 while writes to files named `part` hit a full disk: (exit code or 'raised')."""
        with self.installing(self.v2), full_disk(part):
            try:
                return cli.cmd_install(["--force"])
            except OSError:
                return "raised"

    def check_untouched(self, rc, what):
        self.assertNotEqual(rc, 0, "%s: a failed write was reported as a success" % what)
        now = tree_files(os.path.join(self.shome, "factory"))
        new = tree_files(self.v2 + "/scripts")
        new.update({"templates/" + k: v for k, v in tree_files(self.v2 + "/templates").items()})
        new[".source"] = (self.v2 + "\n").encode()
        for rel in ("a.sh", "lib/b.sh", "templates/t.md", ".source"):  # each file is whole, old or new
            self.assertIn(now.get(rel), (self.before[rel], new[rel]), "%s: %s is neither the old file nor the new one" % (what, rel))
        origin = now[".origin"]  # "<commit> <branch> <kind>\n", never a cut-off line
        self.assertTrue(origin == self.before[".origin"] or (origin.endswith(b"\n") and origin.count(b"\t") == 2),
                        "%s: .origin is cut off: %r" % (what, origin))
        self.assertEqual([r for r in now if r.endswith(".install-tmp") or r.endswith(".tmp")], [], what + ": temp file left")
        self.loads(what)

    def finishes_next_time(self, what):
        with self.installing(self.v2):
            self.assertEqual(cli.cmd_install(["--force"]), 0, what + ": the next install does not finish")
        now = tree_files(os.path.join(self.shome, "factory"))
        self.assertEqual(now["a.sh"], b"a v2 with a longer text\n", what)
        self.assertEqual(now[".source"], (self.v2 + "\n").encode(), what + ": .source")
        self.loads(what + " (after the next install)")

    def test_ac6_install_script_copy(self):
        """AC-6 install: a script copy stops half way (disk full): the old script stays whole, no temp file, the dashboard loads"""
        rc = self.failed_install("a.sh")
        self.check_untouched(rc, "script copy")
        self.assertEqual(tree_files(os.path.join(self.shome, "factory"))["a.sh"], self.before["a.sh"], "the old script was not kept")
        self.assertEqual(tree_files(os.path.join(self.shome, "factory"))[".source"], self.before[".source"], ".source moved on a failed install")
        self.finishes_next_time("script copy")

    def test_ac6_install_source_marker(self):
        """AC-6 install: the .source write stops half way (disk full): .source stays whole and old, no temp file, the dashboard loads"""
        rc = self.failed_install(".source")
        self.check_untouched(rc, ".source write")
        self.assertEqual(tree_files(os.path.join(self.shome, "factory"))[".source"], self.before[".source"], ".source is not the old, whole one")
        self.finishes_next_time(".source write")

    def test_ac6_install_origin_marker(self):
        """AC-6 install: the .origin write stops half way (disk full): .origin stays whole, no temp file, the dashboard loads"""
        rc = self.failed_install(".origin")
        self.check_untouched(rc, ".origin write")
        self.assertEqual(tree_files(os.path.join(self.shome, "factory"))[".origin"], self.before[".origin"], ".origin is half written")
        self.finishes_next_time(".origin write")


class ReportDiskFull(Home):
    def setUp(self):
        super().setUp()
        self.remote = self.path("remote")
        self.repo = self.path("repo")
        git("init", "-q", "--bare", self.remote)
        git("init", "-q", "-b", "main", self.repo)
        git("config", "user.email", "t@t", cwd=self.repo)
        git("config", "user.name", "t", cwd=self.repo)
        self.write("repo/README.md", "base\n")
        git("add", "-A", cwd=self.repo)
        git("commit", "-qm", "base", cwd=self.repo)
        git("remote", "add", "origin", self.remote, cwd=self.repo)
        git("push", "-q", "origin", "main", cwd=self.repo)
        os.environ["FACTORY_REPO"] = self.repo
        self.json = self.write("src/report.json", '{"issue":26,"outcome":"ok","agents":[]}\n' * 5)
        self.md = self.write("src/report.md", "# Report\n" + "a line of the report\n" * 40)
        self.wt = os.path.join(self.pdir, "reports-wt")

    def send(self, stamp):
        with mock.patch.object(report, "_stamp", lambda: stamp), mock.patch.object(report.project, "resolve", lambda *_: None), \
                contextlib.redirect_stderr(io.StringIO()):
            return report.main(["26", "rl", "refine", self.json, self.md])

    def test_ac6_report_disk_full(self):
        """AC-6 report: a report copy stops half way (disk full): the earlier report stays whole, no half file, no temp file, the dashboard loads"""
        self.assertEqual(self.send("2026-10-14T120000"), 0, "the first report is not sent")
        folder = os.path.join(self.wt, "reports", "26-rl")
        first = tree_files(folder)
        self.assertEqual(sorted(first), ["refine-2026-10-14T120000.json", "refine-2026-10-14T120000.md"])
        with open(self.md, "w", encoding="utf-8", newline="\n") as f:
            f.write("# Report 2\n" + "another line of the report\n" * 40)
        with full_disk(".md"):
            rc = self.send("2026-10-14T120001")
        self.assertNotEqual(rc, 0, "a failed write was reported as a success")
        now = tree_files(folder)
        for name, data in first.items():
            self.assertEqual(now.get(name), data, "the earlier report %s changed" % name)
        sources = {".json": open(self.json, "rb").read(), ".md": open(self.md, "rb").read()}
        for name, data in now.items():
            if name in first:
                continue
            self.assertEqual(data, sources[os.path.splitext(name)[1]], "%s is half a report: %d of %d bytes" % (
                name, len(data), len(sources[os.path.splitext(name)[1]])))
        self.assertEqual([n for n in tree_files(self.wt) if n.endswith(".tmp")], [], "temp file left in the reports checkout")
        self.loads("report")
        self.assertEqual(self.send("2026-10-14T120002"), 0, "the next report is not sent")
        shown = subprocess.run(["git", "--git-dir", self.remote, "ls-tree", "-r", "--name-only", "factory-reports"],
                               stdout=subprocess.PIPE, check=True).stdout.decode()
        self.assertIn("reports/26-rl/refine-2026-10-14T120002.md", shown)
        self.assertIn("reports/26-rl/refine-2026-10-14T120000.md", shown)


if __name__ == "__main__":
    unittest.main()
