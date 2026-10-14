"""cycle: one dispatcher cycle for every project in <SHIPFLOOR_HOME>/registry.tsv (slug, repo, worktrees, main).

For each: bring its control checkout to origin/<main>, validate the config there, then run dispatch.sh for it.
A project it cannot use is skipped and logged; the others still run.

The port of the Bash shipfloor-dispatch.sh (#169): the same processes with the same argv (git, bash dispatch.sh,
shipfloor_health.py, shipfloor_notify.py, shipfloor_config.py), the same streams, messages, files and exit codes.
Each project runs in its own process (`sf.py cycle-project`), as it ran in its own subshell: a crash or an exit in
one never stops the others.
"""
import datetime
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import time

from . import proc, project, text

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SF = os.path.join(SCRIPTS, "sf.py")
DEVNULL, PIPE, STDOUT = subprocess.DEVNULL, subprocess.PIPE, subprocess.STDOUT


def _now():
    """date -Is"""
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def _flush():
    sys.stdout.flush()
    sys.stderr.flush()


def _t(b):
    return b.decode("utf-8", "surrogateescape")


def _int_env(name, default):
    try:
        return int(os.environ.get(name) or default)
    except ValueError:
        return default


def _age(path):
    """Seconds since the path was modified (lstat, as find); None when it is not there."""
    try:
        return time.time() - os.lstat(path).st_mtime
    except OSError:
        return None


def _older(path, minutes):
    """find <path> -mmin +<minutes> prints it."""
    a = _age(path)
    return a is not None and a > minutes * 60


def _found_younger(path, minutes):
    """find <path> -mmin -<minutes> prints something: the path or anything under it changed within the minutes."""
    a = _age(path)
    if a is None:
        return False
    if a < minutes * 60:
        return True
    if os.path.isdir(path) and not os.path.islink(path):
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                b = _age(os.path.join(root, name))
                if b is not None and b < minutes * 60:
                    return True
    return False


def _say(lang, line, err=False):
    """echo "<line>" | shipfloor_say <lang>, to stdout or stderr."""
    out = sys.stderr if err else sys.stdout
    out.write(text.say(lang, line + "\n"))
    out.flush()


def _bash():
    """The bash the cycle runs in: the wrapper's own ($BASH), else the one on the PATH."""
    return os.environ.get("SHIPFLOOR_CYCLE_BASH") or shutil.which("bash") or "bash"


def _rc(code):
    return 128 - code if code < 0 else code


# --- the machine-wide checks --------------------------------------------------------------------------------------

def _registry(home):
    """The registry's rows as Bash's `IFS=$'\\t' read -r slug repo wt main` reads them (a last line with no newline
    is not read), without the rows whose slug is empty."""
    try:
        with open(os.path.join(home, "registry.tsv"), "rb") as f:
            data = _t(f.read())
    except OSError:
        return []
    rows = []
    for line in data.split("\n")[:-1]:
        parts = re.split("\t+", line.strip("\t"), maxsplit=3) if line.strip("\t") else []
        parts += [""] * (4 - len(parts))
        if parts[0]:
            rows.append(parts)
    return rows


def usage_limited(home):
    """The Claude usage limit is per account: a recent hit in any project pauses all. A log under projects/*/logs/
    changed in the last 30 minutes whose last `== start` block says so."""
    root = os.path.join(home, "projects")
    for d, dirs, files in os.walk(root):
        for name in files:
            f = os.path.join(d, name)
            if not fnmatch.fnmatchcase(f.replace("\\", "/"), "*/logs/*.log"):
                continue
            a = _age(f)
            if a is None or a >= 30 * 60:
                continue
            try:
                with open(f, "rb") as h:
                    lines = _t(h.read()).split("\n")
            except OSError:
                continue
            buf = []
            for l in lines:
                if l.startswith("== start"):
                    buf = []
                buf.append(l)
            if "hit your session limit" in "\n".join(buf):
                return True
    return False


def _machine_lang():
    try:
        r = project.machine("values", "language")
    except OSError:
        return ""
    return _t(r.stdout).replace("\0", "").rstrip("\n")


class Claim:
    """dispatch.pid: a live pid in one younger than SHIPFLOOR_CYCLE_STALE_MIN is another cycle (this one records the
    overlap and stops); an older file was left behind and is taken over. The claim is atomic (the file is created only
    if absent), so two cycles starting at once cannot both take it."""

    def __init__(self, home):
        self.path = os.path.join(home, "dispatch.pid")
        self.overlap = False

    def _claim(self):
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError:
            return False
        try:
            os.write(fd, ("%d\n" % os.getpid()).encode())
        finally:
            os.close(fd)
        return True

    def take(self):
        if self._claim():
            return
        try:
            with open(self.path, "rb") as f:
                other = _t(f.read()).strip()
        except OSError:
            other = ""
        fresh = not _older(self.path, _int_env("SHIPFLOOR_CYCLE_STALE_MIN", 30))
        if fresh and (not other or _alive(other)):
            self.overlap = True  # a fresh marker (or one still being written) is a cycle running
            return
        try:  # left behind: take over, unless another cycle got there first
            os.unlink(self.path)
        except OSError:
            pass
        if not self._claim():
            self.overlap = True

    def release(self):
        if not self.overlap:
            try:
                os.unlink(self.path)
            except OSError:
                pass


def _alive(pid):
    """kill -0 <pid>. Under Git Bash a pid written by bash is an MSYS pid: bash's own kill -0 is asked too."""
    if proc.alive(pid.split("\n")[0]):
        return True
    if os.name == "nt" and re.fullmatch(r"[0-9]+", pid):
        try:
            return subprocess.run([_bash(), "-c", 'kill -0 "$1"', "_", pid],
                                  stdout=DEVNULL, stderr=DEVNULL).returncode == 0
        except OSError:
            return False
    return False


def _record(home, start, rc, overlap):
    """The health line (logs/health-<month>.jsonl), then what waits for the owner; neither ever fails the cycle."""
    env = dict(os.environ)
    env.pop("SHIPFLOOR_CYCLE_BASH", None)
    env["SHIPFLOOR_BASH"] = proc.native_path(_bash())
    py, nhome = sys.executable, proc.native_path(home)
    argv = [py, "-I", proc.native_path(os.path.join(SCRIPTS, "shipfloor_health.py")), "record", "--home", nhome,
            "--seconds", str(int(time.time()) - start), "--exit", str(rc)] + (["--overlap"] if overlap else [])
    _flush()
    try:
        subprocess.run(argv, env=env, stdout=DEVNULL, stderr=DEVNULL)
    except OSError:
        pass
    # its failures are lines in this log, never the cycle's
    try:
        subprocess.run([py, "-I", proc.native_path(os.path.join(SCRIPTS, "shipfloor_notify.py")), "cycle",
                        "--home", nhome], env=env, stdout=DEVNULL)
    except OSError:
        pass


def run_cycle(home):
    """One cycle; its exit code."""
    reg = os.path.join(home, "registry.tsv")
    try:
        if os.path.getsize(reg) == 0:
            return 0
    except OSError:
        return 0
    start = int(time.time())
    claim = Claim(home)
    claim.take()
    rc = 1
    try:
        rc = _cycle(home, claim)
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 1
    finally:
        claim.release()
        _record(home, start, rc, claim.overlap)
    return rc


def _cycle(home, claim):
    if claim.overlap or os.path.exists(os.path.join(home, "PAUSE")):
        return 0
    lang = _machine_lang()  # the dispatcher's own log lines
    if usage_limited(home):
        _say(lang, "%s shipfloor: Claude usage limit hit recently; waiting" % _now())
        return 0
    # GitHub's API limit is per account too: a board read refused for it in any project holds every project (#190)
    if _found_younger(os.path.join(home, "github-limited"), _int_env("SHIPFLOOR_GITHUB_LIMIT_MIN", 10)):
        _say(lang, "%s shipfloor: GitHub API limit hit recently; waiting" % _now())
        return 0
    status = 0
    for slug, repo, wt, main in _registry(home):
        _flush()
        try:
            r = subprocess.run([sys.executable, "-I", proc.native_path(SF), "cycle-project", slug, repo, wt, main,
                                "--lang", lang])
            code = r.returncode
        except OSError:
            code = 1
        if code != 0:
            status = 1
    return status


# --- one project, in its own process ------------------------------------------------------------------------------

class Project:
    def __init__(self, slug, lang):
        self.slug, self.lang = slug, lang
        self.why = ""  # why refresh_control failed: git's own words

    def _cap(self, argv, err=STDOUT):
        """$(command 2>&1): (exit code, output without its trailing newlines)."""
        _flush()
        try:
            r = subprocess.run(argv, stdout=PIPE, stderr=err)
        except OSError as e:
            return 127, str(e)
        return _rc(r.returncode), _t(r.stdout).rstrip("\n")

    def clear_stale_lock(self, checkout):
        """git holds index.lock for one command; an old one was left by a git that died."""
        raw = os.environ.get("SHIPFLOOR_STALE_LOCK_MIN") or "10"
        minutes = _int_env("SHIPFLOOR_STALE_LOCK_MIN", 10)
        _, gitdir = self._cap(["git", "-C", checkout, "rev-parse", "--absolute-git-dir"], err=DEVNULL)
        lock = gitdir + "/index.lock"
        if not os.path.exists(lock) or not _older(lock, minutes):
            return False
        try:
            os.unlink(lock)
        except OSError:
            return False
        _say(self.lang, "%s shipfloor: %s: removed a stale index.lock (older than %s min): %s"
             % (_now(), self.slug, raw, lock), err=True)
        return True

    def refresh_control(self):
        """control checkout = exactly origin/<main>; touched only when main moved."""
        if os.environ.get("FACTORY_CONTROL_REFRESH", "1") == "0":
            return True
        home, repo, main = os.environ["FACTORY_HOME"], os.environ["FACTORY_REPO"], os.environ["FACTORY_MAIN"]
        c, ref = home + "/control", "origin/" + main
        rc, err = self._cap(["git", "-C", repo, "fetch", "-q", "origin", main])
        if rc != 0:
            self.why = err
            return False
        if not os.path.exists(c + "/.git"):
            os.makedirs(home, exist_ok=True)
            rc, err = self._cap(["git", "-C", repo, "worktree", "add", "-q", "--detach", c, ref])
            if rc != 0:
                self.why = err
                return False
        _, head = self._cap(["git", "-C", c, "rev-parse", "HEAD"], err=DEVNULL)
        _, want = self._cap(["git", "-C", repo, "rev-parse", ref], err=None)
        if head == want:
            _, st = self._cap(["git", "-C", c, "status", "--porcelain"], err=DEVNULL)
            if st == "":
                return True
        # a pipeline running inside the control checkout may hold index.lock for a moment: retry;
        # a lock nobody can still hold is removed first
        for attempt in (1, 2, 3):
            self.clear_stale_lock(c)
            # core.longpaths: node_modules a run left behind passes Windows' 260 characters, and clean would fail on it
            rc, err = self._cap(["git", "-C", c, "-c", "core.longpaths=true", "reset", "-q", "--hard", ref])
            if rc == 0:
                rc, err = self._cap(["git", "-C", c, "-c", "core.longpaths=true", "clean", "-qfdx"])
                if rc == 0:
                    return True
            if attempt != 3:
                time.sleep(float(os.environ.get("SHIPFLOOR_LOCK_RETRY_S") or 5))
        self.why = err
        return False

    def validate(self):
        """The config is valid and every pattern works with grep -E."""
        r = project.cfg("validate")
        _flush()
        sys.stdout.buffer.write(r.stdout)
        sys.stderr.buffer.write(r.stderr)
        sys.stdout.buffer.flush()
        sys.stderr.buffer.flush()
        if r.returncode != 0:
            return False
        p = project.cfg("patterns")
        sys.stderr.buffer.write(p.stderr)
        bad = False
        for pat in _t(p.stdout).split("\0")[:-1]:
            try:
                text.ere_match(pat, "")
            except ValueError:
                sys.stderr.write("shipfloor-config: %s: '%s' is not a valid grep -E pattern\n"
                                 % (os.environ["FACTORY_CONFIG"], pat))
                bad = True
        sys.stderr.flush()
        return not bad

    def skip(self, reason):
        """Log it and leave it in the project's home, where the dashboard and doctor look."""
        home = os.environ["FACTORY_HOME"]
        f = os.path.join(home, "SKIPPED")
        why = re.sub(" +", " ", re.sub("[\t\r\n]", " ", reason))
        _say(self.lang, "%s shipfloor: %s: %s; skipped" % (_now(), self.slug, why), err=True)
        os.makedirs(home, exist_ok=True)
        since = ""
        try:
            with open(f, "rb") as h:
                since = _t(h.read()).split("\n")[0].split("\t")[0]
        except OSError:
            pass
        with open(f, "w", encoding="utf-8", newline="\n") as h:  # the first failed cycle's time is kept
            h.write("%s\t%s\n" % (since or _now(), why))
        return 1

    def run(self, repo, wt, main):
        project.use(self.slug, repo, wt or None, main or None)
        main = os.environ["FACTORY_MAIN"]
        if not self.refresh_control():
            reason = "cannot bring the control checkout to origin/" + main
            if self.why:
                lines = self.why.split("\n")
                first = next((l for l in lines if re.match("(fatal|error)", l)), None)
                reason += ": " + (first if first is not None else lines[0])
            return self.skip(reason)
        if not project.snapshot():
            return self.skip("no .shipfloor/factory.yml on origin/" + main)
        if not self.validate():
            return self.skip("invalid .shipfloor/factory.yml on origin/" + main)
        try:
            os.unlink(os.path.join(os.environ["FACTORY_HOME"], "SKIPPED"))
        except OSError:
            pass
        dispatch = os.environ.get("SHIPFLOOR_DISPATCH") or os.path.join(SCRIPTS, "dispatch.sh")
        env = dict(os.environ)
        env.pop("SHIPFLOOR_CYCLE_BASH", None)
        env["FACTORY_CONTROL_REFRESH"] = "0"
        bash = "bash" if os.name != "nt" else proc.native_path(_bash())
        _flush()
        try:
            return _rc(subprocess.run([bash, dispatch], env=env).returncode)
        except OSError as e:
            sys.stderr.write("bash: %s\n" % e)
            return 127


def main(argv):
    """sf.py cycle"""
    return run_cycle(project.shipfloor_home())


def main_project(argv):
    """sf.py cycle-project <slug> <repo> <worktrees> <main> [--lang <language>]"""
    lang = ""
    if "--lang" in argv:
        i = argv.index("--lang")
        lang = argv[i + 1] if i + 1 < len(argv) else ""
        argv = argv[:i] + argv[i + 2:]
    if len(argv) != 4:
        sys.stderr.write("usage: sf.py cycle-project <slug> <repo> <worktrees> <main> [--lang <language>]\n")
        return 2
    slug, repo, wt, main_branch = argv
    return Project(slug, lang).run(repo, wt, main_branch)
