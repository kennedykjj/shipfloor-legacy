"""deploy repairing what breaks on top of main: red CI or a red gate after merging main hands the card to a fix round
(exit 3, <tmp>/fix.findings); --continue then checks the fix (check_fix): a small one ships, a larger one waits in
Staged for the owner, a dirty, empty or merging one and a second red round go back to Coding."""
import os

from deploy_support import DeployCase, _write


class Fix(DeployCase):
    def red_round(self):
        self.scene("red")

    def test_red_ci_round(self):
        "red CI after merging main is handed to a fix round with the findings; a small fix then ships as deploy-fix"
        self.red_round()
        self.want(3)
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertIn("api=FAILURE", self.hand("fix.findings"))
        self.assertIn("fix round 1 of 2: CI failed on the PR after merging main (", self.out)
        self.assertIn("fix what %s/fix.findings shows, commit, then run: deploy.sh 7 --continue" % self.tmp7, self.out)
        self.assertEqual(self.hand("fix.round"), "1\n")
        self.fix("api/A.kt", 3)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertIn("deploy-fix: ", self.comments())
        self.assertIn("small fix (1 files, ", self.out)

    def test_nothing_fixed(self):
        "a fix round that commits nothing goes back to Coding"
        self.red_round()
        self.run_deploy(7, "--continue")
        self.want(4)
        self.assertEqual(self.status(), "Coding")
        self.assertIn("Back to Coding: the fix round fixed nothing: ", self.comments())

    def test_acceptance_test_edit(self):
        "a fix that edits an acceptance test, however small, never ships: back to Coding, nothing merged"
        self.red_round()
        self.fix("api/src/test/ATest.kt", 1)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(4)
        self.assertEqual(self.status(), "Coding")
        self.assertFalse(self.has("merged"))

    def test_large_fix(self):
        "a fix larger than fix_max_lines goes back to Staged with the fix as the head to approve; approved, it deploys"
        self.red_round()
        fixed = self.fix("api/A.kt", 200)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(4)
        self.assertEqual(self.status(), "Staged")
        self.assertIn("staged-head: " + fixed, self.comments())
        self.assertEqual(self.head_of(), fixed)
        self.assertFalse(self.has("merged"))
        self.assertIn("back to Staged: a fix of 1 files, ", self.out)
        self.put("status", "Ready for Prod\n")
        self.run_deploy(7)
        self.want(0)

    def test_two_red_rounds(self):
        "two rounds that leave CI red go back to Coding"
        self.red_round()
        self.fix("api/A.kt", 2)
        self.run_deploy(7, "--continue")
        self.want(3)
        self.assertIn("fix round 2 of 2", self.out)
        self.fix("api/A.kt", 3)
        self.run_deploy(7, "--continue")
        self.want(4)
        self.assertEqual(self.status(), "Coding")

    def test_dirty(self):
        "a fix round that leaves an untracked or a modified file goes back to Coding, nothing pushed"
        for dirty in ("untracked", "modified"):
            self.red_round()
            before = self.head_of()
            self.fix("api/A.kt", 3)
            if dirty == "untracked":
                _write(self.wt + "/dirty.txt", "junk\n")
            else:
                with open(self.wt + "/api/A.kt", "a") as f:
                    f.write("junk\n")
            self.put("ci", "api=SUCCESS\n")
            self.run_deploy(7, "--continue")
            self.assert_coding("the fix round left uncommitted changes", before)

    def test_merge_in_fix(self):
        "a merge commit inside the fix range counts as 'fixed nothing'"
        self.red_round()
        before = self.head_of()
        self.put("ci", "api=SUCCESS\n")
        self.wg("checkout", "-q", "-b", "side")
        _write(self.wt + "/side.txt", "s\n")
        self.wg("add", "-A")
        self.wg("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "side")
        self.wg("checkout", "-q", "feat/7-x")
        _write(self.wt + "/api/F.kt", "f\n")
        self.wg("add", "-A")
        self.wg("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "f")
        self.wg("-c", "user.email=t@t", "-c", "user.name=t", "merge", "-q", "--no-ff", "--no-edit", "side")
        self.run_deploy(7, "--continue")
        self.assert_coding("the fix round fixed nothing", before)

    def test_large_fix_gates_fail(self):
        "a large fix whose fast gates fail (a forbidden path) goes to Coding; fix.parent is consumed"
        self.red_round()
        before = self.head_of()
        self.fix("docs/engineering/x.md", 200)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.assert_coding("gates failed after the fix: ", before)
        self.assertIsNone(self.hand("fix.parent"))

    def test_thresholds(self):
        "a 40-line fix ships; 41 lines, or 4 files, wait in Staged with the counts on the card, nothing merged"
        self.red_round()
        self.fix("api/N.kt", 40)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertIn("deploy-fix: ", self.comments())
        self.red_round()
        self.fix("api/N.kt", 41)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(4)
        self.assertEqual(self.status(), "Staged")
        self.assertIn("Back to Staged: ", self.comments())
        self.assertIn("The fix is 1 files and 41 lines: more than deploy.fix_max_files=3 / fix_max_lines=40",
                      self.comments())
        self.assertFalse(self.posted("pr merge"))
        self.red_round()
        for i in (1, 2, 3, 4):
            self.fix("api/M%d.kt" % i, 1)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(4)
        self.assertEqual(self.status(), "Staged")
        self.assertIn("The fix is 4 files and 4 lines", self.comments())


class GateRound(DeployCase):
    def test_gate_round(self):
        "a gate failing after merging main is a fix round; dropping the forbidden file ships with both records"
        self.scene("gatered")
        self.want(3)
        self.assertIn("fix round 1 of 2: gates failed after merging main: ", self.out)
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertTrue(self.hand("fix.findings"))
        self.assertTrue(self.hand("fix.parent"))
        self.assertEqual(self.hand("fix.round"), "1\n")
        self.assertFalse(self.posted("pr merge"))
        self.wg("rm", "-q", "docs/engineering/a.md")
        self.wg("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "fix: drop the forbidden file")
        self.run_deploy(7, "--continue")
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertIn("deploy-merge: ", self.comments())
        self.assertIn("deploy-fix: ", self.comments())

    def test_gate_two_rounds(self):
        "a small fix that leaves the gate red goes round again; a second red round goes to Coding"
        self.scene("gatered")
        self.fix("api/N.kt", 1)
        self.run_deploy(7, "--continue")
        self.want(3)
        self.assertIn("fix round 2 of 2: gates failed after merging main: ", self.out)
        before = self.head_of()
        self.fix("api/N2.kt", 1)
        self.run_deploy(7, "--continue")
        self.assert_coding("gates failed after merging main: ", before)

    def test_fresh_run_restarts_rounds(self):
        "a fresh run (not --continue) starts its fix rounds over: the old fix.* files go"
        self.scene("gatered")
        self.assertTrue(self.hand("fix.round"))
        self.run_deploy(7)
        self.want(3)
        self.assertEqual(self.hand("fix.round"), "1\n")
        self.assertIn("fix round 1 of 2", self.out)
