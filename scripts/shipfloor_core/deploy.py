"""deploy: the deterministic deploy of one card (docs/superpowers/specs/2026-10-09-fast-safe-deploy-design.md).

usage: deploy.sh <n> [--refresh | --continue]
  --refresh   bring a Staged card's PR up to date with main (clean merges only); never merges to main
  --continue  resume after what a previous run handed over (conflicts, or a red gate or CI) was fixed and committed
exit: 0 done · 3 handed over to an agent (conflicts in <tmp>/resolve.files, or a fix in <tmp>/fix.findings)
      4 sent back (to Coding, or to Staged with a fix the owner has to see) · 5 blocked · 6 failed after merge (reverted)
      2 usage, configuration, transient API error or busy card (safe to retry)

The port of the Bash deploy.sh (#167): one method per Bash function, the same processes with the same argv (git, gh,
curl, timeout, bash gate.sh, board.sh), the same streams (what Bash let through to stderr still goes there), the same
messages. Tested in process by scripts/test/py/deploy_*.py, and through deploy.sh by scripts/test/deploy-cli.test.sh.
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import time

from . import fs, proc, project, text
from .defaults import DEPLOY_DEFAULTS, TRAILER
from .proc import alive as _alive
from .text import read_tab as _read_tab

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
USAGE = "usage: deploy.sh <n> [--refresh | --continue]"
KEYS = ("project.repo", "project.main", "deploy.ci_workflow", "deploy.environment", "deploy.timeout_min",
        "deploy.conflict_max_files", "deploy.conflict_max_hunks", "paths.specs", "deploy.allow_no_checks",
        "deploy.healthcheck", "deploy.required_checks", "deploy.fix_max_files", "deploy.fix_max_lines", "language",
        "deploy.local_ci")
PIPE, DEVNULL, STDOUT = subprocess.PIPE, subprocess.DEVNULL, subprocess.STDOUT
CHECKS_JQ = ('.headRefOid + " " + ([.statusCheckRollup[] | (.name // .context // "") + "=" + (if (.conclusion // "") != ""'
             ' then .conclusion else (.state // .status // "") end)] | join(","))')
RUN_JQ = '.status + " " + (.conclusion // "")'


class DeployExit(Exception):
    """Leave the run with this exit code (the Bash script's `exit <code>`)."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


# --- the shell's plumbing, as Bash does it ------------------------------------------------------------------------

def _t(b):
    return b.decode("utf-8", "surrogateescape")


def _flush():
    sys.stdout.flush()
    sys.stderr.flush()


def _run(argv, out=None, err=None, cwd=None, input=None):
    """Run a command; (exit code, stdout bytes when out is PIPE). Streams left None are this process's own."""
    _flush()
    try:
        r = subprocess.run(argv, cwd=cwd, input=input, stdout=out, stderr=err)
    except OSError as e:
        if err is None:
            sys.stderr.write("%s: %s\n" % (argv[0], e.strerror or e))
        return 127, b""
    rc = r.returncode
    return (128 - rc if rc < 0 else rc), (r.stdout or b"")


def _cap(argv, err=None, cwd=None, input=None):
    """$(command): (exit code, stdout without its trailing newlines)."""
    rc, out = _run(argv, out=PIPE, err=err, cwd=cwd, input=input)
    return rc, _t(out).rstrip("\n")


def _lines(s):
    """The lines grep, read or tail see in a text: a last line without its newline still counts."""
    parts = s.split("\n")
    if parts and parts[-1] == "":
        parts.pop()
    return parts


def _count(s):
    """grep -c . : the lines with at least one character."""
    return sum(1 for l in _lines(s) if l)


def _tail(path, n):
    """tail -n <n> <path>, or None when the file cannot be read."""
    try:
        with open(path, "rb") as f:
            data = _t(f.read())
    except OSError:
        return None
    return _tail_text(data, n)


def _tail_text(data, n):
    parts = data.split("\n")
    lines = [p + "\n" for p in parts[:-1]] + ([parts[-1]] if parts[-1] else [])
    return "".join(lines[-n:]) if n > 0 else ""


def _tr(s):
    """tr '\\n' ' '"""
    return s.replace("\n", " ")


def _fields(line):
    """awk's default fields: split on runs of blanks and tabs."""
    return [f for f in re.split(r"[ \t\n]+", line) if f]


def _int(s, default=0):
    try:
        return int(str(s).strip())
    except ValueError:
        return default


def _sha(s):
    return re.fullmatch(r"[0-9a-f]{40}", s) is not None


def _write(path, data):
    """echo ... > path"""
    with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
        f.write(data)


def _read(path):
    """$(cat path): None when it cannot be read."""
    try:
        with open(path, "rb") as f:
            return _t(f.read()).rstrip("\n")
    except OSError:
        return None


def _nonempty(path):
    """[ -s path ]"""
    try:
        return os.path.getsize(path) > 0
    except OSError:
        return False


def _rm(path):
    """rm -f / rm -rf"""
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            os.unlink(path)
        except OSError:
            pass


def _env(name):
    """$NAME under `set -u`: an unset one stops the run with exit 1, as Bash does."""
    v = os.environ.get(name)
    if v is None:
        print("deploy.sh: %s: unbound variable" % name, file=sys.stderr)
        raise DeployExit(1)
    return v


def _bounded(secs, argv, cwd, out):
    """run_bounded (the old lib/portable.sh): the command's exit code, or 124 when it was stopped at its limit.
    GNU timeout when there is one; otherwise the command's whole process tree is killed at the limit."""
    if shutil.which("timeout"):
        return _run(["timeout", str(secs), *argv], out=out, err=STDOUT, cwd=cwd)[0]
    _flush()
    kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    try:
        p = subprocess.Popen(argv, cwd=cwd, stdout=out, stderr=STDOUT, **kw)
    except OSError as e:
        out.write(("%s: %s\n" % (argv[0], e.strerror or e)).encode("utf-8"))
        return 127
    try:
        rc = p.wait(timeout=secs)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], stdout=DEVNULL, stderr=DEVNULL)
        else:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
        p.wait()
        return 124
    return 128 - rc if rc < 0 else rc


# --- the deploy -----------------------------------------------------------------------------------------------------

class Deploy:
    def __init__(self):
        self.n = ""
        self.mode = "deploy"
        self.lang = "en"
        self.lock = None
        self.locked = False
        self.BRANCH = ""
        self.PR = ""
        self.HEAD_SHA = None
        self.MERGED = ""
        self.RECORDED = ""
        self.CI_STATES = ""
        self.CONFLICTS = ""
        self.REASON = ""

    # what each process is
    def gh(self, *args):
        return proc.gh_argv(*args)

    def board(self, *args):
        b = os.environ.get("FACTORY_BOARD", "")
        if b:
            return proc.script_argv(b, *args)
        return ["bash", os.path.join(SCRIPTS, "board.sh"), *args]

    def g(self, *args):
        return ["git", "-C", self.WT, *args]

    def r(self, *args):
        return ["git", "-C", _env("FACTORY_REPO"), *args]

    def polls(self, secs):
        return secs // self.POLL + 1 if self.POLL > 0 else _int(os.environ.get("FACTORY_POLLS") or "60")

    def sleep(self, secs):
        if secs > 0:
            time.sleep(secs)

    # the Bash functions
    def say(self, msg):
        sys.stdout.write(text.say(self.lang, "deploy #%s: %s\n" % (self.n, msg)))

    def comment(self, body):
        b = text.say(self.lang, body + "\n").rstrip("\n")
        if _run(self.gh("issue", "comment", self.n, "--repo", self.REPO, "--body", b), out=DEVNULL)[0] != 0:
            self.say("could not comment on #%s" % self.n)
            return False
        return True

    def reset_worktree(self):  # drop any merge in progress or local commit: back to the approved head
        if not self.BRANCH or not os.path.exists(self.WT + "/.git"):
            return
        _run(self.g("merge", "--abort"), out=DEVNULL, err=DEVNULL)
        _run(self.g("reset", "-q", "--hard", self.HEAD_SHA or "origin/" + self.BRANCH), err=DEVNULL)
        _run(self.g("-c", "core.longpaths=true", "clean", "-qfd"), err=DEVNULL)

    def block(self, msg):  # before merging: label, explain, stop
        self.reset_worktree()
        self.comment("Factory deploy stopped: " + msg)
        if _run(self.gh("issue", "edit", self.n, "--repo", self.REPO, "--add-label", "blocked"), out=DEVNULL)[0] != 0:
            self.say("could not label #%s blocked" % self.n)
        self.say("blocked: " + msg)
        raise DeployExit(5)

    def back_to_coding(self, msg):
        self.reset_worktree()
        if self.mode == "--refresh":
            self.say(msg + "; left for the deploy")
            raise DeployExit(0)
        self.comment("Back to Coding: " + msg)
        if _run(self.board("move", self.n, "Coding"), out=DEVNULL)[0] != 0:
            self.say("could not move the card to Coding")
            raise DeployExit(2)
        self.say("back to Coding: " + msg)
        raise DeployExit(4)

    def retry_later(self, msg):
        self.say(msg + "; will retry")
        raise DeployExit(2)

    def handed_over(self):  # exit 3: the lock goes now, the worktree stays as it is for --continue
        self.locked = False
        _rm(self.lock)
        raise DeployExit(3)

    # entry
    def run(self, argv):
        self.n = argv[0] if argv else ""
        self.mode = argv[1] if len(argv) > 1 and argv[1] else "deploy"
        if self.mode not in ("deploy", "--refresh", "--continue"):
            self.n = ""
        if not re.fullmatch(r"[0-9]+", self.n):
            print(USAGE, file=sys.stderr)
            return 2
        try:
            project.resolve(".")
        except project.ProjectError as e:
            print(e, file=sys.stderr)
            return 2
        c = project.cfg("values", *KEYS)
        _flush()
        sys.stderr.buffer.write(c.stderr)
        sys.stderr.buffer.flush()
        V = [_t(v) for v in c.stdout.split(b"\0")]
        if V and V[-1] == "":
            V.pop()
        if len(V) != 15:
            print("deploy: cannot read the project config", file=sys.stderr)
            return 2
        self.REPO, self.MAIN, self.CI_WORKFLOW, self.ENVIRONMENT = V[0], V[1], V[2], V[3]
        self.TIMEOUT_MIN = V[4] or str(DEPLOY_DEFAULTS["timeout_min"])
        self.MAX_FILES, self.MAX_HUNKS = V[5] or str(DEPLOY_DEFAULTS["conflict_max_files"]), V[6] or str(DEPLOY_DEFAULTS["conflict_max_hunks"])
        self.SPECS = V[7]
        self.ALLOW_NO_CHECKS = V[8] or "false"
        self.HEALTH, self.REQUIRED = V[9], V[10]  # lists, one item per line
        self.lang = V[13] or "en"  # what this script says, in the log and on the card
        self.LOCAL_CI = V[14]  # the project's CI as a command run here, where GitHub's checks would be waited for
        self.FIX_FILES, self.FIX_LINES = V[11] or "3", V[12] or "40"  # a fix within both ships without a new approval
        self.GATE = os.path.join(SCRIPTS, "gate.sh")
        self.CURL = os.environ.get("FACTORY_CURL") or "curl"
        self.POLL = _int(os.environ.get("FACTORY_POLL") or "30")
        self.WT = "%s/%s" % (_env("FACTORY_WT_ROOT"), self.n)
        self.TMP = "%s/tmp/%s" % (_env("FACTORY_HOME"), self.n)
        try:
            os.makedirs(self.TMP, exist_ok=True)
        except OSError as e:
            print("mkdir: %s: %s" % (self.TMP, e.strerror), file=sys.stderr)
        if self.mode != "--continue":  # a fresh run starts its fix rounds over
            try:
                for f in os.listdir(self.TMP):
                    if f.startswith("fix."):
                        _rm(os.path.join(self.TMP, f))
            except OSError:
                pass
        self.START = int(time.time())
        try:
            self.take_lock()
            self.deploy()
        except DeployExit as e:
            return e.code
        finally:
            if self.locked:
                _rm(self.lock)
        return 0

    def take_lock(self):  # one deploy.sh per card at a time (refresh, deploy, continue), whoever started it
        locks = _env("FACTORY_HOME") + "/locks"
        self.lock = "%s/deploysh-%s.lock" % (locks, self.n)
        try:
            os.makedirs(locks, exist_ok=True)
        except OSError:
            pass
        info = "%d %d\n" % (os.getpid(), int(time.time()))
        if self._mkdir_lock(info):
            return
        data = _read(self.lock + "/info")
        held = "\n".join(l.split(" ")[0] for l in _lines(data or "")).rstrip("\n")
        if held and _alive(held):
            self.say("another deploy.sh runs on this card (pid %s)" % held)
            raise DeployExit(2)
        _rm(self.lock)
        if not self._mkdir_lock(info):
            raise DeployExit(2)

    def _mkdir_lock(self, info):
        try:
            ok = fs.lock_dir(self.lock, info)
        except OSError:
            return False
        self.locked = ok
        return ok

    def deploy(self):
        n, mode = self.n, self.mode
        # 1. card and PR
        rc, self.status = _cap(self.board("status", n))
        if rc != 0:
            self.retry_later("cannot read the board")
        if mode == "--refresh":
            if self.status != "Staged":
                self.say("not Staged (%s); nothing to refresh" % self.status)
                raise DeployExit(0)
        elif self.status != "Ready for Prod":
            self.say("#%s is in '%s', not Ready for Prod" % (n, self.status))
            raise DeployExit(2)
        rc, self.ME = _cap(self.gh("api", "user", "--jq", ".login"))
        if rc != 0:
            self.retry_later("cannot read the GitHub user")
        rc, lst = _cap(self.gh("pr", "list", "--repo", self.REPO, "--state", "open", "--base", self.MAIN, "--json",
                               "number,headRefName,isCrossRepository,headRefOid", "--jq",
                               r'.[] | "\(.number)\t\(.headRefName)\t\(.isCrossRepository)\t\(.headRefOid)"'))
        if rc != 0:
            self.retry_later("cannot list PRs")
        # the PR's branch as one whole tab-separated field
        self.PR_FIELD = "\t(feat/%s-[^\t]*|revert/%s)\t" % (n, n)
        prs = self.grep_lines(self.PR_FIELD, lst + "\n").rstrip("\n")

        if _count(prs) != 1:
            if mode == "--refresh":
                raise DeployExit(0)
            if not prs and self.resume_merged():
                self.RESUMED = 1
            else:
                self.block("expected one open PR for #%s, found: %s" % (n, prs or "none"))
        else:
            self.RESUMED = 0
            self.PR, self.BRANCH, cross, self.HEAD_SHA = _read_tab(prs.split("\n")[0], 4)
            if cross != "false":
                self.block("PR #%s comes from a fork; the factory deploys only its own branches" % self.PR)

        if self.RESUMED == 0:
            self.approve()
        if self.RESUMED == 0:
            self.update_and_merge()
        self.production()

    def grep_lines(self, pattern, s):
        """grep -E -- <pattern> on the text: the matching lines (a bad pattern matches nothing, as grep exit 2)."""
        try:
            return text.ere_lines(pattern, s)
        except ValueError as e:
            print(e, file=sys.stderr)
            return ""

    def grep_q(self, pattern, s, ignore_case=False, invert=False):
        try:
            return text.ere_match(pattern, s, ignore_case=ignore_case, invert=invert)
        except ValueError as e:
            print(e, file=sys.stderr)
            return False

    def resume_merged(self):  # the PR was merged by an earlier run that stopped before production was checked
        rc, m = _cap(self.gh("pr", "list", "--repo", self.REPO, "--state", "merged", "--base", self.MAIN, "--json",
                             "number,headRefName,mergeCommit", "--jq",
                             r'.[] | "\(.number)\t\(.headRefName)\t\(.mergeCommit.oid // "")"'))
        if rc != 0:
            self.retry_later("cannot list merged PRs")
        m = _lines(self.grep_lines(self.PR_FIELD, m + "\n"))
        m = m[0] if m else ""
        if not m:
            return False
        self.PR, _, m = m.partition("\t")
        self.BRANCH, _, self.MERGED = m.partition("\t")
        if not _sha(self.MERGED):
            return False
        if _run(self.r("fetch", "-q", "origin"))[0] != 0:
            self.retry_later("fetch failed")
        if _run(self.r("merge-base", "--is-ancestor", self.MERGED, "origin/" + self.MAIN))[0] != 0:
            return False
        self.say("PR #%s was already merged as %s; checking production" % (self.PR, self.MERGED))
        return True

    def approve(self):
        n, mode = self.n, self.mode
        if not _sha(self.HEAD_SHA):
            self.retry_later("PR #%s has no head sha" % self.PR)

        # 2. approval: the factory's own comments only. The newest staged-head is the owner-approved commit
        #    (the owner approved it by moving the card); deploy-merge heads are this script's merges of main.
        rc, bodies = _cap(self.gh("issue", "view", n, "--repo", self.REPO, "--json", "comments", "--jq",
                                  '.comments[] | select(.author.login == "%s") | .body' % self.ME))
        if rc != 0:
            self.retry_later("cannot read #%s comments" % n)
        lines = _lines((bodies + "\n").replace("\r", ""))
        approved = [m.group(1) for m in (re.match(r"staged-head: ([0-9a-f]{40})", l) for l in lines) if m]
        self.APPROVED = approved[-1] if approved else ""
        if not self.APPROVED:
            self.block("no staged-head comment on #%s" % n)
        recorded, on = [], False
        for l in lines:
            f = _fields(l)
            f1, f2 = (f + ["", ""])[:2]
            if f1 == "staged-head:":
                on = f2 == self.APPROVED
                continue
            if on and f1 in ("deploy-merge:", "deploy-fix:") and re.fullmatch(r"[0-9a-f]+", f2):
                recorded.append(f2)
        self.RECORDED = "\n".join(recorded)

        # 3. worktree exactly at the PR head GitHub reported
        if _run(self.r("fetch", "-q", "origin"))[0] != 0:
            self.retry_later("fetch failed")
        if _cap(self.r("rev-parse", "origin/" + self.BRANCH), err=DEVNULL)[1] != self.HEAD_SHA:
            self.retry_later("origin/%s is not the PR head %s yet" % (self.BRANCH, self.HEAD_SHA))
        if not self.approved_chain():
            if mode == "--refresh":
                self.say("head %s is not approved; not refreshing" % self.HEAD_SHA)
                raise DeployExit(0)
            self.block("PR #%s changed after it was staged (head %s is not the staged-head nor a recorded merge of main"
                       " on it)" % (self.PR, self.HEAD_SHA))
        if not os.path.exists(self.WT + "/.git"):
            if _run(self.r("worktree", "add", "-q", "-B", self.BRANCH, self.WT, self.HEAD_SHA))[0] != 0:
                self.retry_later("cannot create " + self.WT)
        elif mode != "--continue":
            if _run(self.g("checkout", "-q", "-B", self.BRANCH, self.HEAD_SHA), err=DEVNULL)[0] != 0:
                _run(self.g("merge", "--abort"), out=DEVNULL, err=DEVNULL)
                if _run(self.g("checkout", "-q", "-f", "-B", self.BRANCH, self.HEAD_SHA))[0] != 0:
                    self.retry_later("cannot check out %s in %s" % (self.BRANCH, self.WT))
            self.reset_worktree()

    def approved_chain(self):  # HEAD_SHA is the approved commit, or recorded commits of this script on top of it
        c = self.HEAD_SHA
        recorded = self.RECORDED.split("\n")
        for _ in range(10):
            if c == self.APPROVED:
                return True
            if c not in recorded:
                return False
            rc, p1 = _cap(self.r("rev-parse", "-q", "--verify", c + "^1"))
            if rc != 0:
                return False
            rc, p2 = _cap(self.r("rev-parse", "-q", "--verify", c + "^2"))
            if rc == 0 and _run(self.r("merge-base", "--is-ancestor", p2, "origin/" + self.MAIN))[0] != 0:
                return False
            c = p1
        return False

    def merge_main(self):  # 0 up to date · 1 merged cleanly · 3 conflicts to resolve · 4 beyond the criteria (REASON)
        if _run(self.g("merge-base", "--is-ancestor", "origin/" + self.MAIN, "HEAD"))[0] == 0:
            return 0
        main_sha = _cap(self.g("rev-parse", "origin/" + self.MAIN))[1]
        with open(self.TMP + "/merge.txt", "wb") as f:
            rc = _run(self.g("merge", "--no-ff", "--no-edit", "-m", "Merge origin/%s into %s" % (self.MAIN, self.BRANCH),
                             "-m", TRAILER, main_sha), out=f, err=STDOUT)[0]
        if rc == 0:
            return 1
        self.CONFLICTS = _cap(self.g("diff", "--name-only", "--diff-filter=U"))[1]
        if not self.CONFLICTS:
            self.REASON = "merge failed: " + _tr(_tail(self.TMP + "/merge.txt", 3) or "")
            return 4
        files = _count(self.CONFLICTS)
        hunks = 0
        for f in self.CONFLICTS.split("\n"):
            try:
                with open("%s/%s" % (self.WT, f), "rb") as fh:
                    hunks += sum(1 for l in fh.read().split(b"\n") if l.startswith(b"<<<<<<<"))
            except OSError:
                pass
        for layer, regex in self.migration_layers():
            if regex and self.grep_q(regex, self.CONFLICTS + "\n"):
                self.REASON = "a migration conflicts with main: " + _tr(self.grep_lines(regex, self.CONFLICTS + "\n"))
                return 4
        if files > _int(self.MAX_FILES):
            self.REASON = "%d files conflict with main (limit %s)" % (files, self.MAX_FILES)
            return 4
        if hunks > _int(self.MAX_HUNKS):
            self.REASON = "%d hunks conflict with main (limit %s)" % (hunks, self.MAX_HUNKS)
            return 4
        _write(self.TMP + "/resolve.parents", "%s\n%s\n" % (self.HEAD_SHA, main_sha))
        _write(self.TMP + "/resolve.files", self.CONFLICTS + "\n")
        return 3

    def migration_layers(self):
        """shipfloor_cfg migration-layers | tail -n +2, read as <layer> <ERE>: one pair per layer with migrations."""
        c = project.cfg("migration-layers")
        _flush()
        sys.stderr.buffer.write(c.stderr)
        sys.stderr.buffer.flush()
        out = []
        for line in _t(c.stdout).split("\n")[:-1][1:]:  # while read: a last line without its newline is not read
            layer, regex, _ = _read_tab(line, 3)
            out.append((layer, regex))
        return out

    def check_resolution(self):  # --continue: HEAD must be the merge of the approved head and main, changing only conflicted files
        if _run(self.g("rev-parse", "-q", "--verify", "MERGE_HEAD"), out=DEVNULL)[0] == 0:
            self.block("--continue with the merge still in progress")
        if _cap(self.g("diff", "--name-only", "--diff-filter=U"))[1]:
            self.block("--continue with unresolved conflicts")
        if not _nonempty(self.TMP + "/resolve.parents"):
            self.block("--continue without a conflict handed over by deploy.sh")
        with open(self.TMP + "/resolve.parents", "rb") as f:
            parents = _t(f.read()).split("\n")
        p1 = parents[0].strip(" \t")
        p2 = parents[1].strip(" \t") if len(parents) > 1 else ""
        if not (_cap(self.g("rev-parse", "-q", "--verify", "HEAD^1"))[1] == p1
                and _cap(self.g("rev-parse", "-q", "--verify", "HEAD^2"))[1] == p2):
            self.block("--continue: HEAD is not the merge of %s and %s" % (p1, p2))
        if p1 != self.HEAD_SHA:
            self.block("--continue: the PR head moved since the conflicts were handed over")
        # a file both sides changed that git merged on its own differs from both parents too: compare it with git's own merge
        auto = _lines(_cap(self.g("merge-tree", "--write-tree", p1, p2))[1] + "\n")
        auto = auto[0] if auto else ""
        ours = set(_lines(_cap(self.g("diff", "--name-only", "HEAD^1", "HEAD"))[1] + "\n"))
        theirs = set(_lines(_cap(self.g("diff", "--name-only", "HEAD^2", "HEAD"))[1] + "\n"))
        try:
            with open(self.TMP + "/resolve.files", "rb") as f:
                handed = set(_lines(_t(f.read())))
            both = sorted(ours & theirs)
        except OSError:  # grep -f without its file prints nothing
            print("grep: %s/resolve.files: No such file or directory" % self.TMP, file=sys.stderr)
            both = []
        extra = []
        for f in both:
            if f in handed:
                continue
            if _cap(self.g("rev-parse", "-q", "--verify", "HEAD:" + f))[1] != _cap(self.g("rev-parse", "-q", "--verify", auto + ":" + f))[1]:
                extra.append(f)
        extra = " ".join(" ".join(extra).split())
        if extra:
            self.block("--continue: the resolution changed files that did not conflict: " + extra)
        _rm(self.TMP + "/resolve.parents")
        _rm(self.TMP + "/resolve.files")

    def renumber_migrations(self):  # main took the version of a migration the card adds: the card's file moves above main's newest
        moved = False
        for layer, regex in self.migration_layers():
            existing = _t(_run(self.g("ls-tree", "-r", "--name-only", "origin/" + self.MAIN), out=PIPE)[1])
            added = _t(_run(self.g("diff", "--name-only", "--diff-filter=A", "origin/" + self.MAIN, "HEAD"), out=PIPE)[1])
            feed = "".join("E\t" + l + "\n" for l in _lines(self.grep_lines(regex, existing)))
            feed += "".join("N\t" + l + "\n" for l in _lines(self.grep_lines(regex, added)))
            c = project.cfg("migration-renumber", layer, input=feed.encode("utf-8", "surrogateescape"))
            _flush()
            sys.stderr.buffer.write(c.stderr)
            sys.stderr.buffer.flush()
            out = _t(c.stdout)
            for line in out.split("\n")[:-1]:  # while read: a last line without its newline is not read
                old, new = _read_tab(line, 2)
                if not new or _run(self.g("mv", old, new))[0] != 0:
                    continue
                moved = True
                self.say("migration %s renumbered to %s: %s took its version" % (old, new, self.MAIN))
        if moved:
            _run(self.g("commit", "-qm", "chore(migration): renumber above %s's newest" % self.MAIN, "-m", TRAILER))

    def qa_commit(self):
        return _cap(["bash", self.GATE, "-C", self.WT, "qa-commit", self.n], err=DEVNULL)[1]

    def hand_fix(self, msg):  # red on top of main, with the findings in <tmp>/fix.findings: an agent gets two rounds before Coding
        rnd = _read(self.TMP + "/fix.round")
        rnd = _int(rnd if rnd is not None else "0")
        if self.mode == "--refresh" or rnd >= 2:
            self.back_to_coding(msg)
        _write(self.TMP + "/fix.round", "%d\n" % (rnd + 1))
        with open(self.TMP + "/fix.parent", "wb") as f:
            _run(self.g("rev-parse", "HEAD"), out=f)
        self.say("fix round %d of 2: %s" % (rnd + 1, msg))
        self.say("fix what %s/fix.findings shows, commit, then run: deploy.sh %s --continue" % (self.TMP, self.n))
        self.handed_over()

    def check_fix(self):  # --continue after a fix round: a small fix ships, a larger one waits for the owner
        parent = _read(self.TMP + "/fix.parent") or ""
        _rm(self.TMP + "/fix.parent")
        if _run(self.g("rev-parse", "-q", "--verify", "MERGE_HEAD"), out=DEVNULL)[0] == 0:
            self.block("--continue with a merge in progress")
        if _cap(self.g("status", "--porcelain"))[1]:
            self.back_to_coding("the fix round left uncommitted changes")
        sha = _cap(self.g("rev-parse", "HEAD"))[1]
        if not (sha != parent and _run(self.g("merge-base", "--is-ancestor", parent, "HEAD"))[0] == 0
                and not _cap(self.g("rev-list", "--merges", "%s..HEAD" % parent))[1]):
            self.back_to_coding("the fix round fixed nothing: " + _tr(_tail(self.TMP + "/fix.findings", 5) or ""))
        files = _cap(self.g("diff", "--name-only", parent, "HEAD"))[1]
        nfiles = _count(files + "\n")
        numstat = _t(_run(self.g("diff", "--numstat", parent, "HEAD"), out=PIPE)[1])
        lines = 0
        for l in _lines(numstat):
            f = _fields(l) + ["", ""]
            lines += sum(int(m.group(0)) if m else 0 for m in (re.match(r"[0-9]+", x) for x in f[:2]))
        accept = ""
        qa = self.qa_commit()
        if qa:
            wanted = set((files + "\n").split("\n")[:-1])
            shown = _t(_run(self.g("show", "--name-only", "--format=", qa), out=PIPE)[1])
            accept = "".join(l + " " for l in _lines(shown) if l in wanted)
        if nfiles <= _int(self.FIX_FILES) and lines <= _int(self.FIX_LINES) and not accept:
            self.say("small fix (%d files, %d lines): it ships with the approved head" % (nfiles, lines))
            return
        # more than the owner approved: gates, then back to Staged with the fix as the new head to approve
        if self.fast_gates() != 0:
            self.back_to_coding("gates failed after the fix: " + _tr(_tail(self.TMP + "/gates.txt", 5) or ""))
        if _run(self.g("push", "-q", "--force-with-lease=%s:%s" % (self.BRANCH, self.HEAD_SHA), "origin",
                       "HEAD:" + self.BRANCH))[0] != 0:
            self.block("push of %s failed (the branch moved?)" % sha)
        self.comment(("Back to Staged: the deploy merged %s and an agent fixed what broke (%s). The fix is %d files and %d"
                      " lines%s: more than deploy.fix_max_files=%s / fix_max_lines=%s let through without you. Review the"
                      " diff %s..%s and approve again.\nstaged-head: %s")
                     % (self.MAIN, _tr(_tail(self.TMP + "/fix.findings", 3) or ""), nfiles, lines,
                        ", with acceptance tests (%s)" % accept if accept else "", self.FIX_FILES, self.FIX_LINES,
                        parent, sha, sha))
        if _run(self.board("move", self.n, "Staged"), out=DEVNULL)[0] != 0:
            self.say("could not move the card to Staged")
            raise DeployExit(2)
        self.say("back to Staged: a fix of %d files, %d lines%s needs the owner"
                 % (nfiles, lines, ", acceptance tests" if accept else ""))
        raise DeployExit(4)

    def ci_findings(self, sha):  # the red checks and the end of each failed run's log
        out = ["checks on %s: %s\n" % (sha, self.CI_STATES)]
        if self.LOCAL_CI:
            out.append("deploy.local_ci: %s\n" % self.LOCAL_CI)
            out.append(_tail(self.TMP + "/local-ci.txt", 150) or "")
            return "".join(out)
        ids = _t(_run(self.gh("run", "list", "--repo", self.REPO, "--commit", sha, "--json", "databaseId,conclusion",
                              "--jq", '.[] | select(.conclusion == "failure") | .databaseId'), out=PIPE, err=DEVNULL)[1])
        for i in ids.split():
            if re.fullmatch(r"[0-9]+", i):
                log = _t(_run(self.gh("run", "view", i, "--repo", self.REPO, "--log-failed"), out=PIPE, err=DEVNULL)[1])
                out.append(_tail_text(log, 150))
        return "".join(out)

    def fast_gates(self):  # deterministic checks only: CI runs build and tests on this exact head
        mb = _cap(self.g("merge-base", "HEAD", "origin/" + self.MAIN))[1]
        with open(self.TMP + "/gates.txt", "wb") as f:
            if self.BRANCH.startswith("revert/"):  # a revert removes what the card added: only the forbidden paths apply
                return _run(["bash", self.GATE, "-C", self.WT, "forbidden", mb], out=f, err=STDOUT)[0]
            _flush()
            spec = project.card_spec(self.n, self.SPECS)
            qa = self.qa_commit()
            return _run(["bash", self.GATE, "-C", self.WT, "fast", mb, spec or "/dev/null", *qa.split()],
                        out=f, err=STDOUT)[0]

    def local_ci(self, sha):  # deploy.local_ci run in the card's worktree on this head: 0 green, 1 red (CI_STATES), 2 timed out
        # For a project with no CI on GitHub, or none it can pay for: the head merged with main is still tested before it ships.
        self.say("local CI on " + sha)
        with open(self.TMP + "/local-ci.txt", "wb") as f:
            if os.path.isdir(self.WT):
                rc = _bounded(_int(self.TIMEOUT_MIN) * 60, ["bash", "-c", self.LOCAL_CI], self.WT, f)
            else:
                f.write(("bash: cd: %s: No such file or directory\n" % self.WT).encode("utf-8", "surrogateescape"))
                rc = 1
        if rc == 0:
            self.say("local CI passed on " + sha)
            return 0
        if rc == 124:
            self.say("local CI did not finish on %s in %s min" % (sha, self.TIMEOUT_MIN))
            return 2
        self.CI_STATES = "local-ci=FAILURE"
        self.say("local CI failed on %s (exit %d)" % (sha, rc))
        return 1

    def wait_checks(self, sha):  # 0 green, 1 red (CI_STATES), 2 timed out
        empty = settle = 0
        states = ""
        for _ in range(self.polls(1800)):
            out = _cap(self.gh("pr", "view", self.PR, "--repo", self.REPO, "--json", "headRefOid,statusCheckRollup",
                               "--jq", CHECKS_JQ), err=DEVNULL)[1]
            head, sep, states = out.partition(" ")
            if not sep:
                states = ""
            if head == sha:
                if not states:
                    empty += 1
                    if empty >= 10 and self.ALLOW_NO_CHECKS == "true":
                        self.say("no checks reported for %s (allowed)" % sha)
                        return 0
                elif self.grep_q("=(FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE|STALE)", states,
                                 ignore_case=True):
                    self.say("checks failed on %s: %s" % (sha, states))
                    self.CI_STATES = states
                    return 1
                elif not self.grep_q("=(SUCCESS|NEUTRAL|SKIPPED)$", states.replace(",", "\n"), ignore_case=True,
                                     invert=True):
                    missing = ""
                    for req in self.REQUIRED.split("\n"):
                        if req and (",%s=" % req) not in (",%s," % states):
                            missing += " " + req
                    settle += 1  # late workflows register after the first ones finish: see green twice
                    if not missing and settle >= 2:
                        return 0
            self.sleep(self.POLL)
        self.say("checks did not finish (last: %s)" % (states or "none"))
        return 2

    def push_recorded(self, sha):  # record this script's commits before pushing them: an unrecorded push wedges the card
        # every commit since the PR head: the merge of main (deploy-merge), a renumbered migration or a small fix (deploy-fix)
        if _cap(self.board("status", self.n))[1] != self.status:
            self.retry_later("the card moved meanwhile")
        lines = ""
        for c in _cap(self.g("rev-list", "--first-parent", "--reverse", "%s..%s" % (self.HEAD_SHA, sha)))[1].split():
            if _run(self.g("rev-parse", "-q", "--verify", c + "^2"), out=DEVNULL)[0] == 0:
                lines += "deploy-merge: %s %s\n" % (c, _cap(self.g("rev-parse", c + "^2"))[1])
            else:
                lines += "deploy-fix: %s\n" % c
            self.RECORDED += "\n" + c
        if not self.comment(lines[:-1] if lines.endswith("\n") else lines):
            self.retry_later("cannot record the merge")
        if _run(self.g("push", "-q", "--force-with-lease=%s:%s" % (self.BRANCH, self.HEAD_SHA), "origin",
                       "HEAD:" + self.BRANCH))[0] != 0:
            self.block("push of %s failed (the branch moved?)" % sha)
        self.HEAD_SHA = sha
        self.say("merged main into the PR: " + sha)

    def update_and_merge(self):
        # 4-8. up to date with main, fast gates, pushed, green
        merged = False
        if self.mode == "--continue":
            if _nonempty(self.TMP + "/fix.parent"):
                self.check_fix()
            else:
                self.check_resolution()
            merged = True
        sha = ""
        for attempt in (1, 2, 3):
            if self.mode != "--continue" or attempt > 1:
                rc = self.merge_main()
                if rc == 1:
                    merged = True
                elif rc == 3:
                    if self.mode == "--refresh":
                        self.reset_worktree()
                        self.say("conflicts with main; left for the deploy")
                        raise DeployExit(0)
                    for f in self.CONFLICTS.split("\n"):
                        sys.stdout.write("CONFLICT %s\n" % f)
                    self.say("resolve these conflicts, commit, then run: deploy.sh %s --continue" % self.n)
                    self.handed_over()
                elif rc == 4:
                    self.back_to_coding(self.REASON)
            if merged:
                self.renumber_migrations()
            if self.fast_gates() != 0:
                if not merged:
                    self.block("gates failed: " + _tr(_tail(self.TMP + "/gates.txt", 5) or ""))
                shutil.copyfile(self.TMP + "/gates.txt", self.TMP + "/fix.findings")
                self.hand_fix("gates failed after merging main: " + _tr(_tail(self.TMP + "/gates.txt", 5) or ""))
            sha = _cap(self.g("rev-parse", "HEAD"))[1]
            if sha != self.HEAD_SHA:
                self.push_recorded(sha)
            if self.mode == "--refresh":
                self.say("up to date with main")
                raise DeployExit(0)
            rc = self.local_ci(sha) if self.LOCAL_CI else self.wait_checks(sha)
            if rc != 0:
                if not merged:
                    self.block("CI failed on the PR (%s)" % sha)
                if rc != 1:
                    self.back_to_coding("CI did not finish on the PR after merging main (%s)" % sha)
                findings = self.ci_findings(sha)
                with open(self.TMP + "/fix.findings", "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
                    f.write(findings)
                self.hand_fix("CI failed on the PR after merging main (%s)" % sha)
            if _run(self.g("fetch", "-q", "origin"))[0] != 0:
                self.retry_later("fetch failed")
            if _run(self.g("merge-base", "--is-ancestor", "origin/" + self.MAIN, "HEAD"))[0] == 0:
                break
            self.say("main moved while waiting for CI; updating again")
            if attempt == 3:
                self.block("main kept moving; three updates in a row")
            self.mode = "deploy"

        # 9. merge
        with open(self.TMP + "/merge-pr.txt", "wb") as f:
            rc = _run(self.gh("pr", "merge", self.PR, "--repo", self.REPO, "--squash", "--match-head-commit", sha),
                      out=f, err=STDOUT)[0]
        if rc != 0:
            state = _cap(self.gh("pr", "view", self.PR, "--repo", self.REPO, "--json", "state", "--jq", ".state"),
                         err=DEVNULL)[1]
            if state != "MERGED":
                self.block("gh pr merge failed: " + _tr(_tail(self.TMP + "/merge-pr.txt", 3) or ""))
        self.MERGED = ""
        for _ in range(10):
            self.MERGED = _cap(self.gh("pr", "view", self.PR, "--repo", self.REPO, "--json", "mergeCommit", "--jq",
                                       '.mergeCommit.oid // ""'), err=DEVNULL)[1]
            if _sha(self.MERGED):
                break
            self.sleep(self.POLL)
        if not _sha(self.MERGED):
            self.retry_later("PR #%s merged but its merge commit is not known yet" % self.PR)
        self.say("merged as " + self.MERGED)

    def production(self):
        # 10. production
        # A card merged by an earlier run is judged by main as it is now: its own merge commit may carry a
        # run that failed for a reason main has since fixed, and that run never turns green.
        check = self.MERGED
        if self.RESUMED == 1:
            check = _cap(self.r("rev-parse", "origin/" + self.MAIN))[1]
        failure = deploy_url = faillog = ""
        main = self.MAIN
        if self.CI_WORKFLOW:
            run = ""
            for _ in range(10):
                run = _cap(self.gh("run", "list", "--repo", self.REPO, "--branch", main, "--commit", check, "--workflow",
                                   self.CI_WORKFLOW, "--json", "databaseId", "--jq", ".[0].databaseId"), err=DEVNULL)[1]
                if run:
                    break
                self.sleep(self.POLL)
            if not run:
                failure = "no '%s' run on %s for %s" % (self.CI_WORKFLOW, main, check)
            else:
                reran = False
                concl = ""
                view = self.gh("run", "view", run, "--repo", self.REPO, "--json", "status,conclusion", "--jq", RUN_JQ)
                for _ in range(self.polls(_int(self.TIMEOUT_MIN) * 60)):
                    concl = _cap(view, err=DEVNULL)[1]
                    if concl == "completed success":
                        break
                    if concl.startswith("completed"):  # a runner or the network may have failed, not the code: one more try
                        why = concl[len("completed "):] if concl.startswith("completed ") else concl
                        if not reran and _run(self.gh("run", "rerun", run, "--repo", self.REPO, "--failed"),
                                              out=DEVNULL, err=DEVNULL)[0] == 0:
                            reran = True
                            self.say("CI on %s failed (run %s: %s); running its failed jobs once more" % (main, run, why))
                            for _ in range(6):  # until GitHub shows the rerun as started
                                self.sleep(self.POLL)
                                if _cap(view, err=DEVNULL)[1] != concl:
                                    break
                            continue
                        failure = "CI on %s failed (run %s: %s)" % (main, run, why)
                        log = _run(self.gh("run", "view", run, "--repo", self.REPO, "--log-failed"), out=PIPE,
                                   err=DEVNULL)[1]
                        tail = _tail_text(_t(log), 30).encode("utf-8", "surrogateescape")
                        cut = b"".join(l[:300] + b"\n" for l in tail.split(b"\n")[:-1])
                        if not tail.endswith(b"\n") and tail:
                            cut += tail.split(b"\n")[-1][:300] + b"\n"
                        faillog = _t(cut).rstrip("\n")
                        break
                    self.sleep(self.POLL)
                if not failure and concl != "completed success":
                    failure = "CI on %s did not finish (run %s)" % (main, run)
        if not failure and self.ENVIRONMENT:
            state = ""
            for _ in range(self.polls(_int(self.TIMEOUT_MIN) * 60)):
                d = _cap(self.gh("api", "repos/%s/deployments?sha=%s" % (self.REPO, check), "--jq",
                                 '[.[] | select(.environment == "%s")][0].id' % self.ENVIRONMENT), err=DEVNULL)[1]
                if d and d != "null":
                    statuses = "repos/%s/deployments/%s/statuses" % (self.REPO, d)
                    state = _cap(self.gh("api", statuses, "--jq", ".[0].state"), err=DEVNULL)[1]
                    if state == "success":
                        deploy_url = _cap(self.gh("api", statuses, "--jq", '.[0].environment_url // ""'), err=DEVNULL)[1]
                        break
                    if state == "inactive":
                        self.say("deployment %s superseded by a newer one" % d)
                        break
                    if state in ("failure", "error"):
                        break
                self.sleep(self.POLL)
            if state not in ("success", "inactive"):
                failure = "deployment to '%s' ended '%s'" % (self.ENVIRONMENT, state or "timeout")
        if not failure and self.HEALTH:
            for url in self.HEALTH.split("\n"):
                if not url:
                    continue
                ok = False
                for _ in range(5):
                    if _run(proc.script_argv(self.CURL, "-fsS", "-o", os.devnull, "-m", "10", url),
                            out=DEVNULL, err=DEVNULL)[0] == 0:
                        ok = True
                        break
                    self.sleep(self.POLL // 2)
                if not ok:
                    failure = "health check failed: " + url
                    break

        if failure:
            self.revert(failure, faillog)

        # 11. done
        if _run(self.board("move", self.n, "Done"), out=DEVNULL)[0] != 0:
            self.say("could not move the card to Done")
        mins = (int(time.time()) - self.START) // 60
        self.comment("Deployed: merge %s%s · %d min from the start of this deploy run."
                     % (self.MERGED, " · " + deploy_url if deploy_url else "", mins))
        _run(self.r("worktree", "remove", "--force", self.WT), out=DEVNULL, err=DEVNULL)
        self.say("done in %d min" % mins)
        raise DeployExit(0)

    def revert(self, failure, faillog):  # revert, reopen, block
        n = self.n
        rw = "%s/revert-%s" % (_env("FACTORY_WT_ROOT"), n)
        rpr = ""
        _run(self.r("worktree", "remove", "--force", rw), out=DEVNULL, err=DEVNULL)
        rv = ["git", "-C", rw]
        if (_run(self.r("fetch", "-q", "origin"))[0] == 0
                and _run(self.r("worktree", "add", "-q", "--detach", rw, "origin/" + self.MAIN))[0] == 0
                and _run(rv + ["revert", "--no-commit", self.MERGED])[0] == 0
                and _run(rv + ["commit", "-qm", "revert: #%s after a failed production deploy" % n, "-m", TRAILER])[0] == 0
                and _run(rv + ["push", "-q", "origin", "HEAD:refs/heads/revert/%s" % n])[0] == 0):
            rhead = _cap(rv + ["rev-parse", "HEAD"])[1]
            rc, out = _run(self.gh("pr", "create", "--repo", self.REPO, "--base", self.MAIN, "--head", "revert/" + n,
                                   "--title", "revert: #" + n, "--body",
                                   "Reverts the merge of #%s (%s) after a failed production deploy: %s. Refs #%s."
                                   % (n, self.MERGED, failure, n)), out=PIPE, err=DEVNULL)
            rpr = _tail_text(_t(out), 1).rstrip("\n")
            if rc != 0:
                rpr = "(revert branch revert/%s pushed; opening its PR failed)" % n
            _run(self.r("worktree", "remove", "--force", rw), out=DEVNULL, err=DEVNULL)
            self.comment("Production deploy failed: %s. Revert PR: %s%s\nstaged-head: %s"
                         % (failure, rpr, "\nThe end of the log of the failed run:\n" + faillog if faillog else "", rhead))
        else:
            self.comment("Production deploy failed: %s. The revert could not be prepared automatically: revert %s by hand."
                         % (failure, self.MERGED))
        _run(self.gh("issue", "reopen", n, "--repo", self.REPO), out=DEVNULL, err=DEVNULL)
        if _run(self.gh("issue", "edit", n, "--repo", self.REPO, "--add-label", "blocked"), out=DEVNULL)[0] != 0:
            self.say("could not label #%s blocked" % n)
        self.say("failed after merge: %s; revert %s" % (failure, rpr or "not prepared"))
        raise DeployExit(6)


def main(argv):
    try:
        return Deploy().run(argv)
    except DeployExit as e:
        return e.code
    finally:
        _flush()
