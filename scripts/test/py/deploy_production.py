"""deploy merging the PR and checking production: gh pr merge failing, an unknown merge commit, the CI run on main
(rerun once), each deploy.environment outcome, health checks, the revert (and when it cannot be prepared), a
revert/<n> PR deployed, a run resumed after the merge; and the project's language on the card and in the log."""
import os

from deploy_support import FAKE_GH, DeployCase, M, git


class Production(DeployCase):
    def reverted(self, reason):
        """exit 6: the revert PR opened, the reason on the card, reopened and blocked; the card's worktree kept"""
        self.want(6)
        c = self.comments()
        self.assertIn("Production deploy failed: " + reason, c)
        self.assertIn("Revert PR: https://github.com/acme/shop/pull/999", c)
        self.assertIn("staged-head: " + self.head_of("refs/heads/revert/7"), c)
        self.assertTrue(self.posted("pr create"))
        self.assertIn("reopened", self.fg("labels"))
        self.assertIn("blocked", self.fg("labels"))
        self.assertNotEqual(self.status(), "Done")
        self.assertFalse(os.path.exists(self.T + "/wt/revert-7"), "revert worktree left")
        self.assertTrue(os.path.exists(self.wt + "/.git"), "card worktree removed")
        self.assertIn("failed after merge: " + reason.split(" (run")[0], self.out)

    def ci(self, concl=None, rerun=None):
        self.dcfg("{ci_workflow: CI}")
        if concl:
            self.put("concl-1", concl + "\n")
        if rerun:
            self.put("rerun-1", rerun + "\n")

    def test_merge_fails_but_merged(self):
        "gh pr merge fails but the PR is MERGED (the answer was lost): accepted and shipped"
        self.gh_with('case "$*" in "pr merge"*) bash "$FAKE_GH" "$@" >/dev/null 2>&1; exit 1 ;; esac')
        self.run_deploy(7)
        self.assert_shipped()
        self.assertTrue(self.posted("pr merge"))
        self.assertTrue(self.on_main("api/A.kt"))

    def test_merge_refused(self):
        "gh pr merge fails and the PR is still OPEN: blocked with the end of gh's message, nothing on main"
        self.gh_with('case "$*" in "pr merge"*) L "$*"; echo "merge queue refused it" >&2; exit 1 ;; esac')
        self.run_deploy(7)
        self.want(5)
        self.assertIn("Factory deploy stopped: gh pr merge failed: merge queue refused it", self.comments())
        self.assertIn("blocked", self.fg("labels"))
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertFalse(self.on_main("api/A.kt"))

    def test_unknown_merge_commit(self):
        "a merge commit that never becomes known (asked ten times) or is not a sha: exit 2, nothing said; next run ships"
        self.gh_with('case "$*" in "pr view"*mergeCommit*) L "$*"; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(2)
        self.assertIn("merged but its merge commit is not known yet; will retry", self.out)
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertNotIn("Deployed", self.comments())
        self.assertNotIn("Production deploy failed", self.comments())
        self.assertFalse(self.has("labels"))
        self.assertEqual(sum(1 for l in self.fg("calls").split("\n") if "pr view 78" in l and "mergeCommit" in l), 10)
        os.environ["FACTORY_GH"] = FAKE_GH
        self.run_deploy(7)
        self.assert_shipped()
        self.setUp()
        self.gh_with('case "$*" in "pr view"*mergeCommit*) L "$*"; echo abc123; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(2)

    def test_no_ci_run(self):
        "no CI run on main for the merge commit: reverted, the card stays on main until the revert PR merges"
        self.ci()
        self.run_deploy(7)
        self.reverted("no 'CI' run on main for " + self.fg("merged").strip())
        self.assertTrue(self.on_main("api/A.kt"))

    def test_local_ci_skips_ci_on_main(self):
        "deploy.local_ci set: no GitHub run to wait for on main, so ci_workflow is not asked about and the card ships"
        self.dcfg("{ci_workflow: CI, local_ci: 'true'}")
        self.run_deploy(7)
        self.assert_shipped()
        self.assertFalse(self.posted("run list"))

    def test_ci_never_finishes(self):
        "a CI run on main that does not finish: reverted"
        self.ci("in_progress ")
        self.gh_with('case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; esac')
        self.run_deploy(7, env={"FACTORY_POLLS": "3"})
        self.reverted("CI on main did not finish (run 1)")

    def test_ci_fails_twice(self):
        "a failed run whose failed jobs fail again (rerun once): reverted with the end of the failed log on the card"
        self.ci("completed failure", "completed failure")
        self.gh_with('case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; "run view"*--log-failed*) L "$*"; '
                     'echo "FAILED LOG: boom in step 3"; exit 0 ;; esac')
        self.run_deploy(7)
        self.reverted("CI on main failed (run 1: failure)")
        self.assertIn("The end of the log of the failed run:", self.comments())
        self.assertIn("FAILED LOG: boom in step 3", self.comments())
        self.assertEqual(sum(1 for l in self.fg("calls").split("\n") if "run rerun 1" in l), 1)
        self.assertIn("running its failed jobs once more", self.out)

    def test_ci_log_cut(self):
        "the failed log on the card is its last 30 lines, each cut at 300 bytes"
        self.ci("completed failure")
        self.gh_with('case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; "run rerun"*) exit 1 ;; '
                     '"run view"*--log-failed*) seq 1 40 | sed "s/^/LINE /"; printf "%0400d" 0; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(6)
        c = self.comments()
        self.assertIn("LINE 12\n", c)
        self.assertNotIn("LINE 11\n", c)
        self.assertIn("0" * 300 + "\n", c)
        self.assertNotIn("0" * 301, c)

    def test_ci_no_rerun(self):
        "a failed run that cannot be rerun is reverted at once, no rerun claimed"
        self.ci("completed failure")
        self.gh_with('case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; "run rerun"*) L "$*"; exit 1 ;; '
                     '"run view"*--log-failed*) L "$*"; echo "NO RERUN LOG"; exit 0 ;; esac')
        self.run_deploy(7)
        self.reverted("CI on main failed (run 1: failure)")
        self.assertIn("NO RERUN LOG", self.comments())
        self.assertNotIn("once more", self.out)

    def test_ci_rerun_passes(self):
        "the CI run on main fails once and passes when its failed jobs run again: no revert"
        self.ci("completed failure", "completed success")
        self.gh_with('case "$*" in "run list"*) echo 1; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertFalse(self.posted("pr create"))

    def test_ci_green(self):
        "a green CI run on main ships"
        self.ci("completed success")
        self.gh_with('case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; esac')
        self.run_deploy(7)
        self.assert_shipped()

    def env_gh(self, dep_id=None, state=None, url=None):
        self.dcfg("{environment: production}")
        self.gh_with('case "$*" in\n  "api repos/"*"deployments?sha="*) L "$*"; [ -e "$FG/dep-id" ] && cat "$FG/dep-id"; '
                     'exit 0 ;;\n  "api repos/"*"/statuses"*) L "$*"; case "$*" in *environment_url*) cat "$FG/dep-url" '
                     '2>/dev/null ;; *) cat "$FG/dep-state" 2>/dev/null ;; esac; exit 0 ;;\nesac')
        for name, v in (("dep-id", dep_id), ("dep-state", state), ("dep-url", url)):
            if v:
                self.put(name, v + "\n")

    def test_environment_success(self):
        "deploy.environment success with a URL: Deployed carries the URL and the minutes"
        self.env_gh("5", "success", "https://prod.example/app")
        self.run_deploy(7)
        self.assert_shipped()
        merged = self.fg("merged").strip()
        self.assertIn("Deployed: merge %s · https://prod.example/app · " % merged, self.comments())
        self.assertIn(" min from the start of this deploy run.", self.comments())
        self.assertIn("deployments?sha=" + merged, self.fg("calls"))
        self.assertIn("done in ", self.out)

    def test_environment_inactive(self):
        "an inactive deployment (superseded by a newer one) is as good as success, with no URL"
        self.env_gh("5", "inactive")
        self.run_deploy(7)
        self.assert_shipped()
        self.assertIn("deployment 5 superseded by a newer one", self.out)
        self.assertNotIn("http", self.comments())

    def test_environment_failures(self):
        "failure and error end the wait at once; never appearing, a null id or staying pending end in a revert"
        for state, polls, want in (("failure", None, "failure"), ("error", None, "error"), (None, "3", "timeout"),
                                   ("null-id", "3", "timeout"), ("pending", "3", "pending")):
            self.setUp()
            if state == "null-id":
                self.env_gh("null")
            else:
                self.env_gh("5" if state else None, state)
            self.run_deploy(7, env={"FACTORY_POLLS": polls} if polls else None)
            self.reverted("deployment to 'production' ended '%s'" % want)

    def curl_log(self, pattern):
        """a curl that records its URL and fails for the URLs matching pattern"""
        self.curl_script('echo "$*" >> "$FG/curled"\ncase "$*" in *%s*) exit 22 ;; esac\nexit 0\n' % pattern)

    HC = '{healthcheck: ["https://a.example/health", "https://b.example/health", "https://c.example/health"]}'

    def test_health_urls(self):
        "every health URL is asked once, in order; the first that fails (five tries) reverts, the rest not asked"
        self.dcfg(self.HC)
        self.curl_log("NOPE")
        self.run_deploy(7)
        self.assert_shipped()
        curled = self.fg("curled")
        for u in "abc":
            self.assertEqual(curled.count("https://%s.example/health" % u), 1, u)
        self.setUp()
        self.dcfg(self.HC)
        self.curl_log("b.example")
        self.run_deploy(7)
        self.reverted("health check failed: https://b.example/health")
        curled = self.fg("curled")
        self.assertEqual(curled.count("https://a.example/health"), 1)
        self.assertEqual(curled.count("https://b.example/health"), 5)
        self.assertNotIn("https://c.example/health", curled)

    def test_health_revert(self):
        "a failed health check after merge: revert PR, reopened, blocked, the revert branch pushed"
        self.put("curl", "22\n")
        self.run_deploy(7)
        self.reverted("health check failed: https://shop.example/health")
        self.assertEqual(git("--git-dir=" + self.remote, "rev-parse", "-q", "--verify", "refs/heads/revert/7",
                             check=False), self.head_of("refs/heads/revert/7"))

    def test_revert_not_prepared(self):
        "revert/7 already exists and diverged: 'revert by hand', no PR, the branch untouched, reopened and blocked"
        self.put("curl", "22\n")
        git("-C", self.repo, "push", "-q", "origin", "feat/7-x:refs/heads/revert/7")
        theirs = self.head_of("refs/heads/revert/7")
        self.run_deploy(7)
        self.want(6)
        self.assertIn("Production deploy failed: health check failed: https://shop.example/health. The revert could not "
                      "be prepared automatically: revert %s by hand." % self.fg("merged").strip(), self.comments())
        self.assertFalse(self.posted("pr create"))
        self.assertIn("reopened", self.fg("labels"))
        self.assertIn("blocked", self.fg("labels"))
        self.assertEqual(self.head_of("refs/heads/revert/7"), theirs)
        self.assertNotIn("Revert PR:", self.comments())
        self.assertIn("revert not prepared", self.out)

    def test_pr_create_fails(self):
        "pr create fails after the revert branch was pushed: the card says so"
        self.put("curl", "22\n")
        self.gh_with('case "$*" in "pr create"*) L "$*"; exit 1 ;; esac')
        self.run_deploy(7)
        self.want(6)
        self.assertIn("Revert PR: (revert branch revert/7 pushed; opening its PR failed)", self.comments())
        self.assertIn("staged-head: " + self.head_of("refs/heads/revert/7"), self.comments())
        self.assertIn("reopened", self.fg("labels"))
        self.assertIn("blocked", self.fg("labels"))

    def test_revert_pr_deployed(self):
        "a revert/7 PR deploys itself: Done, merged at its head, the card off main, only the forbidden-path gate ran"
        self.put("curl", "22\n")
        self.run_deploy(7)
        rhead = self.head_of("refs/heads/revert/7")
        for f in ("merged", "curl", "labels"):
            os.remove(os.path.join(self.FG, f))
        self.put("pr", "999\n")
        self.put("branch", "revert/7\n")
        self.put("status", "Ready for Prod\n")
        self.put("calls", "")
        self.run_deploy(7)
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertIn("pr merge 999", self.fg("calls"))
        self.assertIn("--match-head-commit " + rhead, self.fg("calls"))
        self.assertFalse(self.on_main("api/A.kt"))
        self.assertIn("Deployed: merge " + self.fg("merged").strip(), self.comments())
        self.assertFalse(os.path.exists(self.wt))
        gates = self.hand("gates.txt")
        self.assertIn("forbidden", gates)
        for other in ("acceptance", "scope", "migration", "build"):
            self.assertNotIn(other, gates)

    def test_retry_after_red_merge_ci(self):
        "the merge commit's CI failed for a reason main has since fixed: a retry reads main's newest run, no 2nd revert"
        self.dcfg("{ci_workflow: CI, healthcheck: [\"https://shop.example/health\"]}")
        self.gh_with('case "$*" in "run list"*) [ -e "$FG/fixed" ] || { echo 1; exit 0; } ;; esac')
        self.put("concl-1", "completed failure\n")
        self.run_deploy(7)
        self.want(6)
        self.main_commit("web/fix.ts", "fixed")
        head = self.head_of("refs/heads/main")
        self.put("fixed", "")
        self.put("run-" + self.fg("merged").strip(), "1\n")
        self.put("run-" + head, "2\n")
        self.put("concl-2", "completed success\n")
        self.put("status", "Ready for Prod\n")
        self.put("calls", "")
        self.run_deploy(7)
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertFalse(self.posted("pr create"))


class Language(DeployCase):
    """language: pt-BR: the log and the card in Portuguese; markers (staged-head, deploy-merge, deploy-fix), CONFLICT
    lines and findings stay in English."""

    def setUp(self):
        super().setUp()
        self.ptbr()

    def test_blocked(self):
        "pt-BR: blocked, in Portuguese and nothing in English"
        self.put("no-pr", "")
        self.run_deploy(7)
        self.want(5)
        self.assertIn("O deploy da fábrica parou: esperava um PR aberto para #7, encontrou: none", self.comments())
        self.assertIn("blocked", self.fg("labels"))
        self.assertNotIn("Factory deploy stopped", self.comments())

    def test_unapproved_and_fork(self):
        "pt-BR: an unapproved head and a fork PR blocked"
        self.unapproved_push()
        self.run_deploy(7)
        self.want(5)
        self.assertIn("O deploy da fábrica parou: o PR #78 mudou depois de ir para Staged (o head ", self.comments())
        self.assertIn("não é o staged-head nem um merge da main registrado sobre ele)", self.comments())
        self.setUp()
        self.gh_with('case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@" | '
                     'awk -F"\\t" -v OFS="\\t" "{ \\$3 = \\"true\\"; print }"; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(5)
        self.assertIn("O deploy da fábrica parou: o PR #78 vem de um fork; a fábrica só faz deploy dos próprios branches",
                      self.comments())

    def test_coding_and_conflict(self):
        "pt-BR: back to Coding on the card and in the log; a conflict handed over with English CONFLICT lines"
        self.on_branch(M + "/V2__card.sql", "card")
        self.main_commit(M + "/V2__card.sql", "main")
        self.run_deploy(7)
        self.want(4)
        self.assertIn("Voltou para Coding: uma migration conflita com a main: ", self.comments())
        self.assertIn(": voltou para Coding: uma migration conflita com a main: ", self.out)
        self.setUp()
        self.on_branch("shared.txt", "card")
        self.main_commit("shared.txt", "main")
        self.run_deploy(7)
        self.want(3)
        self.assertIn("CONFLICT shared.txt", self.out)
        self.assertIn("resolva estes conflitos, faça o commit e rode: deploy.sh 7 --continue", self.out)
        self.assertNotIn("resolve these conflicts", self.out)

    def test_fix_round(self):
        "pt-BR: a fix round from red CI, then a small fix ships; markers and findings stay English"
        self.scene("behind")
        self.put("ci", "api=FAILURE\n")
        self.run_deploy(7)
        self.want(3)
        self.assertIn("rodada de conserto 1 de 2: o CI falhou no PR depois do merge da main (", self.out)
        self.assertIn("checks on ", self.hand("fix.findings"))
        self.assertIn("deploy-merge: ", self.comments())
        self.assertIn("main mesclada no PR", self.out)
        self.fix("api/A.kt", 3)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(0)
        self.assertIn("conserto pequeno (1 arquivos, ", self.out)
        c = self.comments()
        self.assertIn("deploy-fix: ", c)
        self.assertIn("Deploy feito: merge %s · " % self.fg("merged").strip(), c)
        self.assertIn(" min desde o início desta execução do deploy.", c)
        self.assertNotIn("Deployed:", c)

    def test_large_fix(self):
        "pt-BR: a large fix goes back to Staged; the staged-head marker stays English"
        self.scene("behind")
        self.put("ci", "api=FAILURE\n")
        self.run_deploy(7)
        self.fix("api/N.kt", 200)
        self.put("ci", "api=SUCCESS\n")
        self.run_deploy(7, "--continue")
        self.want(4)
        c = self.comments()
        self.assertIn("Voltou para Staged: o deploy mesclou a main e um agente consertou o que quebrou (", c)
        self.assertIn("O conserto tem 1 arquivos e 200 linhas: mais do que deploy.fix_max_files=3 / fix_max_lines=40 "
                      "deixam passar sem você. Revise o diff ", c)
        self.assertIn("staged-head: " + self.head_of(), c)

    def test_production_failed(self):
        "pt-BR: production failed with the log of the failed run and the revert PR"
        self.dcfg("{ci_workflow: CI}")
        self.put("concl-1", "completed failure\n")
        self.put("rerun-1", "completed failure\n")
        self.gh_with('case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; "run view"*--log-failed*) L "$*"; '
                     'echo "FAILED LOG: boom"; exit 0 ;; esac')
        self.run_deploy(7)
        self.want(6)
        c = self.comments()
        self.assertIn("O deploy em produção falhou: o CI da main falhou (execução 1: failure). PR de revert: "
                      "https://github.com/acme/shop/pull/999", c)
        self.assertIn("Fim do log da execução que falhou:", c)
        self.assertIn("FAILED LOG: boom", c)
        self.assertIn("staged-head: " + self.head_of("refs/heads/revert/7"), c)
        self.assertIn("falhou depois do merge: o CI da main falhou (execução 1: failure); revert ", self.out)
        self.assertIn("rodando os jobs falhos mais uma vez", self.out)

    def test_revert_by_hand(self):
        "pt-BR: a revert that cannot be prepared"
        self.put("curl", "22\n")
        git("-C", self.repo, "push", "-q", "origin", "feat/7-x:refs/heads/revert/7")
        self.run_deploy(7)
        self.want(6)
        self.assertIn("O deploy em produção falhou: o health check falhou: https://shop.example/health. O revert não pôde "
                      "ser preparado automaticamente: reverta %s à mão." % self.fg("merged").strip(), self.comments())
