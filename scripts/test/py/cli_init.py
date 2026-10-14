"""shipfloor init in process (shipfloor_core/init.py, #174): a clean machine to a working factory in one guided run.
git is real (throwaway repos with a bare origin); gh, claude and the dispatcher installer are stand-ins; the plugin is
a plain copy (not a clone) with installer/ and examples/."""
import os
import re
import shutil
import sys
from unittest import mock

from cli_support import CliCase, git, plugin_copy
from shipfloor_core import cli


class InitCase(CliCase):
    def setUp(self):
        super().setUp()
        cli.HERE = os.path.join(plugin_copy(), "scripts")
        self.repo = self.new_repo("shop")
        self.remote = self.with_origin(self.repo)
        self.c0 = self.commits()
        self.head0 = self.head()

    def init(self, *args, path=None, cwd=None):
        saved = os.environ["PATH"]
        if path is not None:
            os.environ["PATH"] = path
        try:
            return self.sf("init", *args, cwd=cwd)
        finally:
            os.environ["PATH"] = saved

    def commits(self):
        return int(git("-C", self.remote, "rev-list", "--count", "main"))

    def head(self):
        return git("-C", self.repo, "rev-parse", "HEAD")

    def origin_cfg(self):
        return git("-C", self.remote, "show", "main:.shipfloor/factory.yml", check=False)

    def installer_changes(self):
        p = os.path.join(self.st, "installer-calls")
        return len([l for l in (self.read(p).splitlines() if os.path.exists(p) else []) if "--status" not in l])

    def steps(self):
        """The `$ <command>` lines."""
        return [l for l in self.out.splitlines() if re.match(r"^ *\$ ", l)]

    def assert_untouched(self):
        self.assertEqual(self.commits(), self.c0)
        self.assertEqual(self.head(), self.head0)

    def assert_nothing_changed(self):
        self.assertEqual(os.listdir(self.sh), [])
        self.assertFalse(os.path.exists(os.path.join(self.st, "installer-calls")))
        self.assert_untouched()
        self.assertEqual(git("-C", self.repo, "status", "--porcelain"), "")


class Init(InitCase):
    def test_full_run_then_again(self):
        "init <repo> --yes does every step, shows each one's command, ends in doctor; a second run changes nothing"
        self.assertEqual(self.init(self.repo, "--yes"), 0, self.out)
        self.assertTrue(os.path.isfile(os.path.join(self.sh, "factory", "gate.sh")))
        self.assertTrue(os.path.isfile(os.path.join(self.sh, "factory", "shipfloor")))
        self.assertIn("name: shop", self.origin_cfg())
        self.assertEqual(self.commits(), self.c0 + 1)
        self.assertEqual(self.head(), git("-C", self.remote, "rev-parse", "main"))
        self.assertEqual(git("-C", self.repo, "status", "--porcelain"), "")
        self.assertIn("shop\t", self.registry())
        self.assertTrue(os.path.isdir(os.path.join(self.home_of(), "control")))
        self.assertIn("label create blocked --repo", self.gh_calls())
        self.assertTrue(os.path.exists(os.path.join(self.st, "registered")))
        self.assertEqual(self.installer_changes(), 1)
        self.assertIn("ok   gh authenticated", self.out)
        self.assertIn("ok   project shop", self.out)
        self.assertNotIn("FAIL", self.out)
        lines = self.out.splitlines()
        doctor = lines.index("ok   gh authenticated")
        dispatcher = next(i for i, l in enumerate(lines) if re.match(r"^ *\$ .*install-dispatcher", l))
        self.assertGreater(doctor, dispatcher)
        for pat in ("shipfloor install", "shipfloor add ", "setup-board shop", "install-dispatcher", "shipfloor doctor",
                    "git -C .* commit"):
            self.assertTrue(any(re.search(pat, l) for l in self.steps()), "no '$ ... %s' line in: %s" % (pat, self.out))
        reg, c1, head1, cfg1 = self.registry(), self.commits(), self.head(), self.origin_cfg()
        self.assertEqual(self.init(self.repo, "--yes"), 0, self.out)
        self.assertEqual((self.commits(), self.head(), self.origin_cfg(), self.registry()), (c1, head1, cfg1, reg))
        self.assertEqual(self.installer_changes(), 1)
        self.assertGreaterEqual(len(re.findall("(?i)already", self.out)), 4, self.out)
        self.assertNotIn("FAIL", self.out)

    def test_keeps_a_config(self):
        "a repo whose origin/main has .shipfloor/factory.yml keeps it: no commit, with or without --yes"
        self.write_file(os.path.join(self.repo, ".shipfloor", "factory.yml"), self.fixture())
        git("-C", self.repo, "add", "-A")
        git("-C", self.repo, "commit", "-qm", "cfg")
        git("-C", self.repo, "push", "-q", "origin", "main")
        self.c0, self.head0, cfg0 = self.commits(), self.head(), self.origin_cfg()
        self.assertEqual(self.init(self.repo, "--yes"), 0, self.out)
        self.assertEqual(self.origin_cfg(), cfg0)
        self.assert_untouched()
        self.assertIn(".shipfloor/factory.yml already on origin/main: kept as it is", self.out)
        self.assertFalse(any(re.search("git -C .* commit", l) for l in self.steps()))
        self.assertIn("shop\t", self.registry())
        self.init(self.repo)
        self.assertEqual(self.origin_cfg(), cfg0)
        self.assert_untouched()
        self.assertEqual(self.read(os.path.join(self.repo, ".shipfloor", "factory.yml")), self.fixture())

    def test_machine_only(self):
        "without <repo> init does the machine part only and touches no repository, not even the one it runs in"
        self.assertEqual(self.init("--yes", cwd=self.repo), 0, self.out)
        self.assertTrue(os.path.isfile(os.path.join(self.sh, "factory", "gate.sh")))
        self.assertTrue(os.path.exists(os.path.join(self.st, "registered")))
        self.assertIn("ok   gh authenticated", self.out)
        self.assertIn("  - shipfloor init <repo>   # add a repository to this machine", self.out)
        self.assertEqual(self.registry(), "")
        self.assertFalse(os.path.exists(self.home_of()))
        self.assert_untouched()
        self.assertEqual(git("-C", self.repo, "status", "--porcelain"), "")
        self.assertFalse(os.path.exists(os.path.join(self.repo, ".shipfloor")))
        self.assertNotRegex(self.gh_calls(), "project view|label create")

    def test_no_terminal_no_yes(self):
        "no terminal and no --yes: exit 1, nothing committed, the exact commit command printed, no project added"
        self.assertEqual(self.init(self.repo), 1, self.out)
        self.assert_untouched()
        self.assertTrue(any("git -C %s" % self.repo in l and "commit" in l for l in self.out.splitlines()), self.out)
        self.assertIn("pending: committing to your repository needs your confirmation (--yes, or a terminal)", self.out)
        self.assertEqual(self.registry(), "")

    def test_staged_changes_block_the_commit(self):
        "with --yes, a staged change that is not init's blocks the commit: the command printed, the owner's file stays staged"
        self.write_file(os.path.join(self.repo, "other.txt"), "mine\n")
        git("-C", self.repo, "add", "other.txt")
        self.assertNotEqual(self.init(self.repo, "--yes"), 0)
        self.assert_untouched()
        self.assertEqual(git("-C", self.repo, "diff", "--cached", "--name-only"), "other.txt")
        self.assertIn("has staged changes that are not init's: other.txt", self.out)
        self.assertTrue(any("git -C" in l and "commit" in l for l in self.out.splitlines()))

    def test_usage(self):
        "init with two repos or an unknown flag is a usage error, exit 2"
        self.assertEqual(self.init("a", "b"), 2)
        self.assertEqual(self.err, "shipfloor: usage: shipfloor init [<repo>] [--yes]\n")
        self.assertEqual(self.init("--bogus"), 2)


class Prerequisites(InitCase):
    """A missing prerequisite stops init before it changes anything; it names the prerequisite and its fix."""

    def bare_path(self, git_too=True):
        nb = self.path("nb")
        for t in ("bash", "env", "dirname", "basename", "mkdir", "rm", "cp", "cat", "id", "mktemp", "sed", "grep",
                  "sort", "date", "readlink", "ls", "chmod", "mv", "tr", "cut", "head", "wc", "find", "stat") + \
                (("git",) if git_too else ()):
            p = shutil.which(t)
            if p and not os.path.exists(os.path.join(nb, t)):
                os.symlink(p, os.path.join(nb, t))
        for t in ("gh", "uname"):
            if not os.path.exists(os.path.join(nb, t)):
                os.symlink(os.path.join(self.tmp, "bin", t), os.path.join(nb, t))
        return nb

    def test_gh_not_authenticated(self):
        "gh not signed in: exit non-zero, 'gh auth login', nothing changed"
        self.write_file(os.path.join(self.g, "noauth"), "")
        self.assertNotEqual(self.init(self.repo, "--yes"), 0)
        self.assertIn("FAIL gh is not authenticated: run: gh auth login", self.out)
        self.assertIn("nothing was changed; fix the above and run shipfloor init again.", self.out)
        self.assert_nothing_changed()

    def test_claude_missing(self):
        "claude not on PATH: exit non-zero, claude named, nothing changed"
        self.assertNotEqual(self.init(self.repo, "--yes", path=self.bare_path()), 0)
        self.assertIn("FAIL claude is missing: install Claude Code from https://claude.com/claude-code", self.out)
        self.assert_nothing_changed()

    def test_git_and_gh_missing(self):
        "git (and gh) not on PATH: exit non-zero, each named, nothing installed"
        nb = self.bare_path(git_too=False)
        os.remove(os.path.join(nb, "gh"))
        self.assertNotEqual(self.init(self.repo, "--yes", path=nb), 0)
        self.assertIn("FAIL git is missing: install it from https://git-scm.com/downloads", self.out)
        self.assertIn("FAIL gh is missing: install it from https://cli.github.com, then run: gh auth login", self.out)
        self.assert_nothing_changed()

    def test_old_python_no_pyyaml(self):
        "a Python older than 3.11 or without PyYAML: exit non-zero, 3.11 and 'pip install pyyaml' named, nothing changed"
        with mock.patch.object(sys, "version_info", (3, 10, 0, "final", 0)):
            self.assertNotEqual(self.init(self.repo, "--yes"), 0)
        self.assertIn("FAIL python 3.10.0 is too old: Shipfloor needs Python 3.11 or later", self.out)
        self.assert_nothing_changed()
        with mock.patch.dict(sys.modules, {"yaml": None}):
            self.assertNotEqual(self.init(self.repo, "--yes"), 0)
        self.assertIn("FAIL PyYAML is missing: run: pip install pyyaml", self.out)
        self.assert_nothing_changed()
