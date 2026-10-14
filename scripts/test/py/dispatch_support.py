"""Helpers for the dispatch suites (dispatch_*.py): a project home, a fake board, claude and deploy.sh, and one
dispatcher cycle run in this process.

A cycle is shipfloor_core.dispatch.main() called here, with stdout and stderr (the file descriptors, so what a child
process prints is caught too) going to files the test reads. The runs it launches are not detached: _detach records
each spec, and after the cycle returns the test runs them with dispatch.supervise() in this process, in launch order
(the cycle never waits on a run, so this is the order the real runs could take). The project and machine configs are
asked in this process too (shipfloor_config.run, the code `shipfloor-config.sh` runs); the wrappers, the detached
process and the real subprocess wiring are dispatch-cli.test.sh's and dispatch-process.test.sh's.
"""
import contextlib
import glob
import io
import json
import os
import stat
import subprocess
import sys
import time
from unittest import mock

import support
from shipfloor_core import dispatch, project

FIXTURE_CONFIG = os.path.join(support.FIXTURE, "factory.yml")
GIT_ENV = {"GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "init.defaultBranch", "GIT_CONFIG_VALUE_0": "main",
           "GIT_CONFIG_KEY_1": "maintenance.auto", "GIT_CONFIG_VALUE_1": "false", "GIT_CONFIG_KEY_2": "gc.auto", "GIT_CONFIG_VALUE_2": "0",
           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
POOL8 = "pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}"
ISO = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}"


def config_in_process(argv):
    """shipfloor_config.py <argv> run here: a CompletedProcess with its exit code, stdout and stderr as bytes."""
    import shipfloor_config
    out, err = io.BytesIO(), io.BytesIO()
    saved = sys.stdout, sys.stderr
    wo = io.TextIOWrapper(out, encoding="utf-8", newline="\n", write_through=True)
    we = io.TextIOWrapper(err, encoding="utf-8", newline="\n", write_through=True)
    sys.stdout, sys.stderr = wo, we
    try:
        rc = shipfloor_config.run(list(argv))
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 2
    finally:
        sys.stdout, sys.stderr = saved
        wo.flush()
        we.flush()
        wo.detach()
        we.detach()
    return subprocess.CompletedProcess(argv, rc, out.getvalue(), err.getvalue())


def fast_cfg(*query, input=None):
    if input is not None:
        raise AssertionError("fast_cfg: no stdin in process")
    e = os.environ
    return config_in_process(["--config", e.get("FACTORY_CONFIG", ""), "--home", e.get("FACTORY_HOME", ""),
                              "--worktrees", e.get("FACTORY_WT_ROOT", ""), *query])


def fast_machine(*args):
    saved = os.environ.get("SHIPFLOOR_MACHINE_CONFIG")
    os.environ["SHIPFLOOR_MACHINE_CONFIG"] = os.path.join(project.shipfloor_home(), "config.yml")
    try:
        return config_in_process(["machine", *args])
    finally:
        if saved is None:
            os.environ.pop("SHIPFLOOR_MACHINE_CONFIG", None)
        else:
            os.environ["SHIPFLOOR_MACHINE_CONFIG"] = saved


# The board: answers from files under <tmp>/board (eligible/<column>, count/<first column>, snapshot, infra,
# fail/<cmd> [<arg>] = the stderr of a failing call); every call is a line of <tmp>/board/calls. A shell script: a cycle
# asks the board a dozen times.
BOARD = r'''#!/bin/sh
d="%s"
echo "$*" >> "$d/calls"
key="$1"; [ $# -gt 1 ] && key="$1 $2"
if [ -f "$d/fail/$key" ]; then cat "$d/fail/$key" >&2; exit 1; fi
case "$1" in
  snapshot) [ ! -f "$d/snapshot" ] || cat "$d/snapshot" ;;
  eligible) [ ! -f "$d/eligible/$2" ] || cat "$d/eligible/$2" ;;
  count) if [ -f "$d/count/$2" ]; then cat "$d/count/$2"; else echo 0; fi ;;
  infra) [ ! -f "$d/infra" ] || cat "$d/infra" ;;
  label) [ ! -f "$d/fail/label" ] || exit 1 ;;
esac
exit 0
'''

# claude: one JSON line per call in <tmp>/claude.calls (argv, stdin, cwd, PWD, env, parent pid, where its own temp file
# went); then what <tmp>/fake.json's "claude" says (per card under "cards"): print, write a gate verdict to the run's
# lock, hand the lock to another owner, take a stack slot, leave files in tmp/<n>/, exit with a code.
CLAUDE = r'''
import json, os, sys, tempfile, time
fake = json.load(open(%(fake)r)) if os.path.exists(%(fake)r) else {}
stdin = sys.stdin.read()
n = stdin.split()[-1] if stdin.split() else ""
c = dict(fake.get("claude", {}))
c.update(c.pop("cards", {}).get(n, {}))
lock = os.environ.get("SHIPFLOOR_RUN_LOCK", "")
fd, tmpfile = tempfile.mkstemp()
os.close(fd)
rec = {"argv": sys.argv[1:], "stdin": stdin, "cwd": os.getcwd(), "pwd": os.environ.get("PWD"), "env": dict(os.environ),
       "ppid": os.getppid(), "tmpfile": tmpfile, "tmpdir_is_dir": os.path.isdir(os.environ.get("TMPDIR", "/nonexistent"))}
with open(%(calls)r, "a") as f:
    f.write(json.dumps(rec) + "\n")
print(c.get("say", "claude says hi"), flush=True)
if c.get("verdict"):
    open(os.path.join(lock, "last-gate"), "w").write("%%s\t%%s\n" %% (c.get("gate", "build"), c["verdict"]))
if c.get("steal_lock"):
    open(os.path.join(lock, "info"), "w").write("99999 %%d 30\n" %% time.time())
if c.get("stack_slot"):
    s = os.path.join(os.environ["SHIPFLOOR_HOME"], "locks", "stack-0.lock")
    os.makedirs(s, exist_ok=True)
    open(os.path.join(s, "info"), "w").write("develop-%%s %%s %%d\n" %% (n, lock, time.time()))
if c.get("scratch"):
    os.makedirs(os.path.join(os.environ["FACTORY_HOME"], "tmp", n, "scratch"), exist_ok=True)
sys.exit(c.get("exit", 0))
'''

# deploy.sh: one JSON line per call in <tmp>/deploy.calls (argv, cwd, env, the project's locks and their info); --refresh exits 0;
# the other calls exit with fake.json's "deploy_exits", one per call (the last one repeats; default 0).
DEPLOY = r'''
import json, os, sys
fake = json.load(open(%(fake)r)) if os.path.exists(%(fake)r) else {}
argv = sys.argv[1:]
locks = os.path.join(os.environ.get("FACTORY_HOME", ""), "locks")
rec = {"argv": argv, "cwd": os.getcwd(), "env": dict(os.environ),
       "locks": sorted(os.listdir(locks)) if os.path.isdir(locks) else []}
rec["infos"] = {l: open(os.path.join(locks, l, "info")).read() for l in rec["locks"]
                if os.path.isfile(os.path.join(locks, l, "info"))}
prev = [json.loads(l) for l in open(%(calls)r)] if os.path.exists(%(calls)r) else []
with open(%(calls)r, "a") as f:
    f.write(json.dumps(rec) + "\n")
if argv[1:2] == ["--refresh"]:
    print("refresh ran for %%s" %% argv[0])
    sys.exit(0)
i = len([p for p in prev if p["argv"][1:2] != ["--refresh"]])
codes = fake.get("deploy_exits") or [0]
print("deploy call %%d: %%s" %% (i + 1, " ".join(argv)))
sys.exit(codes[min(i, len(codes) - 1)])
'''

# gh: the dispatcher's only gh call is the read of a candidate's "Blocked by" issues (#202). It answers from
# <tmp>/deps/<n> (the body, default []); <tmp>/deps/fail fails it. Every call is a JSON line (argv) of <tmp>/deps.calls.
GH = r'''
import json, os, sys
argv = sys.argv[1:]
d = %(dir)r
with open(%(calls)r, "a") as f:
    f.write(json.dumps(argv) + "\n")
path = argv[1].split("?")[0] if argv[:1] == ["api"] and len(argv) > 1 else ""
if path.endswith("/dependencies/blocked_by"):
    if os.path.exists(os.path.join(d, "fail")):
        sys.stderr.write("gh: HTTP 502\n")
        sys.exit(1)
    n = path.split("/")[-3]
    f = os.path.join(d, n)
    sys.stdout.write(open(f).read() if os.path.exists(f) else "[]")
'''


class DispatchCase(support.Case):
    """Project shop at <shome>/projects/shop with an (empty) control checkout, worktrees under <tmp>/wt, no machine
    config (the defaults: pool 4, stages 2/2/2/1), the fixture project config, and the fake board, claude and deploy."""

    def setUp(self):
        super().setUp()
        os.environ.update(GIT_ENV)
        self.shome = os.environ["SHIPFLOOR_HOME"]
        self.home = os.path.join(self.shome, "projects", "shop")
        os.environ.update({"FACTORY_HOME": self.home, "FACTORY_PROJECT": "shop", "FACTORY_CONTROL_REFRESH": "0",
                           "FACTORY_WT_ROOT": self.path("wt"), "FACTORY_CLEANUP": "0"})
        for d in ("control", "logs", "locks"):
            os.makedirs(os.path.join(self.home, d), exist_ok=True)
        self.addCleanup(os.chdir, os.getcwd())
        for target, name, new in ((project, "cfg", fast_cfg), (project, "machine", fast_machine),
                                  (dispatch, "_detach", self._record_spec),
                                  (dispatch, "_ignore_signals", lambda: None)):
            p = mock.patch.object(target, name, new)
            p.start()
            self.addCleanup(p.stop)
        self.fake = {}
        self.pending, self.launches = [], []
        bdir = self.path("board")
        os.environ["FACTORY_BOARD"] = self.script("board", BOARD % bdir, python=False)
        names = {"fake": os.path.join(self.tmp, "fake.json")}
        os.environ["FACTORY_CLAUDE"] = self.script("claude", CLAUDE % dict(names, calls=self.path("claude.calls")))
        # deploy.sh is run by bash (`bash <deploy> <n> ...`): a shell script that hands over to the Python one
        py = self.script("deploy.py", DEPLOY % dict(names, calls=self.path("deploy.calls")))
        os.environ["FACTORY_DEPLOY"] = self.script("deploy", 'exec "%s" "$@"\n' % py, python=False)
        os.environ["FACTORY_GH"] = self.script("gh", GH % {"dir": self.path("deps"), "calls": self.path("deps.calls")})

    # --- files and fakes
    def script(self, name, body, python=True):
        """An executable <tmp>/bin/<name>: a Python script (body without its shebang) or a shell script."""
        p = os.path.join(self.path("bin"), name)
        with open(p, "w") as f:
            f.write(("#!%s -I\n" % sys.executable if python else "") + body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        return p

    def machine_cfg(self, text=POOL8):
        """The machine config (<shome>/config.yml)."""
        self.write(os.path.join(self.shome, "config.yml"), text + "\n")

    def project_cfg(self, text=None, sed=None):
        """A copy of the fixture project config (text replaces it, sed = (old, new) edits it), used from now on."""
        body = text if text is not None else open(FIXTURE_CONFIG, encoding="utf-8").read()
        if sed:
            body = body.replace(*sed)
        p = self.write("cfg/factory.yml", body)
        os.environ["FACTORY_CONFIG"] = p
        return p

    def board(self, queues=None, counts=None, snapshot=None, infra=None, fail=None):
        """Set what the board answers. queues: {column: "26 27" or [26, 27]}; counts: {first column: n}; snapshot: the
        board.tsv text; infra: the cards blocked by infrastructure; fail: {"snapshot" | "eligible <column>" | "label":
        stderr text}. A part left None keeps what it was; a part given replaces it whole."""
        d = os.path.join(self.tmp, "board")
        for part, val in (("eligible", queues), ("count", counts), ("fail", fail)):
            if val is None:
                continue
            sub = os.path.join(d, part)
            for f in glob.glob(os.path.join(glob.escape(sub), "*")):
                os.unlink(f)
            os.makedirs(sub, exist_ok=True)
            for k, v in val.items():
                if isinstance(v, (list, tuple)):
                    v = "\n".join(str(x) for x in v)
                with open(os.path.join(sub, k), "w") as f:
                    f.write(str(v) + ("\n" if part != "fail" or v else ""))
        for name, val in (("snapshot", snapshot), ("infra", infra)):
            if val is not None:
                if isinstance(val, (list, tuple)):
                    val = "".join("%s\n" % x for x in val)
                with open(os.path.join(d, name), "w") as f:
                    f.write(val)

    def deps(self, n, body=None, fail=None):
        """What gh answers for card n's "Blocked by" read: body (a list is dumped as JSON, a str is the raw body);
        fail True/False makes every read fail or answer again."""
        d = self.path("deps")
        if body is not None:
            with open(os.path.join(d, str(n)), "w") as f:
                f.write(body if isinstance(body, str) else json.dumps(body))
        if fail is not None:
            f = os.path.join(d, "fail")
            if fail:
                open(f, "w").close()
            elif os.path.exists(f):
                os.unlink(f)

    def deps_calls(self):
        """The argv of every gh call, in order."""
        return self._records("deps")

    def deps_record(self):
        """<home>/deps.json, the dispatcher's record of the dependencies it read."""
        with open(os.path.join(self.home, "deps.json"), encoding="utf-8") as f:
            return json.load(f)

    def board_calls(self):
        p = os.path.join(self.tmp, "board", "calls")
        return open(p).read().splitlines() if os.path.exists(p) else []

    def set_fake(self, **kw):
        self.fake.update(kw)
        with open(os.path.join(self.tmp, "fake.json"), "w") as f:
            json.dump(self.fake, f)

    def _records(self, name):
        p = os.path.join(self.tmp, name + ".calls")
        return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

    def claude_calls(self):
        return self._records("claude")

    def deploy_calls(self):
        return self._records("deploy")

    def prompts(self):
        """The prompts the runs' agents got, in order."""
        return [c["stdin"] for c in self.claude_calls()]

    def lock(self, name, info=None, age=None, project_home=None):
        """A run lock <home>/locks/<name>.lock; info: its info line (None: a live one of this process, "-": none);
        age: seconds back for the dir's mtime."""
        d = os.path.join(project_home or self.home, "locks", name + ".lock")
        os.makedirs(d, exist_ok=True)
        if info != "-":
            with open(os.path.join(d, "info"), "w") as f:
                f.write((info if info is not None else "%d %d %s" % (os.getpid(), time.time(), name.rsplit("-", 1)[1]))
                        + "\n")
        if age is not None:
            t = time.time() - age
            os.utime(d, (t, t))
        return d

    def log(self, p, n):
        """Card n's log of pipeline p (every date)."""
        return "".join(open(f, encoding="utf-8").read()
                       for f in sorted(glob.glob(os.path.join(glob.escape(self.home), "logs", "*-%s-%s.log" % (n, p)))))

    def usage_log(self, age=0, name="x-5-develop.log", text=None, home=None):
        """A run log that ended on the Claude usage limit, <age> seconds old."""
        p = os.path.join(home or self.home, "logs", name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text if text is not None else "== start /sf:develop 5\nYou've hit your session limit · resets 6pm\n")
        if age:
            t = time.time() - age
            os.utime(p, (t, t))
        return p

    def git(self, *args, cwd=None):
        r = subprocess.run(["git", *args], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            raise AssertionError("git %s: %s" % (" ".join(args), r.stderr))
        return r.stdout.strip()

    def card(self, n, weight=None, header=None):
        """Card n's worktree on feat/<n>-thing; its spec's header names the weight (header: the whole header line,
        "" for none); weight "-" = no spec at all."""
        wt = os.path.join(os.environ["FACTORY_WT_ROOT"], str(n))
        self.git("init", "-q", "-b", "feat/%s-thing" % n, wt)
        if weight != "-":
            line = header if header is not None else "**Weight:** %s" % weight
            self.write(os.path.join(wt, "docs/superpowers/specs/2026-10-12-thing-design.md"),
                       "# Thing — spec\n\n**Issue:** #%s\n**Roles:** PO, Tech Lead\n%s\n\n## Product\n- **AC-1** — x\n\n"
                       "## Decisions\n- **Weight:** heavy\n" % (n, line))
        self.git("-C", wt, "add", "-A")
        self.git("-C", wt, "commit", "-q", "--allow-empty", "-m", "base")
        return wt

    # --- the cycle
    def _record_spec(self, spec):
        self.launches.append(dict(spec, lock_at_launch=os.path.isdir(spec["dir"]),
                                  info_at_launch=os.path.exists(os.path.join(spec["dir"], "info"))))
        self.pending.append(spec)

    @contextlib.contextmanager
    def captured(self):
        """stdout and stderr (the descriptors) into self.out / self.err."""
        io_dir = self.path("io")
        sys.stdout.flush()
        sys.stderr.flush()
        saved = os.dup(1), os.dup(2)
        with open(os.path.join(io_dir, "out"), "w+b") as o, open(os.path.join(io_dir, "err"), "w+b") as e:
            os.dup2(o.fileno(), 1)
            os.dup2(e.fileno(), 2)
            try:
                yield
            finally:
                sys.stdout.flush()
                sys.stderr.flush()
                os.dup2(saved[0], 1)
                os.dup2(saved[1], 2)
                os.close(saved[0])
                os.close(saved[1])
                o.seek(0)
                e.seek(0)
                self.out = o.read().decode("utf-8", "replace")
                self.err = e.read().decode("utf-8", "replace")

    def cycle(self, runs=True):
        """One dispatcher cycle; then (runs) every run it launched, in this process. self.rc, self.out, self.err."""
        with self.captured():
            self.rc = dispatch.main([])
            if runs:
                self._run_pending()
        return self.rc

    def run_pending(self):
        """Run what earlier cycles launched (cycle(runs=False)); their output is in self.out / self.err."""
        with self.captured():
            self._run_pending()

    def _run_pending(self):
        while self.pending:
            spec = self.pending.pop(0)
            here = os.getcwd()
            try:
                dispatch.supervise(spec)
            finally:
                os.chdir(here)
