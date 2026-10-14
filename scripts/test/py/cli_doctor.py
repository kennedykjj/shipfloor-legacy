"""shipfloor doctor in process (shipfloor_core/cli.py cmd_doctor): the tools, gh auth, the installed copy, the
dispatcher (through the real installer/install-dispatcher.sh --status, the machine faked by stand-ins), every project's
config, language, tmp dirs, SKIPPED, control checkout and branch protection, and the models line; its exit code."""
import os
import shutil
import sys
from unittest import mock

import fake_llm
from cli_support import CliCase, ROOT, git, plugin_copy, script
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

    def test_AC5_runtime_line(self):
        "AC-5 with claude on PATH and no runtime configured doctor says `ok   claude-code: claude` instead of `ok   claude`; a project naming it too adds no second line"
        out = self.doctor()
        self.assertIn("ok   claude-code: claude", out)
        self.assertNotRegex(out, r"(?m)^ok   claude$")
        self.assertNotIn("FAIL claude", out)
        self.shop()
        self.write_file(os.path.join(self.h, "factory.yml"), self.fixture() + "\nruntime: claude-code\n")
        self.write_file(os.path.join(self.sh, "config.yml"), "runtime: claude-code\n")
        out = self.doctor()
        self.assertEqual(out.count("claude-code: claude"), 1, out)

    def fake_codex(self):
        """A `codex` first on PATH: --version prints one, `login status` fails while $SF_ST/codex-logged-out exists."""
        script(os.path.join(self.path("bin"), "codex"), '#!/usr/bin/env bash\ncase "$*" in\n'
               '  --version) echo "codex-cli 0.200.0" ;;\n'
               '  "login status") [ -e "$SF_ST/codex-logged-out" ] && { echo "Not logged in" >&2; exit 1; }; echo "Logged in using ChatGPT" ;;\n'
               'esac\n')

    def test_AC8_codex_lines(self):
        "AC-8 with runtime: codex doctor says ok or FAIL for the codex binary, its login (or CODEX_API_KEY) and the generated CODEX_HOME; claude-code alone says nothing of codex"
        self.fake_codex()
        os.environ.pop("CODEX_API_KEY", None)
        home = os.environ["SHIPFLOOR_CODEX_HOME"] = os.path.join(self.st, "codex-home")
        self.write_file(os.path.join(self.sh, "config.yml"), "runtime: codex\n")
        out = self.doctor()
        self.assertIn("ok   codex: codex", out)
        self.assertRegex(out, r"(?mi)^ok   .*(login|logged in)")
        self.assertRegex(out, r"(?m)^FAIL .*CODEX_HOME", "nothing generated yet")
        self.assertEqual(self.rc, 1)
        self.write_file(os.path.join(home, "config.toml"), "# generated\n")
        self.write_file(os.path.join(home, "agents", "architect.toml"), "name = 'architect'\n")
        out = self.doctor()
        self.assertRegex(out, r"(?m)^ok   .*CODEX_HOME")
        self.assertNotRegex(out, r"(?m)^FAIL .*CODEX_HOME")
        self.write_file(os.path.join(self.st, "codex-logged-out"), "")
        self.assertRegex(self.doctor(), r"(?mi)^FAIL .*(login|logged in)")
        os.environ["CODEX_API_KEY"] = "sk-test"
        self.assertRegex(self.doctor(), r"(?mi)^ok   .*(login|logged in)")
        real = shutil.which
        with mock.patch.object(shutil, "which", lambda name, *a, **k: None if name == "codex" else real(name, *a, **k)):
            self.assertIn("FAIL codex: codex", self.doctor())
        self.write_file(os.path.join(self.sh, "config.yml"), "runtime: claude-code\n")
        out = self.doctor()
        self.assertIn("ok   claude-code: claude", out)
        self.assertNotIn("codex", out.lower())

    def test_AC3_models_stages_warns_off_claude_code(self):
        "AC-3 models.stages.<stage> set while that stage runs on another runtime is a WARN naming the key; on claude-code it is not"
        self.fake_codex()
        os.environ["SHIPFLOOR_CODEX_HOME"] = os.path.join(self.st, "codex-home")
        self.write_file(os.path.join(self.sh, "config.yml"), "runtime: {stages: {develop: codex}}\nmodels:\n  stages: {develop: opus}\n")
        self.assertRegex(self.doctor(), r"(?m)^WARN .*models\.stages\.develop")
        self.write_file(os.path.join(self.sh, "config.yml"), "models:\n  stages: {develop: opus}\n")
        self.assertNotRegex(self.doctor(), r"(?m)^WARN .*models\.stages\.develop")

    KEY = "SF_LLM_KEY"
    SECRET = "sk-doctor-151-c41e8b"

    def provider_doctor(self, mode="ok", models=("qwen3-coder",), model="qwen3-coder", key=True, runtime_extra=""):
        """doctor with runtime.provider on a fake endpoint (mode, the models it serves), the model the config names and the key
        variable set or not. Returns (output, endpoint)."""
        llm = fake_llm.FakeLLM(mode, models)
        self.addCleanup(llm.stop)
        self.fake_codex()
        home = os.environ["SHIPFLOOR_CODEX_HOME"] = os.path.join(self.st, "codex-home")
        self.write_file(os.path.join(home, "config.toml"), "# generated\n")
        self.write_file(os.path.join(home, "agents", "architect.toml"), "name = 'architect'\n")
        if key:
            os.environ[self.KEY] = self.SECRET
        else:
            os.environ.pop(self.KEY, None)
        self.write_file(os.path.join(self.sh, "config.yml"),
                        "runtime:\n  default: codex\n%s  provider:\n    base_url: %s\n    api_key_env: %s\n"
                        "    models: {stages: {develop: %s}}\n" % (runtime_extra, llm.base_url, self.KEY, model))
        return self.doctor(), llm

    @staticmethod
    def fails(out):
        return {l for l in out.splitlines() if l.startswith("FAIL")}

    def test_AC7_provider_lines_ok(self):
        "AC-7 with a provider that is up, serves the model, has its key variable and /responses doctor says ok for each and prints no provider FAIL"
        out, llm = self.provider_doctor()
        for what in (self.KEY, "qwen3-coder", llm.host):
            self.assertRegex(out, r"(?m)^ok   .*%s" % what.replace(".", r"\."), "an ok line for %s" % what)
        self.assertFalse([l for l in self.fails(out) if self.KEY in l or "qwen3-coder" in l or llm.host in l or "opencode" in l], out)
        self.assertNotRegex(out, r"(?m)^WARN .*runtime\.models", "nothing is ignored")

    def test_AC7_each_provider_failure_has_its_own_line(self):
        "AC-7 an endpoint that is down, a model the endpoint does not serve, a missing key variable and an endpoint without /responses (naming opencode) are four different FAIL lines, and doctor exits 1"
        base = self.fails(self.provider_doctor()[0])
        down, llm_down = self.provider_doctor("down")
        absent, _ = self.provider_doctor(model="missing-model")
        nokey, _ = self.provider_doctor(key=False)
        noresp, _ = self.provider_doctor("no-responses")
        new = {n: self.fails(o) - base for n, o in (("down", down), ("model", absent), ("key", nokey), ("responses", noresp))}
        for name, lines in new.items():
            self.assertTrue(lines, "%s: a FAIL line of its own: %s" % (name, new))
        self.assertTrue([l for l in new["down"] if llm_down.host in l], new["down"])
        self.assertTrue([l for l in new["model"] if "missing-model" in l], new["model"])
        self.assertTrue([l for l in new["key"] if self.KEY in l], new["key"])
        self.assertTrue([l for l in new["responses"] if "opencode" in l and "responses" in l], new["responses"])
        for name in ("down", "model", "key"):
            self.assertFalse([l for l in new[name] if "opencode" in l], "only the missing /responses suggests opencode: %s" % name)
        self.assertFalse([l for l in new["model"] if self.KEY in l] + [l for l in new["key"] if "missing-model" in l])
        names = list(new)
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                self.assertNotEqual(new[a], new[b], "%s and %s say the same" % (a, b))
        self.assertEqual(self.rc, 1)

    def test_AC7_runtime_models_beside_a_provider_is_a_warning(self):
        "AC-7 runtime.models set beside a provider: a WARN that it is ignored (and no WARN without it)"
        out, _ = self.provider_doctor(runtime_extra="  models: {stages: {develop: gpt-6-mini}}\n")
        self.assertRegex(out, r"(?m)^WARN .*runtime\.models.*ignor")

    def test_AC8_the_key_is_not_in_the_output_nor_in_a_file(self):
        "AC-8 the key's value is in no doctor line, even when the endpoint fails, and in no file under the Shipfloor home or the CODEX_HOME"
        outs = [self.provider_doctor()[0], self.provider_doctor("no-responses")[0], self.provider_doctor(model="missing-model")[0]]
        for out in outs:
            self.assertNotIn(self.SECRET, out)
        self.assertIn("qwen3-coder", outs[0], "the doctor said something about the provider")
        for root in (self.sh, os.environ["SHIPFLOOR_CODEX_HOME"]):
            for d, _, files in os.walk(root):
                for f in files:
                    with open(os.path.join(d, f), "rb") as fh:
                        self.assertNotIn(self.SECRET.encode(), fh.read(), os.path.join(d, f))

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

    def test_AC6_dispatcher_limits(self):
        "AC-6 doctor shows the limits in effect on the installed dispatcher: none when unlimited, not supported on a scheduler without cgroups"
        self.assertNotIn("dispatcher limits", self.doctor(), "no dispatcher, no limits line")
        self.write_file(self.table, "*/3 * * * * /usr/bin/bash -l %s/factory/run-dispatcher.sh # shipfloor-dispatcher\n" % self.sh)
        out = self.doctor()
        self.assertRegex(out, r"ok   dispatcher limits: .*none")
        self.write_file(os.path.join(self.sh, "config.yml"), "limits: {memory_max: 8G, cpu_weight: 200}\n")
        out = self.doctor()
        self.assertRegex(out, r"dispatcher limits: .*not supported")
        self.assertNotRegex(out, r"dispatcher limits: .*none")

    def test_tmpdir_on_tmpfs(self):
        "AC-6 a dispatcher TMPDIR (<home>/tmp) on tmpfs is a WARN naming the path and the fix; elsewhere, or with no mount table, no line"
        want = os.path.join(self.sh, "tmp")
        for fstype, warned in (("tmpfs", True), ("ext4", False), (None, False)):
            with mock.patch.object(cli, "_fs_type", return_value=fstype):
                out = self.doctor()
            self.assertEqual("WARN dispatcher TMPDIR %s is on tmpfs (inode cap); move SHIPFLOOR_HOME off tmpfs" % want in out,
                             warned, (fstype, out))
            self.assertEqual("TMPDIR" in out, warned)

    def test_fs_type_longest_mount(self):
        "AC-6 _fs_type is the type of the longest mount point containing the path (or its nearest existing parent); None without a mount table"
        a, b = os.path.join(self.st, "m"), os.path.join(self.st, "m", "keep")
        os.makedirs(b)
        os.makedirs(os.path.join(self.st, "mx"))
        mounts = self.write_file(os.path.join(self.st, "mounts"),
                                 "rootfs / ext4 rw 0 0\ntmpfs %s tmpfs rw 0 0\nx %s ext4 rw 0 0\n" % (a, b))
        for path, want in ((os.path.join(a, "new", "dir"), "tmpfs"), (os.path.join(b, "z"), "ext4"),
                           (os.path.join(self.st, "mx", "y"), "ext4")):
            self.assertEqual(cli._fs_type(path, mounts), want, path)
        self.assertIsNone(cli._fs_type(a, os.path.join(self.st, "no-such-mounts")))

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
