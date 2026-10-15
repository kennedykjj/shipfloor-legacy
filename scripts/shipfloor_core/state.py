"""The factory's state database (#262): <shipfloor home>/state.db, one SQLite per machine, with the runs and the cycles.

Step 1 of the migration: the files stay as they are (dual write); the database gets the same facts, is filled from the
existing run logs and health-*.jsonl by import_files, keeps 90 days and is backed up once a day (maintain).
The database never fails its caller: every public function catches sqlite3.Error and OSError, says it on stderr and
returns False."""
import functools
import glob
import json
import os
import sqlite3
import sys
from datetime import datetime

from . import project

ROW_DAYS = 90
LOG_DAYS = 30
BACKUPS_KEPT = 7

MIGRATIONS = [
    """
    CREATE TABLE IF NOT EXISTS runs (
        id INTEGER PRIMARY KEY,
        project TEXT, card INTEGER, stage TEXT, pid INTEGER,
        started TEXT, started_s INTEGER, ended TEXT, ended_s INTEGER,
        exit INTEGER, outcome TEXT, model TEXT, weight TEXT, runtime TEXT,
        cost_usd REAL, log TEXT,
        UNIQUE(log, started)
    );
    CREATE INDEX IF NOT EXISTS runs_started_s ON runs(started_s);
    CREATE INDEX IF NOT EXISTS runs_project_card ON runs(project, card);
    CREATE TABLE IF NOT EXISTS cycles (
        id INTEGER PRIMARY KEY,
        ts TEXT UNIQUE, ts_s INTEGER, seconds INTEGER, exit INTEGER, overlap INTEGER, data TEXT
    );
    CREATE INDEX IF NOT EXISTS cycles_ts_s ON cycles(ts_s);
    """,
]


def _warn(what, e):
    try:
        sys.stderr.write("state: %s: %s\n" % (what, e))
    except OSError:
        pass


def _safe(fn):
    @functools.wraps(fn)
    def wrapper(*a, **k):
        try:
            return fn(*a, **k)
        except (sqlite3.Error, OSError) as e:
            _warn(fn.__name__, e)
            return False
    return wrapper


def _epoch(iso):
    try:
        return int(datetime.fromisoformat(iso).timestamp())
    except (TypeError, ValueError):
        return None


def migrate(conn):
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    for i in range(version, len(MIGRATIONS)):
        conn.execute("BEGIN IMMEDIATE")
        try:
            # executescript would commit first; run the statements one by one inside our transaction
            for stmt in MIGRATIONS[i].split(";"):
                if stmt.strip():
                    conn.execute(stmt)
            conn.execute("PRAGMA user_version = %d" % (i + 1))
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise


def _connect(home=None):
    home = home or project.shipfloor_home()
    os.makedirs(home, exist_ok=True)
    conn = sqlite3.connect(os.path.join(home, "state.db"), timeout=5, isolation_level=None)
    try:
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute("PRAGMA journal_mode = WAL")
        migrate(conn)
    except Exception:
        conn.close()
        raise
    return conn


def connect(home=None):
    """The connection to <home>/state.db (WAL, migrated); raises sqlite3.Error / OSError when it cannot."""
    return _connect(home)


def _with_conn(home, fn):
    conn = _connect(home)
    try:
        return fn(conn)
    finally:
        conn.close()


def _cost(log, pid, card, started_s, cache=None):
    """The cost of a run: the runs.jsonl lines beside its log with the same pid and card that started after it."""
    path = os.path.join(os.path.dirname(log), "runs.jsonl")
    if cache is not None and path in cache:
        rows = cache[path]
    else:
        rows = []
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(d, dict):
                        rows.append(d)
        except OSError:
            pass
        if cache is not None:
            cache[path] = rows
    total, found = 0.0, False
    for d in rows:
        if str(d.get("pid")) != str(pid) or str(d.get("card")) != str(card):
            continue
        s, c = _epoch(d.get("start")), d.get("cost_usd")
        if s is None or started_s is None or s < started_s or not isinstance(c, (int, float)):
            continue
        total += c
        found = True
    return total if found else None


def _start(conn, project_name, card, stage, pid, started, model, weight, runtime, log):
    conn.execute(
        "INSERT INTO runs (project, card, stage, pid, started, started_s, model, weight, runtime, log) "
        "VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(log, started) DO UPDATE SET project=excluded.project, "
        "card=excluded.card, stage=excluded.stage, pid=excluded.pid, started_s=excluded.started_s, "
        "model=excluded.model, weight=excluded.weight, runtime=excluded.runtime",
        (project_name, card, stage, pid, started, _epoch(started), model or None, weight or None, runtime or None, log))


def _end(conn, log, started, code, outcome, ended, cache=None):
    row = conn.execute("SELECT pid, card, started_s FROM runs WHERE log = ? AND started = ?", (log, started)).fetchone()
    if row is None:
        return
    cost = _cost(log, row[0], row[1], row[2], cache)
    conn.execute("UPDATE runs SET ended=?, ended_s=?, exit=?, outcome=?, cost_usd=? WHERE log = ? AND started = ?",
                 (ended, _epoch(ended), code, outcome, cost, log, started))


def _cycle(conn, line):
    c = line.get("cycle") or {}
    conn.execute("INSERT OR IGNORE INTO cycles (ts, ts_s, seconds, exit, overlap, data) VALUES (?,?,?,?,?,?)",
                 (line.get("ts"), _epoch(line.get("ts")), c.get("s"), c.get("exit"),
                  1 if c.get("overlap") else 0, json.dumps(line)))


@_safe
def run_started(project, card, stage, pid, started, model, weight, runtime, log):
    _with_conn(None, lambda conn: _start(conn, project, card, stage, pid, started, model, weight, runtime, log))
    return True


@_safe
def run_ended(log, started, exit, outcome, ended):
    _with_conn(None, lambda conn: _end(conn, log, started, exit, outcome, ended))
    return True


@_safe
def record_cycle(line):
    _with_conn(None, lambda conn: _cycle(conn, line))
    return True


def _kv(tokens):
    out = {}
    for t in tokens:
        k, sep, v = t.partition("=")
        if sep:
            out[k] = v
    return out


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _import_log(conn, path, project_name, cache):
    open_run = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            if not raw.startswith("== "):
                continue
            t = raw.split()
            if len(t) < 5 or not t[2].startswith("/sf:"):
                continue
            stage, card = t[2][4:], _int(t[3])
            if t[1] == "start":
                kv = _kv(t[5:])
                _start(conn, project_name, card, stage, _int(kv.get("pid")), t[4], kv.get("model"),
                       kv.get("weight"), kv.get("runtime"), path)
                open_run = t[4]
            elif t[1] == "end" and open_run is not None and len(t) >= 6:
                kv = _kv(t[3:])
                _end(conn, path, open_run, _int(kv.get("exit")), kv.get("outcome"), t[5].rstrip(":"), cache)
                open_run = None


def _import(conn, home):
    conn.execute("BEGIN IMMEDIATE")
    try:
        cache = {}
        for path in sorted(glob.glob(os.path.join(home, "projects", "*", "logs", "*.log"))):
            name = os.path.basename(os.path.dirname(os.path.dirname(path)))
            try:
                _import_log(conn, path, name, cache)
            except OSError as e:
                _warn(path, e)
        for path in sorted(glob.glob(os.path.join(home, "logs", "health-*.jsonl"))):
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    for raw in f:
                        try:
                            line = json.loads(raw)
                        except ValueError:
                            continue
                        if isinstance(line, dict) and line.get("ts"):
                            _cycle(conn, line)
            except OSError as e:
                _warn(path, e)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise


@_safe
def import_files(home):
    _with_conn(home, lambda conn: _import(conn, home))
    return True


def _retention(conn, now):
    log_cut = now - LOG_DAYS * 86400
    row_cut = now - ROW_DAYS * 86400
    done = conn.execute("SELECT log FROM runs GROUP BY log HAVING COUNT(*) = SUM(ended_s IS NOT NULL AND ended_s < ?)",
                        (log_cut,)).fetchall()
    for (log,) in done:
        for p in (log, log[:-4] + ".events.jsonl" if log.endswith(".log") else None):
            if p:
                try:
                    os.remove(p)
                except FileNotFoundError:
                    pass
                except OSError as e:
                    _warn(p, e)
    conn.execute("DELETE FROM runs WHERE ended_s IS NOT NULL AND ended_s < ?", (row_cut,))
    conn.execute("DELETE FROM cycles WHERE ts_s IS NOT NULL AND ts_s < ?", (row_cut,))


def _backup(conn, home, now):
    d = os.path.join(home, "backups")
    os.makedirs(d, exist_ok=True)
    target = os.path.join(d, "state-%s.db" % datetime.fromtimestamp(now).strftime("%Y-%m-%d"))
    tmp = target + ".tmp"
    dst = sqlite3.connect(tmp)
    try:
        conn.backup(dst)
        dst.execute("PRAGMA journal_mode = DELETE")  # a single self-contained file, no -wal/-shm beside it
    finally:
        dst.close()
    os.replace(tmp, target)
    for old in sorted(glob.glob(os.path.join(d, "state-*.db")))[:-BACKUPS_KEPT]:
        try:
            os.remove(old)
        except OSError as e:
            _warn(old, e)


@_safe
def maintain(home, now):
    """Once a day (the day's backup marks it): import the files, apply the retention, back the database up."""
    target = os.path.join(home, "backups", "state-%s.db" % datetime.fromtimestamp(now).strftime("%Y-%m-%d"))
    if os.path.exists(target):
        return True
    conn = _connect(home)
    try:
        _import(conn, home)
        _retention(conn, now)
        _backup(conn, home, now)
    finally:
        conn.close()
    return True
