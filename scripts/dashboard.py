"""Local dashboard: one page and a JSON API over ~/.aghanim and the Claude Code transcripts of the
factory's runs. Read-only, except the owner's approve and request-changes."""
import argparse, json, os, re, secrets, subprocess, sys, time, webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ in the installed scripts
sys.path.insert(0, str(HERE))
import aghanim_config  # exits with a clear message when PyYAML is missing
from dashboard_cost import LEGACY_STAGES, cost, parse_transcript, parse_ts, rounded
import yaml

RUN_LINE = re.compile(r"^== (start|end) /(?:aghanim|mylos):([a-z]+) (\d+)(?: exit=(\d+))? (\S+)")  # legacy mylos
# The review page inside the dashboard's drawer: the drawer already carries the title and the one
# action, so the embedded page drops its header and takes the dashboard's palette and type.
EMBED_CSS = """<style>
header.top{display:none}
html:root:not([data-x]){--page:#0d1014;--sheet:#151a21;--surface:#1b212a;--ink:#ebe5d5;--muted:#8f8b80;--rule:#262e39;
--linen:#262e39;--linen-ink:#ebe5d5;--display:"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;--body:var(--display)}
@media (prefers-color-scheme:light){html:root:not([data-x]){--page:#e7e7e4;--sheet:#f4f4f2;--surface:#ececea;--ink:#23262b;
--muted:#6b6a66;--rule:#d9d9d4;--linen:#d9d9d4;--linen-ink:#23262b}}
h1,section h2{font-weight:600}
button{background:transparent;color:var(--ink);border-color:var(--rule)}
</style>"""
OWNER_MOVES = {"Spec Review": {"approve": "Ready for Dev", "request-changes": "Ready for Refinement"},
               "Staged": {"approve": "Ready for Prod", "request-changes": "Coding"}}


def read_yaml(path):
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return {}


def bash():
    return os.environ.get("AGHANIM_BASH", "bash")


def gh(*args, input=None):  # through bash, so FACTORY_GH can be a script on Windows too
    # Never --jq: started from Python on Windows, gh crashes on it (0xC0000005). Read JSON with gh_json.
    return subprocess.run([bash(), "-c", 'exec "${FACTORY_GH:-gh}" "$@"', "gh", *args],
                          input=input, capture_output=True, text=True, encoding="utf-8")


def gh_json(*args):
    """(value, None) from a gh call that prints JSON, or (None, error)."""
    r = gh(*args)
    if r.returncode != 0:
        return None, r.stderr.strip() or f"gh exited {r.returncode}"
    try:
        return json.loads(r.stdout or "null"), None
    except ValueError:
        return None, "gh did not print JSON"


class Factory:
    def __init__(self, home, claude_dir):
        self.home, self.claude_dir = Path(home), Path(claude_dir)
        self._transcripts, self._titles, self._blocked, self._reasons = {}, {}, {}, {}

    def projects(self):
        try:
            lines = (self.home / "registry.tsv").read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        return [line.split("\t")[0] for line in lines if line.strip()]

    def pdir(self, p):
        return self.home / "projects" / p

    def config(self, p):
        return read_yaml(self.pdir(p) / "factory.yml")

    def prices(self):
        # the installed copy keeps templates/ next to the scripts; the plugin checkout, one level up
        for f in (self.home / "prices.yml", HERE / "templates" / "prices.yml", HERE.parent / "templates" / "prices.yml"):
            if f.is_file():
                return read_yaml(f)
        return {}

    def transcript(self, path):
        st = path.stat()
        key, hit = (st.st_size, st.st_mtime), self._transcripts.get(path)
        if not hit or hit[0] != key:
            hit = self._transcripts[path] = (key, parse_transcript(path))
        return hit[1]

    def sessions(self, p, issue=None):
        out = []
        for d in (self.claude_dir / "projects").glob(f"*-projects-{p}-control"):
            for f in d.glob("*.jsonl"):
                try:  # Claude Code may delete a transcript under us, or a line may carry a bad time
                    s = self.transcript(f)
                    if s["start"]:
                        parse_ts(s["start"])
                except (OSError, ValueError):
                    continue
                if s["stage"] and s["start"] and issue in (None, s["issue"]):
                    subs = [self.transcript(a) for a in sorted((d / f.stem / "subagents").glob("*.jsonl"))]
                    out.append(dict(s, id=f.stem, subagents=subs))
        return sorted(out, key=lambda s: s["start"] or "")

    def session_cost(self, s, prices):
        parts = [cost(s["tokens"], prices)] + [cost(a["tokens"], prices) for a in s["subagents"]]
        return None if None in parts else sum(parts)

    def runs(self, p, issue=None, day=None):
        """Runs as the dispatcher logged them: == start / == end lines."""
        out = []
        for log in sorted((self.pdir(p) / "logs").glob("*.log")):
            if issue is not None and not re.fullmatch(rf"\d{{4}}-\d\d-\d\d-{issue}-[a-z]+\.log", log.name):
                continue
            if day and not log.name.startswith(day + "-"):
                continue
            with open(log, encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = RUN_LINE.match(line)
                    if not m:
                        continue
                    kind, stage, n, rc, ts = m.groups()
                    if kind == "start":
                        out.append({"stage": LEGACY_STAGES.get(stage, stage), "issue": int(n), "start": ts,
                                    "end": None, "exit": None, "log": log.name})
                    elif out and out[-1]["log"] == log.name and out[-1]["end"] is None:
                        out[-1].update(end=ts, exit=int(rc))
        return out

    def board(self, p):
        f = self.pdir(p) / "board.tsv"
        try:
            lines, age = f.read_text(encoding="utf-8").splitlines(), round(time.time() - f.stat().st_mtime)
        except OSError:
            return {}, None
        return {int(c[0]): c[1] for c in (l.split("\t") for l in lines) if len(c) > 1 and c[0].isdigit()}, age

    def titles(self, p):
        at, known = self._titles.get(p, (0, {}))
        if time.time() - at > 300:
            repo = aghanim_config.dotted(self.config(p), "project.repo")
            issues, _ = gh_json("issue", "list", "--repo", str(repo), "--state", "all", "--limit", "300", "--json", "number,title")
            if isinstance(issues, list):
                known = {i["number"]: i.get("title", "") for i in issues if isinstance(i, dict) and "number" in i}
            self._titles[p] = (time.time(), known)
        return known

    def blocked(self, p):
        """{n: "owner" | "infra"} from the block labels, read at most once a minute."""
        at, known = self._blocked.get(p, (0, {}))
        if time.time() - at > 60:
            repo, known = aghanim_config.dotted(self.config(p), "project.repo"), {}
            for label, kind in (("blocked:infra", "infra"), ("blocked", "owner")):
                issues, _ = gh_json("api", f"repos/{repo}/issues?labels={label}&state=open&per_page=100")
                known.update({i["number"]: kind for i in issues or [] if isinstance(i, dict) and "number" in i})
            self._blocked[p] = (time.time(), known)
        return known

    def stacks(self):
        """Stack slots as lib/stack.sh computes them (gate.sh stack status)."""
        projects = self.projects()
        if not projects:
            return [], 0
        p = projects[0]
        env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)),
                   AGHANIM_HOME=str(self.home))
        r = subprocess.run([bash(), (HERE / "gate.sh").as_posix(), "stack", "status"], env=env, cwd=str(self.pdir(p)),
                           capture_output=True, text=True, encoding="utf-8")
        slots, queue = [], 0
        for line in r.stdout.splitlines():
            f = line.split("\t")
            if f[0] == "queue":
                queue = int(f[1]) if f[1].isdigit() else 0
            elif len(f) >= 4 and f[0].isdigit():
                slots.append({"slot": int(f[0]), "state": f[1], "owner": f[2], "held_s": int(f[3] or 0),
                              "reason": f[4] if len(f) > 4 else ""})
        return slots, queue

    def block_reason(self, p, n):
        """The last issue comment about the block (the skills write the step, the output and what was tried
        there), read at most once a minute per card."""
        at, reason = self._reasons.get((p, n), (0, ""))
        if time.time() - at > 60:
            repo = aghanim_config.dotted(self.config(p), "project.repo")
            comments, _ = gh_json("api", f"repos/{repo}/issues/{n}/comments?per_page=100&sort=created&direction=desc")
            reason = next((c["body"][:1200] for c in comments or []
                           if isinstance(c, dict) and "blocked" in (c.get("body") or "").lower()), "")
            self._reasons[(p, n)] = (time.time(), reason)
        return reason

    def unblock(self, p, n):
        repo = aghanim_config.dotted(self.config(p), "project.repo")
        errors = []
        for label in ("blocked", "blocked:infra"):
            r = gh("api", "-X", "DELETE", f"repos/{repo}/issues/{n}/labels/{label}")
            if r.returncode != 0 and "Label does not exist" not in r.stderr and "404" not in r.stderr:
                errors.append(r.stderr.strip())
        self._blocked.pop(p, None); self._reasons.pop((p, n), None)
        return (502, {"error": "; ".join(errors)}) if errors else (200, {"unblocked": True})

    def reports(self, p, n):
        out = []
        for f in sorted((self.pdir(p) / "reports-wt" / "reports").glob(f"{n}-*/*.json")):
            try:
                r = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            out.append({"file": f.name, "pipeline": r.get("pipeline"), "outcome": r.get("outcome"),
                        "gates": r.get("gates") or {}, "failed_gates": r.get("failed_gates") or r.get("gates_failed") or [],
                        "rounds": r.get("rounds"),
                        "notes": "\n".join(r["notes"]) if isinstance(r.get("notes"), list) else r.get("notes") or ""})
        return out

    def card(self, p, n):
        prices, runs = self.prices(), self.runs(p, issue=n)
        sessions = []
        for s in self.sessions(p, n):
            start = parse_ts(s["start"])
            run = next((r for r in reversed(runs) if r["stage"] == s["stage"]
                        and parse_ts(r["start"]).timestamp() <= start.timestamp() + 120), None)
            c = self.session_cost(s, prices)
            sessions.append({"id": s["id"], "stage": s["stage"], "start": s["start"], "end": s["end"],
                             "tokens": s["tokens"], "cost": None if c is None else round(c, 4),
                             "subagents": [{"tokens": a["tokens"], "cost": cost(a["tokens"], prices)} for a in s["subagents"]],
                             "exit": run and run["exit"], "log": run and run["log"]})
        costs = [s["cost"] for s in sessions]
        columns, _ = self.board(p)
        reports = self.reports(p, n)
        return {"project": p, "issue": n, "title": self.titles(p).get(n, ""), "column": columns.get(n),
                "repo": aghanim_config.dotted(self.config(p), "project.repo"),
                "total": None if None in costs else round(sum(costs), 2), "sessions": sessions, "runs": runs,
                "reports": reports, "review": (self.pdir(p) / "reviews" / f"{n}.html").is_file(),
                "blocked": self.blocked(p).get(n),
                "block_reason": self.block_reason(p, n) if self.blocked(p).get(n) else ""}

    def pool(self):
        m = aghanim_config.merged(read_yaml(self.home / "config.yml"), aghanim_config.MACHINE_DEFAULTS)
        return m["pool"], m["stages"]

    def live(self, p):
        out = []
        for d in (self.pdir(p) / "locks").glob("*-*.lock"):
            m = re.fullmatch(r"([a-z]+)-(\d+)\.lock", d.name)
            if not m:
                continue
            stage, n = m.group(1), int(m.group(2))
            try:
                epoch = int((d / "info").read_text().split()[1])
                started = datetime.fromtimestamp(epoch, timezone.utc).isoformat()
            except (OSError, ValueError, IndexError):
                started = None
            last = [r for r in self.runs(p, issue=n) if r["stage"] == stage][-1:]
            out.append({"project": p, "issue": n, "stage": stage, "started": started,
                        "orphan": bool(last and last[0]["end"])})  # the run ended and left its lock
        return out

    def usage_limited(self):
        for log in self.home.glob("projects/*/logs/*.log"):
            if log.stat().st_mtime > time.time() - 1800:
                text = log.read_text(encoding="utf-8", errors="replace")
                if "hit your session limit" in text[max(0, text.rfind("== start")):]:
                    return True
        return False

    def overview(self):
        size, slots = self.pool()
        prices, today = self.prices(), datetime.now().date().isoformat()
        live, projects, finished, today_cost = [], [], [], 0.0
        for p in self.projects():
            runs = self.live(p)
            live += runs
            per_card = {}
            for s in self.sessions(p):
                c = self.session_cost(s, prices)
                prev = per_card.get(s["issue"], 0.0)
                per_card[s["issue"]] = None if c is None or prev is None else prev + c
                if c and parse_ts(s["start"]).astimezone().date().isoformat() == today:
                    today_cost += c
            running = {r["issue"]: r["stage"] for r in runs if not r["orphan"]}
            columns, age = self.board(p)
            titles, blocked = self.titles(p), self.blocked(p)
            projects.append({"slug": p, "paused": (self.pdir(p) / "PAUSE").exists(), "board_age_s": age,
                             "cards": [{"issue": n, "title": titles.get(n, ""), "column": col,
                                        "cost": rounded(per_card.get(n, 0.0)),
                                        "running": running.get(n), "awaiting": col in OWNER_MOVES,
                                        "blocked": blocked.get(n)}
                                       for n, col in columns.items()]})
            finished += [r for r in self.runs(p, day=today) if r["end"]]
        used = {st: sum(1 for r in live if r["stage"] == st and not r["orphan"]) for st in slots}
        stacks, queue = self.stacks()
        return {"pool": {"size": size, "used": sum(used.values()),
                         "stages": {st: {"slots": slots[st], "running": used[st]} for st in slots}},
                "paused": (self.home / "PAUSE").exists(), "usage_limited": self.usage_limited(),
                "runs": live, "projects": projects, "stacks": stacks, "queue": queue,
                "today": {"runs": len(finished), "ok": sum(r["exit"] == 0 for r in finished),
                          "failed": sum(r["exit"] != 0 for r in finished), "cost": round(today_cost, 2)}}

    def act(self, p, n, action, seen, text, move_only):
        """The owner's approve / request-changes. Moves with gh directly: board.sh move refuses
        owner-only columns on purpose (the agents' guardrail), and an owner path there would be open to agents."""
        cfg = self.config(p)
        owner, num, repo = (aghanim_config.dotted(cfg, k) for k in ("board.owner", "board.number", "project.repo"))
        env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)))
        snap = subprocess.run([bash(), (HERE / "board.sh").as_posix(), "snapshot"], env=env,
                              capture_output=True, text=True, encoding="utf-8")
        if snap.returncode != 0:
            return 502, {"error": "cannot read the board: " + snap.stderr.strip()}
        row = next((c for c in (l.split("\t") for l in snap.stdout.splitlines()) if c[0] == str(n)), None)
        column = row[1] if row else None
        if column not in OWNER_MOVES or column != seen:
            return 409, {"error": f"#{n} is in {column or 'no column'} now", "column": column}
        target = OWNER_MOVES[column][action]
        commented = action == "request-changes" and not move_only
        if commented:
            if not text.strip():
                return 400, {"error": "write what should change"}
            r = gh("issue", "comment", str(n), "--repo", str(repo), "--body-file", "-", input=text)
            if r.returncode != 0:
                return 502, {"error": "comment failed, nothing moved: " + r.stderr.strip()}
        err = self.move(p, owner, num, row[2], target)
        if err:
            return 502, {"error": err, "commented": commented}
        return 200, {"moved_to": target}

    def move(self, p, owner, num, item, target):
        fields, err = gh_json("project", "field-list", str(num), "--owner", owner, "--format", "json")
        if err:
            return "cannot read the board columns: " + err
        status = next((f for f in (fields or {}).get("fields", []) if f.get("name") == "Status"), None)
        if not status:
            return "the board has no Status field"
        try:
            project_id, field_id = (self.pdir(p) / "board-ids").read_text().split()[:2]
        except (OSError, ValueError):
            project, err = gh_json("project", "view", str(num), "--owner", owner, "--format", "json")
            if err:
                return "cannot read the board ids: " + err
            project_id, field_id = project.get("id", ""), status.get("id", "")
        option = next((o["id"] for o in status.get("options", [])
                       if re.sub(r"^[^A-Za-z]+ ", "", o.get("name", "")) == target), None)  # columns carry an owner mark
        if not option:
            return f"no column '{target}' on the board"
        r = gh("project", "item-edit", "--project-id", project_id, "--id", item,
               "--field-id", field_id, "--single-select-option-id", option)
        return None if r.returncode == 0 else "move failed: " + r.stderr.strip()

    def log(self, p, name, start):
        f = self.pdir(p) / "logs" / name
        if not re.fullmatch(r"[\w.-]+\.log", name) or ".." in name or not f.is_file():
            return None
        size = f.stat().st_size
        start = max(0, size - 65536) if start < 0 else min(start, size)
        with open(f, "rb") as fh:
            fh.seek(start)
            return {"text": fh.read(size - start).decode("utf-8", "replace"), "next": size}


class Handler(BaseHTTPRequestHandler):
    factory, token = None, ""

    def log_message(self, *args):
        pass

    def send(self, code, body, kind="application/json", headers=()):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def allowed(self, query=None):
        """The API wants the token in a header, which a page cannot send cross-origin without a preflight
        this server never answers; only the review iframe's GET may carry it in the URL."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        given = self.headers.get("X-Aghanim-Token") or (query or {}).get("t", [""])[0]
        return host in ("127.0.0.1", "localhost") and secrets.compare_digest(given.encode(), self.token.encode())

    def do_GET(self):
        url = urlparse(self.path)
        q, parts = parse_qs(url.query), [unquote(x) for x in url.path.strip("/").split("/")]
        if url.path == "/":
            return self.send(200, (HERE / "dashboard.html").read_bytes(), "text/html; charset=utf-8")
        if not self.allowed(q if parts[0] == "review" else None):
            return self.send(403, {"error": "missing or wrong token"})
        f = self.factory
        known = len(parts) > 2 and parts[2] in f.projects()
        try:
            if parts == ["api", "overview"]:
                return self.send(200, f.overview())
            if known and len(parts) == 4 and parts[:2] == ["api", "card"] and parts[3].isdigit():
                return self.send(200, f.card(parts[2], int(parts[3])))
            if known and len(parts) == 4 and parts[:2] == ["api", "log"]:
                start = q.get("from", ["-1"])[0]
                body = f.log(parts[2], parts[3], int(start) if start.lstrip("-").isdigit() else -1)
                if body:
                    return self.send(200, body)
            if len(parts) == 3 and parts[0] == "review" and parts[1] in f.projects() and parts[2].isdigit():
                page = f.pdir(parts[1]) / "reviews" / f"{parts[2]}.html"
                if page.is_file():
                    html = page.read_bytes()
                    if q.get("embed") == ["1"]:
                        html = html.replace(b"</head>", EMBED_CSS.encode() + b"</head>", 1)
                    # agents write these pages: sandboxed, they get an opaque origin and cannot call the API
                    return self.send(200, html, "text/html; charset=utf-8",
                                     [("Content-Security-Policy", "sandbox allow-scripts")])
        except Exception as e:  # one bad file must not take the page down
            return self.send(500, {"error": f"{type(e).__name__}: {e}"})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        parts = url.path.strip("/").split("/")
        if not self.allowed():
            return self.send(403, {"error": "missing or wrong token"})
        if not (len(parts) == 5 and parts[:2] == ["api", "card"] and parts[2] in self.factory.projects()
                and parts[3].isdigit() and parts[4] in ("approve", "request-changes", "unblock")):
            return self.send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            return self.send(400, {"error": "body is not JSON"})
        try:
            if parts[4] == "unblock":
                return self.send(*self.factory.unblock(parts[2], int(parts[3])))
            self.send(*self.factory.act(parts[2], int(parts[3]), parts[4], body.get("column"),
                                        str(body.get("text", "")), bool(body.get("move_only"))))
        except Exception as e:
            self.send(500, {"error": f"{type(e).__name__}: {e}"})


class Server(ThreadingHTTPServer):
    allow_reuse_address = os.name != "nt"  # on Windows SO_REUSEADDR lets a second server share the port


def main():
    a = argparse.ArgumentParser(prog="aghanim dashboard")
    a.add_argument("--home", required=True)
    a.add_argument("--port", type=int, default=7717)
    a.add_argument("--no-open", action="store_true")
    args = a.parse_args()
    Handler.factory = Factory(args.home, os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    Handler.token = secrets.token_urlsafe(16)
    server = None
    for port in [0] if args.port == 0 else range(args.port, args.port + 10):
        try:
            server = Server(("127.0.0.1", port), Handler)
            break
        except OSError:
            continue
    if not server:
        sys.exit(f"aghanim dashboard: ports {args.port}-{args.port + 9} are taken")
    url = f"http://127.0.0.1:{server.server_address[1]}/?t={Handler.token}"
    print(f"aghanim dashboard: {url}  (Ctrl+C stops it)", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
