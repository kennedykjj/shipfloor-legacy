"""Health history: one JSON line per dispatcher cycle in <home>/logs/health-<YYYY-MM>.jsonl (the board,
runs against their limits, the machine), and the alerts read back from its last lines.
  record --home H --seconds N --exit N [--overlap]    alerts --home H"""
import argparse, json, os, re, shlex, shutil, subprocess, sys, time
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in the installed scripts
sys.path.insert(0, str(Path(__file__).resolve().parent))
import shipfloor_config
from shipfloor_core import deps
from shipfloor_core.defaults import STAGES  # stage: (queue column, columns it resumes, WIP columns), as the dispatcher runs them
STOPPED = re.compile(r"^== end /sf:\w+ \d+ exit=\d+ \S+ stopped=(\S+)", re.M)  # a run whose agent did not do its stage
CYCLES = 3  # an alert looks at this many cycles: one cycle with a free slot is the dispatcher's own timing


def cpu_percent():
    if os.name != "nt":
        try:
            return round(100 * os.getloadavg()[0] / (os.cpu_count() or 1))
        except (OSError, AttributeError):
            return None
    import ctypes

    def times():
        idle, kernel, user = ctypes.c_ulonglong(), ctypes.c_ulonglong(), ctypes.c_ulonglong()
        ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user))
        return idle.value, kernel.value + user.value  # kernel time includes idle
    idle0, all0 = times()
    time.sleep(0.25)
    idle1, all1 = times()
    return round(100 * (1 - (idle1 - idle0) / (all1 - all0))) if all1 > all0 else None


def mem_free_mb():
    if os.name == "nt":
        import ctypes

        class Status(ctypes.Structure):
            _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong)] + \
                       [(k, ctypes.c_ulonglong) for k in ("total", "avail", "a", "b", "c", "d", "e")]
        s = Status(length=ctypes.sizeof(Status))
        return s.avail // 2**20 if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(s)) else None
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    except OSError:
        pass
    return None  # shortcut: macOS has no /proc, read vm_stat when a factory runs there


def cgroup_memory():
    """{mem_mb, max_mb} of this process's cgroup (v2), None without a finite memory.max or off Linux."""
    try:
        root = os.environ.get("SHIPFLOOR_CGROUP_ROOT") or "/sys/fs/cgroup"
        path = ""
        for line in Path("/proc/self/cgroup").read_text().splitlines():
            if line.startswith("0::"):
                path = line[3:].strip()
                break
        d = Path(root) / path.strip("/")
        top = (d / "memory.max").read_text().strip()
        if top == "max":
            return None
        return {"mem_mb": int((d / "memory.current").read_text().strip()) // 2**20, "max_mb": int(top) // 2**20}
    except (OSError, ValueError):
        return None


def stopped_today(pdir):
    """Today's runs of a project that ended with `stopped=<why>` on their == end line, counted by why: agents that
    stopped at their first steps (blocked, infra, owner-only) or ended without a report (no-report)."""
    day, out = datetime.now().astimezone().date().isoformat(), {}
    for log in sorted((pdir / "logs").glob(day + "-*.log")):
        try:
            found = STOPPED.findall(log.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        for why in found:
            out[why] = out.get(why, 0) + 1
    return out


def cost_stopped(home, projects):
    """True when today's estimate reached costs.day_stop: the dispatcher starts nothing, as it does paused."""
    try:
        import dashboard_cost
        costs = dashboard_cost.read_costs(home)
        if not costs.get("day_stop") or not projects:
            return False
        claude_dir = os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude"
        spent, base = dashboard_cost.estimate(home, projects[0], claude_dir, costs)
        return bool(dashboard_cost.over(spent, costs, base)["day_stop"])
    except (SystemExit, Exception):  # an unreadable config or transcripts: the dispatcher says so itself
        return False


def snapshot(home, seconds, code, overlap):
    from dashboard import Factory, read_yaml  # here, not at the top: the dashboard imports this module for alerts()
    f = Factory(home, "")
    pool, slots = f.pool()
    paused, limited, gh_limited = (f.home / "PAUSE").exists(), f.usage_limited(), f.github_limited()
    cost_stop = cost_stopped(home, list(f.projects()))
    outside = not shipfloor_config.hours_state(read_yaml(f.home / "config.yml"), shipfloor_config.now())["open"]
    live = {p: [r for r in f.live(p) if not r["orphan"]] for p in f.projects()}
    used = {st: sum(r["stage"] == st for runs in live.values() for r in runs) for st in slots}
    free_pool = pool - sum(used.values())
    over = [f"{st} {used[st]}/{slots[st]}" for st in slots if used[st] > slots[st]]
    over += [f"pool {sum(used.values())}/{pool}"] if free_pool < 0 else []
    cgroup = cgroup_memory()
    if cgroup and cgroup["max_mb"] and cgroup["mem_mb"] * 10 >= cgroup["max_mb"] * 9:
        over.append(f"memory {cgroup['mem_mb']}/{cgroup['max_mb']} MB")
    idle, projects = [], {}
    for p, runs in live.items():
        columns, age = f.board(p)
        blocked, busy = f.blocked(p), {r["issue"] for r in runs}
        limits = shipfloor_config.merged(f.config(p), shipfloor_config.DEFAULTS)["limits"]
        stopped = paused or limited or gh_limited or cost_stop or outside or (f.pdir(p) / "PAUSE").exists() or bool(f.skipped(p))

        record = deps.load(str(f.pdir(p)))

        def held(n):  # the dispatcher starts nothing for a card with an open dependency or one it could not read
            r = record.get(str(n))
            return isinstance(r, dict) and (not r.get("read", True) or bool(deps.open_numbers(r.get("deps"))))

        def waiting(col):
            return sum(c == col and n not in blocked and n not in busy and not held(n) for n, c in columns.items())
        stages = {}
        for st, (queue, resumes, wip_cols) in STAGES.items():
            running, cap, wip = sum(r["stage"] == st for r in runs), (1 if st == "deploy" else 0), limits[st]["wip"]  # cap: deploy is serial per project
            queued, orphans = waiting(queue), sum(waiting(c) for c in resumes)
            room = queued if not wip else max(0, wip - sum(c in wip_cols for c in columns.values()))
            free = min(slots[st] - used[st], free_pool, cap - running if cap else pool)
            stages[st] = {"queue": queued, "orphans": orphans, "running": running, "cap": cap}
            if not stopped and free > 0 and orphans + min(queued, room) > 0:
                idle.append(f"{p}/{st}")
            if cap and running > cap:
                over.append(f"{p}/{st} {running}/{cap}")
        counts = {}
        for col in columns.values():
            counts[col] = counts.get(col, 0) + 1
        projects[p] = {"paused": (f.pdir(p) / "PAUSE").exists(), "skipped": bool(f.skipped(p)), "board_age_s": age,
                       "columns": counts, "blocked": sum(n in columns for n in blocked), "blocked_cards": sorted(n for n, kind in blocked.items() if kind == "owner" and n in columns),
                       "stages": stages, "stopped_runs": stopped_today(f.pdir(p))}
    stacks, queue = f.stacks()
    return {"ts": datetime.now().astimezone().isoformat(timespec="seconds"),
            "cycle": {"s": seconds, "exit": code, "overlap": overlap},
            "paused": paused, "usage_limited": limited, "github_limited": gh_limited, "cost_stop": cost_stop,
            "outside_hours": outside,
            "machine": {"cpu": cpu_percent(), "mem_free_mb": mem_free_mb(),
                        "disk_free_gb": round(shutil.disk_usage(home).free / 2**30, 1)},
            "cgroup": cgroup,
            "pool": {"size": pool, "used": sum(used.values())},
            "stages": {st: {"slots": slots[st], "running": used[st]} for st in slots},
            "stacks": {"busy": sum(s["state"] != "free" for s in stacks), "total": len(stacks), "queue": queue},
            "projects": projects, "idle": idle, "over": over}


def installer():
    """install-dispatcher.sh of the checkout the installed copy came from (recorded in .source), else of this checkout."""
    here = Path(__file__).resolve().parent
    try:
        source = (here / ".source").read_text(encoding="utf-8").strip() or str(here.parent)
    except OSError:
        source = str(here.parent)
    return Path(source) / "installer" / "install-dispatcher.sh"


def registration(bash=None):
    """What the installed registration of the dispatcher says (install-dispatcher.sh --status): {"kind", "pace_s", "limits"},
    kind None when nothing is registered; None where it cannot be read (Windows, no installer, no bash).
    SHIPFLOOR_INSTALLER_STATUS (split like a command line) replaces that command; "none" says there is nothing to read."""
    given = os.environ.get("SHIPFLOOR_INSTALLER_STATUS")
    if given is not None:
        try:
            cmd = None if given.strip() == "none" else shlex.split(given) or None
        except ValueError:
            cmd = None
    elif os.name == "nt":
        cmd = None
    else:
        sh, script = bash or os.environ.get("SHIPFLOOR_BASH") or shutil.which("bash"), installer()
        cmd = [sh, str(script), "--status"] if sh and script.is_file() else None
    if not cmd:
        return None
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode not in (0, 1):  # 1: not registered; anything else is a status it could not give
        return None
    out = {"kind": None, "pace_s": None, "limits": None}
    for line in (l.strip() for l in r.stdout.splitlines()):
        pace = re.fullmatch(r"pace: every (\d+) seconds", line)
        if line.startswith("registered:"):
            out["kind"] = line.split(":", 1)[1].strip() or None
        elif line.startswith("limits:"):
            out["limits"] = line
        elif pace and int(pace.group(1)) > 0:
            out["pace_s"] = int(pace.group(1))
    return out


def registered_every(reg):
    """The minutes between cycles a registration runs at (0.5 for 30 seconds), or None when it does not say."""
    s = (reg or {}).get("pace_s") if (reg or {}).get("kind") else None
    return None if not s else s // 60 if s % 60 == 0 else round(s / 60, 2)


def config_every(home):
    try:
        return shipfloor_config.dispatcher_every(shipfloor_config.yaml.safe_load((Path(home) / "config.yml").read_text(encoding="utf-8")))
    except (OSError, ValueError, shipfloor_config.yaml.YAMLError):  # no config, or one the dispatcher itself refuses
        return shipfloor_config.dispatcher_every(None)


def silence(home, every=None):
    """{"min", "every"} when the newest health line is older than 3x the dispatcher pace, else None. The pace is `every`,
    else the one the installed registration runs at, else dispatcher.every_min of config.yml."""
    logs = sorted((Path(home) / "logs").glob("health-*.jsonl"))
    if not logs:
        return None
    ts = None
    try:
        lines = logs[-1].read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            ts = json.loads(line)["ts"]
            break
        except (ValueError, KeyError, TypeError):  # a line cut short by a cycle that died while writing it
            continue
    try:
        late = (datetime.now().astimezone() - datetime.fromisoformat(ts)).total_seconds() / 60
    except (ValueError, TypeError):
        return None  # no health line yet, or an unreadable timestamp: nothing to be late
    if every is None:
        every = registered_every(registration()) or config_every(home)
    return {"min": late, "every": every} if late > max(3 * every, 3) else None  # 30 s: still 3 min, not 90 s


OVER = re.compile(r"(?:(?P<project>[^/\s]+)/)?(?P<what>[\w-]+) (?P<used>\d+)/(?P<limit>\d+)(?: MB)?")


def findings(home, skip_silence=False, every=None):
    """What the last cycles say is wrong, one dict each, the page words them by key (lang/dashboard.<code>.json, health.*):
    {key: idle, project, stage, cycles}, {key: over_pool | over_memory | over_stage | over_project, used, limit[, stage,
    project]}, {key: over, what} (a limit line this reader does not know), {key: overlap}, {key: silence, min, every}.
    Each also carries `line`, the over limit as the health line wrote it. [] when nothing is wrong."""
    logs = sorted((Path(home) / "logs").glob("health-*.jsonl"))
    if not logs:
        return []
    last = []
    for line in logs[-1].read_text(encoding="utf-8").splitlines()[-CYCLES:]:
        try:
            last.append(json.loads(line))
        except ValueError:  # a line cut short by a cycle that died while writing it
            continue
    out = []
    if len(last) == CYCLES:
        for key in last[0]["idle"]:
            if all(key in c["idle"] for c in last):
                project, _, stage = key.rpartition("/")
                out.append({"key": "idle", "project": project, "stage": stage, "cycles": CYCLES, "line": key})
    for key in dict.fromkeys(k for c in last for k in c["over"]):
        m = OVER.fullmatch(key)
        if not m:
            out.append({"key": "over", "what": key, "line": key})
            continue
        f = {"used": int(m["used"]), "limit": int(m["limit"]), "line": key}
        if m["project"]:
            f.update(key="over_project", project=m["project"], stage=m["what"])
        elif m["what"] in ("pool", "memory"):
            f.update(key="over_" + m["what"])
        else:
            f.update(key="over_stage", stage=m["what"])
        out.append(f)
    if any(c["cycle"]["overlap"] for c in last):
        out.append({"key": "overlap"})
    s = None if skip_silence else silence(home, every)
    if s:
        out.append({"key": "silence", "min": round(s["min"]), "every": s["every"]})
    return out


def text(f):
    """A finding as the English line `shipfloor doctor` prints."""
    if f["key"] == "idle":
        return f"{f['line']}: a free slot and cards waiting for {f['cycles']} cycles in a row"
    if f["key"] == "overlap":
        return "two dispatcher cycles ran at once"
    if f["key"] == "silence":
        return f"no dispatcher cycle for {f['min']} min (it runs every {f['every']})"
    return f"{f['line']}: more runs than the limit"


def alerts(home, skip_silence=False):
    """What the last cycles say is wrong, as English lines for the owner; [] when nothing is."""
    return [text(f) for f in findings(home, skip_silence)]


def main():
    a = argparse.ArgumentParser(prog="shipfloor_health")
    a.add_argument("command", choices=("record", "alerts"))
    a.add_argument("--home", required=True)
    a.add_argument("--seconds", type=int, default=0)
    a.add_argument("--exit", type=int, default=0)
    a.add_argument("--overlap", action="store_true")
    args = a.parse_args()
    if args.command == "alerts":
        print("\n".join(alerts(args.home)))
        return
    line = json.dumps(snapshot(args.home, args.seconds, args.exit, args.overlap), ensure_ascii=False)
    log = Path(args.home) / "logs" / f"health-{datetime.now():%Y-%m}.jsonl"
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(line + "\n")


if __name__ == "__main__":
    main()
