"""dispatch: one dispatcher cycle for one project (docs/superpowers/specs/2026-10-14-port-dispatch-sh-to-python-design.md).

Starts factory pipelines for the project's cards waiting in the owner's queues. Run every 3 min by shipfloor-dispatch.sh,
once per registered project, through the wrapper scripts/dispatch.sh. Pipelines run from the project's control checkout
of origin/main, never from a worktree an agent can edit.

usage: dispatch.sh
exit: 0 done, paused or waiting (PAUSE, usage limit, GitHub limit, costs.day_stop) · 1 a board, cost or step failure
      2 invalid config

The port of the Bash dispatch.sh (#168): one function per Bash function, the same processes with the same argv (git,
the board, claude, deploy.sh, dashboard_cost.py, gh, powershell.exe), the same streams and the same messages, written
in English and served through the language catalog. Each run is watched over by its own detached process,
`sf.py dispatch --supervise <spec>` (supervise below): the cycle starts it and never waits on it or kills it, so the
run outlives the cycle on every OS. New over dispatch.sh (the owner's note on #168): a run's TMPDIR is
$FACTORY_HOME/tmp/<n>/tmp, made with tmp/<n>/ and gone with it, so what the run's tools leave behind never fills /tmp.
"""
import datetime
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

from . import proc, project, stack, text

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIPE, DEVNULL, STDOUT = subprocess.PIPE, subprocess.DEVNULL, subprocess.STDOUT
STAGES = ("refine", "develop", "validate", "deploy")
WEIGHTS = ("light", "standard", "heavy")
SYSTEM_PROMPT = ("This is an unattended factory run. A personal CLAUDE.md is for its owner's interactive sessions: what "
                 "it says to read or write under ~/.claude (memory, journals, notes, a vault) does not apply here.")
# stops processes (dev servers, test runners) left running in the card's worktree; the same text dispatch.sh ran
PS_CLEANUP = r'''
    $p = [regex]::Escape($env:SHIPFLOOR_WT) -replace "/", "[\\/]"
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $p -and $_.ProcessId -ne $PID } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }'''
USAGE_LIMIT = b"hit your session limit"
GH_LIMIT = re.compile(r"API rate limit|secondary rate limit", re.I)


class Exit(Exception):
    """Leave the cycle with this exit code (the Bash script's `exit <code>`)."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


# --- the shell's plumbing ------------------------------------------------------------------------------------------

def _windows():
    return os.name == "nt" or sys.platform == "cygwin"


def _t(b):
    return (b or b"").decode("utf-8", "surrogateescape")


def _flush():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except (OSError, ValueError):  # a reader that went away never stops a run
            pass


def _write(stream, data):
    if data:
        _flush()
        try:
            stream.buffer.write(data if isinstance(data, bytes) else data.encode("utf-8", "surrogateescape"))
            stream.buffer.flush()
        except (OSError, ValueError):
            pass


def _run(argv, out=None, err=None, cwd=None, env=None, input=None):
    """Run a command: (exit code, stdout bytes, stderr bytes). Streams left None are this process's own; a command that
    cannot start is 127 with the shell's line, as Bash would have it."""
    _flush()
    try:
        r = subprocess.run(argv, cwd=cwd, env=env, input=input, stdout=out, stderr=err)
    except OSError as e:
        msg = ("%s: %s\n" % (argv[0], e.strerror or e)).encode("utf-8", "surrogateescape")
        if err is None:
            _write(sys.stderr, msg)
        elif err == STDOUT and hasattr(out, "write"):
            out.write(msg)
        return 127, b"", (msg if err == PIPE else b"")
    rc = r.returncode
    return (128 - rc if rc < 0 else rc), (r.stdout or b""), (r.stderr or b"")


def _cap(argv, err=None, **kw):
    """$(command): (exit code, stdout without its trailing newlines)."""
    rc, out, _ = _run(argv, out=PIPE, err=err, **kw)
    return rc, _t(out).rstrip("\n")


def _nul(b):
    """What `mapfile -d '' -t` reads: the NUL-terminated values."""
    vals = _t(b).split("\0")
    if vals and vals[-1] == "":
        vals.pop()
    return vals


def _int(s, default=0):
    try:
        return int(str(s).strip())
    except (TypeError, ValueError):
        return default


def _iso():
    """date -Is"""
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def _day():
    """date +%F"""
    return datetime.date.today().strftime("%Y-%m-%d")


def _epoch():
    """date +%s, run as the process Bash ran (a test holds a run there, between its lock and its info); the clock when
    there is no date."""
    try:
        r = subprocess.run(["date", "+%s"], stdout=PIPE, stderr=DEVNULL)
        v = _t(r.stdout).strip()
        if r.returncode == 0 and v.isdigit():
            return v
    except OSError:
        pass
    return str(int(time.time()))


def _age(path):
    """Seconds since the path was modified; None when it does not exist."""
    try:
        return time.time() - os.stat(path).st_mtime
    except OSError:
        return None


def _rm(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _rmtree(path):
    shutil.rmtree(path, ignore_errors=True)


def _append(path, line):
    try:
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(line)
    except OSError as e:
        _write(sys.stderr, "dispatch: %s: %s\n" % (path, e.strerror or e))


def _first_line(path):
    """`read -r ... < path`: (the first line, whether it ended with a newline); None when the file cannot be read."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    line, nl, _ = data.partition(b"\n")
    return _t(line), bool(nl)


def _posix(path):
    """`cd <path> && pwd` as Git Bash prints it (/c/...); the path itself elsewhere."""
    if not _windows():
        return path
    try:
        r = subprocess.run(["cygpath", "-u", path], stdout=PIPE, stderr=DEVNULL)
    except OSError:
        return path
    return _t(r.stdout).rstrip("\r\n") if r.returncode == 0 else path


def _python():
    """shipfloor_py: the Python 3 the factory's scripts run under."""
    for v in (os.environ.get("SHIPFLOOR_PY"), os.environ.get("FACTORY_PYTHON")):
        if v:
            return v
    try:
        if subprocess.run(["python3", "-c", ""], stdout=DEVNULL, stderr=DEVNULL).returncode == 0:
            return "python3"
    except OSError:
        pass
    return "python"


def _say(lang, msg, err=False):
    """echo <msg> | shipfloor_say <lang>, to stdout (or stderr)."""
    try:
        line = text.say(lang or "en", msg + "\n")
    except (OSError, RuntimeError):
        line = msg + "\n"
    _write(sys.stderr if err else sys.stdout, line)


def _board(*args):
    """The board command: FACTORY_BOARD, or board.sh run by bash (no dependence on the mode bit)."""
    b = os.environ.get("FACTORY_BOARD", "")
    if b:
        return proc.script_argv(b, *args)
    return ["bash", os.path.join(SCRIPTS, "board.sh"), *args]


def _run_env(envs, cwd=None):
    """env -u FACTORY_BOARD_SNAPSHOT <envs>, in a shell that did cd <cwd> (PWD follows)."""
    env = dict(os.environ)
    env.pop("FACTORY_BOARD_SNAPSHOT", None)
    for kv in envs:
        k, _, v = kv.partition("=")
        env[k] = v
    if cwd:
        env["PWD"] = cwd
    return env


def _detach(spec):
    """Start `sf.py dispatch --supervise <spec>` on its own: a new session (POSIX) or a detached process group
    (Windows), stdin closed, stdout and stderr the cycle's (as the Bash run's were), HUP, INT and QUIT ignored, as a
    background job of a script ignores them. Never waited on, never killed."""
    argv = [sys.executable, "-I", proc.native_path(os.path.join(SCRIPTS, "sf.py")), "dispatch", "--supervise",
            json.dumps(spec)]
    kw = {"stdin": DEVNULL, "close_fds": True}
    saved = {}
    if _windows() and hasattr(subprocess, "DETACHED_PROCESS"):
        kw["creationflags"] = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kw["start_new_session"] = True
        for name in ("SIGHUP", "SIGINT", "SIGQUIT"):  # ignored from its first instruction: the child inherits it
            sig = getattr(signal, name, None)
            if sig is not None:
                saved[sig] = signal.signal(sig, signal.SIG_IGN)
    _flush()
    try:
        subprocess.Popen(argv, **kw)
    except OSError as e:
        _write(sys.stderr, "dispatch: cannot start the run: %s\n" % (e.strerror or e))
    finally:
        for sig, handler in saved.items():
            signal.signal(sig, handler)


# --- locks: what dispatch.sh's lock_live, running_issues, card_busy and live_runs did --------------------------------

def lock_live(d, ttl):
    """0 = still held: younger than the TTL (epoch from info, else the dir's mtime), or its pid alive. An old lock
    whose process is gone is removed."""
    if not os.path.isdir(d):
        return False
    first = _first_line(os.path.join(d, "info"))
    words = first[0].split() if first else []
    pid = words[0] if words else ""
    epoch = words[1] if len(words) > 1 else ""
    if not epoch:
        age = _age(d)
        epoch_n = int(time.time()) if age is None else int(time.time() - age)
    else:
        epoch_n = _int(epoch)
    if int(time.time()) - epoch_n <= ttl:
        return True
    if pid and proc.alive(pid):
        return True
    _rmtree(d)
    return False


def _locks(pattern):
    return sorted(p for p in glob.glob(pattern) if os.path.isdir(p))


# --- the cycle -----------------------------------------------------------------------------------------------------

class Cycle:
    """One dispatcher cycle: the Bash script's top level, its globals as attributes."""

    def __init__(self):
        self.mlang = os.environ.get("MLANG", "")  # ${MLANG:-en} before the machine config names it
        self.started = 0
        self.costfail = False
        self.block_cards = ""
        self.snap_rows = None

    def say(self, msg, err=False):
        _say(self.mlang, msg, err)

    def die(self, msg, code):
        self.say(msg, err=True)
        raise Exit(code)

    # what each process is
    def cfg(self, *query, quiet=False):
        """shipfloor_cfg <query>: (exit code, stdout bytes); stderr goes through unless quiet (2>/dev/null)."""
        r = project.cfg(*query)
        if not quiet:
            _write(sys.stderr, r.stderr)
        return r.returncode, r.stdout

    def machine(self, *args, quiet=False, show=False):
        """shipfloor_machine <args>: (exit code, stdout bytes); with show, stdout goes through too."""
        r = project.machine(*args)
        if show:
            _write(sys.stdout, r.stdout)
        if not quiet:
            _write(sys.stderr, r.stderr)
        return r.returncode, r.stdout

    # --- the top level, in dispatch.sh's order
    def run(self):
        try:
            project.resolve(".")
        except project.ProjectError as e:
            _write(sys.stderr, str(e) + "\n")
            return 2
        from .cli import _validate  # shipfloor_validate: the config, then every pattern with grep -E
        if not _validate():
            self.die("dispatch: invalid config %s" % os.environ.get("FACTORY_CONFIG", ""), 2)
        home = os.environ.get("FACTORY_HOME", "")
        if not home:
            _write(sys.stderr, "dispatch.sh: FACTORY_HOME: FACTORY_HOME unset\n")
            return 127
        self.home = home
        self.repo = os.environ.get("FACTORY_REPO", "")
        self.control = home + "/control"
        self.wt_root = os.environ.get("FACTORY_WT_ROOT") or home + "/wt"
        self.claude = os.environ.get("FACTORY_CLAUDE") or "claude"
        try:  # the plugin checkout, as in scripts/shipfloor
            with open(os.path.join(SCRIPTS, ".source"), "rb") as f:
                self.plugin = _t(f.read()).rstrip("\n")
        except OSError:
            self.plugin = _posix(os.path.dirname(SCRIPTS))
        self.ttl = _int(os.environ.get("FACTORY_LOCK_TTL") or "10800", 10800)
        self.shome = project.shipfloor_home()
        os.environ["FACTORY_HOME"], os.environ["FACTORY_WT_ROOT"] = home, self.wt_root
        os.environ["SHIPFLOOR_HOME"] = self.shome
        for d in ("locks", "logs", "tmp", "reviews"):
            os.makedirs(os.path.join(home, d), exist_ok=True)
        os.makedirs(self.wt_root, exist_ok=True)
        if os.path.exists(os.path.join(home, "PAUSE")):
            return 0
        lim = _nul(self.cfg("values", "limits.refine.wip", "limits.develop.wip")[1])
        if len(lim) != 2:
            self.die("dispatch: cannot read limits", 2)
        # The machine pool (~/.shipfloor/config.yml): runs at once on this machine, and per stage, across projects.
        if self.machine("validate", show=True)[0] != 0:
            self.die("dispatch: invalid %s/config.yml" % self.shome, 2)
        self.mlang = _t(self.machine("values", "language", quiet=True)[1]).replace("\0", "").rstrip("\n")
        # the cost limits ride on this read: none set, no estimate starts
        pool = _nul(self.machine("values", "pool", "stages.refine", "stages.develop", "stages.validate",
                                 "stages.deploy", "costs.card_block", "costs.day_stop")[1])
        if len(pool) != 7:
            self.die("dispatch: cannot read the machine pool", 2)
        self.stage_slots = dict(zip(STAGES, pool[1:5]))
        models = _nul(self.machine("stage-models")[1])  # each stage x light standard heavy; empty = no --model flag
        if len(models) != 12:
            self.die("dispatch: cannot read the stage models", 2)
        self.stage_model = {}
        for i, st in enumerate(STAGES):
            for j, w in enumerate(WEIGHTS):
                self.stage_model[st + ":" + w] = models[i * 3 + j]

        if self.github_limited():
            self.say("dispatch: GitHub API limit hit recently; waiting")
            return 0
        self.read_board()
        if self.usage_limited():
            self.say("dispatch: Claude usage limit hit recently; waiting")
            return 0
        self.clean_markers()
        if pool[5] + pool[6]:
            self.cost_limits()
        self.started = 0
        self.costfail = False

        self.global_free = _int(os.environ.get("SHIPFLOOR_MAX_PARALLEL") or pool[0]) - self.live_runs()
        status = 0
        if not self.retry_infra():
            status = 1
        # Outside the working hours (config.yml, hours) only the starts are skipped; the rest of the cycle runs.
        out = _t(self.machine("hours", quiet=True)[1]).split("\n")[0].split(None, 1)
        state = out[0] if out else ""
        nxt = out[1].strip() if len(out) > 1 else ""
        if (state or "open") == "closed":
            self.say("dispatch: outside working hours; runs start again at %s" % nxt)
        else:
            lr, ld = _int(lim[0]), _int(lim[1])
            if not self.run_pipeline("refine", "Ready for Refinement", 0, lr, "Technical Refinement", "Spec Review"):
                status = 1
            if not self.run_pipeline("develop", "Ready for Dev", 0, ld, "Coding", "Coding", "Validation"):
                status = 1
            if not self.run_pipeline("validate", "Validation", 0, 0, ""):
                status = 1
            # one deploy at a time in a project: merges into its main are serial
            if not self.run_pipeline("deploy", "Ready for Prod", 1, 0, ""):
                status = 1
        # Off by default: every refresh push reruns the whole CI (Actions minutes on GitHub Free).
        rc, out = self.cfg("get", "deploy.refresh_staged", quiet=True)
        if _t(out).rstrip("\n") == "true" and not self.refresh_staged():
            status = 1
        if self.costfail:
            status = 1
        # What finished cards and stray files left under tmp/ goes with every cycle (the same as `shipfloor clean`).
        removed = project.sweep_tmp()
        if removed:
            ts = _iso()
            _write(sys.stdout, "".join("%s dispatch: removed %s\n" % (ts, r) for r in removed))
        return status

    # --- the board snapshot: one read per cycle, shared by every check (the GraphQL quota is shared with the runs)
    def read_board(self):
        self.snap = os.path.join(self.home, "board.tsv")
        # A temp file per process: two dispatches at once must not write, or move away, each other's.
        tmp = "%s.%d.tmp" % (self.snap, os.getpid())
        with open(tmp, "wb") as f:
            rc, _, err = _run(_board("snapshot"), out=f, err=PIPE)
        _write(sys.stderr, err)
        if rc != 0:
            if GH_LIMIT.search(_t(err)):
                self.touch(self.gh_mark())
            _rm(tmp)
            self.die("dispatch: board read failed", 1)
        os.replace(tmp, self.snap)
        os.environ["FACTORY_BOARD_SNAPSHOT"] = self.snap

    @staticmethod
    def touch(path):
        try:
            with open(path, "a"):
                pass
            os.utime(path, None)
        except OSError:
            pass

    def snapshot_rows(self):
        if self.snap_rows is None:
            try:
                with open(self.snap, "rb") as f:
                    self.snap_data = _t(f.read())
            except OSError:
                self.snap_data = ""
            rows = []
            for line in self.snap_data.split("\n"):
                cols = line.split("\t")
                rows.append((cols[0], cols[1] if len(cols) > 1 else ""))
            if self.snap_data.endswith("\n") or not self.snap_data:
                rows.pop()
            self.snap_rows = rows
        return self.snap_rows

    def snapshot_status(self, n):
        """awk -F'\\t' -v n=<n> '$1==n{print $2}' board.tsv, as $(...) holds it."""
        return "\n".join(s for k, s in self.snapshot_rows() if k == n).rstrip("\n")

    def board_read(self):
        """grep -q . board.tsv: the read has something in it (an empty read proves nothing)."""
        self.snapshot_rows()
        return bool(self.snap_data.replace("\n", ""))

    # --- the waits
    def gh_mark(self):
        return os.path.join(self.shome, "github-limited")

    def github_limited(self):
        """GitHub refuses the whole account for a while once its API limit is hit: runs started then die on their
        first gh call. A board read refused for that leaves a mark for the machine, and no cycle launches or reads the
        board until it is SHIPFLOOR_GITHUB_LIMIT_MIN (10) minutes old (#190)."""
        minutes = _int(os.environ.get("SHIPFLOOR_GITHUB_LIMIT_MIN") or "10", None)
        if minutes is None:
            return False
        age = _age(self.gh_mark())
        return age is not None and age < minutes * 60

    def usage_limited(self):
        """A run that ended on the Claude usage limit in the last 30 min pauses new launches: its log's last run (from
        the last == start line) says so."""
        for root, dirs, files in os.walk(os.path.join(self.home, "logs")):
            dirs.sort()
            for name in sorted(files):
                if not name.endswith(".log"):
                    continue
                path = os.path.join(root, name)
                age = _age(path)
                if age is None or age >= 30 * 60:
                    continue
                try:
                    with open(path, "rb") as f:
                        lines = f.read().split(b"\n")
                except OSError:
                    continue
                last = 0
                for i, line in enumerate(lines):
                    if line.startswith(b"== start"):
                        last = i
                if any(USAGE_LIMIT in line for line in lines[last:]):
                    return True
        return False

    # --- markers whose card left the board
    def clean_markers(self):
        if not self.board_read():
            return
        # Cost limits: a marker cost/<n>.json (the baseline of a block) goes when its card leaves the board.
        for f in sorted(glob.glob(os.path.join(glob.escape(self.home), "cost", "*.json"))):
            if os.path.isfile(f) and self.snapshot_status(os.path.basename(f)[:-len(".json")]) == "":
                _rm(f)
        # A step-up marker (stepup/<n>) lasts while its card is in Coding: an unblocked card keeps the higher model.
        for f in sorted(glob.glob(os.path.join(glob.escape(self.home), "stepup", "*"))):
            if not os.path.isfile(f):
                continue
            n = os.path.basename(f)
            if self.snapshot_status(n) != "Coding" and not self.card_busy(n):
                _rm(f)

    # --- cost limits (machine config `costs`): none set, nothing here starts a process
    def cost_limits(self):
        self.cost_py = [_python(), "-I", proc.native_path(os.path.join(SCRIPTS, "dashboard_cost.py"))]
        slug = os.environ.get("FACTORY_PROJECT", "")
        if not slug:
            _write(sys.stderr, "dispatch.sh: FACTORY_PROJECT: parameter null or not set\n")
            raise Exit(127)
        self.cost_args = ["--home", proc.native_path(self.shome), "--project", slug]
        rc, out, _ = _run(self.cost_py + ["limits"] + self.cost_args, out=PIPE)
        if rc != 0:
            self.die("dispatch: cannot read the cost limits", 1)
        for line in _t(out).replace("\r", "").rstrip("\n").split("\n"):
            kind, a, b = text.read_tab(line, 3)
            if kind == "day_stop":
                self.say("dispatch: today's estimate US$ %s reached costs.day_stop (US$ %s); no new run until tomorrow"
                         % (a, b))
                raise Exit(0)
            if kind == "block":
                self.block_cards += " " + a

    def block_card(self, n):
        """The comment says why, then the label; a failure of either fails the cycle. True = blocked (or failed to be:
        not started either); False = no known estimate, never judged: it starts."""
        m = os.path.join(self.home, "cost", n + ".json")
        prev = m + ".prev"
        body = os.path.join(self.home, "tmp", "cost-%s.md" % n)
        rc, out = self.cfg("get", "project.repo", quiet=True)  # owner/repo, never the clone's path in FACTORY_REPO
        slug = _t(out).replace("\0", "").replace("\r", "").rstrip("\n")
        try:
            shutil.copyfile(m, prev)
        except OSError:
            pass
        rc = _run(self.cost_py + ["block"] + self.cost_args + ["--issue", n, "--out", proc.native_path(body)])[0]
        if rc == 1:
            _rm(prev)
            return False
        if rc == 0:
            if (_run(proc.gh_argv("issue", "comment", n, "-R", slug, "--body-file", body), out=DEVNULL)[0] == 0
                    and _run(_board("label", n, "add", "blocked"))[0] == 0):
                _rm(prev)
                _rm(body)
                self.say("dispatch: #%s reached costs.card_block; blocked" % n)
                return True
        # not told: put the marker back, or the next cycle would take this block for done and start the card
        if os.path.isfile(prev):
            try:
                os.replace(prev, m)
            except OSError:
                pass
        else:
            _rm(m)
        _rm(body)
        self.costfail = True
        self.say("dispatch: could not block #%s at costs.card_block" % n, err=True)
        return True

    # --- locks
    def running_issues(self, p):
        """Issue numbers of the pipeline with a live lock (locks are per card)."""
        out = []
        for d in _locks(os.path.join(glob.escape(self.home), "locks", "%s-*.lock" % p)):
            if lock_live(d, self.ttl):
                out.append(d.rsplit("-", 1)[1][:-len(".lock")])
        return out

    def card_busy(self, n):
        """A live run of any pipeline holds this card (its worktree and tmp)."""
        for d in _locks(os.path.join(glob.escape(self.home), "locks", "[a-z]*-%s.lock" % glob.escape(n))):
            if lock_live(d, self.ttl):
                return True
        return False

    def live_runs(self, stage=""):
        """Live runs on this machine (every project), of one stage or all."""
        pat = (stage or "[a-z]*") + "-*.lock"
        found = (_locks(os.path.join(glob.escape(self.shome), "projects", "*", "locks", pat))
                 + _locks(os.path.join(glob.escape(self.home), "locks", pat)))
        n, seen = 0, set()
        for d in found:
            name = os.path.basename(d)
            if name.startswith("refresh-"):  # refreshes are scripts, not agents
                continue
            if name.startswith("deploysh-"):  # a deploy is ONE unit: deploy-<n>.lock counts, deploy.sh's own does not
                continue
            key = os.path.normcase(os.path.normpath(d))
            if key in seen:
                continue
            seen.add(key)
            if lock_live(d, self.ttl):
                n += 1
        return n

    # --- the control checkout = exactly origin/main
    def refresh_control(self):
        if (os.environ.get("FACTORY_CONTROL_REFRESH") or "1") == "0":
            return True
        main = os.environ.get("FACTORY_MAIN") or "main"
        if _run(["git", "-C", self.repo, "fetch", "-q", "origin", main])[0] != 0:
            return False
        if not os.path.exists(os.path.join(self.control, ".git")):
            if _run(["git", "-C", self.repo, "worktree", "add", "-q", "--detach", self.control, "origin/" + main])[0]:
                return False
        g = ["git", "-C", self.control, "-c", "core.longpaths=true"]
        return _run(g + ["reset", "-q", "--hard", "origin/" + main])[0] == 0 and _run(g + ["clean", "-qfdx"])[0] == 0

    # --- launching
    def read_rule(self, d):
        """The permission rule that lets a run read under <d>, never write; None when it does not exist."""
        if not os.path.isdir(d):
            return None
        return "Read(/%s/**)" % _posix(os.path.abspath(d))  # a rule's absolute path opens with two slashes

    def launch(self, p, n):
        d = "%s/locks/%s-%s.lock" % (self.home, p, n)
        try:
            os.mkdir(d)
        except OSError:
            return
        scratch = "%s/tmp/%s" % (self.home, n)
        # the run's own scratch folder exists before it looks for one, and holds its TMPDIR: what its tools leave
        # behind goes with tmp/<n>/, never into the machine's /tmp (#168)
        os.makedirs(scratch + "/tmp", exist_ok=True)
        log = "%s/logs/%s-%s-%s.log" % (self.home, _day(), n, p)
        # print mode stops background subagents 10 min after the last turn and ends the run half done; 0 waits.
        # Only the project's settings and this plugin: the owner's personal plugins, MCP servers and output style
        # cost every run ~19k tokens of context and steer its agents.
        extra = ["--setting-sources", "project,local", "--strict-mcp-config", "--plugin-dir", self.plugin]
        envs = ["SHIPFLOOR_FACTORY=1", "SHIPFLOOR_RUN_LOCK=" + d, "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0"]
        # A run reads the factory's scripts and templates and the reports of earlier runs, and writes neither.
        # PowerShell is refused in every headless run; without the tool no turn is spent finding that out.
        rules = [r for r in (self.read_rule(SCRIPTS), self.read_rule(self.home + "/reports-wt")) if r]
        if rules:
            extra += ["--allowedTools", *rules]
        extra += ["--disallowedTools", "PowerShell"]
        # The owner's personal CLAUDE.md is loaded whatever the setting sources are: its memory and notes are not
        # for a run.
        envs.append("CLAUDE_CODE_DISABLE_AUTO_MEMORY=1")
        extra += ["--append-system-prompt", SYSTEM_PROMPT]
        # The model comes from the card's weight (its spec header, standard when none); a develop run after a failed
        # gate runs one model up (stepup/<n>: <from> <to> <gate>, written when the run before ended).
        weight = project.card_weight(n)
        model = self.stage_model.get(p + ":" + weight, "")
        step = frm = gate = ""
        if p == "develop" and os.path.isfile("%s/stepup/%s" % (self.home, n)):
            first = _first_line("%s/stepup/%s" % (self.home, n))
            if first is not None:
                frm, step, gate = text.read_tab(first[0], 3)
            if step:
                model = step
        if model:
            extra += ["--model", model]
        # the language the project writes in, read once: the run keeps it even if the owner changes it while it runs
        rc, out = self.cfg("get", "language", quiet=True)
        lang = _t(out).rstrip("\n")
        if rc == 0 and lang:
            envs.append("FACTORY_LANGUAGE=" + lang)
        if os.path.exists("%s/infra/%s" % (self.home, n)):
            envs.append("SHIPFLOOR_INFRA_RETRY=1")
        envs.append("TMPDIR=" + scratch + "/tmp")
        args = ["-p", "--permission-mode", "acceptEdits", "--add-dir", self.wt_root, "--add-dir", self.home + "/tmp",
                "--add-dir", self.home + "/reviews", *extra]
        _detach({"mode": "run", "p": p, "n": n, "dir": d, "log": log, "model": model, "weight": weight,
                 "step": step, "from": frm, "gate": gate, "envs": envs, "claude": self.claude, "args": args,
                 "control": self.control, "wt_root": self.wt_root, "home": self.home, "mlang": self.mlang,
                 "deploy": os.environ.get("FACTORY_DEPLOY") or os.path.join(SCRIPTS, "deploy.sh")})

    def run_pipeline(self, p, queue, maxpar, limit, orphan_cols, *wip_cols):
        """Start pipeline <p> on its orphans, then on its queue's cards within the WIP limit (0 = none) and the
        project's cap (maxpar, 0 = the stage slots decide). False when a board read or a step failed."""
        running = self.running_issues(p)
        free = maxpar - len(running)
        stage_free = _int(self.stage_slots.get(p) or "0") - self.live_runs(p)
        if maxpar == 0 or stage_free < free:
            free = stage_free
        if free <= 0:
            return True
        st = {"free": free, "refreshed": False}
        resumed = []

        def start_run(n, orphan=False):
            self.started = 0
            if (" %s " % n) in (" %s " % self.block_cards) and self.block_card(n):
                return True  # blocked, not started: it takes no slot
            self.started = 1
            if not st["refreshed"]:
                if not self.refresh_control():
                    self.say("dispatch: could not refresh %s from origin/main" % self.control, err=True)
                    return False
                st["refreshed"] = True
            self.launch(p, n)
            running.append(n)
            st["free"] -= 1
            self.global_free -= 1
            if orphan:
                resumed.append(n)  # resumed orphans already sit in a WIP column
            return True

        # 1. resume orphans: cards this pipeline left mid-way (crash, usage limit) with no live run
        for col in orphan_cols.split(","):
            if not col:
                continue
            rc, cards = _cap(_board("eligible", col))
            if rc != 0:
                return False
            for n in cards.split():
                if st["free"] <= 0 or self.global_free <= 0:
                    return True
                if n in running or self.card_busy(n):
                    continue
                if not start_run(n, orphan=True):
                    return False
        # 2. new cards from the queue, within the WIP limit
        slots = st["free"]
        if limit > 0:
            rc, used = _cap(_board("count", *wip_cols))
            if rc != 0:
                return False
            inflight = 0
            for n in running:  # runs whose card is not in a WIP column yet still take a WIP slot
                if n in resumed:
                    continue
                if not any(line in wip_cols for line in self.snapshot_status(n).split("\n")):
                    inflight += 1
            room = limit - _int(used or "0") - inflight
            if room < slots:
                slots = room
        if slots <= 0:
            return True
        rc, cards = _cap(_board("eligible", queue))
        if rc != 0:
            return False
        for n in cards.split():
            if slots <= 0 or self.global_free <= 0:
                break
            if n in running or self.card_busy(n):
                continue
            if not start_run(n):
                return False
            if self.started == 1:
                slots -= 1
        return True

    # --- the scripts that keep cards moving without an agent slot
    def refresh_staged(self):
        """Keep approved-to-be PRs on top of main: deploy.sh --refresh, a script, no agent slot."""
        rc, cards = _cap(_board("eligible", "Staged"))
        if rc != 0:
            return False
        for n in cards.split():
            if self.card_busy(n):
                continue
            d = "%s/locks/refresh-%s.lock" % (self.home, n)
            try:
                os.mkdir(d)
            except OSError:
                continue
            _detach({"mode": "refresh", "n": n, "dir": d, "log": "%s/logs/%s-%s-refresh.log" % (self.home, _day(), n),
                     "control": self.control,
                     "deploy": os.environ.get("FACTORY_DEPLOY") or os.path.join(SCRIPTS, "deploy.sh")})
        return True

    def retry_infra(self):
        """Cards blocked by infrastructure: clean up and retry once; a second block goes to the owner."""
        rc, cards = _cap(_board("infra"))
        if rc != 0:
            return False
        cards = cards.split()
        infra = os.path.join(self.home, "infra")
        os.makedirs(infra, exist_ok=True)
        for f in sorted(glob.glob(os.path.join(glob.escape(infra), "*"))):  # a marker whose block is gone is spent
            if not os.path.isfile(f):
                continue
            n = os.path.basename(f)
            if n not in cards and not self.card_busy(n):
                _rm(f)
        for n in cards:
            if self.card_busy(n):
                continue
            marker = os.path.join(infra, n)
            if os.path.exists(marker):
                _run(_board("label", n, "add", "blocked"))
                _run(_board("label", n, "remove", "blocked:infra"))
                _rm(marker)
                continue
            project.clean_tmp(n)
            with open(marker, "w", encoding="utf-8", newline="\n") as f:
                f.write("%d\n" % int(time.time()))
            _run(_board("label", n, "remove", "blocked:infra"))
        return True


# --- one run, in its own process -------------------------------------------------------------------------------------

def cleanup_processes(wt_root, n):
    """Stop processes (dev servers, test runners) left running in the card's worktree: Windows only."""
    if not shutil.which("powershell.exe"):
        return
    env = dict(os.environ)
    env["SHIPFLOOR_WT"] = proc.native_path(wt_root + "/" + n + "/")
    _run(proc.script_argv("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", PS_CLEANUP),
         out=DEVNULL, err=DEVNULL, env=env)


def step_up(spec, model, log):
    """A develop run that ended on a failed gate runs once more, one model up. The verdict is the gate's own
    (<lock>/last-gate), never the agent's report. INFRA is the infra retry's; a card that already stepped up, a top
    model or one off the ladder fails as before: it stays blocked for the owner."""
    n, home = spec["n"], spec["home"]
    marker = os.path.join(home, "stepup", n)
    if not model or os.path.exists(marker):
        return
    first = _first_line(os.path.join(spec["dir"], "last-gate"))
    if first is None or not first[1]:  # read fails on a line with no newline
        return
    name, verdict = text.read_tab(first[0], 2)
    if verdict != "FAIL":
        return
    r = project.machine("model-up", model)
    up = _t(r.stdout).rstrip("\n")
    if not up:
        return
    os.makedirs(os.path.join(home, "stepup"), exist_ok=True)
    with open(marker, "w", encoding="utf-8", newline="\n") as f:
        f.write("%s\t%s\t%s\n" % (model, up, name))
    _run(_board("label", n, "remove", "blocked"), out=DEVNULL, env=_run_env([], spec["control"]))
    _append(log, "== step-up /sf:develop %s %s -> %s: gate %s failed %s\n" % (n, model, up, name, _iso()))
    _say(spec["mlang"], "%s dispatch: #%s failed gate %s on %s; the next run is on %s" % (_iso(), n, name, model, up))


def _ignore_signals():
    for name in ("SIGHUP", "SIGINT", "SIGQUIT"):
        sig = getattr(signal, name, None)
        if sig is not None:
            signal.signal(sig, signal.SIG_IGN)


def _write_info(d, n):
    line = "%d %s %s\n" % (os.getpid(), _epoch(), n)  # the epoch first: info does not exist while it is read
    try:
        with open(os.path.join(d, "info"), "w", encoding="utf-8", newline="\n") as f:
            f.write(line)
    except OSError as e:
        _write(sys.stderr, "dispatch: %s/info: %s\n" % (d, e.strerror or e))


def _no_control(control):
    if os.path.isdir(control):
        return False
    _write(sys.stderr, "dispatch.sh: cd: %s: No such file or directory\n" % control)
    return True


def supervise(spec):
    """One run: info, == start, the agent (or deploy.sh and its rounds), == end, the step-up, then what the run created
    goes with it, before its lock: its stack slot, its tmp/<n>/ (its TMPDIR in it), its leftover processes."""
    _ignore_signals()
    if spec.get("mode") == "refresh":
        return _refresh(spec)
    p, n, d, log, control = spec["p"], spec["n"], spec["dir"], spec["log"], spec["control"]
    model, step = spec["model"], spec["step"]
    pid = os.getpid()
    _write_info(d, n)
    _append(log, "== start /sf:%s %s %s pid=%d%s weight=%s\n" % (p, n, _iso(), pid, " model=" + model if model else "",
                                                                 spec["weight"]))
    if step:
        _say(spec["mlang"], "%s dispatch: #%s runs on %s, one model up after %s failed gate %s"
             % (_iso(), n, step, spec["from"], spec["gate"]))
    if _no_control(control):
        _append(log, "== end /sf:%s %s exit=1 %s: no %s\n" % (p, n, _iso(), control))
        _rmtree(d)  # no lock left to hold the slot
        return 1
    os.chdir(control)  # as the Bash run did: what follows (the step-up, the cleanup) runs from the control checkout
    env = _run_env(spec["envs"], control)

    def agent():
        # The prompt goes on stdin: as an argument Git Bash turns "/develop 54" into "C:/Program Files/Git/develop 54".
        argv = proc.script_argv(spec["claude"], *spec["args"])
        with open(log, "ab") as f:
            return _run(argv, out=f, err=STDOUT, cwd=control, env=env, input=("/sf:%s %s" % (p, n)).encode("utf-8"))[0]

    def deploy(*args):
        with open(log, "ab") as f:
            return _run(["bash", spec["deploy"], n, *args], out=f, err=STDOUT, cwd=control, env=env)[0]

    try:
        _work(spec, agent, deploy, log)
    except Exception as e:  # whatever happens, the cleanup below runs and the lock goes
        _write(sys.stderr, "dispatch: #%s: %s\n" % (n, e))
    # what the run created goes with it, before its lock: its stack slot, its tmp/<n>/, its retry marker stays
    try:
        stack.release_run(stack.read_settings(), d)
    except Exception as e:  # a broken stack config never keeps the lock
        _write(sys.stderr, "dispatch: #%s: releasing its stack slot: %s\n" % (n, e))
    try:
        project.clean_tmp(n)  # the retry's marker stays: it is how the next block goes to the owner
        if (os.environ.get("FACTORY_CLEANUP") or "1") == "1":
            cleanup_processes(spec["wt_root"], n)
    except Exception as e:
        _write(sys.stderr, "dispatch: #%s: %s\n" % (n, e))
    first = _first_line(os.path.join(d, "info"))
    owner = first[0].split()[0] if first and first[0].split() else ""
    if owner == str(pid):
        _rmtree(d)
    return 0


def _work(spec, agent, deploy, log):
    """The run itself: the agent, or deploy.sh and its rounds; == end; the step-up. Its exit code."""
    p, n, model = spec["p"], spec["n"], spec["model"]
    if p == "deploy":
        # The deploy is a script, not an agent: it can wait for CI and production as long as needed. An agent is
        # called only for what the script hands over (exit 3): merge conflicts with main, then up to two rounds on a
        # gate or CI that went red on top of main.
        rc = deploy()
        for _round in range(3):
            if rc != 3:
                break
            agent()
            rc = deploy("--continue")
        _append(log, "== end /sf:%s %s exit=%d %s\n" % (p, n, rc, _iso()))
    else:
        rc = agent()
        _append(log, "== end /sf:%s %s exit=%d %s\n" % (p, n, rc, _iso()))
        if p == "develop" and rc == 0:
            step_up(spec, model, log)
    return rc


def _refresh(spec):
    """deploy.sh <n> --refresh from the control checkout, under refresh-<n>.lock; the lock goes when it ends."""
    d, n = spec["dir"], spec["n"]
    _write_info(d, n)
    control = spec["control"]
    if not _no_control(control):
        with open(spec["log"], "ab") as f:
            _run(["bash", spec["deploy"], n, "--refresh"], out=f, err=STDOUT, cwd=control, env=_run_env([], control))
    _rmtree(d)
    return 0


def main(argv):
    if len(argv) == 2 and argv[0] == "--supervise":
        return supervise(json.loads(argv[1]))
    try:
        return Cycle().run()
    except Exit as e:
        return e.code
    finally:
        _flush()
