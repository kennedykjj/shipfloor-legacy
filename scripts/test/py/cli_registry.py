"""The shipfloor CLI in process (shipfloor_core/cli.py): install, the project registry (add, remove, list, pause,
resume), the machine pool, clean, accept, setup-board, metrics and the usage. What it prints, writes and exits with."""
import os
import re
import shutil

from cli_support import CliCase, git, plugin_copy
from shipfloor_core import cli

USAGE = """shipfloor: installs the factory scripts and manages the projects the dispatcher serves.
  install [--force]             copy scripts and templates to ~/.shipfloor/factory
  doctor                        check tools, the installed copy and every project's config
  add <repo> [--worktrees DIR]  register a local clone whose origin/main has .shipfloor/factory.yml
  remove <slug> | list | pause [slug] | resume [slug] | setup-board <slug> | metrics <slug>
  pool [set <n> | stage <stage> <n> | stacks <n>]  runs at once on this machine, per stage, and stack slots
  clean <slug>                  remove what cards left under tmp/ (the dispatcher does it every cycle)
  accept <slug> <n> <reason>    owner only: take card <n>'s acceptance tests as they stand (acceptance-intact)
  weight <slug> <n> <light|standard|heavy>  owner only: card <n>'s weight, in Spec Review (the model its runs take)
"""


class Install(CliCase):
    def install(self, uname="Linux"):
        cli.HERE = os.path.join(plugin_copy(), "scripts")
        os.environ["SF_UNAME"] = uname
        return self.ok("install")

    def test_install_copies_scripts_not_tests(self):
        "install copies the scripts and templates to <home>/factory, without the tests"
        out = self.install()
        inst = os.path.join(self.sh, "factory")
        for f in ("gate.sh", "board.sh", "dispatch.sh", "shipfloor-dispatch.sh", "shipfloor-config.sh",
                  "shipfloor_config.py", "lib/project.sh", "shipfloor", "templates/spec-template.md", ".source"):
            self.assertTrue(os.path.isfile(os.path.join(inst, f)), f)
        self.assertFalse(os.path.exists(os.path.join(inst, "test")))
        self.assertIn("installed %s → %s: 0 replaced, " % (plugin_copy(), inst), out)

    def test_install_drops_retired_files(self):
        "install drops a file the plugin no longer ships and stays complete"
        self.write_file(os.path.join(self.sh, "factory", "retired-script.sh"), "stale\n")
        out = self.install()
        self.assertFalse(os.path.exists(os.path.join(self.sh, "factory", "retired-script.sh")))
        self.assertTrue(os.path.isfile(os.path.join(self.sh, "factory", "gate.sh")))
        self.assertIn(", 1 removed", out)

    def test_install_next_line_per_system(self):
        "install's next: line names the dispatcher installer of the system it runs on (.sh on Linux/macOS, .ps1 on Windows)"
        src = plugin_copy()
        self.assertIn('then bash "%s/installer/install-dispatcher.sh"' % src, self.install("Linux"))
        self.assertIn('then bash "%s/installer/install-dispatcher.sh"' % src, self.install("Darwin"))
        self.assertIn('install-dispatcher.ps1"', self.install("MINGW64_NT-10.0"))

    def test_install_usage(self):
        "install with an unknown flag is a usage error, exit 2"
        self.ok("install", "--bogus", want=2)
        self.assertEqual(self.err, "shipfloor: usage: shipfloor install [--force]\n")


class Registry(CliCase):
    def setUp(self):
        super().setUp()
        self.r = self.with_config()
        self.top = git("-C", self.r, "rev-parse", "--show-toplevel")

    def test_add(self):
        "add registers the clone (slug, repo, worktrees, main), makes the control checkout and the config snapshot"
        out = self.ok("add", self.r)
        h = self.home_of()
        self.assertEqual(out, "registered shop (%s, worktrees in %s/wt)\n" % (self.top, h))
        self.assertEqual(self.registry(), "shop\t%s\t%s/wt\tmain\n" % (self.top, h))
        self.assertTrue(os.path.isfile(os.path.join(h, "control", ".shipfloor", "factory.yml")))
        self.assertTrue(os.path.isfile(os.path.join(h, "factory.yml")))

    def test_add_again(self):
        "add is idempotent; --worktrees sets them; adding again without it keeps them and reads the new origin/main"
        self.ok("add", self.r)
        self.ok("add", self.r)
        self.assertEqual(self.registry().count("shop\t"), 1)
        wt = self.path("wts")
        self.ok("add", self.r, "--worktrees", wt)
        self.assertIn("\t%s\t" % wt, self.registry())
        p = os.path.join(self.r, ".shipfloor", "factory.yml")
        self.write_file(p, re.sub(r"(?m)^(  name: shop)$", r"\1 # v2", self.read(p)))
        git("-C", self.r, "commit", "-qam", "v2")
        git("-C", self.r, "push", "-q", "origin", "main")
        self.ok("add", self.r)
        self.assertEqual(self.registry(), "shop\t%s\t%s\tmain\n" % (self.top, wt))
        self.assertIn("# v2", self.read(os.path.join(self.home_of(), "factory.yml")))

    def test_add_refusals(self):
        "add refuses a name another repo holds, an invalid config, a repo without one, the old .aghanim dir, a non-repo"
        self.ok("add", self.r)
        self.ok("add", self.with_config(name="other"), want=1)
        self.assertIn("shipfloor: project 'shop' is already registered for %s" % self.top, self.err)
        self.ok("add", self.with_config("project: {name: bad}\n", name="bad"), want=1)
        self.assertIn("shipfloor: invalid .shipfloor/factory.yml on origin/main", self.err)
        self.assertNotIn("bad", self.registry())
        noconf = self.new_repo("noconf")
        self.with_origin(noconf)
        self.ok("add", noconf, want=1)
        self.assertIn("shipfloor: origin/main has no .shipfloor/factory.yml", self.err)
        old = self.new_repo("old")
        self.write_file(os.path.join(old, ".aghanim", "factory.yml"), self.fixture())
        git("-C", old, "add", "-A")
        git("-C", old, "commit", "-qm", "old")
        self.with_origin(old)
        self.ok("add", old, want=1)
        self.ok("add", self.path("plain"), want=1)
        self.assertIn("is not a git repository", self.err)
        self.ok("add", want=2)
        self.ok("add", self.r, "--bogus", want=2)
        self.assertEqual(self.err, "shipfloor: add: unknown option --bogus\n")

    def test_add_main_branch(self):
        "add --main <b>: the project follows that branch, not main; an unknown branch is exit 1"
        cfg = self.fixture().replace("name: shop", "name: trunky").replace("acme/shop", "acme/trunky")
        tr = self.with_config(cfg, name="trunky")
        git("-C", tr, "push", "-q", "origin", "main:trunk")
        git("-C", tr, "commit", "-q", "--allow-empty", "-m", "main moves on")
        git("-C", tr, "push", "-q", "origin", "main")
        self.ok("add", tr, "--main", "trunk")
        top = git("-C", tr, "rev-parse", "--show-toplevel")
        self.assertIn("trunky\t%s\t%s/wt\ttrunk\n" % (top, self.home_of("trunky")), self.registry())
        control = git("-C", os.path.join(self.home_of("trunky"), "control"), "rev-parse", "HEAD")
        self.assertEqual(control, git("-C", tr, "rev-parse", "origin/trunk"))
        self.assertNotEqual(control, git("-C", tr, "rev-parse", "origin/main"))
        self.ok("add", tr, "--main", "nope-branch", want=1)
        self.assertIn("shipfloor: cannot fetch origin/nope-branch in %s" % top, self.err)

    def test_list_pause_resume(self):
        "list prints slug, state, repo, worktrees; pause and resume one project or all; an unknown slug is exit 1"
        self.ok("list")
        self.assertEqual(self.out, "no projects\n")
        self.ok("add", self.r)
        line = "shop\t%%s\t%s\t%s/wt\n" % (self.top, self.home_of())
        self.assertEqual(self.ok("list"), line % "active")
        self.ok("pause", "shop")
        self.assertTrue(os.path.exists(os.path.join(self.home_of(), "PAUSE")))
        self.assertEqual(self.ok("list"), line % "paused")
        self.ok("pause")
        self.assertTrue(os.path.exists(os.path.join(self.sh, "PAUSE")))
        self.assertEqual(self.ok("list"), "(all paused)\n" + line % "paused")
        self.ok("resume")
        self.assertFalse(os.path.exists(os.path.join(self.sh, "PAUSE")))
        self.ok("resume", "shop")
        self.assertFalse(os.path.exists(os.path.join(self.home_of(), "PAUSE")))
        self.assertEqual(self.ok("list"), line % "active")
        self.ok("pause", "nope", want=1)
        self.assertEqual(self.err, "shipfloor: no project 'nope' (shipfloor list)\n")
        self.ok("resume", "nope", want=1)

    def test_remove(self):
        "remove unregisters the project and its control checkout, keeps logs and reports; again is exit 1"
        self.ok("add", self.r)
        out = self.ok("remove", "shop")
        self.assertEqual(out, "removed shop (logs and reports stay in %s)\n" % self.home_of())
        self.assertNotIn("shop", self.registry())
        self.assertFalse(os.path.exists(os.path.join(self.home_of(), "control")))
        self.ok("remove", "shop", want=1)

    def test_clean(self):
        "clean removes tmp/<n>/ of cards that are Done or off the board and prints each; the active one stays"
        self.ok("add", self.r)
        h = self.home_of()
        for n in ("5", "6", "8"):
            os.makedirs(os.path.join(h, "tmp", n, "x"))
        self.write_file(os.path.join(h, "board.tsv"), "5\tDone\tI5\n6\tCoding\tI6\n")
        out = self.ok("clean", "shop")
        self.assertEqual(sorted(out.splitlines()), ["removed tmp/5", "removed tmp/8"])
        self.assertEqual(os.listdir(os.path.join(h, "tmp")), ["6"])
        self.ok("clean", "nope", want=1)


class Pool(CliCase):
    def test_pool(self):
        "pool shows the machine pool; set, stage and stacks change it; a refused value is exit 1 and changes nothing"
        self.assertIn("pool: 4", self.ok("pool", want=1))  # no project: no stack status, exit 1
        self.ok("pool", "set", "6")
        self.ok("pool", "stage", "validate", "3")
        out = self.ok("pool", want=1)
        self.assertIn("pool: 6", out)
        self.assertIn("validate: 3", out)
        lock = os.path.join(self.sh, "projects", "a", "locks", "validate-7.lock")
        self.write_file(os.path.join(lock, "info"), "%d 0 7\n" % os.getpid())
        self.assertIn("validate: 3 (1 running)", self.ok("pool", want=1))
        self.ok("pool", "stage", "validate", "9", want=1)
        self.ok("pool", "stage", "review", "1", want=1)
        for bad in (["x"], [], ["0"]):
            self.ok("pool", "stacks", *bad, want=1)
        self.assertIn("validate: 3 (1 running)", self.ok("pool", want=1))
        self.ok("pool", "bogus", want=2)
        self.assertEqual(self.err, "shipfloor: usage: shipfloor pool [set <n> | stage <refine|develop|validate|deploy> <n> | stacks <n>]\n")

    def test_pool_stacks(self):
        "pool lists the machine's stack slots through the first project's gate.sh stack status (exit 1: no queue); stacks <n> writes config.yml"
        self.ok("add", self.with_config())
        out = self.ok("pool", want=1)
        self.assertIn("stacks: 3", out)
        for s in ("0", "1", "2"):
            self.assertIn("  slot %s: free" % s, out)
        self.ok("pool", "stacks", "5")
        out = self.ok("pool", want=1)
        self.assertIn("stacks: 5", out)
        self.assertIn("  slot 4: free", out)
        self.assertIn("stacks: 5", self.read(os.path.join(self.sh, "config.yml")))
        self.ok("pool", "stacks", "x", want=1)
        self.assertIn("stacks: 5", self.ok("pool", want=1))


class Accept(CliCase):
    def setUp(self):
        super().setUp()
        r = self.with_config()
        self.ok("add", r, "--worktrees", self.path("wts"))
        self.w = os.path.join(self.path("wts"), "9")
        git("-C", r, "worktree", "add", "-q", "-b", "feat/9-x", self.w, "main")
        self.accepted = os.path.join(self.home_of(), "accepted.tsv")

    def qa(self, path, text, after):
        """A QA commit with that file, then `after(path)` and a commit: returns the QA commit."""
        self.write_file(os.path.join(self.w, path), text)
        git("-C", self.w, "add", "-A")
        git("-C", self.w, "commit", "-qm", "test(x): acceptance tests for #9")
        qa = git("-C", self.w, "rev-parse", "HEAD")
        after(path)
        return qa

    def test_accept_changed_file(self):
        "accept records a changed acceptance file (file, key, #n, date -Is, reason) and the gate then takes it"
        def edit(p):
            self.write_file(os.path.join(self.w, p), "resolved\n")
            git("-C", self.w, "commit", "-qam", "merge resolved by hand")
        qa = self.qa("api/src/test/NineTest.kt", "qa\n", edit)
        self.ok("accept", "shop", "9", want=2)
        self.assertEqual(self.err, "shipfloor: usage: shipfloor accept <project> <n> <reason>\n")
        self.assertEqual(self.gate("-C", self.w, "acceptance-intact", qa), 1)
        out = self.ok("accept", "shop", "9", "main", "reworded", "the", "setup")
        self.assertIn("accepted api/src/test/NineTest.kt at ", out)
        self.assertRegex(self.read(self.accepted), r"^api/src/test/NineTest\.kt\t[^\t]+\t#9\t\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d\tmain reworded the setup\n$")
        self.assertEqual(self.gate("-C", self.w, "acceptance-intact", qa), 0)
        self.assertEqual(self.ok("accept", "shop", "9", "again"), "nothing to accept: acceptance-intact already passes for card 9\n")

    def test_accept_deleted_file(self):
        "accept records a file the card deleted after the QA commit (a stub) with the key deleted"
        def delete(p):
            git("-C", self.w, "rm", "-q", p)
            git("-C", self.w, "commit", "-qm", "the real class replaces the stub")
        qa = self.qa("api/src/test/RedStubs.kt", "stub\n", delete)
        self.assertEqual(self.gate("-C", self.w, "acceptance-intact", qa), 1)
        self.assertEqual(self.ok("accept", "shop", "9", "stub", "replaced"), "accepted the deletion of api/src/test/RedStubs.kt\n")
        self.assertRegex(self.read(self.accepted), r"^api/src/test/RedStubs\.kt\tdeleted\t#9\t[^\t]+\tstub replaced\n$")
        self.assertEqual(self.gate("-C", self.w, "acceptance-intact", qa), 0)
        self.assertIn("nothing to accept", self.ok("accept", "shop", "9", "again"))

    def test_accept_refusals(self):
        "accept without a worktree or a QA commit says so, exit 1"
        self.ok("accept", "shop", "8", "why", want=1)
        self.assertIn("shipfloor: no worktree for card 8 at ", self.err)
        self.ok("accept", "shop", "9", "why", want=1)
        self.assertEqual(self.err, 'shipfloor: no QA commit ("acceptance tests for #9") on feat/9-x\n')


class BoardAndMetrics(CliCase):
    def setUp(self):
        super().setUp()
        self.ok("add", self.with_config())
        self.h = self.home_of()

    def test_setup_board(self):
        "setup-board <slug> runs setup-board.sh in the project's control checkout, with its config and home"
        self.write_file(os.path.join(self.h, "board-ids"), "PVT_x FLD_x\n")
        out = self.ok("setup-board", "shop")
        calls = self.gh_calls()
        self.assertTrue(calls.startswith("%s/control\tproject view 7 --owner acme" % self.h), calls)
        self.assertIn("project item-edit --project-id PVT_x --id I1 --field-id FLD_x --single-select-option-id opt6", calls)
        self.assertIn("label create blocked --repo acme/shop", calls)
        self.assertFalse(os.path.exists(os.path.join(self.h, "board-ids")))
        self.assertIn("): 1 items", out)
        self.assertIn("Coding: 1", out)

    def test_setup_board_refusals(self):
        "setup-board of an unknown project or none is exit 1 with the message; a missing control checkout too"
        self.ok("setup-board", "nope", want=1)
        self.assertEqual(self.err, "shipfloor: no project 'nope' (shipfloor list)\n")
        self.ok("setup-board", want=1)
        shutil.rmtree(os.path.join(self.h, "control"))
        self.ok("setup-board", "shop", want=1)
        self.assertEqual(self.err, "shipfloor: cd: %s/control: No such file or directory\n" % self.h)

    def test_metrics(self):
        "metrics <slug> prints the header and one line per report of the project; an unknown project is exit 1"
        self.write_file(os.path.join(self.h, "reports-wt", "reports", "9-x", "refine-1.json"),
                        '{"issue":9,"slug":"x","pipeline":"refine","outcome":"ok","agents":[{"role":"po","tokens":500}],'
                        '"rounds":{"a":1},"gates_failed":[],"manual_edit":false,"started_at":"2026-10-09T10:00:00-03:00",'
                        '"finished_at":"2026-10-09T10:05:00-03:00"}\n')
        self.assertEqual(self.ok("metrics", "shop"),
                         "issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit\n"
                         "9\trefine\tok\t500\t5\t1\t\tFalse\n")
        self.ok("metrics", "nope", want=1)


class Usage(CliCase):
    def test_usage(self):
        "an unknown command, no command, help and the gone migrate-home print the header's lines 2-10 on stderr, exit 2"
        for argv in (["nonsense"], [], ["help"], ["migrate-home"]):
            self.ok(*argv, want=2)
            self.assertEqual(self.err, USAGE, argv)
            self.assertEqual(self.out, "", argv)
        self.assertNotIn("migrate-home", USAGE)
        self.assertNotIn("dashboard [--port", USAGE)  # line 11 of the header is not in it, as before
