"""Helpers for the gate suites (gate_*.py): a gate called in this process as gate.sh would run it, temp git repos
where git is the behavior, the fixture config with edits, and runner doubles (the layers' mvn/pnpm) as tiny scripts."""
import io
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

import support
from shipfloor_core.gate import main as gate_main

FIX = os.path.join(support.FIXTURE, "factory.yml")
M = "api/src/main/resources/db/migration"  # the fixture's api migrations
GIT_ENV = {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "4",
           "GIT_CONFIG_KEY_0": "init.defaultBranch", "GIT_CONFIG_VALUE_0": "main",
           "GIT_CONFIG_KEY_1": "user.email", "GIT_CONFIG_VALUE_1": "t@t",
           "GIT_CONFIG_KEY_2": "user.name", "GIT_CONFIG_VALUE_2": "t",
           "GIT_CONFIG_KEY_3": "core.autocrlf", "GIT_CONFIG_VALUE_3": "false"}


def quiet(fn, *args):
    """fn(*args) with its stdout and stderr (text or bytes) caught: (its return value, stdout bytes, stderr bytes)."""
    out, err = io.BytesIO(), io.BytesIO()
    real = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = (io.TextIOWrapper(b, encoding="utf-8", newline="\n") for b in (out, err))
    try:
        value = fn(*args)
        sys.stdout.flush()
        sys.stderr.flush()
        return value, out.getvalue(), err.getvalue()
    finally:
        sys.stdout, sys.stderr = real


class Result:
    """What a gate call left: exit code, stdout and stderr (text), and stderr's last line (the verdict)."""

    def __init__(self, code, out, err):
        self.code, self.out, self.err = code, out, err
        lines = err.rstrip("\n").split("\n")
        self.last = lines[-1] if err else ""

    def __repr__(self):
        return "exit %s, stdout %r, stderr %r" % (self.code, self.out[-600:], self.err[-600:])


def _restore_env(saved):
    os.environ.clear()
    os.environ.update(saved)


def config_here(*query, input=None):
    """project.cfg answered by shipfloor_config.run in this process: the same arguments, stdin, stdout, stderr and exit
    code as the `python -I shipfloor_config.py` it starts, without a Python start per query (a gate asks 2-6 times).
    The real process is what gate-cli.test.sh goes through."""
    import shipfloor_config
    argv = ["--config", os.environ.get("FACTORY_CONFIG", ""), "--home", os.environ.get("FACTORY_HOME", ""),
            "--worktrees", os.environ.get("FACTORY_WT_ROOT", ""), *query]
    out, err = io.BytesIO(), io.BytesIO()
    real = sys.stdin, sys.stdout, sys.stderr
    sys.stdin = io.TextIOWrapper(io.BytesIO(input or b""), encoding="utf-8")
    sys.stdout = io.TextIOWrapper(out, encoding="utf-8", newline="\n")
    sys.stderr = io.TextIOWrapper(err, encoding="utf-8", errors="backslashreplace")
    try:
        code = shipfloor_config.run(argv)
        sys.stdout.flush()
        sys.stderr.flush()
        return subprocess.CompletedProcess(argv, code, out.getvalue(), err.getvalue())
    finally:
        sys.stdin, sys.stdout, sys.stderr = real


class GateCase(support.Case):
    """A test in a scrubbed factory environment (support.Case) whose gate calls behave as separate gate.sh runs: each
    call gets the environment and cwd it was given, and fds 1 and 2 go to files, so the runners' and builds' own
    output lands in the gate's stdout/stderr as it would through the wrapper."""

    def setUp(self):
        super().setUp()
        os.environ.update(GIT_ENV)
        os.environ["SHIPFLOOR_GATE_FRESH"] = "1"  # as lib.sh: a gate called twice runs twice (the cache suite unsets it)
        os.environ["FACTORY_CLEANUP"] = "0"
        os.environ["TMPDIR"] = self.path("t")  # what the gates' children write goes inside this test's dir
        for k in ("NO_COLOR", "FORCE_COLOR", "SHIPFLOOR_PY", "SHIPFLOOR_RUN_LOCK", "GIT_DIR", "GIT_WORK_TREE"):
            os.environ.pop(k, None)
        os.environ["PATH"] = self.path("bin") + os.pathsep + os.environ.get("PATH", "")
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        if not self.real_config:
            from unittest import mock
            from shipfloor_core import project
            p = mock.patch.object(project, "cfg", config_here)
            p.start()
            self.addCleanup(p.stop)

    real_config = False  # True: the config queries start shipfloor_config.py as the product does

    # ---- the gate, in process

    def gate(self, *argv, **env):
        """gate.sh <argv> with env changes (None unsets) in the current directory; a Result."""
        saved, cwd = dict(os.environ), os.getcwd()
        for k, v in env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        sigs = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
        out_f, err_f = tempfile.TemporaryFile(dir=self.tmp), tempfile.TemporaryFile(dir=self.tmp)
        sys.stdout.flush()
        sys.stderr.flush()
        real = sys.stdout, sys.stderr
        fd1, fd2 = os.dup(1), os.dup(2)
        try:
            os.dup2(out_f.fileno(), 1)
            os.dup2(err_f.fileno(), 2)
            sys.stdout, sys.stderr = (io.TextIOWrapper(io.BufferedWriter(io.FileIO(fd, "w", closefd=False)),
                                                       encoding="utf-8", newline="\n") for fd in (1, 2))
            try:
                code = gate_main(list(argv))
            finally:
                sys.stdout.flush()
                sys.stderr.flush()
        finally:
            sys.stdout, sys.stderr = real
            os.dup2(fd1, 1)
            os.dup2(fd2, 2)
            os.close(fd1)
            os.close(fd2)
            _restore_env(saved)
            os.chdir(cwd)
            for s, h in sigs.items():
                signal.signal(s, h)
        data = []
        for f in (out_f, err_f):
            f.seek(0)
            data.append(f.read().decode("utf-8", "surrogateescape"))
            f.close()
        return Result(code, *data)

    def expect(self, want, *argv, **env):
        """The gate's Result, after asserting its exit code."""
        r = self.gate(*argv, **env)
        self.assertEqual(r.code, want, "gate %s: %r" % (" ".join(argv), r))
        return r

    def table(self, rows):
        """rows of (label, exit wanted, argv tuple[, text stderr must have]); every mismatch reported at once."""
        bad = []
        for row in rows:
            label, want, argv = row[:3]
            r = self.gate(*argv)
            if r.code != want or (len(row) > 3 and row[3] not in r.err):
                bad.append("%s: want exit %s%s, got %r" % (label, want, " with %r" % row[3] if len(row) > 3 else "", r))
        self.assertFalse(bad, "\n".join(bad))

    # ---- repos (git is the behavior here)

    _template = None

    @classmethod
    def _repo_template(cls):
        if GateCase._template is None or not os.path.isdir(GateCase._template):
            d = tempfile.mkdtemp(prefix="gate-template-")
            env = dict(os.environ, **GIT_ENV)
            for argv in (["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-qm", "base"]):
                if argv[0] == "add":
                    with open(os.path.join(d, "README.md"), "w") as f:
                        f.write("base\n")
                subprocess.run(["git", "-C", d, *argv], check=True, env=env, stdout=subprocess.DEVNULL)
            GateCase._template = d
            import atexit
            atexit.register(shutil.rmtree, d, True)
        return GateCase._template

    def repo(self, name=None):
        """A fresh repo with one commit (README.md) on main, private to this test; cwd moves into it."""
        d = os.path.join(self.tmp, "repos", name or "r%d" % len(os.listdir(self.path("repos"))))
        shutil.copytree(self._repo_template(), d)
        os.chdir(d)
        return d

    def git(self, *args, check=True):
        r = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and r.returncode != 0:
            raise AssertionError("git %s: %s" % (" ".join(args), r.stderr.decode("utf-8", "replace")))
        return r.stdout.decode("utf-8", "surrogateescape").strip()

    def head(self, rev="HEAD"):
        return self.git("rev-parse", rev)

    def commit(self, msg="c", add=True):
        """git add -A (unless add=False: commit -a) and commit; the new HEAD."""
        if add:
            self.git("add", "-A")
            self.git("commit", "-qm", msg)
        else:
            self.git("commit", "-qam", msg)
        return self.head()

    def put(self, rel, text="x\n"):
        """A file in the current repo (folders made); its path."""
        d = os.path.dirname(rel)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(rel, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        return rel

    def lines(self, rel, *lines):
        return self.put(rel, "".join(l + "\n" for l in lines))

    # ---- configs and runner doubles

    def config(self, extra="", replace=(), base=FIX, name="factory.yml", use=True):
        """The fixture (or base) with (old, new) replacements and extra lines appended; set as FACTORY_CONFIG."""
        with open(base, encoding="utf-8") as f:
            text = f.read()
        for old, new in replace:
            self.assertIn(old, text, "the config has no %r to replace" % old)
            text = text.replace(old, new)
        if extra:
            text += extra if extra.endswith("\n") else extra + "\n"
        p = self.write(os.path.join("cfg", "%d-%s" % (len(os.listdir(self.path("cfg"))), name)), text)
        if use:
            os.environ["FACTORY_CONFIG"] = p
        return p

    def own_config(self, text, name="factory.yml"):
        """A config of its own (not the fixture), set as FACTORY_CONFIG."""
        p = self.write(os.path.join("cfg", "%d-%s" % (len(os.listdir(self.path("cfg"))), name)), text)
        os.environ["FACTORY_CONFIG"] = p
        return p

    def sh(self, name, body):
        """A bash script `name` first on PATH (bin/ of this test); its path."""
        p = os.path.join(self.path("bin"), name)
        with open(p, "w") as f:
            f.write("#!/usr/bin/env bash\n" + body + "\n")
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        return p

    def runner(self, name, out, code=0):
        """A runner (mvn, pnpm) that prints `out` and exits `code`; each call's argv goes to <tmp>/<name>.argv."""
        data = self.write(os.path.join("runner", name + ".out"), out if out.endswith("\n") or not out else out + "\n")
        log = os.path.join(self.tmp, name + ".argv")
        return self.sh(name, 'printf "%%s\\n" "$*" >> "%s"\ncat "%s"\nexit %d' % (log, data, code))

    def argv_log(self, name):
        p = os.path.join(self.tmp, name + ".argv")
        return open(p).read() if os.path.exists(p) else ""

    def count(self, mark):
        """Lines in <tmp>/marks/<mark>: how many times a command that appends to it ran."""
        p = os.path.join(self.tmp, "marks", mark)
        return len(open(p).read().splitlines()) if os.path.exists(p) else 0

    def mark(self, mark):
        """A shell snippet that appends a line to <tmp>/marks/<mark>."""
        os.makedirs(os.path.join(self.tmp, "marks"), exist_ok=True)
        return 'echo m >> "%s"' % os.path.join(self.tmp, "marks", mark)
