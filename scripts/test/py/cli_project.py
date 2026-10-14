"""The project helpers in process (shipfloor_core/project.py, text.py's say): resolve, snapshot, the tmp helpers, card
specs and weights, and the command lines behind lib/project.sh (sf.py project) and shipfloor-config.sh (sf.py config),
on a fixture state: a registered project, its control checkout, card worktrees, a tmp/ folder and specs."""
import os
import time

from cli_support import CliCase, ROOT, git
from shipfloor_core import project, text

SPECS = "docs/superpowers/specs"
SAY = """acceptance tests changed after the QA commit (beyond what merges from main brought):
acceptance tests changed after the QA commit
the owner can review these files and record them as they stand: shipfloor accept
QA commit abc1234 has no files
red: tests passed before implementation; they prove nothing
migration: V3__x.sql already exists on the base; applied migrations are immutable (add a new file)
Back to Coding: the gates failed
Deployed: merge 12 min from the start of this deploy run.
fix round 1 of 2: build
dispatch: #162 runs on opus, one model up after sonnet failed gate green
outside working hours; runs start again at 08:30
Factory report
== start
nothing to translate here
a line with ação and çã accents, and a trailing space
"""


class State(CliCase):
    """mk_state: sets self.repo, self.hp (the project's home) and self.wtr (its worktrees)."""

    def state(self, cfg=True, env=True):
        self.repo = self.new_repo("repo")
        self.other = self.new_repo("other")
        self.hp = os.path.join(self.sh, "projects", "shop")
        self.wtr = os.path.join(self.hp, "wt")
        if cfg:
            self.write_file(os.path.join(self.repo, ".shipfloor", "factory.yml"), self.fixture())
            git("-C", self.repo, "add", "-A")
            git("-C", self.repo, "commit", "-qm", "config")
        git("-C", self.repo, "worktree", "add", "-q", "--detach", os.path.join(self.hp, "control"))
        self.write_file(os.path.join(self.sh, "registry.tsv"), "shop\t%s\t%s\n" % (self.repo, self.wtr))
        for n, br in (("7", "feat/7-demo"), ("9", "other"), ("10", "feat/10-nospec")):
            git("-C", self.repo, "worktree", "add", "-q", "-b", br, os.path.join(self.wtr, n))
        self.write_file(os.path.join(self.wtr, "7", SPECS, "2026-01-01-demo-design.md"), "# Demo\n\n**Weight:** heavy\n\n## Product\n")
        self.write_file(os.path.join(self.wtr, "9", SPECS, "2026-01-01-demo-design.md"), "# Other\n\n**Weight:** light\n\n## Product\n")
        # tmp/: 7 is Done (stale), 8 is Coding, 9 is off the board (stale), 10 is off the board but locked; strays old and new
        for n in ("7", "8", "9", "10"):
            os.makedirs(os.path.join(self.hp, "tmp", n))
        os.makedirs(os.path.join(self.hp, "locks"))
        git("-C", self.repo, "worktree", "add", "-q", "--detach", os.path.join(self.hp, "tmp", "7", "wt"))
        self.write_file(os.path.join(self.hp, "board.tsv"), "7\tDone\n8\tCoding\n")
        self.write_file(os.path.join(self.hp, "locks", "dev-10.lock"), "")
        old = time.time() - 10 * 86400
        for name, age in (("stray-12.log", old), ("new-13.log", None), ("old-8.log", old), ("old-99.log", old), ("old-7.log", old)):
            p = self.write_file(os.path.join(self.hp, "tmp", name), "x\n")
            if age:
                os.utime(p, (age, age))
        self.write_file(os.path.join(self.hp, "factory.yml"), self.fixture())
        if env:
            project.use("shop", self.repo, self.wtr, "main")

    def pm(self, *args, cwd=None):
        """sf.py project <args>: (rc, out, err)."""
        return self.call(project.main, list(args), cwd=cwd)

    def pc(self, *args, cwd=None):
        """sf.py config <args> (shipfloor-config.sh past its step fast path): (rc, out, err)."""
        return self.call(project.config_main, list(args), cwd=cwd)


class Resolve(State):
    def setUp(self):
        super().setUp()
        self.state(env=False)

    def test_resolve(self):
        "resolve from a card worktree or the repository: the registered project, its home, worktrees and config"
        want = dict(project="shop", repo=self.repo, main="main", home=self.hp, wt_root=self.wtr,
                    config=os.path.join(self.hp, "factory.yml"))
        for d in (os.path.join(self.wtr, "7"), self.repo):
            self.assertEqual(self.call(lambda: project.resolve(), cwd=d)[0], want)
            for k in ("FACTORY_PROJECT", "FACTORY_CONFIG"):
                self.assertNotIn(k, os.environ)  # the call's env went with it

    def test_resolve_failure(self):
        "resolve outside a registered project: the message names the directory; sf.py project resolve prints return 1"
        with self.assertRaises(project.ProjectError) as e:
            self.call(lambda: project.resolve(), cwd=self.other)
        self.assertEqual(str(e.exception), "shipfloor: %s is not in a registered project (shipfloor add <repo>)" % self.other)
        rc, out, err = self.pm("resolve", cwd=self.other)
        self.assertEqual((rc, out), (1, "return 1\n"))
        self.assertIn("is not in a registered project", err)

    def test_resolve_exports(self):
        "sf.py project resolve and use print one export of the six variables, each value quoted for the shell"
        rc, out, _ = self.pm("resolve", cwd=os.path.join(self.wtr, "7"))
        self.assertEqual(rc, 0)
        self.assertEqual(out, "export FACTORY_PROJECT=shop FACTORY_REPO=%s FACTORY_MAIN=main FACTORY_HOME=%s "
                              "FACTORY_WT_ROOT=%s FACTORY_CONFIG=%s/factory.yml\n" % (self.repo, self.hp, self.wtr, self.hp))
        rc, out, _ = self.pm("use", "web", "/r e/p'$x", "", "dev")
        self.assertIn("FACTORY_PROJECT=web FACTORY_REPO='/r e/p'\"'\"'$x' FACTORY_MAIN=dev", out)
        self.assertIn("FACTORY_WT_ROOT=%s/projects/web/wt" % self.sh, out)
        os.environ["FACTORY_CONFIG"] = "/given.yml"
        self.assertEqual(self.pm("resolve", cwd=self.other), (0, "", ""))  # a known project: nothing to do

    def test_config_from_snapshot(self):
        "sf.py config reads the snapshot of the project's main, not the checkout it runs in; outside a project exit 2"
        evil = self.fixture().replace("acme/shop", "evil/shop")
        self.write_file(os.path.join(self.repo, ".shipfloor", "factory.yml"), evil)
        for d in (self.repo, os.path.join(self.wtr, "7")):
            self.assertEqual(self.pc("get", "project.repo", cwd=d), (0, "acme/shop\n", ""))
        rc, out, _ = self.pc("describe", cwd=self.repo)
        self.assertIn("projects/shop", out)
        self.assertIn("projects/shop/wt", out)
        for d in (self.other, self.path("plain")):
            rc, out, err = self.pc("get", "project.repo", cwd=d)
            self.assertEqual(rc, 2)
            self.assertIn("is not in a registered project", err)
        os.environ["FACTORY_CONFIG"] = os.path.join(self.repo, ".shipfloor", "factory.yml")
        self.assertEqual(self.pc("get", "project.repo", cwd=self.repo)[1], "evil/shop\n")  # an explicit one wins

    def test_config_validate_and_machine(self):
        "sf.py config: machine needs no project; validate exits 0, or 1 on a pattern grep -E refuses; forbidden covers .shipfloor/"
        rc, out, _ = self.pc("machine", "values", "pool", cwd=self.other)
        self.assertEqual((rc, out), (0, "4\0"))
        os.environ["FACTORY_CONFIG"] = os.path.join(self.hp, "factory.yml")
        self.assertEqual(self.pc("validate")[0], 0)
        rc, out, _ = self.pc("regex", "forbidden")
        self.assertRegex(".shipfloor/factory.yml", out.strip())
        self.assertIn(".shipfloor/", self.read(os.path.join(ROOT, "templates", "factory-guard.yml")))
        bad = self.write_file(self.path("bad.yml"), self.fixture() + 'acceptance_assertions: "[[:foo:]]"\n')
        os.environ["FACTORY_CONFIG"] = bad
        rc, out, err = self.pc("validate")
        self.assertEqual(rc, 1)
        self.assertIn("is not a valid grep -E pattern", out + err)


class Snapshot(State):
    def test_snapshot(self):
        "snapshot writes the config committed at control's HEAD to the project's home"
        self.state()
        os.remove(os.path.join(self.hp, "factory.yml"))
        self.assertTrue(project.snapshot())
        self.assertEqual(self.read(os.path.join(self.hp, "factory.yml")), self.fixture())
        self.assertEqual(self.pm("snapshot")[0], 0)

    def test_snapshot_no_config(self):
        "snapshot with no committed config fails"
        self.state(cfg=False)
        self.assertFalse(project.snapshot())
        self.assertEqual(self.pm("snapshot")[0], 1)
        self.assertEqual(project.config_path(self.repo, "HEAD"), None)


class Tmp(State):
    def setUp(self):
        super().setUp()
        self.state()

    def test_stale(self):
        "stale_tmp names the cards 7 (Done) and 9 (off the board), not 8 (Coding) or 10 (off the board, but a run holds its lock)"
        self.assertEqual(sorted(project.stale_tmp()), ["7", "9"])
        self.assertEqual(self.pm("stale-tmp")[1], "7\n9\n")

    def test_clean(self):
        "clean_tmp removes tmp/7 and the worktree a run left under it"
        self.assertEqual(self.pm("clean-tmp", "7")[0], 0)
        self.assertFalse(os.path.exists(os.path.join(self.hp, "tmp", "7")))
        self.assertEqual(len(git("-C", self.repo, "worktree", "list").splitlines()), 5)

    def test_sweep(self):
        "sweep_tmp removes the stale cards' dirs and old strays not tied to an active card, and prints each"
        rc, out, _ = self.pm("sweep-tmp")
        self.assertEqual(sorted(out.splitlines()), ["tmp/7", "tmp/9", "tmp/old-7.log", "tmp/old-99.log", "tmp/stray-12.log"])
        self.assertTrue(os.path.exists(os.path.join(self.hp, "tmp", "new-13.log")))
        self.assertTrue(os.path.exists(os.path.join(self.hp, "tmp", "old-8.log")))

    def test_no_board(self):
        "with no board rows nothing is stale and nothing is swept"
        self.write_file(os.path.join(self.hp, "board.tsv"), "")
        self.assertEqual((project.stale_tmp(), project.sweep_tmp()), ([], []))


class Specs(State):
    def test_card_spec_and_weight(self):
        "card_spec finds the spec in the card's worktree (none without one, on another branch or without a file); card_weight reads it or says standard"
        self.state()
        self.assertTrue(project.card_spec(7).endswith("7/%s/2026-01-01-demo-design.md" % SPECS))
        for n in (8, 9, 10):
            self.assertIsNone(project.card_spec(n), n)
        self.assertEqual(self.pm("card-spec", "8"), (0, "", ""))
        self.assertEqual(self.pm("card-weight", "7")[1], "heavy\n")
        self.assertEqual([project.card_weight(n) for n in (8, 10)], ["standard", "standard"])
        self.assertTrue(self.pm("card-spec", "9", SPECS + "/")[1] == "")

    def test_spec_weight(self):
        "spec_weight: the one weight line of the header; standard for none, two, unknown, capitalised, after a section, missing"
        cases = {"none": ("# T\n\n**Issue:** #1\n\n## Product\n", "standard"),
                 "heavy": ("# T\n\n**Weight:** heavy\n\n## Product\n", "heavy"),
                 "ticks": ("# T\n\n**Weight:** `light`\n\n## Product\n", "light"),
                 "spaces": ("# T\n\n**Weight:**    standard  \n\n## Product\n", "standard"),
                 "two": ("# T\n\n**Weight:** light\n**Weight:** heavy\n\n## Product\n", "standard"),
                 "unknown": ("# T\n\n**Weight:** gigantic\n\n## Product\n", "standard"),
                 "crlf": ("# T\r\n\r\n**Weight:** heavy\r\n\r\n## Product\r\n", "heavy"),
                 "crlf-ticks": ("# T\r\n\r\n**Weight:** `light`\r\n\r\n## Product\r\n", "light"),
                 "after-section": ("# T\n\n## Product\n\n**Weight:** heavy\n", "standard"),
                 "capital": ("# T\n\n**Weight:** Heavy\n", "standard")}
        for name, (body, want) in cases.items():
            self.assertEqual(project.spec_weight(self.write(name + ".md", body)), want, name)
        self.assertEqual(project.spec_weight(self.path("w") + "/missing.md"), "standard")
        self.assertEqual(self.pm("spec-weight", self.path("w") + "/missing.md")[1], "standard\n")


class Commands(State):
    def test_project_commands(self):
        "sf.py project: native, git-common, config-path, ere-ok, cfg, machine, validate; an unknown command is the usage, exit 2"
        self.state()
        self.assertEqual(self.pm("native", "/a/b"), (0, "/a/b\n", ""))
        self.assertEqual(self.pm("git-common", self.repo)[1], os.path.join(self.repo, ".git") + "\n")
        self.assertEqual(self.pm("git-common", self.path("plain"))[0], 1)
        self.assertEqual(self.pm("config-path", self.repo, "HEAD"), (0, ".shipfloor/factory.yml\n", ""))
        self.assertEqual(self.pm("config-path", self.other, "HEAD")[0], 1)
        self.assertEqual(self.pm("ere-ok", "^[0-9]+$")[0], 0)
        self.assertEqual(self.pm("ere-ok", "a(")[0], 1)
        self.assertEqual(self.pm("cfg", "get", "project.repo")[1], "acme/shop\n")
        self.assertEqual(self.pm("machine", "values", "pool")[1], "4\0")
        self.assertEqual(self.pm("validate")[0], 0)
        rc, _, err = self.pm("nonsense")
        self.assertEqual(rc, 2)
        self.assertTrue(err.startswith("usage: sf.py project resolve|use|cfg|"), err)


class Say(CliCase):
    def test_say(self):
        "say pt-BR translates the catalog's lines, one line out per line in; en and an unknown language pass the text through"
        lines = SAY.split("\n")[:-1]
        out = [text.say("pt-BR", l).rstrip("\n") for l in lines]
        self.assertEqual(len(out), len(lines))
        self.assertIn("os testes de aceitação mudaram depois do commit do QA", out[1])
        self.assertEqual(out[-2:], lines[-2:])
        for lang in ("en", "xx"):
            self.assertEqual([text.say(lang, l) for l in lines], lines)
            self.assertEqual(text.say_bytes(lang, SAY.encode()), (0, SAY.encode(), b""))
