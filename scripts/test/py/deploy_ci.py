"""deploy pushing the merge of main and waiting for CI: a failed push, a card moved meanwhile, a record comment that
fails, every wait_checks case (FACTORY_POLL=0: no sleeps), main moving while CI runs, deploy.local_ci in place of
GitHub's checks (green, red, timed out, without GNU timeout), and the findings a red run leaves for the fix round."""
import os
import shutil
import subprocess
import time
from unittest import mock

from deploy_support import DeployCase, _write
from shipfloor_core import deploy

SHIPPED = "Deployed: merge"


class Push(DeployCase):
    def polls(self):
        """how many times the checks were asked for (calls with statusCheckRollup)"""
        return sum(1 for l in self.fg("calls").split("\n") if "statusCheckRollup" in l)

    def shipped(self):
        self.want(0)
        self.assertEqual(self.status(), "Done")

    def test_failed_push(self):
        "the push fails (the remote refuses the branch): blocked; the merge was recorded first, the branch unchanged"
        self.scene("behind")
        before = self.head_of()
        _write(self.remote + "/hooks/pre-receive", '#!/bin/sh\nwhile read o n r; do case "$r" in refs/heads/feat/*) '
               'echo rejected >&2; exit 1 ;; esac; done\n', 0o755)
        self.run_deploy(7)
        self.assert_blocked("push of ", before)
        self.assertIn("failed (the branch moved?)", self.comments())
        self.assertIn("deploy-merge: ", self.comments())

    def test_card_moved(self):
        "the card was moved while the deploy ran: retry later, nothing recorded, pushed, merged or labelled"
        self.scene("behind")
        before, said = self.head_of(), self.comments()
        self.board_script('case "$1" in status) c=$(cat "$FG/bcount" 2>/dev/null || echo 0); echo $((c+1)) > '
                          '"$FG/bcount"; if [ "$c" = 0 ]; then echo "Ready for Prod"; else echo Coding; fi ;; '
                          'move) echo "$3" > "$FG/status" ;; esac\n')
        self.run_deploy(7)
        self.want(2)
        self.assertIn("the card moved meanwhile; will retry", self.out)
        self.assertEqual(self.comments(), said)
        self.assertEqual(self.head_of(), before)
        self.assertFalse(self.posted("pr merge"))
        self.assertFalse(self.has("labels"))

    def test_record_fails(self):
        "posting the record comment fails: retry later, nothing pushed (an unrecorded push would wedge the card)"
        self.scene("behind")
        before, said = self.head_of(), self.comments()
        self.gh_with('case "$*" in "issue comment"*) L "$*"; echo boom >&2; exit 1 ;; esac')
        self.run_deploy(7)
        self.want(2)
        self.assertIn("could not comment on #7", self.out)
        self.assertIn("cannot record the merge; will retry", self.out)
        self.assertEqual(self.comments(), said)
        self.assertEqual(self.head_of(), before)
        self.assertFalse(self.posted("pr merge"))

    def test_gates_nothing_merged(self):
        "the fast gates fail with nothing merged (main did not move): blocked for the owner, no fix round"
        self.on_branch("docs/engineering/a.md", "x")
        before = self.head_of()
        self.run_deploy(7)
        self.assert_blocked("gates failed: ", before)
        self.assertIsNone(self.hand("fix.parent"))

    def test_allow_no_checks(self):
        "allow_no_checks gives way after 10 empty polls; 9 are not enough, and without it empty checks never pass"
        self.dcfg("{allow_no_checks: true}")
        self.put("ci", "")
        self.run_deploy(7)
        self.shipped()
        self.assertIn("no checks reported for", self.out)
        self.assertEqual(self.polls(), 10)
        self.setUp()
        self.dcfg("{allow_no_checks: true}")
        self.put("ci", "")
        self.run_deploy(7, env={"FACTORY_POLLS": "9"})
        self.assert_blocked("CI failed on the PR (")
        self.assertEqual(self.polls(), 9)
        self.assertIn("checks did not finish (last: none)", self.out)
        self.setUp()
        self.put("ci", "")
        self.run_deploy(7, env={"FACTORY_POLLS": "12"})
        self.assert_blocked("CI failed on the PR (")
        self.assertEqual(self.polls(), 12)

    def test_red_keywords(self):
        "each failure keyword (any case) is red on the approved head: blocked at the first poll, no fix round"
        for k in ("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE", "error"):
            self.setUp()
            self.put("ci", "api=SUCCESS,web=%s\n" % k)
            self.run_deploy(7)
            self.assert_blocked("CI failed on the PR (")
            self.assertEqual(self.polls(), 1, k)
            self.assertIn("checks failed on ", self.out)
            self.assertIsNone(self.hand("fix.parent"))

    def test_neutral_pending(self):
        "NEUTRAL and SKIPPED count as green; IN_PROGRESS does not"
        self.put("ci", "api=SUCCESS,web=NEUTRAL,e2e=SKIPPED\n")
        self.run_deploy(7)
        self.shipped()
        self.setUp()
        self.put("ci", "api=SUCCESS,web=IN_PROGRESS\n")
        self.run_deploy(7, env={"FACTORY_POLLS": "4"})
        self.assert_blocked("CI failed on the PR (")

    def calls(self):
        return self.fg("calls").split("\n")

    def timed(self, *args, poll="10"):
        """run_deploy with a real poll interval and Deploy.sleep recorded instead of slept: the sleeps, in order"""
        slept = []
        with mock.patch.object(deploy.Deploy, "sleep", lambda d, secs: slept.append(secs)):
            self.run_deploy(*args, env={"FACTORY_POLL": poll})
        return slept

    def merge_argv(self, sha):
        return "pr merge 78 --repo acme/shop --squash --match-head-commit %s" % sha

    def test_green_merges_at_once(self):
        "the approved head, up to date with main and all green: merged at the first poll, with no sleep and no poll more"
        slept = self.timed(7)
        self.shipped()
        self.assertEqual(slept, [])
        self.assertEqual(self.polls(), 1)
        calls = [l for l in self.calls() if l]
        merges = [l for l in calls if l.startswith("pr merge")]
        self.assertEqual(merges, [self.merge_argv(self.staged)])
        poll = next(i for i, l in enumerate(calls) if "statusCheckRollup" in l)
        self.assertEqual(calls[poll + 1], merges[0], "something ran between the green poll and the merge")
        self.assertNotIn("deploy-merge: ", self.comments())

    def test_pending_waits(self):
        "checks still running on the approved head: polled every FACTORY_POLL s until green, then merged"
        self.gh_with('case "$*" in *statusCheckRollup*) c=$(cat "$FG/polls" 2>/dev/null || echo 0); '
                     'echo $((c+1)) > "$FG/polls"\n  if [ "$c" -lt 2 ]; then out="$(bash "$FAKE_GH" "$@")"; '
                     'echo "${out%% *} api=IN_PROGRESS"; exit 0; fi ;; esac')
        slept = self.timed(7)
        self.shipped()
        self.assertEqual(self.polls(), 3)
        self.assertEqual(slept, [10, 10])
        self.assertIn(self.merge_argv(self.staged), self.calls())

    def test_behind_merges_main_and_waits(self):
        "a PR behind main: main merged in, recorded, pushed, and the pushed head must be seen green twice"
        self.scene("behind")
        slept = self.timed(7)
        self.shipped()
        self.assertIn("deploy-merge: ", self.comments())
        self.assertIn("merged main into the PR: ", self.out)
        head = self.head_of()
        self.assertNotEqual(head, self.staged)
        self.assertEqual(self.polls(), 2)
        self.assertEqual(slept, [10])
        self.assertIn(self.merge_argv(head), self.calls())

    def test_poll_default(self):
        "without FACTORY_POLL the polls are 10 s apart"
        self.scene("behind")
        slept = []
        os.environ.pop("FACTORY_POLL")
        try:
            with mock.patch.object(deploy.Deploy, "sleep", lambda d, secs: slept.append(secs)):
                self.run_deploy(7)
        finally:
            os.environ["FACTORY_POLL"] = "0"
        self.shipped()
        self.assertEqual(slept, [10])

    def test_green_twice(self):
        "a head this run pushed needs green on two polls, not necessarily in a row: pending polls in between do not count"
        self.scene("behind")
        self.run_deploy(7)
        self.shipped()
        self.assertEqual(self.polls(), 2)
        self.assertIn("statusCheckRollup", self.fg("calls"), "no local_ci: GitHub's checks are asked for")
        for pending, want in (("1", 3), ("lt3", 5)):
            self.scene("behind")
            cond = '[ "$c" = 1 ]' if pending == "1" else '[ "$c" -lt 3 ]'
            self.gh_with('case "$*" in *statusCheckRollup*) c=$(cat "$FG/polls" 2>/dev/null || echo 0); '
                         'echo $((c+1)) > "$FG/polls"\n  if %s; then out="$(bash "$FAKE_GH" "$@")"; '
                         'echo "${out%%%% *} api=IN_PROGRESS"; exit 0; fi ;; esac' % cond)
            self.run_deploy(7)
            self.shipped()
            self.assertEqual(self.polls(), want)

    def test_other_head(self):
        "only polls on the right head count: another head's red or green is ignored, and alone it never passes"
        bogus = "0" * 40
        self.gh_with('case "$*" in *statusCheckRollup*) c=$(cat "$FG/polls" 2>/dev/null || echo 0); echo $((c+1)) > '
                     '"$FG/polls"\n  if [ "$c" = 0 ]; then L "$*"; echo "%s api=FAILURE"; exit 0; fi\n'
                     '  if [ "$c" -lt 3 ]; then L "$*"; echo "%s api=SUCCESS"; exit 0; fi ;; esac' % (bogus, bogus))
        self.run_deploy(7)
        self.shipped()
        self.assertEqual(self.polls(), 4)
        self.assertNotIn("checks failed on", self.out)
        self.setUp()
        self.gh_with('case "$*" in *statusCheckRollup*) L "$*"; echo "%s api=SUCCESS"; exit 0 ;; esac' % bogus)
        self.run_deploy(7, env={"FACTORY_POLLS": "4"})
        self.assert_blocked("CI failed on the PR (")
        self.assertIn("checks did not finish", self.out)
        self.assertEqual(self.polls(), 4)

    def test_timeout_after_merge(self):
        "CI that does not finish after merging main goes to Coding: the merge recorded, nothing merged, no fix round"
        self.scene("behind")
        self.put("ci", "api=PENDING\n")
        self.run_deploy(7, env={"FACTORY_POLLS": "3"})
        self.assert_coding("CI did not finish on the PR after merging main (")
        self.assertIn("deploy-merge: ", self.comments())
        self.assertIsNone(self.hand("fix.parent"))

    def test_red_approved_head(self):
        "red GitHub checks on the approved head, nothing merged in: blocked, not a fix round"
        self.put("ci", "api=FAILURE\n")
        self.run_deploy(7)
        self.assert_blocked("CI failed on the PR (")
        self.assertIsNone(self.hand("fix.parent"))

    def move_main(self, n):
        """every poll of the checks lands a commit on main, up to n commits"""
        self.put("move-max", "%d\n" % n)
        self.gh_with('case "$*" in *statusCheckRollup*) c=$(cat "$FG/moves" 2>/dev/null || echo 0); echo $((c+1)) > '
                     '"$FG/moves"\n    if [ "$c" -lt "$(cat "$FG/move-max")" ]; then\n'
                     '      w="$(mktemp -d)"; git clone -q "$(cat "$FG/remote")" "$w"; echo "$c" > "$w/moving-$c.txt"; '
                     'git -C "$w" add -A\n      git -C "$w" -c user.email=t@t -c user.name=t commit -qm "main moves $c"; '
                     'git -C "$w" push -q origin HEAD:main\n    fi ;; esac')

    def test_main_moves(self):
        "main moving once while CI runs: updated again and shipped; three times in a row: blocked"
        self.move_main(1)
        self.run_deploy(7)
        self.shipped()
        self.assertIn("main moved while waiting for CI; updating again", self.out)
        self.assertEqual(self.comments().count("deploy-merge: "), 1)
        self.setUp()
        self.move_main(99)
        self.run_deploy(7)
        self.assert_blocked("main kept moving; three updates in a row")
        self.assertEqual(self.out.count("main moved while waiting for CI"), 3)
        self.assertEqual(self.comments().count("deploy-merge: "), 2)


class LocalCI(DeployCase):
    def test_green(self):
        "green local CI runs in the worktree on the head merged with main and ships; GitHub's checks are not asked"
        self.scene("behind")
        self.put("ci", "api=FAILURE\n")
        self.lci('git rev-parse HEAD > "$FG/ran"; test -f web/other.ts && test -f api/A.kt')
        self.run_deploy(7)
        self.want(0)
        self.assertEqual(self.status(), "Done")
        ran = self.fg("ran").strip()
        self.assertTrue(ran)
        self.assertEqual(subprocess.run(["git", "--git-dir=" + self.remote, "merge-base", "--is-ancestor",
                                         self.head_of("main~1"), ran]).returncode, 0, "ran without main")
        self.assertNotIn("statusCheckRollup", self.fg("calls"))
        self.assertIn("local CI passed on", self.out)

    def test_red_after_merge(self):
        "red local CI after merging main: a fix round with the command and its output as findings, nothing merged"
        self.scene("behind")
        self.lci('echo "suite: 3 FAIL in gate.test.sh"; exit 1')
        self.run_deploy(7)
        self.want(3)
        f = self.hand("fix.findings")
        self.assertIn("suite: 3 FAIL in gate.test.sh", f)
        self.assertIn("deploy.local_ci:", f)
        self.assertIn("checks on ", f)
        self.assertIn("local-ci=FAILURE", f)
        self.assertIn("local CI failed on ", self.out)
        self.assertNotEqual(self.status(), "Done")
        self.assertFalse(self.on_main("api/A.kt"))

    def test_red_approved_head(self):
        "red local CI on the approved head, nothing merged in: blocked, not shipped"
        self.lci("exit 1")
        self.run_deploy(7)
        self.assert_blocked("CI failed on the PR (")
        self.assertFalse(self.on_main("api/A.kt"))

    def test_timeout(self):
        "local_ci timing out (124) after merging main goes to Coding; on the approved head it is blocked"
        self.scene("behind")
        self.lci("exit 124")
        self.run_deploy(7)
        self.assert_coding("CI did not finish on the PR after merging main (")
        self.assertIn("local CI did not finish on ", self.out)
        self.assertIn(" in 30 min", self.out)
        self.assertIsNone(self.hand("fix.parent"))
        self.setUp()
        self.lci("exit 124")
        self.run_deploy(7)
        self.assert_blocked("CI failed on the PR (")

    def test_limit(self):
        "local_ci gets deploy.timeout_min as its limit, and a run stopped there does not ship"
        self.scene("behind")
        self.dcfg("{timeout_min: 1, local_ci: 'sleep 75'}")
        seen = []
        with mock.patch.object(deploy, "_bounded", lambda secs, argv, cwd, out: seen.append((secs, argv, cwd)) or 124):
            self.run_deploy(7)
        self.assertEqual(seen, [(60, ["bash", "-c", "sleep 75"], self.wt)])
        self.assertIn("local CI did not finish", self.out)
        self.assertIn(" in 1 min", self.out)
        self.assertNotEqual(self.status(), "Done")

    def test_no_timeout_binary(self):
        "without GNU timeout the command still runs and decides: green ships, red is a fix round, its 124 is Coding"
        which = shutil.which
        no_timeout = lambda name, *a, **k: None if name == "timeout" else which(name, *a, **k)
        with mock.patch.object(shutil, "which", no_timeout):
            self.scene("behind")
            self.lci('echo ran > "$FG/ran"; test -f web/other.ts && test -f api/A.kt')
            self.run_deploy(7)
            self.want(0)
            self.assertTrue(self.fg("ran"))
            self.assertEqual(self.status(), "Done")
            self.assertIn("local CI passed on", self.out)
            self.assertIn(SHIPPED, self.comments())
            self.scene("behind")
            self.lci('echo "suite: 2 FAIL without timeout"; exit 1')
            self.run_deploy(7)
            self.want(3)
            self.assertIn("suite: 2 FAIL without timeout", self.hand("fix.findings"))
            self.assertFalse(self.posted("pr merge"))
            self.scene("behind")
            self.lci("exit 124")
            self.run_deploy(7)
            self.assert_coding("CI did not finish on the PR after merging main (")

    def test_findings_local(self):
        "with deploy.local_ci the findings are the command's output; GitHub's failed runs are not asked for"
        self.scene("behind")
        self.lci('echo "local says no"; exit 1')
        self.gh_with('case "$*" in "run list"*conclusion*) L "$*"; echo 41; exit 0 ;; "run view"*--log-failed*) L "$*"; '
                     'echo "GITHUB LOG"; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(3)
        f = self.hand("fix.findings")
        self.assertIn("local says no", f)
        self.assertNotIn("GITHUB LOG", f)
        self.assertFalse(self.posted("run list"))


class Findings(DeployCase):
    def test_github_logs(self):
        "red CI after merging main: the findings hold the red checks and the last 150 lines of each failed run's log"
        self.scene("behind")
        self.put("ci", "api=FAILURE\n")
        self.gh_with('case "$*" in\n  "run list"*conclusion*) L "$*"; printf "41\\n42\\nabc\\n"; exit 0 ;;\n'
                     '  "run view 41"*--log-failed*) L "$*"; seq 1 200 | sed "s/^/L41 /"; exit 0 ;;\n'
                     '  "run view 42"*--log-failed*) L "$*"; echo "LOG42 only line"; exit 0 ;;\nesac')
        self.run_deploy(7)
        self.want(3)
        f = self.hand("fix.findings")
        self.assertIn("checks on %s: api=FAILURE" % self.head_of(), f)
        self.assertIn("L41 200", f)
        self.assertIn("L41 51\n", f)
        self.assertNotIn("L41 50\n", f)
        self.assertIn("LOG42 only line", f)
        self.assertFalse(self.posted("run view abc"))
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertFalse(self.posted("pr merge"))


class Bounded(DeployCase):
    """deploy._bounded, the limit on local_ci: GNU timeout when there is one, else the whole process tree is killed."""

    def tree(self, use_timeout):
        pidfile = os.path.join(self.tmp, "child.pid")
        which = shutil.which
        fake = which if use_timeout else (lambda name, *a, **k: None if name == "timeout" else which(name, *a, **k))
        with open(os.path.join(self.tmp, "out"), "wb") as out, mock.patch.object(shutil, "which", fake):
            t0 = time.monotonic()
            rc = deploy._bounded(1, ["bash", "-c", 'sleep 30 & echo $! > "%s"; wait' % pidfile], self.tmp, out)
            took = time.monotonic() - t0
        return rc, took, open(pidfile).read().strip()

    def test_limit_without_timeout(self):
        "without timeout on the PATH a command that hangs is stopped at its limit (124) with its whole process tree"
        rc, took, child = self.tree(False)
        self.assertEqual(rc, 124)
        self.assertLess(took, 10)
        time.sleep(0.2)
        self.assertFalse(os.path.exists("/proc/%s" % child) and open("/proc/%s/stat" % child).read().split()[2] != "Z",
                         "the command's child still runs")

    def test_limit_with_timeout(self):
        "with GNU timeout a command that hangs is stopped at its limit (124)"
        rc, took, _ = self.tree(True)
        self.assertEqual(rc, 124)
        self.assertLess(took, 10)

    def test_exit_code_passes(self):
        "a command that ends in time gives its own exit code, with or without timeout"
        which = shutil.which
        for fake in (which, lambda name, *a, **k: None if name == "timeout" else which(name, *a, **k)):
            with open(os.path.join(self.tmp, "out"), "wb") as out, mock.patch.object(shutil, "which", fake):
                self.assertEqual(deploy._bounded(5, ["bash", "-c", "echo hi; exit 7"], self.tmp, out), 7)
            self.assertEqual(open(os.path.join(self.tmp, "out")).read(), "hi\n")
