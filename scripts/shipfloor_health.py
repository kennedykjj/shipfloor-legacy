"""Health history: one JSON line per dispatcher cycle in <home>/logs/health-<YYYY-MM>.jsonl (the board,
runs against their limits, the machine), and the alerts read back from its last lines.
  record --home H --seconds N --exit N [--overlap]    alerts --home H"""
import argparse, json, os, shutil, sys, time
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in the installed scripts
sys.path.insert(0, str(Path(__file__).resolve().parent))
import shipfloor_config

# stage: (queue column, columns whose cards with no live run it resumes, WIP columns), as dispatch.sh runs them
STAGES = {"refine": ("Ready for Refinement", ("Technical Refinement",), ("Spec Review",)),
          "develop": ("Ready for Dev", ("Coding",), ("Coding", "Validation")),
          "validate": ("Validation", (), ()), "deploy": ("Ready for Prod", (), ())}
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


def snapshot(home, seconds, code, overlap):
    from dashboard import Factory  # here, not at the top: the dashboard imports this module for alerts()
    f = Factory(home, "")
    pool, slots = f.pool()
    paused, limited = (f.home / "PAUSE").exists(), f.usage_limited()
    live = {p: [r for r in f.live(p) if not r["orphan"]] for p in f.projects()}
    used = {st: sum(r["stage"] == st for runs in live.values() for r in runs) for st in slots}
    free_pool = pool - sum(used.values())
    over = [f"{st} {used[st]}/{slots[st]}" for st in slots if used[st] > slots[st]]
    over += [f"pool {sum(used.values())}/{pool}"] if free_pool < 0 else []
    idle, projects = [], {}
    for p, runs in live.items():
        columns, age = f.board(p)
        blocked, busy = f.blocked(p), {r["issue"] for r in runs}
        limits = shipfloor_config.merged(f.config(p), shipfloor_config.DEFAULTS)["limits"]
        stopped = paused or limited or (f.pdir(p) / "PAUSE").exists() or bool(f.skipped(p))

        def waiting(col):
            return sum(c == col and n not in blocked and n not in busy for n, c in columns.items())
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
                       "columns": counts, "blocked": sum(n in columns for n in blocked), "stages": stages}
    stacks, queue = f.stacks()
    return {"ts": datetime.now().astimezone().isoformat(timespec="seconds"),
            "cycle": {"s": seconds, "exit": code, "overlap": overlap},
            "paused": paused, "usage_limited": limited,
            "machine": {"cpu": cpu_percent(), "mem_free_mb": mem_free_mb(),
                        "disk_free_gb": round(shutil.disk_usage(home).free / 2**30, 1)},
            "pool": {"size": pool, "used": sum(used.values())},
            "stages": {st: {"slots": slots[st], "running": used[st]} for st in slots},
            "stacks": {"busy": sum(s["state"] != "free" for s in stacks), "total": len(stacks), "queue": queue},
            "projects": projects, "idle": idle, "over": over}


def alerts(home):
    """What the last cycles say is wrong, as lines for the owner; [] when nothing is."""
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
                out.append(f"{key}: a free slot and cards waiting for {CYCLES} cycles in a row")
    for key in dict.fromkeys(k for c in last for k in c["over"]):
        out.append(f"{key}: more runs than the limit")
    if any(c["cycle"]["overlap"] for c in last):
        out.append("two dispatcher cycles ran at once")
    try:
        every = shipfloor_config.dispatcher_every(shipfloor_config.yaml.safe_load((Path(home) / "config.yml").read_text(encoding="utf-8")))
    except (OSError, ValueError, shipfloor_config.yaml.YAMLError):  # no config, or one the dispatcher itself refuses
        every = shipfloor_config.dispatcher_every(None)
    try:
        late = (datetime.now().astimezone() - datetime.fromisoformat(last[-1]["ts"])).total_seconds() / 60
    except (IndexError, KeyError, ValueError, TypeError):
        late = 0  # no health line yet: nothing to be late
    if late > 1.5 * every:
        out.append(f"no dispatcher cycle for {round(late)} min (it runs every {every})")
    return out


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
