"""Helpers for the in-process deploy suites (deploy_*.py): a base repo built once per process (a bare remote and a
clone with main and the staged card #7 on feat/7-x), a private copy per test, and deploy.main called in this process
with its stdout and stderr (and those of the processes it starts) caught in a file.

The doubles: gh is test/fake-gh-deploy (state in $FG: remote, pr, branch, comments, ci, prhead, merged, no-pr, calls,
labels, run-<sha>, concl-<id>, rerun-<id>), the board and curl are small scripts reading $FG; git and gate.sh are real,
because the repo and the fast gates are what a deploy acts on."""
import atexit
import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import support
from shipfloor_core import deploy, project

TEST = os.path.join(support.SCRIPTS, "test")
FAKE_GH = os.path.join(TEST, "fake-gh-deploy")
M = "api/src/main/resources/db/migration"
STATE = {}  # the base repo of this process: dir, staged


def git(*args, cwd=None, check=True):
    """git with the test's identity; its stdout without the trailing newline."""
    r = subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "core.autocrlf=false", *args],
                       cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and r.returncode != 0:
        raise AssertionError("git %s: %s" % (" ".join(args), r.stderr))
    return r.stdout.rstrip("\n")


def _write(path, text, mode=None):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


def _build_base(base):
    git("init", "-q", "--bare", "-b", "main", os.path.join(base, "remote.git"))
    r = os.path.join(base, "repo")
    git("init", "-q", "-b", "main", r)
    git("-C", r, "remote", "add", "origin", os.path.join(base, "remote.git"))
    _write(os.path.join(r, M, "V1__a.sql"), "create table a (id int);\n")
    _write(os.path.join(r, "docs/superpowers/specs/2026-01-01-x-design.md"), "# x\n\n## Rollback\n\nn/a\n")
    _write(os.path.join(r, "README.md"), "base\n")
    _write(os.path.join(r, "shared.txt"), "shared\n")
    _write(os.path.join(r, "lines.txt"), "one\ntwo\nthree\nfour\nfive\n")
    git("-C", r, "add", "-A")
    git("-C", r, "commit", "-qm", "main")
    git("-C", r, "push", "-q", "origin", "main")
    git("-C", r, "checkout", "-qb", "feat/7-x")
    _write(os.path.join(r, "api/src/test/ATest.kt"), "test\n")
    git("-C", r, "add", "-A")
    git("-C", r, "commit", "-qm", "test(x): acceptance tests for #7")
    _write(os.path.join(r, "api/A.kt"), "impl\n")
    git("-C", r, "add", "-A")
    git("-C", r, "commit", "-qm", "feat(x): impl")
    git("-C", r, "push", "-q", "origin", "feat/7-x")
    git("-C", r, "checkout", "-q", "main")


def base():
    """The base repo: run.sh's DEPLOY_BASE (built by deploy-lib.sh) when there is one, else built here once."""
    if not STATE:
        given = os.environ.get("DEPLOY_BASE", "")
        if given and os.path.isdir(os.path.join(given, "repo")):
            d = given
        else:
            d = tempfile.mkdtemp()
            atexit.register(shutil.rmtree, d, True)
            _build_base(d)
        STATE["dir"] = d
        STATE["staged"] = git("-C", os.path.join(d, "repo"), "rev-parse", "feat/7-x")
    return STATE["dir"]


_REAL_RUN = deploy._run


def _gate_in_process(argv, out=None, err=None, cwd=None, input=None):
    """deploy._run, with `bash gate.sh <args>` answered by gate.main in this process (the same argv and streams, one
    Python start less per gate); every other command runs as it is."""
    if list(argv[:2]) != ["bash", os.path.join(deploy.SCRIPTS, "gate.sh")]:
        return _REAL_RUN(argv, out=out, err=err, cwd=cwd, input=input)
    from shipfloor_core import gate
    deploy._flush()
    saved = os.dup(1), os.dup(2)
    here, env = os.getcwd(), dict(os.environ)
    cap = tempfile.TemporaryFile() if out == subprocess.PIPE else None
    null = open(os.devnull, "wb")
    try:
        target = {subprocess.PIPE: cap, subprocess.DEVNULL: null, None: None}.get(out, out)
        if target is not None:
            os.dup2(target.fileno(), 1)
        e = {subprocess.STDOUT: 1, subprocess.DEVNULL: null.fileno(), None: None}.get(err, err)
        if e is not None:
            os.dup2(e if isinstance(e, int) else e.fileno(), 2)
        if cwd:
            os.chdir(cwd)
        try:
            rc = gate.main(list(argv[2:]))
        except SystemExit as x:
            rc = x.code if isinstance(x.code, int) else 1
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        os.dup2(saved[0], 1)
        os.dup2(saved[1], 2)
        os.close(saved[0])
        os.close(saved[1])
        null.close()
        os.chdir(here)
        os.environ.clear()
        os.environ.update(env)
    data = b""
    if cap is not None:
        cap.seek(0)
        data = cap.read()
        cap.close()
    return rc, data


_REAL_CFG, _REAL_MACHINE = project.cfg, project.machine


def _answer(fn, query, input=None):
    """fn(query) (shipfloor_config in this process) as the CompletedProcess (bytes) its process would give."""
    out, err = io.BytesIO(), io.BytesIO()
    saved = sys.stdout, sys.stderr, sys.stdin
    sys.stdout = io.TextIOWrapper(out, encoding="utf-8", errors="surrogateescape", newline="\n", write_through=True)
    sys.stderr = io.TextIOWrapper(err, encoding="utf-8", errors="surrogateescape", newline="\n", write_through=True)
    sys.stdin = io.TextIOWrapper(io.BytesIO(input or b""), encoding="utf-8", errors="surrogateescape")
    try:
        rc = fn(list(query))
    finally:
        for s in (sys.stdout, sys.stderr):
            s.flush()
            s.detach()
        sys.stdout, sys.stderr, sys.stdin = saved
    return subprocess.CompletedProcess(list(query), rc, out.getvalue(), err.getvalue())


def _cfg_in_process(*query, input=None):
    """project.cfg answered in this process: the same CompletedProcess, no Python start."""
    return _answer(project._cfg_in_process, query, input)


def _machine_in_process(*query):
    """project.machine answered in this process (it sets SHIPFLOOR_MACHINE_CONFIG, as its process had it)."""
    return _answer(project._machine_in_process, query)


@contextlib.contextmanager
def config_in_process():
    """project.cfg and project.machine answered in this process for the block."""
    project.cfg, project.machine = _cfg_in_process, _machine_in_process
    try:
        yield
    finally:
        project.cfg, project.machine = _REAL_CFG, _REAL_MACHINE


class DeployCase(support.Case):
    """One deploy case in $T (the same path for every test of the class, so a scene's copy, whose worktrees hold
    absolute paths, can be put back): remote.git, repo, fg/ (the fakes' state), home/, wt/."""

    scenes = None
    # gate.sh and the config queries answered in this process (DEPLOY_REAL_GATE=1: through their real processes)
    gate_in_process = os.environ.get("DEPLOY_REAL_GATE") != "1"

    @classmethod
    def setUpClass(cls):
        cls.ctmp = tempfile.mkdtemp()
        cls.scenes = {}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.ctmp, True)

    def setUp(self):
        super().setUp()
        b = base()
        self.staged = STATE["staged"]
        self.T = os.path.join(self.ctmp, "t")
        shutil.rmtree(self.T, True)
        os.makedirs(self.T)
        for n in ("remote.git", "repo"):
            shutil.copytree(os.path.join(b, n), os.path.join(self.T, n), symlinks=True)
        self.point()
        git("-C", self.repo, "remote", "set-url", "origin", self.remote)
        os.makedirs(self.FG)
        self.put("remote", self.remote + "\n")
        self.put("pr", "78\n")
        self.put("branch", "feat/7-x\n")
        self.put("ci", "api=SUCCESS\n")
        self.put("comments", "factory\tstaged-head: %s\n" % self.staged)
        self.put("status", "Ready for Prod\n")
        _write(os.path.join(self.T, "board"), '#!/usr/bin/env bash\ncase "$1" in status) cat "%s/status" ;; '
               'move) echo "$3" > "%s/status" ;; esac\n' % (self.FG, self.FG), 0o755)
        _write(os.path.join(self.T, "curl"), '#!/usr/bin/env bash\nexit "$(cat "%s/curl" 2>/dev/null || echo 0)"\n'
               % self.FG, 0o755)
        with open(os.path.join(support.FIXTURE, "factory.yml"), encoding="utf-8") as f:
            cfg = "".join(l for l in f if not l.startswith("deploy:"))
        _write(self.cfg, cfg + 'deploy: {healthcheck: ["https://shop.example/health"]}\n')
        os.makedirs(os.environ["FACTORY_HOME"], exist_ok=True)
        self.code = None
        self.out = ""

    def point(self):
        T = self.T
        self.remote, self.repo, self.FG, self.cfg = T + "/remote.git", T + "/repo", T + "/fg", T + "/factory.yml"
        self.wt = T + "/wt/7"
        self.tmp7 = T + "/home/tmp/7"
        os.environ.update(FG=self.FG, FACTORY_CONFIG=self.cfg, FACTORY_HOME=T + "/home", FACTORY_WT_ROOT=T + "/wt",
                          FACTORY_REPO=self.repo, FACTORY_GH=FAKE_GH, FACTORY_BOARD=T + "/board",
                          FACTORY_CURL=T + "/curl", FACTORY_POLL="0", SHIPFLOOR_GATE_FRESH="1")

    # --- the run -------------------------------------------------------------------------------------------------
    def run_deploy(self, *args, env=None):
        """deploy.main(args) from the repo, in this process; its exit code (also self.code), its output in self.out."""
        saved_env = {k: os.environ.get(k) for k in (env or {})}
        os.environ.update(env or {})
        here = os.getcwd()
        out = os.path.join(self.T, "out")
        sys.stdout.flush()
        sys.stderr.flush()
        fd1, fd2 = os.dup(1), os.dup(2)
        try:
            with open(out, "wb") as f:
                os.dup2(f.fileno(), 1)
                os.dup2(f.fileno(), 2)
            os.chdir(self.repo)
            if self.gate_in_process:
                deploy._run, project.cfg = _gate_in_process, _cfg_in_process
            try:
                self.code = deploy.main([str(a) for a in args])
            finally:
                deploy._run, project.cfg = _REAL_RUN, _REAL_CFG
        finally:
            sys.stdout.flush()
            sys.stderr.flush()
            os.dup2(fd1, 1)
            os.dup2(fd2, 2)
            os.close(fd1)
            os.close(fd2)
            os.chdir(here)
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        with open(out, encoding="utf-8", errors="replace") as f:
            self.out = f.read()
        return self.code

    # --- the fakes' state ----------------------------------------------------------------------------------------
    def put(self, name, text):
        _write(os.path.join(self.FG, name), text)

    def fg(self, name):
        try:
            with open(os.path.join(self.FG, name), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""

    def has(self, name):
        return os.path.exists(os.path.join(self.FG, name))

    def status(self):
        return self.fg("status").strip()

    def comments(self):
        return self.fg("comments")

    def posted(self, text):
        return text in self.fg("calls")

    def gh_with(self, snippet):
        """The fake gh behind a snippet that may answer a call itself (L logs it) or let it through."""
        p = os.path.join(self.T, "gh")
        _write(p, '#!/usr/bin/env bash\nL() { echo "$*" >> "$FG/calls"; }\nFAKE_GH="%s"\n%s\nexec bash "%s" "$@"\n'
               % (FAKE_GH, snippet, FAKE_GH), 0o755)
        os.environ["FACTORY_GH"] = p

    def board_script(self, body):
        _write(os.path.join(self.T, "board"), "#!/usr/bin/env bash\n" + body, 0o755)

    def curl_script(self, body):
        _write(os.path.join(self.T, "curl"), "#!/usr/bin/env bash\n" + body, 0o755)

    def dcfg(self, yaml):
        """The deploy section of the project config, replaced."""
        with open(self.cfg, encoding="utf-8") as f:
            lines = [l for l in f if not l.startswith("deploy:")]
        _write(self.cfg, "".join(lines) + "deploy: %s\n" % yaml)

    def append_cfg(self, line):
        with open(self.cfg, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def ptbr(self):
        self.append_cfg("language: pt-BR")

    def lci(self, cmd):
        self.dcfg("{local_ci: '%s'}" % cmd)

    # --- git -----------------------------------------------------------------------------------------------------
    def head_of(self, ref="feat/7-x"):
        return git("--git-dir=" + self.remote, "rev-parse", ref)

    def on_main(self, path):
        return subprocess.run(["git", "--git-dir=" + self.remote, "cat-file", "-e", "main:" + path],
                              stderr=subprocess.DEVNULL).returncode == 0

    def clone(self, branch=None):
        w = tempfile.mkdtemp(dir=self.T)
        git("clone", "-q", *(["-b", branch] if branch else []), self.remote, w)
        return w

    def commit_file(self, w, path, text, msg=None):
        _write(os.path.join(w, path), text)
        git("-C", w, "add", "-A")
        git("-C", w, "commit", "-qm", msg or "commit " + path)
        return git("-C", w, "rev-parse", "HEAD")

    def main_commit(self, path, text):
        """Another card lands on main."""
        w = self.clone()
        self.commit_file(w, path, text + "\n", "main: " + path)
        git("-C", w, "push", "-q", "origin", "main")

    def on_branch(self, path, text, record=True):
        """A commit on the card's branch, re-staged (a new staged-head comment) unless record=False."""
        w = self.clone("feat/7-x")
        sha = self.commit_file(w, path, text + "\n", "card: " + path)
        git("-C", w, "push", "-q", "origin", "feat/7-x")
        if record:
            with open(os.path.join(self.FG, "comments"), "a") as f:
                f.write("factory\tstaged-head: %s\n" % sha)
        return sha

    def unapproved_push(self, name="B.kt"):
        """A commit on the card's branch that nobody approved."""
        return self.on_branch("api/" + name, "sneaky", record=False)

    def fix(self, path, lines):
        """What the agent of a fix round commits in the card's worktree."""
        _write(os.path.join(self.wt, path), "".join("%d\n" % i for i in range(1, lines + 1)))
        git("-C", self.wt, "add", "-A")
        git("-C", self.wt, "commit", "-qm", "fix: " + path)
        return git("-C", self.wt, "rev-parse", "HEAD")

    def wg(self, *args):
        return git("-C", self.wt, *args)

    def resolve(self):
        _write(os.path.join(self.wt, "shared.txt"), "resolved\n")
        self.wg("add", "shared.txt")
        self.wg("commit", "-q", "--no-edit")

    def hand(self, name):
        """A file the deploy keeps in <home>/tmp/7 (fix.findings, fix.round, resolve.parents, gates.txt...)."""
        try:
            with open(os.path.join(self.tmp7, name), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return None

    # --- scenes: a state several tests start from, built once per class --------------------------------------------
    def scene(self, name):
        if name not in self.scenes:
            getattr(self, "scene_" + name)()
            keep = tempfile.mkdtemp(dir=self.ctmp)
            shutil.copytree(self.T, os.path.join(keep, "t"), symlinks=True)
            self.scenes[name] = (os.path.join(keep, "t"), self.code, self.out)
            return
        src, self.code, self.out = self.scenes[name]
        shutil.rmtree(self.T, True)
        shutil.copytree(src, self.T, symlinks=True)
        self.point()

    def scene_behind(self):  # another card landed on main: the PR is behind
        self.main_commit("web/other.ts", "x")

    def scene_red(self):  # red CI on top of main: a fix round (code 3)
        self.scene_behind()
        self.put("ci", "api=FAILURE\n")
        self.run_deploy(7)

    def scene_conflict(self):  # a small conflict, handed over (code 3)
        self.on_branch("shared.txt", "card")
        self.main_commit("shared.txt", "main")
        self.run_deploy(7)

    def scene_gatered(self):  # a gate fails after merging main: a fix round (code 3)
        self.on_branch("docs/engineering/a.md", "x")
        self.main_commit("web/other.ts", "x")
        self.run_deploy(7)

    # --- the outcomes ------------------------------------------------------------------------------------------------
    def want(self, code):
        self.assertEqual(self.code, code, self.out)

    def assert_blocked(self, reason, before=None):
        """exit 5, the reason on the card, labelled, the card where it was, nothing merged (nor pushed)."""
        self.want(5)
        self.assertIn("Factory deploy stopped: " + reason, self.comments())
        self.assertIn("blocked", self.fg("labels"))
        self.assertEqual(self.status(), "Ready for Prod")
        self.assertFalse(self.posted("pr merge"), "merged")
        if before:
            self.assertEqual(self.head_of(), before, "pushed")

    def assert_coding(self, reason, before=None):
        """exit 4, in Coding with the reason, nothing merged (nor pushed)."""
        self.want(4)
        self.assertEqual(self.status(), "Coding")
        self.assertIn("Back to Coding: " + reason, self.comments())
        self.assertFalse(self.posted("pr merge"), "merged")
        if before:
            self.assertEqual(self.head_of(), before, "pushed")

    def assert_shipped(self, worktree=True):
        """exit 0, Done, the Deployed comment naming the merge, the worktree gone, no label."""
        self.want(0)
        self.assertEqual(self.status(), "Done")
        self.assertIn("Deployed: merge " + self.fg("merged").strip(), self.comments())
        if worktree:
            self.assertFalse(os.path.exists(self.wt), "worktree left")
            self.assertNotIn("/7 ", git("-C", self.repo, "worktree", "list"))
        self.assertFalse(self.has("labels"), self.fg("labels"))
