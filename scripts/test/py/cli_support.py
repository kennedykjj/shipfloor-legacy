"""Helpers for the in-process CLI suites (cli_*.py): shipfloor_core.cli.main (and init, project) called in this process
with fds 0, 1 and 2 swapped for files, so the output of the processes it starts (git, gh, gate.sh, setup-board.sh) is
caught too; the environment and the working directory as they were after each call, as a process would leave them.

Doubles: gh is a small Bash script reading $GH_STUB_DIR (calls, noauth, protection, protection-fails); uname, systemctl,
crontab and launchctl stand in for the machine (SF_UNAME, $SF_ST/table); claude is `exit 0`. git is real, on throwaway
repos with a bare origin. The config queries (project.cfg, project.machine) are answered in this process."""
import atexit
import os
import shutil
import stat
import subprocess
import sys
import tempfile

import support
from deploy_support import config_in_process, git
from shipfloor_core import cli

FIXTURE_CFG = os.path.join(support.FIXTURE, "factory.yml")
ROOT = os.path.dirname(support.SCRIPTS)
_SHARED = {}

GH = r'''#!/usr/bin/env bash
d="$GH_STUB_DIR"; args="$*"
printf '%s\t%s\n' "$PWD" "$args" >> "$d/calls"
case "$args" in
  "auth status"*) [ -e "$d/noauth" ] && { echo "You are not logged in" >&2; exit 1; }; exit 0 ;;
  "api repos/"*"/protection"*) cat "$d/protection" 2>/dev/null || echo true; [ -e "$d/protection-fails" ] && exit 1; exit 0 ;;
  "api -X POST repos/"*"/issues/"*"/comments"*)
    [ -e "$d/comment-fails" ] && { echo "HTTP 500" >&2; exit 1; }
    f=""; for a in "$@"; do case "$a" in body=@*) f="${a#body=@}" ;; esac; done
    [ -n "$f" ] || exit 1
    k=1; while [ -e "$d/comment-$k" ]; do k=$((k+1)); done
    cp "$f" "$d/comment-$k" ;;
  "repo view"*) echo acme/shop ;;
  "project view"*) echo PVT_x ;;
  "project field-list"*"| .id") echo FLD_x ;;
  "project field-list"*) i=0; for s in "👤 Inbox" "👤 Ready for Refinement" "🤖 Technical Refinement" "👤 Spec Review" "👤 Ready for Dev" "🤖 Coding" "🤖 Validation" "👤 Staged" "👤 Ready for Prod" "🤖 Done"; do i=$((i+1)); printf '%s\topt%s\n' "$s" "$i"; done ;;
  "project item-list"*group_by*) echo "Coding: 1" ;;
  "project item-list"*) printf 'I1\t🤖 Coding\n' ;;
  "api graphql"*|"project item-edit"*|"label create"*) ;;
  *) exit 1 ;;
esac
'''
UNAME = '#!/usr/bin/env bash\nif [ "${1:-}" = -s ]; then echo "${SF_UNAME:-Linux}"; else exec "$SF_REAL_UNAME" "$@"; fi\n'
CRONTAB = ('#!/usr/bin/env bash\ncase "${1:-}" in -l) [ -f "$SF_ST/table" ] && { cat "$SF_ST/table"; exit 0; }; exit 1 ;;'
           ' -) cat > "$SF_ST/table" ;; esac\n')
INSTALLER = '''#!/usr/bin/env bash
echo "$*" >> "$SF_ST/installer-calls"
case "${1:-}" in
  --status) [ -e "$SF_ST/registered" ] && { echo "registered: cron"; exit 0; }; echo "not registered"; exit 1 ;;
  --uninstall) rm -f "$SF_ST/registered" ;;
  *) touch "$SF_ST/registered" ;;
esac
exit 0
'''


def script(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP)
    return path


def _shared_dir():
    if "dir" not in _SHARED:
        _SHARED["dir"] = tempfile.mkdtemp()
        atexit.register(shutil.rmtree, _SHARED["dir"], True)
    return _SHARED["dir"]


def template():
    """A repo with one commit (README.md) on main, built once per process."""
    t = os.path.join(_shared_dir(), "template")
    if not os.path.isdir(t):
        git("init", "-q", "-b", "main", t)
        with open(os.path.join(t, "README.md"), "w") as f:
            f.write("base\n")
        git("-C", t, "add", "-A")
        git("-C", t, "commit", "-qm", "base")
    return t


def plugin_copy():
    """A plain (non-git) copy of scripts/ and templates/, with examples/factory.yml and a stand-in dispatcher installer
    (logs to $SF_ST/installer-calls, "registered" kept as $SF_ST/registered); built once per process."""
    pc = os.path.join(_shared_dir(), "plugin")
    if not os.path.isdir(pc):
        shutil.copytree(support.SCRIPTS, os.path.join(pc, "scripts"),
                        ignore=lambda d, names: [n for n in names if n == "__pycache__" or
                                                 (d == support.SCRIPTS and n == "test")])
        shutil.copytree(os.path.join(ROOT, "templates"), os.path.join(pc, "templates"))
        os.makedirs(os.path.join(pc, "examples"))
        shutil.copy(os.path.join(ROOT, "examples", "factory.yml"), os.path.join(pc, "examples", "factory.yml"))
        script(os.path.join(pc, "installer", "install-dispatcher.sh"), INSTALLER)
        script(os.path.join(pc, "installer", "install-dispatcher.ps1"), "exit 0\n")
    return pc


class CliCase(support.Case):
    """A machine of its own: SHIPFLOOR_HOME = self.sh, no FACTORY_* variable, gh and the machine tools as doubles."""

    def setUp(self):
        super().setUp()
        for k in ("FACTORY_CONFIG", "FACTORY_HOME", "FACTORY_REPO", "FACTORY_PROJECT", "FACTORY_WT_ROOT", "FACTORY_MAIN"):
            os.environ.pop(k, None)
        self.sh = self.path("sh")
        os.environ.update(SHIPFLOOR_HOME=self.sh, GIT_TERMINAL_PROMPT="0", HOME=self.path("userhome"),
                          GH_STUB_DIR=self.path("ghstate"), SF_ST=self.path("st"),
                          SF_REAL_UNAME=shutil.which("uname") or "/usr/bin/uname", CLAUDE_CONFIG_DIR=self.path("claude"),
                          GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        self.g = os.environ["GH_STUB_DIR"]
        self.st = os.environ["SF_ST"]
        b = self.path("bin")
        script(os.path.join(b, "gh"), GH)
        script(os.path.join(b, "uname"), UNAME)
        script(os.path.join(b, "crontab"), CRONTAB)
        script(os.path.join(b, "systemctl"), "#!/usr/bin/env bash\nexit 1\n")
        script(os.path.join(b, "launchctl"), "#!/usr/bin/env bash\nexit 1\n")
        script(os.path.join(b, "claude"), "#!/usr/bin/env bash\nexit 0\n")
        os.environ["PATH"] = b + os.pathsep + os.environ["PATH"]
        saved_here = cli.HERE
        self.addCleanup(setattr, cli, "HERE", saved_here)
        cfg = config_in_process()
        cfg.__enter__()
        self.addCleanup(cfg.__exit__, None, None, None)

    # --- calling the product ------------------------------------------------------------------------------------------

    def call(self, fn, *args, cwd=None):
        """fn(*args) as a process: fds 0 (/dev/null), 1 and 2 swapped; (rc, stdout, stderr); env and cwd restored."""
        out, err = tempfile.TemporaryFile(), tempfile.TemporaryFile()
        null = open(os.devnull, "rb")
        sys.stdout.flush()
        sys.stderr.flush()
        saved = os.dup(0), os.dup(1), os.dup(2)
        here, env, stdin = os.getcwd(), dict(os.environ), sys.stdin
        try:
            os.dup2(null.fileno(), 0)
            os.dup2(out.fileno(), 1)
            os.dup2(err.fileno(), 2)
            sys.stdin = null
            if cwd:
                os.chdir(cwd)
            try:
                rc = fn(*args)
            except SystemExit as x:
                rc = x.code if isinstance(x.code, int) else 1
        finally:
            sys.stdout.flush()
            sys.stderr.flush()
            for fd in (0, 1, 2):
                os.dup2(saved[fd], fd)
                os.close(saved[fd])
            sys.stdin = stdin
            null.close()
            os.chdir(here)
            os.environ.clear()
            os.environ.update(env)
        res = []
        for f in (out, err):
            f.seek(0)
            res.append(f.read().decode("utf-8", "replace").replace("\r", ""))
            f.close()
        return rc, res[0], res[1]

    def sf(self, *argv, cwd=None):
        """`shipfloor <argv>`: sets self.rc, self.out, self.err and self.both; returns the exit code."""
        self.rc, self.out, self.err = self.call(cli.main, list(argv), cwd=cwd)
        self.both = self.out + self.err
        return self.rc

    def ok(self, *argv, want=0):
        rc = self.sf(*argv)
        self.assertEqual(rc, want, "shipfloor %s → exit %s, want %s: %s" % (" ".join(argv), rc, want, self.both))
        return self.out

    # --- the world ----------------------------------------------------------------------------------------------------

    def new_repo(self, name="repo"):
        d = os.path.join(tempfile.mkdtemp(dir=self.tmp), name)
        shutil.copytree(template(), d)
        return d

    def with_origin(self, repo):
        remote = tempfile.mkdtemp(dir=self.tmp)
        git("init", "-q", "--bare", "-b", "main", remote)
        git("-C", repo, "remote", "add", "origin", remote)
        git("-C", repo, "push", "-q", "origin", "main")
        return remote

    def with_config(self, yaml=None, name="repo"):
        """A repo whose origin/main carries that config (the fixture's by default); self.remote is its origin."""
        r = self.new_repo(name)
        self.write_file(os.path.join(r, ".shipfloor", "factory.yml"), yaml if yaml is not None else self.fixture())
        git("-C", r, "add", "-A")
        git("-C", r, "commit", "-qm", "cfg")
        self.remote = self.with_origin(r)
        return r

    def fixture(self):
        with open(FIXTURE_CFG, encoding="utf-8") as f:
            return f.read()

    def write_file(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        return path

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def registry(self):
        p = os.path.join(self.sh, "registry.tsv")
        return self.read(p) if os.path.exists(p) else ""

    def gh_calls(self):
        p = os.path.join(self.g, "calls")
        return self.read(p) if os.path.exists(p) else ""

    def home_of(self, slug="shop"):
        return os.path.join(self.sh, "projects", slug)

    def run_cmd(self, *argv, cwd=None, env=None):
        """A real process (stdout+stderr, exit code)."""
        r = subprocess.run(list(argv), cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return r.returncode, r.stdout.decode("utf-8", "replace")

    def gate(self, *args):
        return self.run_cmd("bash", os.path.join(support.SCRIPTS, "gate.sh"), *args)[0]
