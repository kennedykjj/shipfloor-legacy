"""The failure invariant (#173), as a check a chaos test runs after the failure and the next cycle.

usage: python -I -B chaos_invariant.py [--ttl SECS] [--board FILE] [--no-dashboard] [--no-run-tmp] <home> [<home>...]
  <home>   a SHIPFLOOR_HOME (its projects/<slug>/ are the project homes) or one project home (it has locks/)
  --ttl    the lock TTL in seconds (FACTORY_LOCK_TTL, default 10800)
  --board  the cards, one line each: "<n><TAB><status>[<TAB><label,label>]" (the 👤/🤖 mark on the status is optional)

Prints one line per violation and exits 1; nothing printed and exit 0 when the state holds:
  1. no locks/*.lock whose pid is dead and that is older than the TTL
  2. no card in a WIP column (Technical Refinement, Coding, Validation) with neither a live lock nor a blocked* label
  3. no *.tmp / .*.install-tmp left under a home, and no tmp/<n> folder for a card with no live lock
  4. the dashboard's readers load the home without an exception
Also usable as a module: violations(homes, ttl, board, dashboard) returns the lines.
"""
import glob
import os
import re
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(os.path.dirname(HERE))
WIP = ("Technical Refinement", "Coding", "Validation")
SKIP_DIRS = {".git", "control", "wt", "node_modules", "__pycache__"}


def alive(pid):
    if not re.fullmatch(r"[0-9]+", pid or ""):
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except OSError:  # EPERM: it exists
        return True
    return True


def lock_facts(d):
    """(pid, age in seconds) of a lock dir: info is "pid epoch n"; the age comes from the epoch, else the dir's mtime."""
    pid, epoch = "", ""
    try:
        with open(os.path.join(d, "info"), encoding="utf-8", errors="replace") as f:
            words = f.readline().split()
        pid = words[0] if words else ""
        epoch = words[1] if len(words) > 1 else ""
    except OSError:
        pass
    if re.fullmatch(r"[0-9]+", epoch):
        return pid, time.time() - int(epoch)
    try:
        return pid, time.time() - os.stat(d).st_mtime
    except OSError:
        return pid, 0


def project_homes(home):
    if os.path.isdir(os.path.join(home, "locks")) and not os.path.isdir(os.path.join(home, "projects")):
        return [home]
    return sorted(p for p in glob.glob(os.path.join(glob.escape(home), "projects", "*")) if os.path.isdir(p))


def live_cards(phomes, ttl):
    """The cards with a live lock in any project home: its pid is alive, or it is younger than the TTL."""
    out = set()
    for ph in phomes:
        for d in glob.glob(os.path.join(glob.escape(ph), "locks", "*-[0-9]*.lock")):
            pid, age = lock_facts(d)
            if alive(pid) or age <= ttl:
                out.add(os.path.basename(d).rsplit("-", 1)[1][:-len(".lock")])
    return out


def strip_mark(s):
    return re.sub(r"^[^A-Za-z]+ ", "", s)


def read_board(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) >= 2 and cols[0]:
                rows.append((cols[0], strip_mark(cols[1]), cols[2].split(",") if len(cols) > 2 else []))
    return rows


def dashboard_errors(home):
    """The dashboard's own readers on the home: any exception is a violation."""
    sys.path.insert(0, SCRIPTS)
    try:
        import dashboard
    except Exception as e:  # the module itself must import
        return ["dashboard: cannot be imported: %s: %s" % (type(e).__name__, e)]
    errors = []
    f = dashboard.Factory(home, tempfile.mkdtemp())
    calls = [("projects", f.projects), ("costs", f.costs), ("pool", f.pool), ("github_limited", f.github_limited),
             ("usage_limited", f.usage_limited)]
    try:
        names = f.projects()
    except Exception:
        names = []
    for p in names:
        calls += [("config(%s)" % p, lambda p=p: f.config(p)), ("skipped(%s)" % p, lambda p=p: f.skipped(p)),
                  ("runs(%s)" % p, lambda p=p: f.runs(p))]
    for name, fn in calls:
        try:
            fn()
        except Exception as e:
            errors.append("dashboard: %s raised %s: %s" % (name, type(e).__name__, e))
    return errors


def violations(homes, ttl=10800, board=None, dashboard=True, run_tmp=True):
    out = []
    phomes = []
    for h in homes:
        phomes += project_homes(h)
    live = live_cards(phomes, ttl)
    for ph in phomes:  # 1. a lock nobody holds
        for d in sorted(glob.glob(os.path.join(glob.escape(ph), "locks", "*.lock"))):
            pid, age = lock_facts(d)
            if age > ttl and not alive(pid):
                out.append("stale lock: %s (pid %r dead, %d s old)" % (d, pid, age))
    if board:  # 2. a WIP card nobody works on or blocks
        for n, status, labels in read_board(board):
            if status in WIP and n not in live and not any(l.startswith("blocked") for l in labels):
                out.append("card #%s sits in %s with no live run and no block" % (n, status))
    seen = set(homes) | set(phomes)
    for h in sorted(seen):  # 3. leftovers
        for top, dirs, files in os.walk(h):
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS and not (top == h and x == "tmp"))
            for name in sorted(files + dirs):
                if name.endswith(".tmp") or re.fullmatch(r"\..*\.install-tmp", name):
                    out.append("temp file left: %s" % os.path.join(top, name))
    for ph in phomes if run_tmp else []:
        for d in sorted(glob.glob(os.path.join(glob.escape(ph), "tmp", "[0-9]*"))):
            if os.path.isdir(d) and os.path.basename(d) not in live:
                out.append("tmp/%s left for a card with no live run: %s" % (os.path.basename(d), d))
    if dashboard:  # 4. the owner's view
        for h in homes:
            if os.path.isdir(os.path.join(h, "projects")) or os.path.exists(os.path.join(h, "registry.tsv")):
                out += dashboard_errors(h)
    return out


def main(argv):
    ttl, board, dash, run_tmp, homes = 10800, None, True, True, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--ttl":
            ttl, i = int(argv[i + 1]), i + 1
        elif a == "--board":
            board, i = argv[i + 1], i + 1
        elif a == "--no-dashboard":
            dash = False
        elif a == "--no-run-tmp":
            run_tmp = False
        else:
            homes.append(a)
        i += 1
    if not homes:
        print("usage: chaos_invariant.py [--ttl SECS] [--board FILE] [--no-dashboard] [--no-run-tmp] <home>...",
              file=sys.stderr)
        return 2
    found = violations(homes, ttl, board, dash, run_tmp)
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
