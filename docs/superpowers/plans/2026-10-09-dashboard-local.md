# Local Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aghanim dashboard` serves a local page that shows the pool, live runs, logs, per-card cost from Claude Code transcripts, and the review pages, with approve / request changes.

**Architecture:** One Python stdlib server (`scripts/dashboard.py`) with a `Factory` class whose methods read `~/.aghanim` and the transcripts, a small request handler, and one HTML page (`scripts/dashboard.html`) designed with `/impeccable`. The only writes are the owner's two actions, done with `gh` directly; `board.sh move` keeps refusing owner-only transitions.

**Tech Stack:** Python 3 stdlib + PyYAML (already required), bash, `gh`, plain HTML/CSS/JS.

**Spec:** `docs/superpowers/specs/2026-10-09-dashboard-local-design.md`

## Global Constraints

- No new dependencies, frameworks, build steps or directories; same shape as `review-page.sh` / `review_page.py` / `review-template.html`.
- `dashboard.py` stays under ~400 lines; only then the cost reader moves to `dashboard_cost.py`.
- No options beyond `--port`, `--no-open` and `prices.yml`. No narrating comments, dead code, commented-out code, or emoji in code or UI copy.
- Every line naming `mylos` carries `# legacy mylos` (enforced by `hygiene.test.sh`).
- Binds `127.0.0.1` only; every `/api/*` and `/review/*` request needs the run's token and a `127.0.0.1`/`localhost` Host header.
- Tests: only `scripts/test/dashboard.test.sh`, small fixtures, no git repositories (the owner asked for the minimum).
- Code, comments and UI copy in English.

## Review Focus

Not covered by tests (the owner asked for the minimum); reviewers check them in code:

1. A transcript whose last line is half-written (run in progress) → that line is skipped, never a 500 (`parse_transcript` catches `ValueError`).
2. Claude Code logs one API message once per content block with the same `message.id` and the same `usage` → usage counted once per id, or cost is ~2× (`parse_transcript` keys by id). The cost test pins this one.
3. `<synthetic>` messages with zero usage → not shown as an unpriced model.
4. A project that was never dispatched (no `board.tsv`, no `logs/`) → empty board with the snapshot age shown as missing, no error.
5. `gh` failing in an owner action (network, auth) → 502 with gh's stderr, and nothing moved when the comment failed.

## File Structure

- Create `scripts/dashboard.py` — server, `Factory` readers, owner actions.
- Create `scripts/dashboard.html` — the page (Task 4, with `/impeccable`).
- Create `templates/prices.yml` — default US$ per million tokens; `~/.aghanim/prices.yml` overrides it when present (no install step: the installed copy already carries `templates/`).
- Create `scripts/test/dashboard.test.sh`.
- Modify `scripts/test/fake-gh` — answer `issue comment`.
- Modify `scripts/aghanim` — `dashboard` command and header line.
- Modify `README.md` — one entry under Operation.
- Modify the spec — prices come from the shipped template unless `~/.aghanim/prices.yml` exists (replaces "copied by install").

---

### Task 1: Cost per card from the transcripts

**Files:**
- Create: `templates/prices.yml`, `scripts/dashboard.py`, `scripts/test/dashboard.test.sh`
- Modify: `docs/superpowers/specs/2026-10-09-dashboard-local-design.md` (prices line)

**Interfaces:**
- Produces: `python -I dashboard.py --home H [--port N] [--no-open]` prints `aghanim dashboard: http://127.0.0.1:<port>/?t=<token>  (Ctrl+C stops it)` as its first line. `GET /api/card/<p>/<n>` → `{"project","issue","title","column","repo","total","sessions":[{"id","stage","start","end","tokens":{model:{kind:int}},"cost","subagents":[{"tokens","cost"}],"exit","log"}],"runs","reports","review"}`. `GET /api/log/<p>/<file>?from=<byte>` → `{"text","next"}`; `-1` = last 64 KB. Env: `CLAUDE_CONFIG_DIR` (default `~/.claude`), `AGHANIM_BASH`, `FACTORY_GH`.

- [ ] **Step 1: Write the failing test**

`scripts/test/dashboard.test.sh`:

```bash
#!/usr/bin/env bash
# The local dashboard: what a card cost (from Claude Code transcripts) and the owner's two actions.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$AGHANIM_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"

# card 7: a develop session (two log lines per API message, one subagent), a legacy refine session,
# a manual session in control (ignored) and a half-written last line
T="$C/projects/C--x--aghanim-projects-shop-control"; mkdir -p "$T/s1/subagents"
cmd() { printf '{"type":"user","timestamp":"2026-10-09T10:00:00Z","message":{"role":"user","content":%s}}\n' "$1"; }
ast() { printf '{"type":"assistant","timestamp":"2026-10-09T10:05:00Z","message":{"id":"%s","model":"%s","usage":%s}}\n' "$1" "$2" "$3"; }
U='{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}'
{ cmd '"<command-message>aghanim:develop</command-message>\n<command-name>/aghanim:develop</command-name>\n<command-args>7</command-args>"'
  ast m1 claude-opus-5-5 "$U"; ast m1 claude-opus-5-5 "$U"; printf '{"type":"assistant","mess'; } > "$T/s1.jsonl"
ast a1 claude-sonnet-5-5 '{"input_tokens":0,"output_tokens":1000000}' > "$T/s1/subagents/agent-a.jsonl"
{ cmd '[{"type":"text","text":"<command-name>/mylos:refinar</command-name>\n<command-args>7</command-args>"}]'
  ast m2 claude-haiku-5-5 '{"input_tokens":1000000,"output_tokens":0}'; } > "$T/s2.jsonl"
{ cmd '"hello"'; ast m3 claude-opus-5-5 '{"input_tokens":1000000,"output_tokens":0}'; } > "$T/s3.jsonl"

export CLAUDE_CONFIG_DIR="$(nat "$C")" AGHANIM_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# opus 1M input $4 + 0.1M output $2 + 1M cache read $0.20 + 1M 1h cache write $8 = 14.20, once;
# subagent sonnet 1M output $10; legacy refine haiku 1M input $0.10; the manual session is not the card's
got="$(curl -s "$base/api/card/shop/7?t=$tok" | $PY -c 'import json,sys; c=json.load(sys.stdin); print(c["total"], len(c["sessions"]), ",".join(sorted(s["stage"] for s in c["sessions"])))')"
assert_contains "$got" "24.3 2 develop,refine"
[ "$(code "$base/api/card/shop/7")" = 403 ] && pass "no token, no data" || fail "served without the token"
[ "$(code "$base/api/log/shop/..%2F..%2Fregistry.tsv?t=$tok")" = 404 ] && pass "no path outside logs" || fail "served a file outside logs"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/test/run.sh dashboard.test.sh`
Expected: FAIL — `dashboard.py` does not exist, no URL is printed, the asserts fail.

- [ ] **Step 3: Write the prices and the first half of `dashboard.py`**

`templates/prices.yml`:

```yaml
# US$ per million tokens for the dashboard's cost estimate (Anthropic API list prices).
# Cache writes cost 1.25x input for 5 minutes and 2x for 1 hour; Claude Code writes 1-hour entries.
# To change a price or add a model, copy this file to ~/.aghanim/prices.yml and edit it there.
claude-opus-5-5:   {input: 4.00,  output: 20.00, cache_write_5m: 5.00,  cache_write_1h: 8.00,  cache_read: 0.20}
claude-sonnet-5-5: {input: 2.00,  output: 10.00, cache_write_5m: 2.50,  cache_write_1h: 4.00,  cache_read: 0.20}
claude-haiku-5-5:  {input: 0.10,  output: 0.50,  cache_write_5m: 0.125, cache_write_1h: 0.20,  cache_read: 0.01}
claude-fable-5-1:  {input: 10.00, output: 50.00, cache_write_5m: 12.50, cache_write_1h: 20.00, cache_read: 0.25}
```

`scripts/dashboard.py`:

```python
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
        own = self.home / "prices.yml"
        return read_yaml(own if own.is_file() else HERE / "templates" / "prices.yml")

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
```

In the spec, replace "`templates/prices.yml`: default price table, copied to `~/.aghanim/prices.yml` by `aghanim install` when missing (the owner's edits are kept)." with "`templates/prices.yml`: default price table; `~/.aghanim/prices.yml` replaces it when present."

- [ ] **Step 4: Run the test**

Run: `bash scripts/test/run.sh dashboard.test.sh hygiene.test.sh`
Expected: PASS (`contains 24.3 2 develop,refine`, `no token, no data`, `no path outside logs`, hygiene green).

- [ ] **Step 5: Commit**

```bash
git add templates/prices.yml scripts/dashboard.py scripts/test/dashboard.test.sh docs/superpowers/specs/2026-10-09-dashboard-local-design.md
git commit -m "feat(dashboard): card cost from the Claude Code transcripts"
```

---

### Task 2: Owner actions

**Files:**
- Modify: `scripts/dashboard.py`, `scripts/test/fake-gh`, `scripts/test/dashboard.test.sh`

**Interfaces:**
- Consumes: `Factory`, `gh`, `bash` from Task 1.
- Produces: `POST /api/card/<p>/<n>/approve` and `/request-changes` with JSON `{"column": <column the page saw>, "text": "...", "move_only": false}` → `200 {"moved_to"}`, `400`, `403`, `409 {"error","column"}`, `502 {"error","commented"?}`. `OWNER_MOVES` constant.

- [ ] **Step 1: Write the failing tests**

Add to `scripts/test/fake-gh`, before the `*)` line:

```bash
  "issue comment"*)
    [ -e "$d/fail-comment" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    cat >> "$d/comments" ;;
```

Add to `dashboard.test.sh`, before `finish`:

```bash
# owner actions: the board says 7 is in Spec Review, 8 in Coding, 9 in Staged
printf 'PVTI_7\t7\t👤 Spec Review\nPVTI_8\t8\t🤖 Coding\nPVTI_9\t9\t👤 Staged\n' > "$FAKE_GH_DIR/items.tsv"
post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$@"; }
[ "$(post -d '{"column":"Spec Review"}' "$base/api/card/shop/7/approve")" = 403 ] && pass "no token, no action" || fail "acted without the token"
[ "$(post -d '{"column":"Coding"}' "$base/api/card/shop/8/approve?t=$tok")" = 409 ] && pass "Coding is not the owner's" || fail "approved a card in Coding"
[ ! -e "$FAKE_GH_DIR/edits" ] && pass "nothing moved" || fail "moved a card it should not"
[ "$(post -d '{"column":"Spec Review"}' "$base/api/card/shop/7/approve?t=$tok")" = 200 ] && pass "approved" || fail "approve failed"
assert_contains "$(cat "$FAKE_GH_DIR/edits")" "--id PVTI_7 --field-id FLD_x --single-select-option-id opt5"
[ "$(post -d '{"column":"Staged","text":"fix the header"}' "$base/api/card/shop/9/request-changes?t=$tok")" = 200 ] && pass "changes requested" || fail "request-changes failed"
assert_contains "$(cat "$FAKE_GH_DIR/comments")" "fix the header"
c="$(grep -n '^issue comment 9' "$FAKE_GH_DIR/calls" | cut -d: -f1)"; m="$(grep -n 'item-edit.*PVTI_9.*opt6' "$FAKE_GH_DIR/calls" | cut -d: -f1)"
[ -n "$c" ] && [ -n "$m" ] && [ "$c" -lt "$m" ] && pass "comment first, then back to Coding" || fail "comment $c, move $m"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash scripts/test/run.sh dashboard.test.sh`
Expected: FAIL — POSTs answer 501 (no `do_POST`).

- [ ] **Step 3: Implement**

In `dashboard.py`, after `TOKEN_KINDS`:

```python
OWNER_MOVES = {"Spec Review": {"approve": "Ready for Dev", "request-changes": "Ready for Refinement"},
               "Staged": {"approve": "Ready for Prod", "request-changes": "Coding"}}
```

Add to `Factory`:

```python
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
```

Add to `Handler`:

```python
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
```

- [ ] **Step 4: Run the tests**

Run: `bash scripts/test/run.sh dashboard.test.sh board.test.sh hygiene.test.sh`
Expected: PASS (the `fake-gh` change leaves `board.test.sh` green).

- [ ] **Step 5: Commit**

```bash
git add scripts/dashboard.py scripts/test/fake-gh scripts/test/dashboard.test.sh
git commit -m "feat(dashboard): approve and request changes from the dashboard"
```

---

### Task 3: Overview, `aghanim dashboard` and README

**Files:**
- Modify: `scripts/dashboard.py`, `scripts/aghanim`, `README.md`

**Interfaces:**
- Consumes: `Factory` readers from Task 1.
- Produces: `GET /api/overview` → `{"pool":{"size","used","stages":{stage:{"slots","running"}}},"paused","usage_limited","runs":[{"project","issue","stage","started","orphan"}],"projects":[{"slug","paused","board_age_s","cards":[{"issue","title","column","cost","running","awaiting"}]}],"today":{"runs","ok","failed","cost"}}`. CLI: `aghanim dashboard [--port N] [--no-open]`.

No new test (the owner asked for the minimum): the overview only aggregates readers Task 1 tests, and the check below runs it against the real home.

- [ ] **Step 1: Implement the overview**

Add after `cost()` (module level):

```python
def rounded(usd):
    return None if usd is None else round(usd, 2)
```

Add to `Factory`:

```python
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
            titles = self.titles(p)
            projects.append({"slug": p, "paused": (self.pdir(p) / "PAUSE").exists(), "board_age_s": age,
                             "cards": [{"issue": n, "title": titles.get(n, ""), "column": col,
                                        "cost": rounded(per_card.get(n, 0.0)),
                                        "running": running.get(n), "awaiting": col in OWNER_MOVES}
                                       for n, col in columns.items()]})
            finished += [r for r in self.runs(p, day=today) if r["end"]]
        used = {st: sum(1 for r in live if r["stage"] == st and not r["orphan"]) for st in slots}
        return {"pool": {"size": size, "used": sum(used.values()),
                         "stages": {st: {"slots": slots[st], "running": used[st]} for st in slots}},
                "paused": (self.home / "PAUSE").exists(), "usage_limited": self.usage_limited(),
                "runs": live, "projects": projects,
                "today": {"runs": len(finished), "ok": sum(r["exit"] == 0 for r in finished),
                          "failed": sum(r["exit"] != 0 for r in finished), "cost": round(today_cost, 2)}}
```

- [ ] **Step 2: Add the CLI command**

In `scripts/aghanim`, add to the header after the `pool` line:

```bash
#   dashboard [--port N] [--no-open]  local dashboard: pool, runs, logs, cost per card, reviews
```

Add before `cmd_migrate_home`:

```bash
cmd_dashboard() {  # dashboard [--port N] [--no-open]: serves the local dashboard until Ctrl+C
  AGHANIM_BASH="$(aghanim_native "$BASH")" aghanim_python "$(aghanim_native "$HERE/dashboard.py")" \
    --home "$(aghanim_native "$AGHANIM_HOME")" "$@"
}
```

Add to the command `case`: `  dashboard) cmd_dashboard "$@" ;;`

- [ ] **Step 3: README**

In `README.md` under `## Operation`, change the first line to:

```markdown
`aghanim dashboard` · `aghanim list` · `aghanim pool` · `aghanim pause [project]` · `aghanim resume [project]` · `aghanim remove <project>` · `aghanim metrics <project>`.
```

and add after it: `` `aghanim dashboard` opens a local page with the pool, live runs, logs, the estimated cost of each card and the review pages, where Spec Review and Staged cards are approved or sent back. ``

- [ ] **Step 4: Check against the real home (read-only)**

Run: `bash scripts/aghanim dashboard --no-open --port 0 &` then `curl -s "<printed url with /api/overview?t=...>"` piped to `python -m json.tool | head -40`, then stop the server.
Expected: the pool shows `size: 10` and the per-stage slots, `projects[0].slug == "pickio"`, cards with columns from `board.tsv`, non-null costs on cards that have runs. Then `bash scripts/test/run.sh dashboard.test.sh hygiene.test.sh aghanim-cli.test.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/dashboard.py scripts/aghanim README.md
git commit -m "feat(dashboard): overview and the aghanim dashboard command"
```

---

### Task 4: The page, designed with `/impeccable`

**Files:**
- Create: `scripts/dashboard.html`

**Interfaces:**
- Consumes: the endpoints from Tasks 1–3. The page reads the token from `?t=` and sends it as `X-Aghanim-Token` on every request; POST bodies carry the `column` the page last saw.

- [ ] **Step 1: Invoke `/impeccable`** (the owner's requirement) with this brief, then build the page from its output:

> One self-contained HTML file (inline CSS and JS, no CDN, no build) for developers who run a software factory locally. Dense and exact: monospace for numbers and ids, tabular figures, dark and light themes from `prefers-color-scheme`, nothing decorative, every item links to its source. Layout "control room" (approved mockup): a top strip with pool usage and per-stage slots (`refine 2/3`), today's runs/ok/failed/cost, cards awaiting the owner, factory state (paused, usage limit, orphaned locks) and board snapshot age; below, compact board columns in factory order (Inbox, Ready for Refinement, Technical Refinement, Spec Review, Ready for Dev, Coding, Validation, Staged, Ready for Prod, Done) with each card's number, title, live-run marker, awaiting-owner marker and cost; clicking a card opens a right drawer with issue/PR links, total cost, and tabs Sessions (one row per session: start, stage, model, input / cache write / cache read / output tokens, duration, exit, cost; subagents expandable; a row opens that session's log), Log (live tail), Gates (from reports), Review (widens the drawer to ~70%; the review page in an iframe; Approve and Request changes with a text box at the top, shown only for Spec Review and Staged). Costs are labeled "est."; an unpriced model shows `$ ?` with a hint to add it to `~/.aghanim/prices.yml`.

Behavior the page must implement:
- Poll `/api/overview` every 5 s; while the drawer is open, poll `/api/card/<p>/<n>` every 5 s and the log with `?from=<next>`, appending.
- Project selector only when `projects.length > 1`.
- After an action, mark the card "moving…" until the overview shows the new column; on `409` show the server's message and reload the card; on a `502` with `commented: true` offer "Retry the move" (POST again with `move_only: true`).
- When a request fails, show "offline" in the top strip and keep polling.
- Copy uses the factory's names verbatim; no emoji.

- [ ] **Step 2: Smoke check with `playwright-cli`**

Against the Task 1 fake home (or the real one, read-only): open the printed URL, check the top strip and the board render, click a card, see the Sessions table with costs, switch to Log and see text. No action buttons are clicked against the real home.

- [ ] **Step 3: Full suite**

Run: `bash scripts/test/run.sh`
Expected: all files PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/dashboard.html
git commit -m "feat(dashboard): the control-room page"
```
