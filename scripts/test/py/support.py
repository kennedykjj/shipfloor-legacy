"""Shared helpers for the in-process tests: a private temp dir per test, a scrubbed factory environment and a
recording double for an external program (gh, git, claude) put first on PATH."""
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(SCRIPTS, "test", "fixture")


class Case(unittest.TestCase):
    """A test with its own temp dir (self.tmp, removed after) and an environment with no factory variables of the
    real machine: FACTORY_HOME and SHIPFLOOR_HOME point inside self.tmp."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(saved)))
        for k in [k for k in os.environ if k.startswith(("FACTORY_", "SHIPFLOOR_", "AGHANIM_"))]:
            del os.environ[k]
        os.environ["FACTORY_HOME"] = self.path("home")
        os.environ["SHIPFLOOR_HOME"] = self.path("shome")
        os.environ["FACTORY_CONFIG"] = os.path.join(FIXTURE, "factory.yml")
        os.environ["FACTORY_PYTHON"] = sys.executable

    def path(self, *parts):
        p = os.path.join(self.tmp, *parts)
        os.makedirs(p if not os.path.splitext(p)[1] else os.path.dirname(p), exist_ok=True)
        return p

    def write(self, rel, text):
        p = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        return p

    def double(self, name, script):
        """A program `name` first on PATH: a Python script body that sees `argv` (list) and `log(obj)`, which appends
        a JSON line to <tmp>/<name>.calls. Returns a function giving the recorded calls."""
        bindir = self.path("bin")
        calls = os.path.join(self.tmp, name + ".calls")
        body = ("#!%s\nimport json, sys\nargv = sys.argv[1:]\n"
                "def log(o):\n    open(%r, 'a').write(json.dumps(o) + '\\n')\nlog(argv)\n%s\n") % (sys.executable, calls, script)
        p = os.path.join(bindir, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        if not os.environ.get("PATH", "").startswith(bindir + os.pathsep):
            os.environ["PATH"] = bindir + os.pathsep + os.environ.get("PATH", "")
        return lambda: [json.loads(l) for l in open(calls)] if os.path.exists(calls) else []
