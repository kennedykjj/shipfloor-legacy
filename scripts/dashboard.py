"""Local dashboard: one page and a JSON API over ~/.aghanim and the Claude Code transcripts of the
factory's runs. Read-only, except the owner's approve and request-changes."""
import argparse, json, os, re, secrets, subprocess, sys, time, webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import aghanim_config  # exits with a clear message when PyYAML is missing
import yaml

LEGACY_STAGES = {"refinar": "refine", "desenvolver": "develop", "validar": "validate", "deployar": "deploy"}  # legacy mylos
COMMAND = re.compile(r"<command-name>/(?:aghanim|mylos):([a-z]+)</command-name>\s*<command-args>(\d+)</command-args>")  # legacy mylos
RUN_LINE = re.compile(r"^== (start|end) /(?:aghanim|mylos):([a-z]+) (\d+)(?: exit=(\d+))? (\S+)")  # legacy mylos
TOKEN_KINDS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")
OWNER_MOVES = {"Spec Review": {"approve": "Ready for Dev", "request-changes": "Ready for Refinement"},
               "Staged": {"approve": "Ready for Prod", "request-changes": "Coding"}}


def read_yaml(path):
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return {}


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def parse_transcript(path):
    """The card a session ran for (its first user message is the dispatcher's /aghanim:<stage> <n>)
    and its tokens per model."""
    stage = issue = start = end = None
    first_user, usage = True, {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue  # a run still writing its last line
            start, end = start or o.get("timestamp"), o.get("timestamp") or end
            msg = o.get("message") or {}
            if o.get("type") == "user" and first_user:
                first_user = False
                m = COMMAND.search(text_of(msg.get("content")))
                if m:
                    stage, issue = LEGACY_STAGES.get(m.group(1), m.group(1)), int(m.group(2))
            elif o.get("type") == "assistant" and msg.get("usage"):
                # Claude Code logs one API message once per content block, repeating its usage
                usage[msg.get("id") or len(usage)] = (msg.get("model"), msg["usage"])
    tokens = {}
    for model, u in usage.values():
        cw = u.get("cache_creation") or {}
        kinds = {"input": u.get("input_tokens"), "output": u.get("output_tokens"),
                 "cache_read": u.get("cache_read_input_tokens"),
                 "cache_write_5m": cw.get("ephemeral_5m_input_tokens") if cw else u.get("cache_creation_input_tokens"),
                 "cache_write_1h": cw.get("ephemeral_1h_input_tokens")}
        if not any(kinds.values()):
            continue
        t = tokens.setdefault(model, dict.fromkeys(TOKEN_KINDS, 0))
        for k, v in kinds.items():
            t[k] += v or 0
    return {"stage": stage, "issue": issue, "start": start, "end": end, "tokens": tokens}


def cost(tokens, prices):
    """US$ for {model: {kind: n}}, or None when a model has no price."""
    total = 0.0
    for model, t in tokens.items():
        p = prices.get(model)
        if not p:
            return None
        total += sum(t[k] * p.get(k, 0) for k in TOKEN_KINDS) / 1e6
    return total


def bash():
    return os.environ.get("AGHANIM_BASH", "bash")


def gh(*args, input=None):  # through bash, so FACTORY_GH can be a script on Windows too
    return subprocess.run([bash(), "-c", 'exec "${FACTORY_GH:-gh}" "$@"', "gh", *args],
                          input=input, capture_output=True, text=True, encoding="utf-8")


class Factory:
    def __init__(self, home, claude_dir):
        self.home, self.claude_dir = Path(home), Path(claude_dir)
        self._transcripts, self._titles = {}, {}

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
                s = self.transcript(f)
                if s["stage"] and issue in (None, s["issue"]):
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
            r = gh("issue", "list", "--repo", str(repo), "--state", "all", "--limit", "300",
                   "--json", "number,title", "--jq", '.[] | "\\(.number)\\t\\(.title)"')
            if r.returncode == 0:
                known = {int(a): b for a, _, b in (l.partition("\t") for l in r.stdout.splitlines()) if a.isdigit()}
            self._titles[p] = (time.time(), known)
        return known

    def reports(self, p, n):
        out = []
        for f in sorted((self.pdir(p) / "reports-wt" / "reports").glob(f"{n}-*/*.json")):
            try:
                r = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            out.append({"file": f.name, "pipeline": r.get("pipeline"), "outcome": r.get("outcome"),
                        "gates": r.get("gates") or {}, "failed_gates": r.get("failed_gates") or r.get("gates_failed") or [],
                        "rounds": r.get("rounds"), "notes": r.get("notes", "")})
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
        return {"project": p, "issue": n, "title": self.titles(p).get(n, ""), "column": columns.get(n),
                "repo": aghanim_config.dotted(self.config(p), "project.repo"),
                "total": None if None in costs else round(sum(costs), 2), "sessions": sessions, "runs": runs,
                "reports": self.reports(p, n), "review": (self.pdir(p) / "reviews" / f"{n}.html").is_file()}

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
        try:
            project_id, field_id = (self.pdir(p) / "board-ids").read_text().split()[:2]
        except (OSError, ValueError):
            a = gh("project", "view", str(num), "--owner", owner, "--format", "json", "--jq", ".id")
            b = gh("project", "field-list", str(num), "--owner", owner, "--format", "json",
                   "--jq", '.fields[] | select(.name=="Status") | .id')
            if a.returncode or b.returncode:
                return "cannot read the board ids: " + (a.stderr or b.stderr).strip()
            project_id, field_id = a.stdout.strip(), b.stdout.strip()
        opts = gh("project", "field-list", str(num), "--owner", owner, "--format", "json",
                  "--jq", '.fields[] | select(.name=="Status") | .options[] | "\\(.name)\\t\\(.id)"')
        option = next((i for name, _, i in (l.partition("\t") for l in opts.stdout.splitlines())
                       if re.sub(r"^[^A-Za-z]+ ", "", name) == target), None)  # columns carry an owner mark
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

    def send(self, code, body, kind="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def allowed(self, query):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        given = self.headers.get("X-Aghanim-Token") or query.get("t", [""])[0]
        return host in ("127.0.0.1", "localhost") and secrets.compare_digest(given, self.token)

    def do_GET(self):
        url = urlparse(self.path)
        q, parts = parse_qs(url.query), [unquote(x) for x in url.path.strip("/").split("/")]
        if url.path == "/":
            return self.send(200, (HERE / "dashboard.html").read_bytes(), "text/html; charset=utf-8")
        if not self.allowed(q):
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
                    return self.send(200, page.read_bytes(), "text/html; charset=utf-8")
        except Exception as e:  # one bad file must not take the page down
            return self.send(500, {"error": f"{type(e).__name__}: {e}"})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        parts = url.path.strip("/").split("/")
        if not self.allowed(parse_qs(url.query)):
            return self.send(403, {"error": "missing or wrong token"})
        if not (len(parts) == 5 and parts[:2] == ["api", "card"] and parts[2] in self.factory.projects()
                and parts[3].isdigit() and parts[4] in ("approve", "request-changes")):
            return self.send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            return self.send(400, {"error": "body is not JSON"})
        self.send(*self.factory.act(parts[2], int(parts[3]), parts[4], body.get("column"),
                                    str(body.get("text", "")), bool(body.get("move_only"))))


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
            server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
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
