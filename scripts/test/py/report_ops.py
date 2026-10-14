"""report.sh and metrics.sh in process (shipfloor_core/report.py, metrics.py): the orphan factory-reports branch, the
worktree in the home, pull --rebase before the write, the <pipeline>-<stamp> names, a failed push, same-second reports,
usage and project resolution; the metrics TSV, its odd inputs (missing fields, no times, no home, a failed pull)."""
import contextlib
import io
import json
import os
import re

from report_support import ReportCase, git
from shipfloor_core import metrics, report

R26 = {"issue": 26, "slug": "rl", "pipeline": "refine", "outcome": "ok",
       "agents": [{"role": "product-owner", "tokens": 1000, "duration_s": 60}], "rounds": {}, "gates_failed": [],
       "manual_edit": None, "started_at": "2026-10-09T10:00:00-03:00", "finished_at": "2026-10-09T10:12:00-03:00"}
USAGE = "usage: report.sh <issue> <slug> <pipeline> <report.json> <report.md>"
HEADER = "issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit"


class Base(ReportCase):
    def setUp(self):
        super().setUp()
        self.j = self.write("in/report.json", json.dumps(R26))
        self.m = self.write("in/report.md", "# Relatorio\n")

    def rep(self, home, repo, issue, slug, pipeline, j=None):
        os.environ["FACTORY_HOME"] = home
        os.environ["FACTORY_REPO"] = repo
        return self.call(report.main, [issue, slug, pipeline, j or self.j, self.m])

    def tree(self, remote, ref="factory-reports"):
        return git("--git-dir", remote, "ls-tree", "-r", "--name-only", ref).splitlines()

    def log(self, remote, fmt="%s", *more):
        return git("--git-dir", remote, "log", "--format=" + fmt, *more, "factory-reports")

    def fixed_clock(self):
        self.double("date", "print('2026-10-14T120000')")


class Usage(Base):
    def test_help(self):
        "-h, --help and help print the usage on stdout and exit 0 before resolving a project"
        del os.environ["FACTORY_CONFIG"]
        os.environ["SHIPFLOOR_HOME"] = self.path("none")
        for a in ("-h", "--help", "help"):
            rc, out, err = self.call(report.main, [a])
            self.assertEqual(rc, 0, a)
            self.assertIn(USAGE, out)
            self.assertIn("pipeline: refine | develop | validate | deploy", out)

    def test_wrong_count(self):
        "a wrong argument count exits 2 with the usage on stderr"
        for argv in ([], ["1", "2", "3"], ["1", "2", "3", "4", "5", "6"]):
            rc, out, err = self.call(report.main, argv)
            self.assertEqual((rc, out), (2, ""), argv)
            self.assertIn(USAGE, err)

    def test_not_a_project(self):
        "outside a registered project report and metrics exit 2 naming it"
        del os.environ["FACTORY_CONFIG"]
        os.environ["SHIPFLOOR_HOME"] = self.path("none")
        rc, out, err = self.call(report.main, ["1", "s", "refine", self.j, self.m])
        self.assertEqual(rc, 2)
        self.assertIn("is not in a registered project (shipfloor add <repo>)", err)
        rc, out, err = self.call(metrics.main, [])
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("not in a registered project", err)


class Report(Base):
    def test_orphan_branch(self):
        "no remote factory-reports: an orphan branch, README first, the report on top with the trailer, main untouched"
        remote = self.bare()
        r = self.repo(remote, push=True)
        h = self.path("h1")
        rc, out, err = self.rep(h, r, "26", "rl", "refine")
        self.assertEqual(rc, 0, err)
        first = git("--git-dir", remote, "rev-list", "--max-parents=0", "factory-reports")
        self.assertEqual(git("--git-dir", remote, "show", first + ":README.md"), "# Factory reports")
        self.assertEqual(git("--git-dir", remote, "rev-list", "--count", "factory-reports"), "2")
        self.assertEqual(git("--git-dir", remote, "merge-base", "main", "factory-reports", check=False), "")
        self.assertEqual(git("--git-dir", remote, "rev-list", "--count", "main"), "1")
        subjects = self.log(remote).splitlines()
        self.assertEqual(subjects[-1], "chore(factory): start reports branch")
        self.assertTrue(subjects[0].startswith("chore(factory): report #26 refine 20"), subjects)
        self.assertIn("Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", self.log(remote, "%B", "-1"))
        files = self.tree(remote)
        self.assertTrue([f for f in files if re.match(r"reports/26-rl/refine-\d{4}-\d\d-\d\dT\d{6}\.json$", f)], files)
        self.assertTrue([f for f in files if f.startswith("reports/26-rl/refine-") and f.endswith(".md")], files)
        self.assertTrue(os.path.exists(os.path.join(h, "reports-wt", ".git")))
        # a second pipeline of the same card lands beside it
        self.assertEqual(self.rep(h, r, "26", "rl", "develop")[0], 0)
        self.assertTrue([f for f in self.tree(remote) if f.startswith("reports/26-rl/develop-")])
        # and the metrics read it back
        os.environ["FACTORY_HOME"] = h
        rc, out, err = self.call(metrics.main, [])
        self.assertIn("26\trefine\tok\t1000\t12\t0\t\t", out.splitlines())

    def test_pull_before_write(self):
        "a worktree already in the home and behind the remote pulls --rebase before writing, so the push goes through"
        remote = self.bare()
        r = self.repo(remote, push=True)
        h = self.path("h")
        self.assertEqual(self.rep(h, r, "26", "rl", "refine")[0], 0)
        other = self.fresh("other")
        git("clone", "-q", "-b", "factory-reports", remote, other)
        self.write(os.path.join(other, "reports/50-else/x.json"), "{}\n")
        git("-C", other, "add", "reports")
        git("-C", other, "commit", "-qm", "other report")
        git("-C", other, "push", "-q", "origin", "factory-reports")
        self.assertEqual(self.rep(h, r, "27", "two", "develop")[0], 0)
        files = self.tree(remote)
        self.assertIn("reports/50-else/x.json", files)
        self.assertTrue([f for f in files if f.startswith("reports/27-two/develop-")])

    def test_remote_branch_fresh_home(self):
        "a remote branch and no worktree in the home: worktree add -B resets a stale local branch, history continues"
        remote = self.bare()
        r1 = self.repo(remote, push=True)
        self.assertEqual(self.rep(self.path("h1"), r1, "26", "rl", "refine")[0], 0)
        r3 = self.repo(remote)
        git("-C", r3, "branch", "factory-reports", "main")
        stale = git("-C", r3, "rev-parse", "factory-reports")
        h3 = self.path("h3")
        self.assertFalse(os.path.exists(os.path.join(h3, "reports-wt")))
        rc, out, err = self.rep(h3, r3, "27", "two", "refine")
        self.assertEqual(rc, 0, err)
        wt = os.path.join(h3, "reports-wt")
        self.assertTrue(os.path.exists(os.path.join(wt, ".git")))
        self.assertEqual(git("-C", wt, "rev-parse", "--abbrev-ref", "HEAD"), "factory-reports")
        local = git("-C", r3, "rev-parse", "factory-reports")
        self.assertNotEqual(local, stale)
        self.assertEqual(local, git("--git-dir", remote, "rev-parse", "factory-reports"))
        files = self.tree(remote)
        self.assertTrue([f for f in files if f.startswith("reports/26-rl/refine-")], files)
        self.assertTrue([f for f in files if f.startswith("reports/27-two/refine-")], files)
        self.assertEqual(self.log(remote).count("start reports branch"), 1)
        self.assertEqual(git("--git-dir", remote, "rev-list", "--count", "main"), "1")

    def test_failed_push(self):
        "a push the remote refuses exits 1: the report stays committed in the home's worktree, the remote has no branch"
        remote = self.bare()
        hook = self.write(os.path.join(remote, "hooks", "pre-receive"), "#!/bin/sh\nexit 1\n")
        os.chmod(hook, 0o755)
        r = self.repo(remote)
        h = self.path("hf")
        rc, out, err = self.rep(h, r, "28", "three", "develop")
        self.assertEqual(rc, 1)
        self.assertEqual(git("--git-dir", remote, "branch", "--list", "factory-reports"), "")
        wt = os.path.join(h, "reports-wt")
        self.assertIn("chore(factory): report #28 develop", git("-C", wt, "log", "--format=%s", "-1"))
        self.assertTrue([f for f in git("-C", wt, "ls-tree", "-r", "--name-only", "HEAD").splitlines()
                         if f.startswith("reports/28-three/develop-")])

    def test_same_second(self):
        "two reports in one second share a name: the second replaces the first in the tree, both are commits; an identical third has nothing to commit and fails"
        self.fixed_clock()
        remote = self.bare()
        r = self.repo(remote)
        h = self.path("hs")
        j2 = self.write("in/r2.json", json.dumps(dict(R26, agents=[{"role": "po", "tokens": 2000}])))
        self.assertEqual(self.rep(h, r, "29", "same", "refine")[0], 0)
        self.assertEqual(self.rep(h, r, "29", "same", "refine", j2)[0], 0)
        self.assertEqual(sorted(f for f in self.tree(remote) if f.startswith("reports/29-same/")),
                         ["reports/29-same/refine-2026-10-14T120000.json", "reports/29-same/refine-2026-10-14T120000.md"])
        shown = git("--git-dir", remote, "show", "factory-reports:reports/29-same/refine-2026-10-14T120000.json")
        self.assertIn('"tokens": 2000', shown)
        self.assertNotIn('"tokens": 1000', shown)
        self.assertEqual(self.log(remote).count("report #29"), 2)
        self.assertEqual(self.log(remote, "%s", "-1"), "chore(factory): report #29 refine 2026-10-14T120000")
        self.assertEqual(self.rep(h, r, "29", "same", "refine", j2)[0], 1)

    def test_stamp_from_the_clock(self):
        "without a date on PATH that answers, the stamp is the clock's, shaped <pipeline>-YYYY-MM-DDTHHMMSS"
        self.double("date", "sys.exit(1)")
        remote = self.bare()
        rc, out, err = self.rep(self.path("h"), self.repo(remote), "31", "st", "validate")
        self.assertEqual(rc, 0, err)
        names = [f for f in self.tree(remote) if f.startswith("reports/31-st/")]
        self.assertRegex(names[0], r"^reports/31-st/validate-\d{4}-\d\d-\d\dT\d{6}\.json$")
        self.assertTrue(names[1].endswith(".md"))
        self.assertRegex(self.log(remote, "%s", "-1"), r"^chore\(factory\): report #31 validate 20\d\d-\d\d-\d\dT\d{6}$")

    def test_repo_from_cwd(self):
        "without FACTORY_REPO the repository is the checkout report.sh runs from; outside one it fails with git's code"
        remote = self.bare()
        r = self.repo(remote)
        os.environ["FACTORY_HOME"] = self.path("h")
        os.environ.pop("FACTORY_REPO", None)
        rc, out, err = self.call(report.main, ["32", "cwd", "refine", self.j, self.m], cwd=r)
        self.assertEqual(rc, 0, err)
        self.assertTrue([f for f in self.tree(remote) if f.startswith("reports/32-cwd/")])
        os.environ["FACTORY_HOME"] = self.path("h2")
        rc, out, err = self.call(report.main, ["33", "x", "refine", self.j, self.m], cwd=self.path("nogit"))
        self.assertNotIn(rc, (0, 2))

    def test_missing_file(self):
        "a report file that does not exist exits 1 with report.sh: <error>"
        rc, out, err = self.rep(self.path("h"), self.repo(self.bare()), "34", "x", "refine", self.path("in") + "/nope.json")
        self.assertEqual(rc, 1)
        self.assertIn("report.sh: ", err)
        self.assertIn("nope.json", err)


class Metrics(Base):
    def home(self, reports):
        """A home whose reports-wt holds {dir/file: dict or text} (no git worktree: the pull fails quietly)."""
        h = self.fresh("mhome")
        os.makedirs(os.path.join(h, "reports-wt", "reports"))
        for rel, body in reports.items():
            self.write(os.path.join(h, "reports-wt", "reports", rel), body if isinstance(body, str) else json.dumps(body))
        os.environ["FACTORY_HOME"] = h
        return h

    def test_good_report(self):
        "a good report is one line: issue pipeline outcome tokens minutes rounds gates_failed manual_edit"
        self.home({"10-a/develop-1.json": {"issue": 10, "slug": "a", "pipeline": "develop", "outcome": "blocked",
                   "agents": [{"role": "qa", "tokens": 300}, {"role": "eng", "tokens": None}], "rounds": {"qa": 2, "eng": 1},
                   "gates_failed": ["build", "red"], "manual_edit": True,
                   "started_at": "2026-10-09T10:00:00-03:00", "finished_at": "2026-10-09T10:30:00-03:00"}})
        rc, out, err = self.call(metrics.main, [])
        self.assertEqual((rc, out), (0, HEADER + "\n10\tdevelop\tblocked\t300\t30\t3\tbuild,red\tTrue\n"))

    def test_sums_rounding_and_order(self):
        "null tokens count 0, 2.5 minutes round to 2, rounds sum, gates join with a comma; rows in path order, LF only"
        self.home({"9-x/develop-a.json": {"issue": 9, "pipeline": "develop", "outcome": "blocked",
                   "agents": [{"tokens": 10}, {"tokens": None}, {"tokens": 20}], "rounds": {"a": 2, "b": 3},
                   "gates_failed": ["build", "green web x"], "manual_edit": True,
                   "started_at": "2026-10-09T10:00:00-03:00", "finished_at": "2026-10-09T10:02:30-03:00"},
                   "9-x/refine-b.json": {"issue": 8, "pipeline": "refine", "outcome": "ok", "agents": [], "rounds": {},
                   "gates_failed": [], "manual_edit": None}})
        rc, out, err = self.call(metrics.main, [])
        self.assertEqual(out.splitlines(), [HEADER, "9\tdevelop\tblocked\t30\t2\t5\tbuild,green web x\tTrue",
                                            "8\trefine\tok\t0\t\t0\t\t"])
        self.assertNotIn("\r", out)

    def test_no_times(self):
        "a report without started_at or finished_at gets an empty duration, not a crash"
        self.home({"11-b/refine-1.json": {"issue": 11, "pipeline": "refine", "outcome": "ok"}})
        self.assertEqual(self.call(metrics.main, [])[1], HEADER + "\n11\trefine\tok\t0\t\t0\t\t\n")

    def test_missing_key(self):
        "a report without issue, pipeline or outcome raises KeyError: the header and the rows before it are printed, nothing after"
        for k in ("issue", "pipeline", "outcome"):
            bad = {"issue": 2, "pipeline": "refine", "outcome": "ok"}
            del bad[k]
            self.home({"1-a/refine-1.json": {"issue": 1, "pipeline": "refine", "outcome": "ok"}, "2-b/refine-1.json": bad,
                       "3-c/refine-1.json": {"issue": 3, "pipeline": "refine", "outcome": "ok"}})
            out = io.StringIO()
            with contextlib.redirect_stdout(out), self.assertRaises(KeyError) as e:
                metrics.main([])
            self.assertEqual(e.exception.args, (k,))
            self.assertEqual(out.getvalue(), HEADER + "\n1\trefine\tok\t0\t\t0\t\t\n", k)

    def test_no_home(self):
        "FACTORY_HOME unset while FACTORY_CONFIG is set: exit 1 naming the unbound variable, no table"
        del os.environ["FACTORY_HOME"]
        rc, out, err = self.call(metrics.main, [])
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("FACTORY_HOME: unbound variable", err)

    def test_failed_pull(self):
        "a pull --rebase that fails (a worktree whose origin is gone) still prints the table and exits 0"
        remote = self.bare()
        h = self.path("hm")
        self.assertEqual(self.rep(h, self.repo(remote), "26", "rl", "refine")[0], 0)
        git("-C", os.path.join(h, "reports-wt"), "remote", "set-url", "origin", os.path.join(h, "does-not-exist"))
        rc, out, err = self.call(metrics.main, [])
        self.assertEqual(rc, 0)
        self.assertIn("26\trefine\tok\t1000\t12\t0\t\t", out.splitlines())
