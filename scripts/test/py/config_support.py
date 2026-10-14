"""Helpers for the config suites: shipfloor-config.sh's queries answered in this process (project.config_main, the
code past the wrapper's step fast path) with stdout and stderr captured, and a machine config.yml in the test's own
Shipfloor home."""
import io
import os
import sys

from support import Case, FIXTURE

from shipfloor_core import project
import shipfloor_config

FIXTURE_YML = os.path.join(FIXTURE, "factory.yml")
BOARD = "project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\n"
LAYER = "layers:\n  - {name: a, path: a/, test: t, ran: ok, tests: [a/**]}\n"


class _Stream(io.TextIOWrapper):
    def __init__(self):
        super().__init__(io.BytesIO(), encoding="utf-8", newline="", write_through=True)

    def text(self):
        self.flush()
        return self.buffer.getvalue().decode("utf-8")


class ConfigCase(Case):
    def call(self, fn, argv):
        """(exit code, stdout, stderr) of fn(argv), its streams captured."""
        out, err = _Stream(), _Stream()
        saved = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = out, err
        try:
            rc = fn(list(argv))
        finally:
            sys.stdout, sys.stderr = saved
        return rc, out.text(), err.text()

    def cfg(self, *argv, config=None):
        """shipfloor-config.sh <argv> for the project whose factory.yml is config (default: the fixture)."""
        os.environ["FACTORY_CONFIG"] = config or FIXTURE_YML
        return self.call(project.config_main, argv)

    def raw(self, *argv, config=None):
        """shipfloor_config.py <argv> on its own (no grep -E pass of `validate`): the module's exit codes."""
        return self.call(shipfloor_config.run, (["--config", config] if config else []) + list(argv))

    def out(self, *argv, config=None):
        rc, out, err = self.cfg(*argv, config=config)
        self.assertEqual(rc, 0, "%s: exit %s, stderr %s" % (argv, rc, err))
        return out

    def mach(self, *argv):
        """shipfloor-config.sh machine <argv>, on the test's $SHIPFLOOR_HOME/config.yml."""
        return self.call(project.config_main, ["machine", *argv])

    def values(self, *keys, sep=" "):
        rc, out, err = self.mach("values", *keys)
        self.assertEqual(rc, 0, err)
        return out.replace("\0", sep)

    def conf(self, text):
        """The machine config.yml holds text (None: there is none)."""
        p = os.path.join(os.environ["SHIPFLOOR_HOME"], "config.yml")
        if text is None:
            if os.path.exists(p):
                os.unlink(p)
            return p
        return self.write(os.path.relpath(p, self.tmp), text + "\n")

    def yml(self, text, name="factory.yml"):
        return self.write(os.path.join("proj", name), text)
