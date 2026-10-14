"""deploy merging main into the PR: up to date, behind (merged and recorded), a migration main took (renumbered),
conflicts handed over or sent back (migration, over the file and hunk limits, a merge that fails without conflicts),
and what --continue accepts as a resolution (check_resolution)."""
import os

from deploy_support import DeployCase, M, git, _write


class Merge(DeployCase):
    def test_up_to_date(self):
        "an up-to-date head is merged, health checked and Done, squashed into main"
        self.run_deploy(7)
        self.assert_shipped()
        self.assertIn("Deployed: merge %s · " % self.fg("merged").strip(), self.comments())
        self.assertIn(" min from the start of this deploy run.", self.comments())
        self.assertTrue(self.on_main("api/A.kt"))

    def test_behind(self):
        "behind main: main merged into the PR, pushed, recorded as deploy-merge, then deployed"
        self.scene("behind")
        self.run_deploy(7)
        self.want(0)
        self.assertIn("deploy-merge: ", self.comments())

    def test_branch_with_t(self):
        "a branch whose name has a 't' (the tab-separated pattern): the PR is still found"
        self.put("branch", "feat/7-tests-at-last\n")
        git("-C", self.repo, "push", "-q", "origin", "feat/7-x:feat/7-tests-at-last")
        self.run_deploy(7)
        self.want(0)

    def test_migration_renumbered(self):
        "main took the card's migration version under another name: the card's file moves above it and ships"
        self.on_branch(M + "/V2__card.sql", "create table c (id int);")
        self.main_commit(M + "/V2__other.sql", "create table o (id int);")
        self.run_deploy(7)
        self.want(0)
        self.assertTrue(self.on_main(M + "/V3__card.sql"))
        self.assertIn("deploy-fix: ", self.comments())
        self.assertIn("migration %s/V2__card.sql renumbered to %s/V3__card.sql: main took its version" % (M, M),
                      self.out)

    def test_migration_conflict(self):
        "a migration conflicting with main goes back to Coding: nothing pushed, the worktree left clean"
        self.on_branch(M + "/V2__card.sql", "card")
        self.main_commit(M + "/V2__card.sql", "main")
        before = self.head_of()
        self.run_deploy(7)
        self.assert_coding("a migration conflicts with main: ", before)
        self.assertEqual(self.wg("status", "--porcelain"), "")

    def test_conflict_handed_over(self):
        "a small conflict is handed over (exit 3, CONFLICT lines); after it is resolved, --continue deploys"
        self.scene("conflict")
        self.want(3)
        self.assertIn("CONFLICT shared.txt", self.out)
        self.assertIn("resolve these conflicts, commit, then run: deploy.sh 7 --continue", self.out)
        self.assertFalse(os.path.exists(self.T + "/home/locks/deploysh-7.lock"), "lock kept after the hand-over")
        self.resolve()
        self.run_deploy(7, "--continue")
        self.want(0)
        self.assertIsNone(self.hand("resolve.parents"))
        self.assertIsNone(self.hand("resolve.files"))
        self.assertEqual(self.status(), "Done")

    def test_modify_delete(self):
        "a modify/delete conflict (no markers) is handed over, not a crash"
        self.on_branch("shared.txt", "card")
        w = self.clone()
        git("-C", w, "rm", "-q", "shared.txt")
        git("-C", w, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "main: drop shared")
        git("-C", w, "push", "-q", "origin", "main")
        self.run_deploy(7)
        self.want(3)

    def test_refresh_conflict(self):
        "--refresh leaves a conflict to the deploy: exit 0, nothing pushed"
        self.put("status", "Staged\n")
        self.on_branch("shared.txt", "card")
        self.main_commit("shared.txt", "main")
        before = self.head_of()
        self.run_deploy(7, "--refresh")
        self.want(0)
        self.assertEqual(self.head_of(), before)
        self.assertIn("conflicts with main; left for the deploy", self.out)


class MergeFail(DeployCase):
    def scene_two(self):  # two files, one hunk each
        self.on_branch("shared.txt", "card")
        self.on_branch("lines.txt", "card")
        self.main_commit("shared.txt", "main")
        self.main_commit("lines.txt", "main")

    def sent_back(self, reason, before):
        """Coding with the reason, nothing pushed, merged or labelled, the worktree clean with no merge in progress"""
        self.assert_coding(reason, before)
        self.assertFalse(self.has("merged"))
        self.assertFalse(self.has("labels"))
        self.assertEqual(self.wg("status", "--porcelain"), "")
        self.assertEqual(self.wg("diff", "--name-only", "--diff-filter=U"), "")
        self.assertFalse(self.hand("resolve.files"), "handed over conflicts")

    def test_merge_fails_without_conflicts(self):
        "a merge that fails without conflicts (a hook refuses it) goes to Coding with 'merge failed: ...'"
        self.scene("behind")
        _write(self.repo + "/.git/hooks/pre-merge-commit", '#!/bin/sh\necho "refused by hook" >&2\nexit 1\n', 0o755)
        before = self.head_of()
        self.run_deploy(7)
        self.sent_back("merge failed: ", before)
        self.assertIn("back to Coding: merge failed: ", self.out)
        self.assertIn("refused by hook", self.comments())
        self.assertIsNone(self.hand("fix.findings"))

    def test_file_limit(self):
        "conflicts in more files than conflict_max_files go to Coding; exactly at the limit they are handed over"
        self.scene("two")
        self.dcfg("{conflict_max_files: 1}")
        before = self.head_of()
        self.run_deploy(7)
        self.sent_back("2 files conflict with main (limit 1)", before)
        self.scene("two")
        self.dcfg("{conflict_max_files: 2}")
        self.run_deploy(7)
        self.want(3)
        self.assertIn("CONFLICT lines.txt", self.out)
        self.assertIn("CONFLICT shared.txt", self.out)
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertFalse(self.has("labels"))
        self.assertEqual(self.hand("resolve.files"), "lines.txt\nshared.txt\n")

    def test_hunk_limit(self):
        "conflicts in more hunks than conflict_max_hunks go to Coding; exactly at the limit they are handed over"
        self.scene("two")
        self.dcfg("{conflict_max_hunks: 1}")
        before = self.head_of()
        self.run_deploy(7)
        self.sent_back("2 hunks conflict with main (limit 1)", before)
        self.scene("two")
        self.dcfg("{conflict_max_hunks: 2}")
        self.run_deploy(7)
        self.want(3)
        self.assertIn("CONFLICT shared.txt", self.out)
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertFalse(self.posted("pr merge"))


class Resolution(DeployCase):
    """--continue after a conflict: check_resolution."""

    def scene_automerge(self):  # a real conflict in shared.txt next to lines.txt, which git merges on its own
        self.on_branch("shared.txt", "card")
        self.on_branch("lines.txt", "ONE\ntwo\nthree\nfour\nfive")
        self.main_commit("shared.txt", "main")
        self.main_commit("lines.txt", "one\ntwo\nthree\nfour\nFIVE")
        self.run_deploy(7)

    def test_merge_head(self):
        "--continue with MERGE_HEAD still there (the merge never committed) is blocked"
        self.scene("conflict")
        before = self.head_of()
        self.run_deploy(7, "--continue")
        self.assert_blocked("--continue with the merge still in progress", before)

    def test_unresolved(self):
        "--continue with no MERGE_HEAD but conflicts still in the index is blocked"
        self.scene("conflict")
        before = self.head_of()
        os.remove(os.path.join(self.wg("rev-parse", "--absolute-git-dir"), "MERGE_HEAD"))
        self.run_deploy(7, "--continue")
        self.assert_blocked("--continue with unresolved conflicts", before)

    def test_no_parents(self):
        "--continue without resolve.parents (deploy.sh did not hand this conflict over) is blocked"
        self.scene("conflict")
        before = self.head_of()
        self.resolve()
        os.remove(self.tmp7 + "/resolve.parents")
        self.run_deploy(7, "--continue")
        self.assert_blocked("--continue without a conflict handed over by deploy.sh", before)

    def test_wrong_parents(self):
        "--continue with resolve.parents naming other parents than the merge has is blocked"
        self.scene("conflict")
        before = self.head_of()
        self.resolve()
        a, b = self.hand("resolve.parents").split("\n")[:2]
        _write(self.tmp7 + "/resolve.parents", "%s\n%s\n" % (b, a))
        self.run_deploy(7, "--continue")
        self.assert_blocked("--continue: HEAD is not the merge of %s and %s" % (b, a), before)

    def test_head_moved(self):
        "--continue after the PR head moved (a new approved head) is blocked"
        self.scene("conflict")
        self.resolve()
        self.on_branch("api/Z.kt", "z")
        before = self.head_of()
        self.run_deploy(7, "--continue")
        self.assert_blocked("--continue: the PR head moved since the conflicts were handed over", before)

    def test_tampered(self):
        "--continue refuses a resolution that changes a file that did not conflict"
        self.scene("conflict")
        _write(self.wt + "/shared.txt", "resolved\n")
        _write(self.wt + "/api/A.kt", "sneaky\n")
        self.wg("add", "-A")
        self.wg("commit", "-q", "--no-edit")
        self.run_deploy(7, "--continue")
        self.assert_blocked("--continue: the resolution changed files that did not conflict: api/A.kt")

    def test_automerge(self):
        "--continue accepts a file git merged on its own next to a real conflict, but not when the resolver edits it"
        self.scene("automerge")
        self.want(3)
        self.resolve()
        self.run_deploy(7, "--continue")
        self.want(0)
        self.scene("automerge")
        _write(self.wt + "/shared.txt", "resolved\n")
        with open(self.wt + "/lines.txt", "a") as f:
            f.write("sneaky\n")
        self.wg("add", "-A")
        self.wg("commit", "-q", "--no-edit")
        self.run_deploy(7, "--continue")
        self.assert_blocked("--continue: the resolution changed files that did not conflict: lines.txt")
