"""deploy, the start of a run and the approval: the lock, the column, --refresh, forks, several PRs, a merged PR
missing from main, and which head counts as approved (staged-head, recorded chains, CRLF, the login of the factory)."""
import os
import subprocess

from deploy_support import DeployCase, M, git


class Start(DeployCase):
    def untouched(self, before):
        """nothing was said or labelled on the card"""
        self.assertEqual(self.comments(), before)
        self.assertFalse(self.has("labels"), self.fg("labels"))

    def test_busy_lock(self):
        "a busy lock (a live pid) is exit 2: nothing asked of GitHub, the lock stays with its owner, the card untouched"
        lock = self.T + "/home/locks/deploysh-7.lock"
        os.makedirs(lock)
        with open(lock + "/info", "w") as f:
            f.write("%d 0\n" % os.getpid())
        before = self.comments()
        self.run_deploy(7)
        self.want(2)
        self.assertIn("another deploy.sh runs on this card (pid %d)" % os.getpid(), self.out)
        self.assertEqual(self.fg("calls"), "")
        self.assertTrue(os.path.isdir(lock))
        self.assertEqual(self.status(), "Ready for Prod")
        self.untouched(before)

    def test_stale_lock(self):
        "a stale lock (its pid is gone) or one with no info is taken over, the deploy goes on, the lock goes at the end"
        p = subprocess.Popen(["true"])
        p.wait()
        lock = self.T + "/home/locks/deploysh-7.lock"
        os.makedirs(lock)
        with open(lock + "/info", "w") as f:
            f.write("%d 0\n" % p.pid)
        self.run_deploy(7)
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertIn("Deployed: merge", self.comments())
        self.assertFalse(os.path.exists(lock))
        self.setUp()
        os.makedirs(self.T + "/home/locks/deploysh-7.lock")
        self.run_deploy(7)
        self.want(0)
        self.assertEqual(self.status(), "Done")

    def test_wrong_column(self):
        "a card in another column than Ready for Prod is exit 2 before gh is asked anything"
        for col in ("Staged", "Coding", "In Progress", "Done"):
            self.setUp()
            self.put("status", col + "\n")
            before = self.comments()
            self.run_deploy(7)
            self.assertEqual(self.code, 2, col)
            self.assertIn("#7 is in '%s', not Ready for Prod" % col, self.out)
            self.assertEqual(self.fg("calls"), "", col)
            self.assertEqual(self.status(), col)
            self.untouched(before)

    def test_usage(self):
        "a card that is not a number, or a mode that does not exist, is a usage error (exit 2), gh not called"
        self.run_deploy("x")
        self.want(2)
        self.assertIn("usage: deploy.sh <n> [--refresh | --continue]", self.out)
        self.run_deploy(7, "--bogus")
        self.want(2)
        self.assertEqual(self.fg("calls"), "")

    def test_refresh_not_staged(self):
        "--refresh on a card that is not Staged: exit 0, gh not called, nothing moved or said"
        before = self.comments()
        self.run_deploy(7, "--refresh")
        self.want(0)
        self.assertIn("not Staged (Ready for Prod); nothing to refresh", self.out)
        self.assertEqual(self.fg("calls"), "")
        self.assertEqual(self.status(), "Ready for Prod")
        self.untouched(before)

    def test_refresh_unapproved(self):
        "--refresh on a head nobody approved: exit 0, nothing pushed, the card stays Staged, nothing said"
        self.put("status", "Staged\n")
        self.main_commit("web/other.ts", "x")
        self.unapproved_push()
        before, said = self.head_of(), self.comments()
        self.run_deploy(7, "--refresh")
        self.want(0)
        self.assertIn("is not approved; not refreshing", self.out)
        self.assertEqual(self.head_of(), before)
        self.assertEqual(self.status(), "Staged")
        self.untouched(said)

    def test_refresh_back_to_coding(self):
        "--refresh meeting back_to_coding (a migration conflicts): exit 0, left for the deploy, nothing moves"
        self.put("status", "Staged\n")
        self.on_branch(M + "/V2__card.sql", "card")
        self.main_commit(M + "/V2__card.sql", "main")
        before, said = self.head_of(), self.comments()
        self.run_deploy(7, "--refresh")
        self.want(0)
        self.assertIn("a migration conflicts with main", self.out)
        self.assertIn("left for the deploy", self.out)
        self.assertEqual(self.status(), "Staged")
        self.assertEqual(self.head_of(), before)
        self.untouched(said)
        self.assertFalse(self.posted("pr merge"))

    def test_refresh_two_prs(self):
        "--refresh with more than one open PR: exit 0, quietly"
        self.put("status", "Staged\n")
        self.put("extra-pr", "79\tfeat/7-y\tfalse\t%s\n" % self.staged)
        self.gh_with('case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@"; cat "$FG/extra-pr"; exit 0 ;; esac')
        before = self.comments()
        self.run_deploy(7, "--refresh")
        self.want(0)
        self.untouched(before)

    def test_refresh(self):
        "--refresh behind main pushes and records the merge, the card stays Staged and nothing is merged"
        self.put("status", "Staged\n")
        self.main_commit("web/other.ts", "x")
        self.run_deploy(7, "--refresh")
        self.want(0)
        self.assertEqual(self.status(), "Staged")
        self.assertIn("deploy-merge: ", self.comments())
        self.assertFalse(self.posted("pr merge"))

    def test_fork(self):
        "a fork PR is blocked with the reason on the card"
        self.gh_with('case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@" | '
                     'awk -F"\\t" -v OFS="\\t" "{ \\$3 = \\"true\\"; print }"; exit 0 ;; esac')
        self.run_deploy(7)
        self.assert_blocked("PR #78 comes from a fork; the factory deploys only its own branches")

    def test_several_prs(self):
        "two feat/7-* PRs, or revert/7 beside feat/7-x, are blocked; PRs of card #70 are not #7's"
        for extra, other in (("79\tfeat/7-y", "79"), ("80\trevert/7", "revert/7")):
            self.setUp()
            self.put("extra-pr", "%s\tfalse\t%s\n" % (extra, self.staged))
            self.gh_with('case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@"; cat "$FG/extra-pr"; exit 0 ;; esac')
            self.run_deploy(7)
            self.assert_blocked("expected one open PR for #7, found: 78")
            self.assertIn(other, self.comments())
        self.setUp()
        self.put("extra-pr", "81\tfeat/70-z\tfalse\t%s\n82\trevert/70\tfalse\t%s\n" % (self.staged, self.staged))
        self.gh_with('case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@"; cat "$FG/extra-pr"; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(0)
        self.assertEqual(self.status(), "Done")

    def test_no_pr(self):
        "no open PR while the worktree exists is blocked with a comment, not a crash"
        os.makedirs(self.T + "/wt")
        git("-C", self.repo, "worktree", "add", "-q", self.wt, "feat/7-x")
        self.put("no-pr", "")
        self.run_deploy(7)
        self.assert_blocked("expected one open PR for #7, found: none")

    def test_merged_not_on_main(self):
        "a merged PR missing from origin/main, or with no merge sha, is not resumed: blocked"
        self.put("merged", self.staged + "\n")
        self.run_deploy(7)
        self.assert_blocked("expected one open PR for #7, found: none")
        self.assertNotIn("already merged as", self.out)
        self.setUp()
        self.put("merged", "notasha\n")
        self.run_deploy(7)
        self.want(5)
        self.assertIn("found: none", self.comments())

    def test_resumed(self):
        "a merged PR on origin/main goes straight to production: Done, the PR not merged again"
        self.run_deploy(7)
        self.put("status", "Ready for Prod\n")
        self.put("calls", "")
        self.run_deploy(7)
        self.want(0)
        self.assertIn("was already merged as %s; checking production" % self.fg("merged").strip(), self.out)
        self.assertEqual(self.status(), "Done")
        self.assertFalse(self.posted("pr merge"))
        self.assertIn("Deployed: merge " + self.fg("merged").strip(), self.comments())


class Approval(DeployCase):
    def chain(self, k, end=""):
        """k commits on the card's branch, each recorded by the factory as a deploy-fix"""
        w = self.clone("feat/7-x")
        with open(self.FG + "/comments", "a", newline="") as f:
            for i in range(1, k + 1):
                f.write("factory\tdeploy-fix: %s%s\n" % (self.commit_file(w, "api/F%d.kt" % i, "%d\n" % i), end))
        git("-C", w, "push", "-q", "origin", "feat/7-x")
        return w

    def done_ok(self):
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertIn("Deployed: merge", self.comments())

    def unapproved(self):
        self.assert_blocked("PR #78 changed after it was staged")

    def test_unapproved_head(self):
        "a head nobody approved is blocked and labelled"
        self.unapproved_push()
        self.run_deploy(7)
        self.unapproved()

    def test_head_mismatch(self):
        "the PR head GitHub reports is not the branch (a push mid-run), or is empty: retry later, never merge"
        self.put("prhead", "0123456789012345678901234567890123456789\n")
        self.run_deploy(7)
        self.want(2)
        self.assertFalse(self.posted("pr merge"))
        self.setUp()
        self.put("prhead", "")
        self.run_deploy(7)
        self.want(2)

    def test_forged(self):
        "only the factory's own comments approve: another author's staged-head is ignored"
        sha = self.unapproved_push("E.kt")
        with open(self.FG + "/comments", "a") as f:
            f.write("mallory\tstaged-head: %s\n" % sha)
        self.run_deploy(7)
        self.want(5)

    def test_chain_limit(self):
        "9 recorded fixes above the staged head deploy; 10 are one too many for approved_chain"
        self.chain(9)
        self.run_deploy(7)
        self.done_ok()
        self.setUp()
        self.chain(10)
        self.run_deploy(7)
        self.unapproved()

    def test_chain_broken(self):
        "an unrecorded head on a recorded chain, or a record from before the newest staged-head, is not approved"
        w = self.clone("feat/7-x")
        with open(self.FG + "/comments", "a") as f:
            f.write("factory\tdeploy-fix: %s\n" % self.commit_file(w, "api/G1.kt", "a\n"))
        self.commit_file(w, "api/G2.kt", "b\n")
        git("-C", w, "push", "-q", "origin", "feat/7-x")
        self.run_deploy(7)
        self.unapproved()
        self.setUp()
        w = self.clone("feat/7-x")
        rec = self.commit_file(w, "api/G1.kt", "a\n")
        git("-C", w, "push", "-q", "origin", "feat/7-x")
        with open(self.FG + "/comments", "a") as f:
            f.write("factory\tdeploy-fix: %s\nfactory\tstaged-head: %s\n" % (rec, "1" * 40))
        self.run_deploy(7)
        self.unapproved()

    def test_recorded_merges(self):
        "a recorded merge whose second parent is not on main breaks the chain; a recorded merge of main is fine"
        w = self.clone("feat/7-x")
        git("-C", w, "checkout", "-q", "-b", "side")
        side = self.commit_file(w, "side.txt", "s\n")
        git("-C", w, "checkout", "-q", "feat/7-x")
        git("-C", w, "merge", "-q", "--no-ff", "--no-edit", "side")
        with open(self.FG + "/comments", "a") as f:
            f.write("factory\tdeploy-merge: %s %s\n" % (git("-C", w, "rev-parse", "HEAD"), side))
        git("-C", w, "push", "-q", "origin", "feat/7-x")
        self.run_deploy(7)
        self.unapproved()
        self.setUp()
        self.main_commit("web/other.ts", "x")
        w = self.clone("feat/7-x")
        git("-C", w, "merge", "-q", "--no-ff", "--no-edit", "origin/main")
        with open(self.FG + "/comments", "a") as f:
            f.write("factory\tdeploy-merge: %s %s\n" % (git("-C", w, "rev-parse", "HEAD"),
                                                       git("-C", w, "rev-parse", "origin/main")))
        git("-C", w, "push", "-q", "origin", "feat/7-x")
        self.run_deploy(7)
        self.done_ok()

    def test_crlf(self):
        "CRLF in the comments: the staged-head and the records are read without the carriage return"
        self.put("comments", "factory\tstaged-head: %s\r\n" % self.staged)
        self.run_deploy(7)
        self.done_ok()
        self.setUp()
        self.put("comments", "factory\tstaged-head: %s\r\n" % self.staged)
        self.chain(2, "\r")
        self.run_deploy(7)
        self.done_ok()

    def test_login(self):
        "the login spliced into the jq filter: ci-bot[bot] works, only that login's comments approve"
        self.put("comments", "ci-bot[bot]\tstaged-head: %s\n" % self.staged)
        self.gh_with('case "$*" in "api user"*) L "$*"; echo "ci-bot[bot]"; exit 0 ;; esac')
        self.run_deploy(7)
        self.done_ok()
        self.setUp()
        self.gh_with('case "$*" in "api user"*) L "$*"; echo "someone-else"; exit 0 ;; esac')
        self.run_deploy(7)
        self.assert_blocked("no staged-head comment on #7")

    def test_login_quote(self):
        "a login with a quote breaks the filter: gh fails, the run retries later and says, labels, moves nothing"
        before = self.comments()
        self.gh_with('case "$*" in "api user"*) L "$*"; echo "fa\\"ctory"; exit 0 ;; "issue view"*) L "$*"; '
                     'echo "jq: error: syntax error" >&2; exit 3 ;; esac')
        self.run_deploy(7)
        self.want(2)
        self.assertIn("cannot read #7 comments; will retry", self.out)
        self.assertEqual(self.comments(), before)
        self.assertFalse(self.has("labels"))
        self.assertFalse(self.posted("pr merge"))
        self.assertEqual(self.status(), "Ready for Prod")

    def test_required_checks(self):
        "pending checks keep waiting; a required check that never reports is not green (not merged)"
        self.dcfg("{required_checks: [api, web]}")
        self.run_deploy(7, env={"FACTORY_POLLS": "3"})
        self.want(5)
