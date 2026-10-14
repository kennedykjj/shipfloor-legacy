"""The machine-wide cycle (shipfloor_core/cycle.py, run by shipfloor-dispatch.sh): one project at a time (Project.run:
bring its control checkout to origin/<main>, snapshot and validate the config, run dispatch.sh, or skip it and say why),
and the cycle around them (run_cycle: the registry, dispatch.pid, PAUSE, the waits, the health line). Real git repos
(git is the behavior); dispatch.sh is a stub (SHIPFLOOR_DISPATCH). A real cycle over several projects, each in its own
process, is dispatch-cli.test.sh's."""
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
from unittest import mock

import dispatch_support as ds
from shipfloor_core import cycle, project

ISO = ds.ISO


class CycleCase(ds.support.Case):
    captured = ds.DispatchCase.captured
    git = ds.DispatchCase.git

    def setUp(self):
        super().setUp()
        os.environ.update(ds.GIT_ENV)
        for k in ("FACTORY_CONFIG", "FACTORY_HOME"):
            del os.environ[k]
        self.shome = os.environ["SHIPFLOOR_HOME"]
        os.makedirs(self.shome, exist_ok=True)
        for name, new in (("cfg", ds.fast_cfg), ("machine", ds.fast_machine)):
            p = mock.patch.object(project, name, new)
            p.start()
            self.addCleanup(p.stop)
        self.ran_file = os.path.join(self.tmp, "ran")
        stub = self.write("bin/dispatch", '#!/bin/sh\necho "$FACTORY_PROJECT $PWD $FACTORY_CONFIG $FACTORY_CONTROL_REFRESH" '
                                          '>> "%s"\n' % self.ran_file)
        os.chmod(stub, 0o755)
        os.environ["SHIPFLOOR_DISPATCH"] = stub
        self.addCleanup(os.chdir, os.getcwd())

    def ran(self):
        return open(self.ran_file).read().splitlines() if os.path.exists(self.ran_file) else []

    def project(self, slug="shop", cfg=None):
        """A repo with a bare remote whose main carries .shipfloor/factory.yml (cfg: its text; "-": none), registered."""
        remote = self.path(slug + "-remote.git")
        self.git("init", "-q", "--bare", remote)
        repo = self.path(slug + "-repo")
        self.git("init", "-q", "-b", "main", repo)
        self.write(os.path.join(repo, "README.md"), "base\n")
        if cfg != "-":
            text = cfg if cfg is not None else open(ds.FIXTURE_CONFIG).read().replace("name: shop", "name: " + slug)
            self.write(os.path.join(repo, ".shipfloor", "factory.yml"), text)
        self.git("-C", repo, "add", "-A")
        self.git("-C", repo, "commit", "-qm", "cfg")
        self.git("-C", repo, "remote", "add", "origin", remote)
        self.git("-C", repo, "push", "-q", "origin", "main")
        with open(os.path.join(self.shome, "registry.tsv"), "a") as f:
            f.write("%s\t%s\t%s\tmain\n" % (slug, repo, os.path.join(self.shome, "projects", slug, "wt")))
        self.repo, self.remote = repo, remote
        self.control = os.path.join(self.shome, "projects", slug, "control")
        return repo

    def bump(self, number):
        p = os.path.join(self.repo, ".shipfloor", "factory.yml")
        self.write(p, re.sub(r"number: \d+", "number: %d" % number, open(p).read()))
        self.git("-C", self.repo, "commit", "-qam", "bump %d" % number)
        self.git("-C", self.repo, "push", "-q", "origin", "main")

    def run_project(self, slug="shop", lang=""):
        """cycle-project for one registered project, in this process: its exit code; self.out / self.err."""
        row = [l.split("\t") for l in open(os.path.join(self.shome, "registry.tsv")).read().splitlines()
               if l.startswith(slug + "\t")][0]
        with self.captured():
            self.rc = cycle.Project(slug, lang).run(row[1], row[2], row[3])
        return self.rc

    def run_cycle(self):
        with self.captured():
            self.rc = cycle.run_cycle(self.shome)
        return self.rc

    def health(self):
        return [json.loads(l) for f in sorted(glob.glob(os.path.join(self.shome, "logs", "health-*.jsonl")))
                for l in open(f) if l.strip()]

    def skipped(self, slug="shop"):
        p = os.path.join(self.shome, "projects", slug, "SKIPPED")
        return open(p).read() if os.path.exists(p) else None


class OneProject(CycleCase):
    def test_runs_from_origin_main(self):
        "a project's dispatch runs with the config committed on origin/main (outside the control checkout) and no refresh of its own"
        self.project()
        self.assertEqual(self.run_project(), 0)
        home = os.path.join(self.shome, "projects", "shop")
        self.assertEqual(self.ran(), ["shop %s %s/factory.yml 0" % (os.getcwd(), home)])
        self.assertTrue(os.path.isfile(os.path.join(self.control, ".shipfloor", "factory.yml")))
        self.assertIsNone(self.skipped())

    def test_control_follows_origin(self):
        "the control checkout follows origin/main and drops local edits"
        self.project()
        self.run_project()
        self.bump(8)
        cfg = os.path.join(self.control, ".shipfloor", "factory.yml")
        with open(cfg, "a") as f:
            f.write("tampered\n")
        self.run_project()
        text = open(cfg).read()
        self.assertIn("number: 8", text)
        self.assertNotIn("tampered", text)

    def test_committed_config_wins(self):
        "the gates' config is the committed one: an uncommitted edit in the control checkout is ignored"
        repo = self.project()
        os.makedirs(os.path.join(self.shome, "projects", "shop"))
        self.git("-C", repo, "worktree", "add", "-q", "--detach", self.control, "main")
        cfg = os.path.join(self.control, ".shipfloor", "factory.yml")
        self.write(cfg, open(cfg).read().replace("number: 7", "number: 99"))
        os.environ["FACTORY_CONTROL_REFRESH"] = "0"
        self.run_project()
        self.assertIn("number: 7", open(os.path.join(self.shome, "projects", "shop", "factory.yml")).read())

    def assert_skipped(self, reason, slug="shop"):
        self.assertEqual(self.rc, 1)
        self.assertEqual(self.ran(), [])
        s = self.skipped(slug)
        self.assertRegex(s, r"^%s\t[^\t\n]+\n$" % ISO, "one line: <iso date><TAB><reason>")
        self.assertEqual(s.split("\t", 1)[1].rstrip("\n"), reason)
        self.assertRegex(self.err, r"%s shipfloor: %s: %s; skipped" % (ISO, slug, re.escape(reason)))

    def test_no_or_invalid_config(self):
        "no config on origin/main, or one that does not validate: skipped (exit 1), not dispatched, why in SKIPPED"
        self.project(cfg="-")
        self.run_project()
        self.assert_skipped("no .shipfloor/factory.yml on origin/main")
        self.project("blog", cfg="project: {name: broken}\n")
        self.run_project("blog")
        self.assert_skipped("invalid .shipfloor/factory.yml on origin/main", "blog")

    def test_git_failure(self):
        "a git failure: the reason is the fixed words and git's first fatal line; the first failed time is kept; a good cycle clears it"
        self.project()
        self.run_project()
        os.unlink(self.ran_file)
        self.git("-C", self.repo, "remote", "set-url", "origin", self.path("no-such-remote"))
        self.run_project()
        reason = self.skipped().split("\t", 1)[1].rstrip("\n")
        self.assertTrue(reason.startswith("cannot bring the control checkout to origin/main: fatal: "), reason)
        self.assertIn("does not appear to be a git repository", reason)
        self.assertNotIn("Could not read from remote repository", reason)
        self.assert_skipped(reason)
        self.write(os.path.join(self.shome, "projects", "shop", "SKIPPED"), "2026-10-09T20:06:50-03:00\t%s\n" % reason)
        self.run_project()
        self.assertTrue(self.skipped().startswith("2026-10-09T20:06:50-03:00\t"))
        self.git("-C", self.repo, "remote", "set-url", "origin", self.remote)
        self.assertEqual(self.run_project(), 0)
        self.assertIsNone(self.skipped())
        self.assertEqual(len(self.ran()), 1)

    def test_stale_index_lock(self):
        "an index.lock older than SHIPFLOOR_STALE_LOCK_MIN (10) is a dead git's: removed and named; a younger one skips the project"
        os.environ["SHIPFLOOR_LOCK_RETRY_S"] = "0"
        wrong = []
        for i, (age, limit, removed) in enumerate(((5, None, False), (15, None, True), (5, "3", True), (15, "30", False))):
            if os.path.exists(os.path.join(self.shome, "registry.tsv")):
                os.unlink(os.path.join(self.shome, "registry.tsv"))
            slug = "p%d" % i
            self.project(slug)
            self.run_project(slug)
            lock = os.path.join(self.git("-C", self.control, "rev-parse", "--absolute-git-dir"), "index.lock")
            self.bump(8)
            open(lock, "w").close()
            os.utime(lock, (time.time() - age * 60,) * 2)
            os.environ.pop("SHIPFLOOR_STALE_LOCK_MIN", None)
            if limit:
                os.environ["SHIPFLOOR_STALE_LOCK_MIN"] = limit
            before = len(self.ran())
            rc = self.run_project(slug)
            got = (not os.path.exists(lock), rc, len(self.ran()) - before)
            if got != ((True, 0, 1) if removed else (False, 1, 0)):
                wrong.append((age, limit, got))
            if removed and "removed a stale index.lock (older than %s min): %s" % (limit or "10", lock) not in self.err:
                wrong.append((age, limit, self.err))
            if not removed and "index.lock" not in (self.skipped(slug) or ""):
                wrong.append((age, limit, "SKIPPED does not name the lock", self.skipped(slug)))
        self.assertEqual(wrong, [])

    def test_long_paths_are_cleaned(self):
        "files a run left with very long paths in the control checkout are cleaned, not a reason to skip"
        self.project()
        self.run_project()
        deep = os.path.join(self.control, "node_modules", *(["a-rather-long-directory-name-0123456789"] * 8))
        os.makedirs(deep)
        open(os.path.join(deep, "left-by-a-run.js"), "w").close()
        self.bump(12)
        os.environ["SHIPFLOOR_LOCK_RETRY_S"] = "0"
        self.assertEqual(self.run_project(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.control, "node_modules")))
        self.assertIn("number: 12", open(os.path.join(self.control, ".shipfloor", "factory.yml")).read())

    def test_usage(self):
        "cycle-project needs slug, repo, worktrees and main"
        with self.captured():
            rc = cycle.main_project(["shop", "--lang", "en"])
        self.assertEqual(rc, 2)
        self.assertIn("usage: sf.py cycle-project <slug> <repo> <worktrees> <main> [--lang <language>]", self.err)


class TheCycle(CycleCase):
    def register(self):
        self.write(os.path.join(self.shome, "registry.tsv"), "shop\t/x/shop\t/x/wt\tmain\n")

    def test_no_registry(self):
        "a missing or empty registry: exit 0, nothing said, written or dispatched"
        for _ in range(2):
            self.assertEqual(self.run_cycle(), 0)
            self.assertEqual((self.out, self.err, self.ran()), ("", "", []))
            self.assertFalse(os.path.exists(os.path.join(self.shome, "logs")))
            self.assertFalse(os.path.exists(os.path.join(self.shome, "dispatch.pid")))
            open(os.path.join(self.shome, "registry.tsv"), "w").close()

    def test_pause(self):
        "a global PAUSE: exit 0, nothing dispatched, one health line (exit 0, no overlap), dispatch.pid removed"
        self.register()
        open(os.path.join(self.shome, "PAUSE"), "w").close()
        self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(self.ran(), [])
        self.assertEqual([(h["cycle"]["exit"], h["cycle"]["overlap"]) for h in self.health()], [(0, False)])
        self.assertFalse(os.path.exists(os.path.join(self.shome, "dispatch.pid")))

    def test_usage_limit(self):
        "a recent usage limit in any project pauses the cycle: exit 0, a dated line in the machine's language, the health line"
        self.register()
        log = os.path.join(self.shome, "projects", "blog", "logs", "x-5-develop.log")
        self.write(log, "== start /sf:develop 5\nYou've hit your session limit · resets 6pm\n")
        self.assertEqual(self.run_cycle(), 0)
        self.assertRegex(self.out, r"^%s shipfloor: Claude usage limit hit recently; waiting\n$" % ISO)
        self.assertEqual([(h["cycle"]["exit"], h["cycle"]["overlap"]) for h in self.health()], [(0, False)])
        self.write(os.path.join(self.shome, "config.yml"), "language: pt-BR\n")
        self.run_cycle()
        self.assertIn("shipfloor: limite de uso do Claude atingido há pouco; aguardando", self.out)
        self.assertEqual(self.ran(), [])

    def test_AC4_usage_limit_names_codex(self):
        "AC-4 a recent Codex usage limit pauses the cycle and the line names Codex (Codex in pt-BR too); a Claude one still says Claude"
        self.register()
        log = os.path.join(self.shome, "projects", "blog", "logs", "x-5-develop.log")
        start = "== start /sf:develop 5 2026-10-14T10:00:00-03:00 pid=1 model=gpt-6-sol weight=standard runtime=%s\n"
        end = "== end /sf:develop 5 exit=1 2026-10-14T10:20:00-03:00 outcome=usage_limit\n"
        self.write(log, start % "codex" + "some other words\n" + end)
        self.assertEqual(self.run_cycle(), 0)
        self.assertRegex(self.out, r"%s shipfloor: Codex usage limit hit recently; waiting\n" % ISO)
        self.assertEqual(self.ran(), [])
        self.write(os.path.join(self.shome, "config.yml"), "language: pt-BR\n")
        self.run_cycle()
        self.assertIn("shipfloor: limite de uso do Codex atingido há pouco; aguardando", self.out)
        self.write(log, start % "claude-code" + "some other words\n" + end)
        self.run_cycle()
        self.assertIn("shipfloor: limite de uso do Claude atingido há pouco; aguardando", self.out)
        self.assertNotIn("Codex", self.out)

    def test_github_limit(self):
        "a fresh GitHub-limit mark holds every project: exit 0 and says so"
        self.register()
        open(os.path.join(self.shome, "github-limited"), "w").close()
        self.assertEqual(self.run_cycle(), 0)
        self.assertIn("shipfloor: GitHub API limit hit recently; waiting", self.out)
        self.assertEqual(self.ran(), [])

    def age(self, path, days):
        t = time.time() - days * 86400
        for root, dirs, files in os.walk(path):
            for n in dirs + files:
                os.utime(os.path.join(root, n), (t, t), follow_symlinks=False)
        os.utime(path, (t, t), follow_symlinks=False)

    def test_home_tmp_sweep(self):
        "AC-4 AC-5 a cycle removes what in <home>/tmp has not changed for over 3 days, logging each; keeps the fresh, the recently touched and anything outside it"
        self.register()
        open(os.path.join(self.shome, "github-limited"), "w").close()  # a cycle that only waits still sweeps
        tmp = os.path.join(self.shome, "tmp")
        outside = self.path("outside")
        self.write(os.path.join(outside, "precious"), "keep")
        self.write(os.path.join(tmp, "old-file"), "x")
        self.write(os.path.join(tmp, "old-dir", "deep", "f"), "x")
        self.write(os.path.join(tmp, "mixed", "old"), "x")
        self.write(os.path.join(tmp, "mixed", "new"), "x")
        self.write(os.path.join(tmp, "fresh-file"), "x")
        self.write(os.path.join(tmp, "fresh-dir", "f"), "x")
        self.write(os.path.join(tmp, "5", "tmp", "scratch"), "x")
        os.symlink(outside, os.path.join(tmp, "old-link"))
        for n in ("old-file", "old-dir", "5"):
            self.age(os.path.join(tmp, n), 4)
        self.age(os.path.join(tmp, "mixed"), 4)
        self.write(os.path.join(tmp, "mixed", "new"), "y")  # touched now: the folder is in use
        self.age(os.path.join(tmp, "old-link"), 4)
        self.age(os.path.join(tmp, "fresh-file"), 2)
        self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(sorted(os.listdir(tmp)), ["fresh-dir", "fresh-file", "mixed"])
        self.assertTrue(os.path.isfile(os.path.join(outside, "precious")), "a symlink is unlinked, never followed")
        for name in ("old-file", "old-dir", "old-link"):
            self.assertRegex(self.out + self.err, r"%s shipfloor: removed tmp/%s\n" % (ISO, name))
        self.assertNotIn("removed tmp/fresh", self.out + self.err)

    def test_home_tmp_sweep_needs_the_claim(self):
        "AC-5 a cycle that finds another one running, or a PAUSE, sweeps nothing"
        self.register()
        old = os.path.join(self.shome, "tmp", "old-file")
        self.write(old, "x")
        self.age(old, 9)
        self.write(os.path.join(self.shome, "dispatch.pid"), "%d\n" % os.getpid())
        self.run_cycle()
        self.assertTrue(os.path.exists(old))

    def test_overlap(self):
        "a cycle that finds another one running (a live pid in a fresh dispatch.pid): exit 0, nothing dispatched, recorded as an overlap, its marker left alone"
        self.register()
        pid = os.path.join(self.shome, "dispatch.pid")
        self.write(pid, "%d\n" % os.getpid())
        self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(self.ran(), [])
        self.assertEqual([(h["cycle"]["exit"], h["cycle"]["overlap"]) for h in self.health()], [(0, True)])
        self.assertEqual(open(pid).read(), "%d\n" % os.getpid())

    def test_overlap_at_30_seconds(self):
        "every 30 s: a cycle still running past its 30 s (another process holding dispatch.pid, 45 s old) makes the next tick an overlap that dispatches nothing; once it ends, the next tick dispatches"
        self.register()
        pid = os.path.join(self.shome, "dispatch.pid")
        go = os.path.join(self.tmp, "go")
        holder = subprocess.Popen(
            [sys.executable, "-c", "import os, sys, time; sys.path[:0] = sys.argv[3:]; from shipfloor_core import cycle\n"
             "c = cycle.Claim(sys.argv[1]); c.take(); assert not c.overlap\n"
             "while not os.path.exists(sys.argv[2]): time.sleep(0.05)\nc.release()", self.shome, go, *sys.path])
        self.addCleanup(holder.kill)
        for _ in range(200):
            if os.path.exists(pid) and open(pid).read().strip() == str(holder.pid):
                break
            time.sleep(0.05)
        os.utime(pid, (time.time() - 45,) * 2)  # the long cycle started 45 s ago: the 30 s tick came and went
        self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(self.ran(), [])
        self.assertEqual([(h["cycle"]["exit"], h["cycle"]["overlap"]) for h in self.health()], [(0, True)])
        self.assertEqual(open(pid).read().strip(), str(holder.pid), "the running cycle's marker is left alone")
        open(go, "w").close()
        self.assertEqual(holder.wait(10), 0)
        self.assertFalse(os.path.exists(pid))
        self.run_cycle()
        self.assertEqual([h["cycle"]["overlap"] for h in self.health()], [True, False], "the next tick runs")

    def test_claim(self):
        "dispatch.pid: a fresh one (live pid, or still empty) is a running cycle; one older than SHIPFLOOR_CYCLE_STALE_MIN (30) or with a dead pid is taken over"
        pid = os.path.join(self.shome, "dispatch.pid")
        dead = __import__("dispatch_select").dead_pid()
        wrong = []
        for text, age, stale_min, overlap in (("%d" % os.getpid(), 0, None, True), ("", 0, None, True),
                                              ("%d" % os.getpid(), 10, None, True), ("%d" % os.getpid(), 40, None, False),
                                              ("%d" % os.getpid(), 10, "5", False), ("%d" % dead, 0, None, False)):
            self.write(pid, text)
            os.utime(pid, (time.time() - age * 60,) * 2)
            os.environ.pop("SHIPFLOOR_CYCLE_STALE_MIN", None)
            if stale_min:
                os.environ["SHIPFLOOR_CYCLE_STALE_MIN"] = stale_min
            c = cycle.Claim(self.shome)
            c.take()
            mine = open(pid).read() == "%d\n" % os.getpid()
            c.release()
            if (c.overlap, mine or c.overlap, os.path.exists(pid)) != (overlap, True, overlap):
                wrong.append((text, age, stale_min, c.overlap, os.path.exists(pid)))
        c = cycle.Claim(self.shome)
        c.take()
        self.assertEqual((c.overlap, open(pid).read()), (False, "%d\n" % os.getpid()), "none there: taken")
        self.assertEqual(wrong, [])


class CodexPipeline(ds.CodexCase):
    """`runtime: codex` over a fake `codex`: the dispatcher runs each stage on it."""

    def test_AC1_a_card_goes_through_the_stages_on_codex(self):
        "AC-1 runtime: codex with a fake codex: refine, develop and validate each run on it, with the sandbox, the generated prompt and the Codex trailer; claude is never started"
        self.board(queues={"Ready for Refinement": 70, "Ready for Dev": 54, "Validation": 60})
        self.assertEqual(self.cycle(), 0, self.err)
        self.assertEqual(self.claude_calls(), [], "no fallback to Claude Code")
        calls = {c["stdin"].split("Card: #")[-1].strip(): c for c in self.codex_calls()}
        self.assertEqual(sorted(calls), ["54", "60", "70"])
        for n, stage in (("70", "refine"), ("54", "develop"), ("60", "validate")):
            call = calls[n]
            self.assertEqual(call["argv"][0], "exec")
            self.assertEqual(self.flag(call, "-s"), "workspace-write")
            self.assertEqual(os.path.realpath(self.flag(call, "-C")), os.path.realpath(self.home + "/control"))
            self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(self.home + "/control"))
            for flag in ("--json", "--skip-git-repo-check"):
                self.assertIn(flag, call["argv"])
            self.assertEqual(call["argv"][-1], "-", "the prompt comes on stdin")
            self.assertTrue(self.flag(call, "-o").endswith(".last"), "the final message goes beside the log")
            self.assertIn("PROMPT " + stage, call["stdin"], "the prompt is the stage's generated one")
            self.assertEqual(call["env"]["CODEX_HOME"], self.codex_home, "the factory's CODEX_HOME, never the owner's")
            self.assertEqual(call["env"]["SHIPFLOOR_TRAILER"], "Co-Authored-By: Codex <noreply@openai.com>")
            self.assertEqual((call["env"]["SHIPFLOOR_FACTORY"], call["env"]["SHIPFLOOR_RUN_LOCK"]),
                             ("1", "%s/locks/%s-%s.lock" % (self.home, stage, n)))
            log = self.log(stage, n).splitlines()
            self.assertRegex(log[0], r"^== start /sf:%s %s %s pid=\d+ .*runtime=codex$" % (stage, n, ISO))
            self.assertRegex(log[-1], r"^== end /sf:%s %s exit=0 %s outcome=ok$" % (stage, n, ISO))


class CodexUsageLimit(ds.CodexCase):
    def test_AC4_the_limit_text_is_the_outcome_and_the_next_cycle_waits(self):
        "AC-4 a Codex run that prints the usage limit ends on outcome=usage_limit, and the next cycle starts nothing and says Codex"
        self.board(queues={"Ready for Dev": 54})
        self.set_fake(codex={"say": "You’ve hit your usage limit. Upgrade to Plus to continue.", "exit": 1})
        self.assertEqual(self.cycle(), 0, self.err)
        self.assertRegex(self.log("develop", 54).splitlines()[-1], r"^== end /sf:develop 54 exit=1 %s outcome=usage_limit$" % ISO)
        self.board(queues={"Ready for Dev": 55})
        self.launches = []
        self.cycle(runs=False)
        self.assertEqual(self.launches, [], "new runs wait")
        self.assertIn("Codex usage limit hit recently; waiting", self.out)

    def test_AC4_outcome_of_the_adapter(self):
        "AC-4 the adapter's outcome: usage_limit for the limit's wording (curly, escaped or plain apostrophe, credits, spend cap, quota, Plus, 429), ok on exit 0, fail otherwise"
        import runtimes
        outcome = runtimes.get("codex").outcome
        for text in ("You’ve hit your usage limit. Try again at 6pm.", "{\"message\":\"You\\u2019ve hit your usage limit\"}",
                     "You've hit your usage limit", "You are out of credits", "You hit your spend cap",
                     "Quota exceeded for this account", "Please upgrade to Plus to keep going",
                     "exceeded retry limit, last status: 429 Too Many Requests"):
            for rc in (0, 1):
                self.assertEqual(outcome(rc, "work\n" + text + "\nmore\n"), "usage_limit", (rc, text))
        self.assertEqual(outcome(1, ("x\n" + "You’ve hit your usage limit").encode("utf-8")), "usage_limit", "a block as bytes")
        self.assertEqual((outcome(0, "all fine\n"), outcome(2, "boom\n")), ("ok", "fail"))
