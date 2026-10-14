"""shipfloor doctor in process (shipfloor_core/cli.py cmd_doctor): the tools, gh auth, the installed copy, the
dispatcher (through the real installer/install-dispatcher.sh --status, the machine faked by stand-ins), every project's
config, language, tmp dirs, SKIPPED, control checkout and branch protection, and the models line; its exit code."""
import os
import sys
from unittest import mock

from cli_support import CliCase, ROOT, git, plugin_copy
from shipfloor_core import cli

SCRIPTS_HERE = cli.HERE


class Doctor(CliCase):
    def setUp(self):
        super().setUp()
        os.environ["SF_UNAME"] = "Linux"
        self.table = os.path.join(self.st, "table")

    def doctor(self, want=None):
        cli.HERE = SCRIPTS_HERE
        rc = self.sf("doctor")
        if want is not None:
            self.assertEqual(rc, want, self.both)
        return self.out

    def install(self):
        cli.HERE = os.path.join(plugin_copy(), "scripts")
        self.ok("install")

    def shop(self):
        self.r = self.with_config()
        self.ok("add", self.r)
        self.h = self.home_of()

    def test_no_projects_and_no_legacy_home(self):
        "with no project doctor warns so, says nothing about a leftover ~/.aghanim and leaves it alone"
        self.write_file(os.path.join(os.environ["HOME"], ".aghanim", "marker"), "keep")
        out = self.doctor()
        self.assertIn("WARN no projects (shipfloor add <repo>)", out)
        self.assertIn("FAIL not installed (shipfloor install)", out)
        self.assertNotRegex(out, "[Aa]ghanim|migrate-home")
        self.assertEqual(self.read(os.path.join(os.environ["HOME"], ".aghanim", "marker")), "keep")

    def test_dispatcher_line(self):
        "doctor says whether a dispatcher is registered (cron here); a missing one is a WARN that leaves the exit code alone; none on Windows"
        out = self.doctor()
        self.assertIn("WARN no dispatcher registered; run: bash %s/installer/install-dispatcher.sh" % ROOT, out)
        without = self.rc
        self.write_file(self.table, "*/3 * * * * /usr/bin/bash -l %s/factory/run-dispatcher.sh # shipfloor-dispatcher\n" % self.sh)
        out = self.doctor()
        self.assertIn("ok   dispatcher registered (cron)", out)
        self.assertNotIn("no dispatcher registered", out)
        self.assertEqual(self.rc, without)
        os.environ["SF_UNAME"] = "MINGW64_NT-10.0"
        self.assertNotIn("dispatcher registered", self.doctor())

    def test_gh_protection_models(self):
        "doctor: the gh-auth line, each project's branch protection and the models line; a FAIL makes it exit 1"
        self.shop()
        out = self.doctor()
        self.assertIn("ok   gh authenticated", out)
        self.assertIn("ok   project shop", out)
        self.assertIn("ok   shop: main requires up-to-date branches", out)
        self.assertIn("ok   models", out)
        self.write_file(os.path.join(self.g, "noauth"), "")
        self.write_file(os.path.join(self.g, "protection"), "false\n")
        out = self.doctor(want=1)
        self.assertIn("FAIL gh auth login", out)
        self.assertNotIn("ok   gh authenticated", out)
        self.assertIn("WARN shop: main does not require up-to-date branches (false); a hand merge can race the deploy", out)
        os.remove(os.path.join(self.g, "noauth"))
        self.write_file(os.path.join(self.g, "protection"), "gh: Branch not protected (HTTP 404)\n")
        self.write_file(os.path.join(self.g, "protection-fails"), "")
        self.assertIn("WARN shop: main does not require up-to-date branches (Branch not protected (HTTP 404)); a hand "
                      "merge can race the deploy", self.doctor())
        self.write_file(os.path.join(self.sh, "config.yml"), "models:\n  stages: {develop: gpt}\n")
        out = self.doctor()
        self.assertIn('WARN models: models.stages.develop: "gpt" is not a model the factory knows (opus, sonnet, haiku, fable)', out)
        self.assertNotIn("ok   models", out)

    def test_notify_channels_not_a_mapping(self):
        "AC-2 notify.channels a list with no ntfy_topic: doctor shows the problem line instead of a traceback"
        self.shop()
        for text in ("notify: {channels: [toast]}\n", "notify: {channels: toast}\n"):
            self.write_file(os.path.join(self.sh, "config.yml"), text)
            out = self.doctor()
            self.assertIn("notify.channels must be a mapping", out)
            self.assertNotIn("Traceback", out)

    def test_warnings_only_exit_0(self):
        "doctor exits 0 when it only warns: no FAIL line with the factory installed and gh signed in"
        self.install()
        self.shop()
        self.write_file(os.path.join(self.g, "protection"), "false\n")
        out = self.doctor(want=0)
        self.assertNotIn("FAIL", out)
        self.assertIn("WARN shop: main does not require up-to-date branches", out)
        self.assertIn("WARN installed copy has no recorded commit", out)

    def test_project_lines(self):
        "doctor names stale tmp dirs, a project the dispatcher skips, a control checkout behind origin/main, the language and its source"
        self.shop()
        for n in ("5", "6", "8"):
            os.makedirs(os.path.join(self.h, "tmp", n, "x"))
        self.write_file(os.path.join(self.h, "board.tsv"), "5\tDone\tI5\n6\tCoding\tI6\n")
        self.write_file(os.path.join(self.h, "SKIPPED"), "2026-10-09T20:06:50-03:00\tcannot bring the control checkout "
                                                         "to origin/main: index.lock exists\n")
        out = self.doctor()
        self.assertIn("WARN shop: 2 tmp dir(s) of finished cards; run: shipfloor clean shop", out)
        self.assertIn("WARN shop: the dispatcher skips it since 2026-10-09T20:06:50-03:00: cannot bring the control "
                      "checkout to origin/main: index.lock exists", out)
        self.assertIn("ok   shop: writes in English (en), from the repository", out)
        self.assertNotIn("behind origin/main", out)
        git("-C", self.r, "commit", "-q", "--allow-empty", "-m", "ahead")
        git("-C", self.r, "push", "-q", "origin", "HEAD:main")
        git("-C", self.r, "fetch", "-q", "origin")
        self.assertIn("WARN shop: control checkout is behind origin/main", self.doctor())
        self.write_file(os.path.join(self.h, "overrides.yml"), "language: pt-BR\n")
        os.environ["FACTORY_LANGUAGE"] = "en"
        self.assertIn("ok   shop: writes in Brazilian Portuguese (pt-BR), from this machine", self.doctor())

    def test_invalid_project_and_python(self):
        "an invalid project config, an old Python or no PyYAML is a FAIL line and exit 1"
        self.shop()
        self.write_file(os.path.join(self.h, "factory.yml"), "project: {name: shop}\n")
        self.assertIn("FAIL project shop: invalid or missing config", self.doctor(want=1))
        with mock.patch.object(sys, "version_info", (3, 10, 0, "final", 0)), mock.patch.dict(sys.modules, {"yaml": None}):
            out = self.doctor(want=1)
        self.assertIn("FAIL python 3.10.0 is too old: Shipfloor needs Python 3.11 or later (set FACTORY_PYTHON to one)", out)
        self.assertIn("FAIL python 3 with PyYAML (pip install pyyaml)", out)
