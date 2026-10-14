"""Stack slots: each run that needs the local stack leases a slot, which gives it a port range and its own compose
project. What scripts/lib/stack.sh did, behaving the same (the files under <home>/locks, the messages, exit 3); that
file is now a shim of Bash functions running `sf.py stack <command>`.

The shim hands this shell's settings over in SHIPFLOOR_STACK_SETTINGS (the 15 values stack_settings sets, each ended
by \\x1f), so a caller that changed one of them in its shell is heard; without it the settings are read from the
configs. SHIPFLOOR_STACK_PID is the pid a ticket names (the shim's $$): the process that waits in the queue."""
import datetime
import os
import re
import shutil
import signal
import subprocess
import sys
import time

from . import proc, project

FIELDS = ("STACKS", "BASE", "SPAN", "WAIT", "STALE", "HOLD", "NAME", "UP", "DOWN", "PORTS", "URL", "HEALTH",
          "REJECT", "TIMEOUT", "SOLO")
SETTINGS_ENV = "SHIPFLOOR_STACK_SETTINGS"
PID_ENV = "SHIPFLOOR_STACK_PID"
BEAT_EVERY = 15  # seconds between two touches of a slot's beat file
_SF = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sf.py")
_ENV_LINE = re.compile(r"SHIPFLOOR_(SLOT|STACK|STACK_URL|PORT_[A-Z0-9]+)=")
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_INT = re.compile(r"-?[0-9]+")
_T0 = time.monotonic()
USAGE = ("usage: sf.py stack <settings|slot-state|fill-ports|slot-env|free-range|slot-down|slot-release|"
         "slot-reclaim|solo-busy|queue-ticket|lease|up|down|release-run|status|heartbeat> [args]")


class Interrupted(Exception):
    """INT or TERM reached a command that waits or holds a slot."""


def _seconds():
    """Whole seconds since this process started (Bash's $SECONDS)."""
    return int(time.monotonic() - _T0)


def _int(value, default=0):
    """A number as Bash arithmetic reads a plain integer; anything else is the default."""
    value = (value or "").strip()
    return int(value) if _INT.fullmatch(value) else default


def _windows():
    return sys.platform.startswith("win") or sys.platform == "cygwin"


def _err(msg):
    sys.stdout.flush()
    print(msg, file=sys.stderr, flush=True)


def _err_bytes(data):
    if data:
        sys.stdout.flush()
        sys.stderr.flush()
        sys.stderr.buffer.write(data)
        sys.stderr.buffer.flush()


def _read(path):
    """The file's text, or None when it cannot be read."""
    try:
        with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
            return f.read()
    except OSError:
        return None


def _read_line(path, fields, strict=False):
    """What `read -r a b c < path` sets: the first line split on blanks, the last field taking the rest (missing ones
    empty). None when the file cannot be read, or, with strict, when it holds no newline (read then fails)."""
    content = _read(path)
    if content is None or (strict and "\n" not in content):
        return None
    parts = content.split("\n", 1)[0].split(None, fields - 1)
    return parts + [""] * (fields - len(parts))


def _write(path, data):
    with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
        f.write(data)


def _touch(path):
    try:
        with open(path, "a"):
            pass
        os.utime(path, None)
    except OSError:
        pass


def _entries(directory):
    """`ls <dir> | sort`: the names in the directory, dot files left out."""
    try:
        return sorted(n for n in os.listdir(directory) if not n.startswith("."))
    except OSError:
        return []


def _alive(pid):
    """`kill -0 <pid>`: the process exists and can be signalled."""
    pid = (pid or "").strip()
    if not _INT.fullmatch(pid):
        return False
    if _windows():  # the pid is the shell's own (MSYS), which only its kill knows; os.kill would end the process
        return subprocess.run(["bash", "-c", 'kill -0 "$1"', "_", pid], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, OverflowError, ValueError):
        return False


def _kill(pid):
    """`kill <pid>` (TERM), quiet."""
    pid = (pid or "").strip()
    if not _INT.fullmatch(pid):
        return
    try:
        os.kill(int(pid), signal.SIGTERM)
    except (OSError, OverflowError, ValueError):
        pass


def locks():
    return os.path.join(project.shipfloor_home(), "locks")


def slot_dir(k):
    return os.path.join(locks(), "stack-%s.lock" % k)


def _queue():
    return os.path.join(locks(), "stack-queue")


class Settings:
    """Machine and project settings: STACKS BASE SPAN WAIT STALE HOLD NAME UP DOWN PORTS URL HEALTH REJECT TIMEOUT
    SOLO, as strings (as the shell holds them)."""

    def __init__(self, values):
        for name, value in zip(FIELDS, values):
            setattr(self, name, value)

    def values(self):
        return [getattr(self, name) for name in FIELDS]

    def stacks(self):
        return _int(self.STACKS)

    def port(self, k, i):
        return _int(self.BASE) + int(k) * _int(self.SPAN) + i

    def ports(self):
        return self.PORTS.split()


def _values(r):
    """The NUL-separated values a config query printed (what `mapfile -d ''` reads)."""
    _err_bytes(r.stderr)
    out = r.stdout.decode("utf-8", "surrogateescape").split("\0")
    if out and out[-1] == "":
        out.pop()
    return out


def read_settings():
    """The settings from the machine config and the resolved project's config. Fail open: a broken or missing
    config gives the defaults, and a project without an up command shares one stack, one run at a time (solo)."""
    if not os.environ.get("FACTORY_CONFIG"):
        try:
            project.resolve(".")
        except project.ProjectError:
            pass
    m = _values(project.machine("values", "stacks", "ports.base", "ports.span", "stack_wait", "stack_stale",
                                "stack_hold_max"))
    p = _values(project.cfg("values", "project.name", "stack.up", "stack.down", "stack.ports", "stack.url",
                            "stack.health", "stack.reject", "stack.timeout"))
    m += [""] * (6 - len(m))
    p += [""] * (8 - len(p))
    s = Settings([m[0] or "3", m[1] or "20000", m[2] or "20", os.environ.get("FACTORY_STACK_WAIT") or m[3] or "1800",
                  m[4] or "90", m[5] or "2700", p[0] or "project", p[1], p[2], p[3], p[4], p[5], p[6], p[7] or "300",
                  "-"])
    if not s.UP:
        s.SOLO = s.NAME
    for d in (_queue(), os.path.join(project.shipfloor_home(), "logs")):
        os.makedirs(d, exist_ok=True)
    return s


def settings():
    """The shell's settings when the shim passed them, else the configs'."""
    given = os.environ.get(SETTINGS_ENV, "")
    if given:
        values = given.split("\x1f")
        if len(values) >= len(FIELDS):
            return Settings(values[:len(FIELDS)])
    return read_settings()


def slot_state(s, k):
    """"free", "busy" or "stuck <reason>"."""
    d = slot_dir(k)
    now = int(time.time())
    if not os.path.isdir(d):
        return "free"
    info = _read_line(os.path.join(d, "info"), 3, strict=True)
    if info is None:
        return "stuck no-info"
    _owner, run, epoch = info
    try:
        beat = int(os.stat(os.path.join(d, "beat")).st_mtime)
    except OSError:
        beat = _int(epoch)
    run = run or "-"
    # a lease owned by a run lives as long as that run; the heartbeat only guards leases without one
    if run != "-" and not os.path.isdir(run):
        return "stuck run-ended"
    if run == "-" and now - beat > _int(s.STALE):
        return "stuck heartbeat"
    if now - _int(epoch) > _int(s.HOLD):
        return "stuck hold-max"
    return "busy"


def fill_ports(s, k, template):
    """{name} -> that port of slot k."""
    out = template
    for i, name in enumerate(s.ports()):
        out = out.replace("{%s}" % name, str(s.port(k, i)))
    return out


def slot_vars(s, k):
    """The slot's environment for up, down, tests and agents, in order: [(name, value)]. A port name that makes no
    shell identifier is kept here; whoever exports the list skips it, as the shell refused it."""
    out = [("SHIPFLOOR_SLOT", str(k)), ("SHIPFLOOR_STACK", "shipfloor-%s-%s" % (s.NAME, k))]
    out += [("SHIPFLOOR_PORT_" + name.upper(), str(s.port(k, i))) for i, name in enumerate(s.ports())]
    out.append(("SHIPFLOOR_STACK_URL", fill_ports(s, k, s.URL)))
    return out


def _run_quiet(argv):
    try:
        return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None


def free_range(s, k):
    """Stop what still listens on the slot's ports; Docker's own processes are left to `down`."""
    lo, hi = s.port(k, 0), _int(s.BASE) + (int(k) + 1) * _int(s.SPAN) - 1
    if shutil.which("netstat.exe"):
        r = _run_quiet(proc.script_argv("netstat.exe", "-ano"))
        pids = set()
        for line in (r.stdout.decode("utf-8", "replace") if r else "").splitlines():
            f = line.split()
            if len(f) >= 5 and f[0] == "TCP" and f[3] == "LISTENING":
                port = f[1].split(":")[-1]
                if port.isdigit() and lo <= int(port) <= hi:
                    pids.add(f[4])
        for pid in sorted(pids):
            r = _run_quiet(proc.script_argv("tasklist.exe", "//FI", "PID eq %s" % pid, "//FO", "CSV", "//NH"))
            out = r.stdout.decode("utf-8", "replace") if r else ""
            name = "\n".join(line.split(",")[0].replace('"', "") for line in out.split("\n")).rstrip("\n")
            if name == "" or re.match(r"(com\.docker|docker|vpnkit|wslrelay)", name):
                continue
            _run_quiet(proc.script_argv("taskkill.exe", "//PID", pid, "//F"))
    elif shutil.which("lsof"):
        r = _run_quiet(["lsof", "-nP", "-iTCP:%d-%d" % (lo, hi), "-sTCP:LISTEN", "-Fpc"])
        pids, p = [], ""
        for line in (r.stdout.decode("utf-8", "replace") if r else "").splitlines():
            if line.startswith("p"):
                p = line[1:]
            if line.startswith("c") and not re.match(r"c(com\.docker|docker|vpnkit)", line):
                pids += p.split()
        if pids:  # the kill program, as xargs ran it: -9 to every pid at once
            _run_quiet(["kill", "-9", *pids])


# the slot's own stored down command (it may be another project's), with the slot's env, from the slot's cwd
_DOWN = 'set -a; . "$1/env" 2>/dev/null; set +a; { cd "$(cat "$1/cwd" 2>/dev/null)" 2>/dev/null || cd /; }; bash -c "$(cat "$1/down")"'


def slot_down(s, k):
    """Run the slot's stored down command, then free its ports."""
    d = slot_dir(k)
    try:
        has_down = os.path.getsize(os.path.join(d, "down")) > 0
    except OSError:
        has_down = False
    if has_down:
        subprocess.run(["bash", "-c", _DOWN, "_", d], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env=_child_env())
    free_range(s, k)


def slot_release(k, reason=""):
    """Stop the slot's heartbeat (unless it is the one found dead) and drop the lock."""
    d = slot_dir(k)
    if reason != "heartbeat":
        pid = _read_line(os.path.join(d, "beat.pid"), 1, strict=True)
        if pid:
            _kill(pid[0])
    shutil.rmtree(d, ignore_errors=True)


def slot_reclaim(s, k, reason):
    owner = "?"
    info = os.path.join(slot_dir(k), "info")
    if os.path.isfile(info):
        owner = (_read_line(info, 2) or [""])[0]
    stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    try:
        with open(os.path.join(project.shipfloor_home(), "logs", "stacks.log"), "a", encoding="utf-8",
                  newline="\n") as f:
            f.write("%s reclaimed slot %s from %s %s\n" % (stamp, k, owner or "?", reason))
    except OSError:
        pass
    slot_down(s, k)
    slot_release(k, reason)


def solo_busy(s, name):
    """True when a live slot is held by a run of that no-up project."""
    for k in range(s.stacks()):
        solo = _read(os.path.join(slot_dir(k), "solo"))
        if solo is not None and solo.rstrip("\n") == name and slot_state(s, k) == "busy":
            return True
    return False


def _nap():
    """0.1 s, through the sleep program as the shell did (the tests count its calls)."""
    try:
        subprocess.run(["sleep", "0.1"])
    except OSError:
        time.sleep(0.1)


def _owner_pid():
    return os.environ.get(PID_ENV) or str(os.getpid())


def queue_ticket(s, owner):
    """Write the owner's ticket, named by the next sequence taken under a mkdir lock; returns its path."""
    q = _queue()
    lock = os.path.join(q, ".lock")
    tries = 0
    while True:
        try:
            os.mkdir(lock)
            break
        except OSError:
            pass
        tries += 1
        if tries >= 50:
            try:
                os.rmdir(lock)
            except OSError:
                pass
            tries = 0
        _nap()
    top = 0
    for name in _entries(q):
        n = re.sub(r"[^0-9]", "", name.split("-", 1)[0])
        if n and int(n) > top:
            top = int(n)
    t = os.path.join(q, "%019d-%s" % (top + 1, owner))
    _write(t, "%s %s %s\n" % (_owner_pid(), os.environ.get("SHIPFLOOR_RUN_LOCK") or "-", s.SOLO))
    try:
        os.rmdir(lock)
    except OSError:
        pass
    return t


def _rm(path):
    try:
        os.unlink(path)
    except OSError:
        pass


class _Held:
    """What an interrupted command gives back: its ticket, the slot it leased."""
    ticket = None
    slot = None


def lease(s, owner, held=None):
    """Slots go to tickets in order (a no-up project's second run is skipped while its first runs), up to WAIT seconds
    on the clock. Returns the slot, or None when it gave up (3)."""
    held = held or _Held()
    q = _queue()
    deadline = _seconds() + _int(s.WAIT)
    note = _seconds()
    me = _owner_pid()
    held.ticket = queue_ticket(s, owner)
    mine = os.path.basename(held.ticket)
    while True:
        for name in _entries(q):  # tickets of waiters or runs that are gone leave the queue
            f = os.path.join(q, name)
            if not os.path.isfile(f):
                continue
            pid, run, _ = _read_line(f, 3) or ["", "", ""]
            if not _alive(pid or "0") or ((run or "-") != "-" and not os.path.isdir(run)):
                _rm(f)
        if not _alive(me):  # the shell that waits is gone: nobody would take the slot
            _rm(held.ticket)
            return None
        head = None
        for name in _entries(q):  # the first ticket not blocked by its own project's running slot
            fields = _read_line(os.path.join(q, name), 3, strict=True)
            if fields is None:
                continue
            solo = fields[2] or "-"
            if solo != "-" and solo_busy(s, solo):
                continue
            head = name
            break
        if head == mine:
            for k in range(s.stacks()):
                st = slot_state(s, k)
                if st.startswith("stuck "):
                    slot_reclaim(s, k, st[len("stuck "):])
                d = slot_dir(k)
                try:
                    os.mkdir(d)
                except OSError:
                    continue
                held.slot = k
                if s.SOLO != "-":
                    _write(os.path.join(d, "solo"), s.SOLO + "\n")
                _write(os.path.join(d, "info"), "%s %s %d\n" % (owner, os.environ.get("SHIPFLOOR_RUN_LOCK") or "-",
                                                                int(time.time())))
                _touch(os.path.join(d, "beat"))
                _rm(held.ticket)
                held.ticket = None
                return k
        if _seconds() >= deadline:
            _rm(held.ticket)
            held.ticket = None
            _err("stack: no free slot after %ss" % s.WAIT)
            return None
        if _seconds() >= note:
            note = _seconds() + 60
            names = _entries(q)
            pos = str(names.index(mine) + 1) if mine in names else ""
            _err("stack: waiting, position %s of %d" % (pos, len(names)))
        time.sleep(1)


def _child_env(extra=()):
    env = {k: v for k, v in os.environ.items() if k not in (SETTINGS_ENV, PID_ENV)}
    env.update(extra)
    return env


def _pwd():
    """The shell's working directory as `pwd` prints it."""
    here = os.getcwd()
    logical = os.environ.get("PWD", "")
    try:
        if logical and os.path.samefile(logical, here):
            return logical
    except OSError:
        pass
    return here


def start_heartbeat(d):
    """A detached child that touches <d>/beat every BEAT_EVERY seconds while <d> exists: its own session, HUP
    ignored, from /, no inherited fd. Returns its pid."""
    kw = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True,
              cwd=os.path.abspath(os.sep), env=_child_env())
    if _windows():
        kw["creationflags"] = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess,
                                                                                   "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kw["start_new_session"] = True
    hup = getattr(signal, "SIGHUP", None)
    saved = signal.signal(hup, signal.SIG_IGN) if hup else None  # ignored from its first instant on (exec keeps it)
    try:
        return subprocess.Popen([sys.executable, "-I", _SF, "stack", "heartbeat", d], **kw).pid
    finally:
        if hup:
            signal.signal(hup, saved)


def heartbeat(d):
    """The heartbeat's loop (see start_heartbeat). It looks for <d> every second, so it ends soon after the lock."""
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    try:
        os.chdir(os.path.abspath(os.sep))
    except OSError:
        pass
    beat = os.path.join(d, "beat")
    while os.path.isdir(d):
        _touch(beat)
        for _ in range(BEAT_EVERY):
            time.sleep(1)
            if not os.path.isdir(d):
                return 0
    return 0


def _tail(path, n=20):
    """`tail -n 20 <path> >&2`."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return
    lines = data.splitlines(keepends=True)
    _err_bytes(b"".join(lines[-n:]))


def _healthy(s, health, env, deadline):
    """One probe: no health URL, or curl fetched it (-f) and the body does not match REJECT."""
    body = ""
    if health:
        m = max(1, min(5, deadline - _seconds()))
        try:
            r = subprocess.run(["curl", "-fsS", "-m", str(m), health], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=env)
        except OSError:
            return False
        if r.returncode != 0:
            return False
        body = r.stdout.decode("utf-8", "surrogateescape").rstrip("\n")
    if not s.REJECT:
        return True
    # grep itself rather than text.ere_match: a pattern grep refuses must print grep's complaint and count as healthy
    # (`! grep -Eq` is true on exit 2), as it did in Bash
    r = subprocess.run(["grep", "-Eq", "--", s.REJECT], input=body.encode("utf-8", "surrogateescape"),
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    _err_bytes(r.stderr)
    return r.returncode != 0


def up(s, owner, held=None, export=None):
    """Lease, clean the range, up, wait for health up to TIMEOUT seconds on the clock. Returns the URL, or None
    (3: infrastructure). export: a file that gets SLOT=<k> and the slot's variables, one NAME=value per line."""
    held = held or _Held()
    k = lease(s, owner, held)
    if k is None:
        return None
    d = slot_dir(k)
    pairs = slot_vars(s, k)
    env = _child_env((n, v) for n, v in pairs if _IDENT.fullmatch(n))
    if export:
        _write(export, "SLOT=%s\n" % k + "".join("%s=%s\n" % p for p in pairs))
    _write(os.path.join(d, "env"), "".join("%s=%s\n" % (n, v) for n, v in env.items()
                                           if _ENV_LINE.match("%s=" % n) and "\n" not in v))
    _write(os.path.join(d, "down"), s.DOWN)
    _write(os.path.join(d, "cwd"), _pwd() + "\n")
    _write(os.path.join(d, "beat.pid"), "%d\n" % start_heartbeat(d))
    slot_down(s, k)
    url = dict(pairs)["SHIPFLOOR_STACK_URL"]
    if s.UP:
        with open(os.path.join(d, "up.log"), "wb") as log:
            rc = subprocess.run(["bash", "-c", s.UP], stdout=log, stderr=subprocess.STDOUT, env=env).returncode
        if rc != 0:
            _err("stack: up failed:")
            _tail(os.path.join(d, "up.log"))
            _give_back(s, held)
            return None
        health = fill_ports(s, k, s.HEALTH)
        deadline = _seconds() + _int(s.TIMEOUT)
        while True:
            if _healthy(s, health, env, deadline):
                break
            if _seconds() >= deadline:
                _err("stack: not healthy after %ss at %s" % (s.TIMEOUT, health))
                _tail(os.path.join(d, "up.log"))
                _give_back(s, held)
                return None
            time.sleep(1)
    held.slot = None
    return url or s.URL


def _give_back(s, held):
    if held.slot is not None:
        k, held.slot = held.slot, None
        slot_down(s, k)
        slot_release(k)


def down(s, owner):
    """Down, free the range, release every slot <owner> holds; nothing when it holds none."""
    for k in range(s.stacks()):
        info = os.path.join(slot_dir(k), "info")
        fields = _read_line(info, 2, strict=True) if os.path.isfile(info) else None
        if fields and fields[0] == owner:
            slot_down(s, k)
            slot_release(k)


def release_run(s, run):
    """Release every slot a finished run still holds."""
    base = locks()
    for name in _entries(base):
        if not (name.startswith("stack-") and name.endswith(".lock")):
            continue
        info = os.path.join(base, name, "info")
        if not os.path.isfile(info):
            continue
        held_by = (_read_line(info, 3) or ["", "", ""])[1]
        same = held_by == run
        if not same and held_by and run:
            try:
                same = os.path.samefile(held_by, run)
            except OSError:
                same = False
        if same:
            k = name[len("stack-"):-len(".lock")]
            slot_down(s, k)
            slot_release(k)


def status(s):
    """One line per slot: k state owner held_s reason; then the queue length."""
    now = int(time.time())
    out = []
    for k in range(s.stacks()):
        st = slot_state(s, k)
        owner, epoch = "-", str(now)
        info = os.path.join(slot_dir(k), "info")
        if os.path.isfile(info):
            fields = _read_line(info, 3)
            if fields is not None:
                owner, epoch = fields[0], fields[2]
        state = st.split(" ", 1)[0]
        reason = st[len("stuck "):] if state == "stuck" else ""
        out.append("%d\t%s\t%s\t%d\t%s\n" % (k, state, owner or "-", now - _int(epoch or str(now)), reason))
    out.append("queue\t%d\n" % len(_entries(_queue())))
    return "".join(out)


def _on_signal(signum, frame):
    raise Interrupted()


def _guarded(s, fn):
    """Run fn(held) with INT and TERM handled: the ticket goes, a slot taken is downed and given back, exit 3."""
    held = _Held()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, _on_signal)
    try:
        return fn(held)
    except Interrupted:
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        if held.ticket:
            _rm(held.ticket)
        if held.slot is not None:
            k = held.slot
            slot_down(s, k)
            slot_release(k)
        return 3


def main(args):
    if not args:
        _err(USAGE)
        return 2
    cmd, rest = args[0], args[1:]
    if cmd == "heartbeat" and len(rest) == 1:
        return heartbeat(rest[0])
    if cmd == "settings":
        sys.stdout.write("".join(v + "\0" for v in read_settings().values()))
        return 0
    one = {"slot-state", "slot-env", "free-range", "slot-down", "solo-busy", "queue-ticket", "lease", "down",
           "release-run"}
    if not ((cmd in one and len(rest) == 1) or (cmd == "fill-ports" and len(rest) == 2)
            or (cmd == "slot-release" and len(rest) in (1, 2)) or (cmd == "slot-reclaim" and len(rest) == 2)
            or (cmd == "status" and not rest) or (cmd == "up" and len(rest) in (1, 3) and
                                                  (len(rest) == 1 or rest[0] == "--export"))):
        _err(USAGE)
        return 2
    s = settings()
    if cmd == "slot-state":
        print(slot_state(s, rest[0]))
    elif cmd == "fill-ports":
        sys.stdout.write(fill_ports(s, rest[0], rest[1]))
    elif cmd == "slot-env":
        sys.stdout.write("".join("%s=%s\n" % p for p in slot_vars(s, rest[0])))
    elif cmd == "free-range":
        free_range(s, rest[0])
    elif cmd == "slot-down":
        slot_down(s, rest[0])
    elif cmd == "slot-release":
        slot_release(rest[0], rest[1] if len(rest) > 1 else "")
    elif cmd == "slot-reclaim":
        slot_reclaim(s, rest[0], rest[1])
    elif cmd == "solo-busy":
        return 0 if solo_busy(s, rest[0]) else 1
    elif cmd == "queue-ticket":
        print(queue_ticket(s, rest[0]))
    elif cmd == "lease":
        def _lease(held):
            k = lease(s, rest[0], held)
            if k is None:
                return 3
            print(k, flush=True)
            return 0
        return _guarded(s, _lease)
    elif cmd == "up":
        export, owner = (rest[1], rest[2]) if len(rest) == 3 else (None, rest[0])

        def _up(held):
            url = up(s, owner, held, export)
            if url is None:
                return 3
            print(url, flush=True)
            return 0
        return _guarded(s, _up)
    elif cmd == "down":
        down(s, rest[0])
    elif cmd == "release-run":
        release_run(s, rest[0])
    elif cmd == "status":
        sys.stdout.write(status(s))
    return 0
