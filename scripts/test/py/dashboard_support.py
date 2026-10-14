"""Helpers for the dashboard's in-process suites: one dashboard.py server per test process, in a thread, whose Factory
each test swaps for a fresh one on its own temp home (project "shop", fixture factory.yml), with test/fake-gh as gh."""
import http.client
import json
import os
import shutil
import socket
import struct
import sys
import threading
import time

import support

TEST = os.path.join(support.SCRIPTS, "test")
FAKE_GH = os.path.join(TEST, "fake-gh")
BASH = shutil.which("bash")
COLS = ("Inbox", "Ready for Refinement", "Technical Refinement", "Spec Review", "Ready for Dev", "Coding", "Validation",
        "Staged", "Ready for Prod", "Done")
TRANSCRIPTS = os.path.join("claude", "projects", "C--x--shipfloor-projects-shop-control")


def opt(col):
    """the fake board's option id of a column"""
    return "opt%d" % (COLS.index(col) + 1)


_server = None
_errors = []


def server():
    """the one server of this process: (dashboard module, port)"""
    global _server
    if _server is None:
        import dashboard

        class Recording(dashboard.Server):
            def handle_error(self, request, client_address):  # an exception that escaped a handler: a test sees it
                _errors.append(sys.exc_info()[1])

        srv = Recording(("127.0.0.1", 0), dashboard.Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        _server = (dashboard, srv.server_address[1])
    return _server


class Resp:
    def __init__(self, code, raw, headers):
        self.code, self.raw, self.headers = code, raw, headers

    @property
    def text(self):
        return self.raw.decode("utf-8", "replace")

    @property
    def json(self):
        return json.loads(self.raw or b"null")


class Dash(support.Case):
    """A dashboard on a temp home with project shop. self.H the home, self.P the project's folder, self.T its transcripts,
    self.G the fake gh's folder."""
    PROJECTS = ("shop",)

    def setUp(self):
        super().setUp()
        self.H = os.environ["SHIPFLOOR_HOME"]
        for p in self.PROJECTS:
            for d in ("logs", "locks", "reviews"):
                self.path("shome", "projects", p, d)
            shutil.copy(os.path.join(support.FIXTURE, "factory.yml"), self.pdir(p, "factory.yml"))
        self.write("shome/registry.tsv", "".join("%s\t/x/%s\t/x/wt\tmain\n" % (p, p) for p in self.PROJECTS))
        self.P = self.pdir("shop")
        self.G = self.path("gh")
        self.T = self.path(TRANSCRIPTS)
        os.environ.update(FAKE_GH_DIR=self.G, FACTORY_GH=FAKE_GH, FAKE_GH_NO_JQ="1", SHIPFLOOR_BASH=BASH,
                          CLAUDE_CONFIG_DIR=self.path("claude"))
        self.dashboard, self.port = server()
        del _errors[:]
        self.fresh()

    def pdir(self, p, *rest):
        return os.path.join(self.H, "projects", p, *rest)

    def fresh(self, token="test-token-0123456789ab"):
        """a new Factory (no caches) behind the server, and its token"""
        self.dashboard.Handler.factory = self.dashboard.Factory(self.H, os.environ["CLAUDE_CONFIG_DIR"])
        self.dashboard.Handler.token = self.token = token
        return self.dashboard.Handler.factory

    def memo_board(self):
        """reads the live board (board.sh snapshot through the fake gh) once per content of items.tsv: for the tests that
        walk a whole table of columns"""
        f = self.dashboard.Handler.factory
        real, seen = f.board_rows, {}

        def rows(p):
            key = (p, self.gh("items.tsv"))
            if key not in seen:
                seen[key] = real(p)
            return seen[key]
        f.board_rows = rows

    # ---- HTTP
    def req(self, method, path, body=None, token=True, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        h = dict(headers or {})
        if token:
            h["X-Shipfloor-Token"] = self.token if token is True else token
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else (body.encode() if isinstance(body, str) else json.dumps(body).encode())
            h.setdefault("Content-Type", "application/json")
        conn.request(method, path, body=data, headers=h)
        r = conn.getresponse()
        out = Resp(r.status, r.read(), dict(r.getheaders()))
        conn.close()
        return out

    def get(self, path, token=True, **kw):
        return self.req("GET", path, token=token, **kw)

    def post(self, path, body=None, token=True, **kw):
        return self.req("POST", path, {} if body is None else body, token=token, **kw)

    def card_post(self, n, action, body=None, p="shop"):
        return self.post("/api/card/%s/%s/%s" % (p, n, action), body)

    def overview(self):
        return self.get("/api/overview").json

    def cards(self, p=0):
        return {c["issue"]: c for c in self.overview()["projects"][p]["cards"]}

    def settings(self):
        return self.get("/api/settings").json

    def raw(self, request):
        """sends raw bytes, reads to the end: the status code as text, or "dropped" when no answer came back"""
        data = b""
        try:
            s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
            s.sendall(request)
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            s.close()
        except OSError:
            pass
        return data.split(b" ")[1].decode() if data.startswith(b"HTTP/") else "dropped"

    def hangup(self, path, body):
        """a POST whose client resets the connection without reading the answer, as a tab closed right after its fetch"""
        body = json.dumps(body)
        s = socket.create_connection(("127.0.0.1", self.port))
        head = ("POST /%s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nX-Shipfloor-Token: %s\r\nContent-Type: application/json\r\n"
                "Content-Length: %d\r\n\r\n") % (path, self.port, self.token, len(body))
        before = len(self.calls())
        s.sendall(head.encode() + body.encode())
        end = time.time() + 10  # gone once the server works on it (its first gh call), before it answers
        while len(self.calls()) == before and time.time() < end:
            time.sleep(0.01)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        s.close()

    def server_errors(self):
        return list(_errors)

    # ---- the fake gh
    def gh(self, name, text=None):
        """writes <gh>/<name>, or (text None) reads it ("" when missing)"""
        p = os.path.join(self.G, name)
        if text is None:
            try:
                with open(p, encoding="utf-8") as f:
                    return f.read()
            except OSError:
                return ""
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)

    def gh_rm(self, *names):
        for n in names:
            try:
                os.unlink(os.path.join(self.G, n))
            except OSError:
                pass

    def items(self, *rows):
        """the fake board: (n, column) rows, item ids PVTI_<n>"""
        self.gh("items.tsv", "".join("PVTI_%s\t%s\t%s\n" % (n, n, c) for n, c in rows))

    def calls(self):
        return self.gh("calls").splitlines()

    def edits(self):
        return [l for l in self.gh("edits").splitlines() if "item-edit" in l]

    def line_of(self, needle):
        """the index of the first gh call holding needle, or None"""
        return next((i for i, l in enumerate(self.calls()) if needle in l), None)

    def reset_gh(self):
        for f in os.listdir(self.G):
            if f in ("edits", "comments", "positions", "pr-closed", "prs") or f.startswith(("fail", "labels-")):
                os.unlink(os.path.join(self.G, f))
        self.gh("calls", "")

    def wait_file(self, name, needle, secs=10):
        end = time.time() + secs
        while time.time() < end:
            if needle in self.gh(name):
                return True
            time.sleep(0.05)
        return False

    # ---- the home
    def board(self, rows, p="shop"):
        """the dispatcher's board snapshot (board.tsv): {n: column} or (n, column) rows"""
        rows = rows.items() if isinstance(rows, dict) else rows
        self.write(os.path.relpath(self.pdir(p, "board.tsv"), self.tmp), "".join("%s\t%s\n" % r for r in rows))

    def config(self, text):
        self.write("shome/config.yml", text)

    def read_config(self):
        import yaml
        with open(os.path.join(self.H, "config.yml"), encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    def config_text(self):
        with open(os.path.join(self.H, "config.yml"), encoding="utf-8") as f:
            return f.read()

    def lock(self, name, n, pid=1, p="shop"):
        d = self.pdir(p, "locks", name + ".lock")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "info"), "w") as f:
            f.write("%s %d %s\n" % (pid, time.time(), n))
        return d

    def unlock(self, name, p="shop"):
        shutil.rmtree(self.pdir(p, "locks", name + ".lock"), ignore_errors=True)

    def log(self, name, text, p="shop"):
        with open(self.pdir(p, "logs", name), "a", encoding="utf-8") as f:
            f.write(text)

    def transcript(self, name, *events, sub=None):
        """a session's transcript: each event a dict (one JSON line) or a str (written as is)"""
        p = os.path.join(self.T, name + ".jsonl") if sub is None else os.path.join(self.T, name, "subagents", sub + ".jsonl")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            for e in events:
                f.write(e if isinstance(e, str) else json.dumps(e) + "\n")
        return p


def cmd(content, ts="2026-10-09T10:00:00Z"):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": content}}


def slash(stage, n, ts="2026-10-09T10:00:00Z"):
    return cmd("<command-name>/sf:%s</command-name>\n<command-args>%s</command-args>" % (stage, n), ts)


def ast(mid, model, usage, ts="2026-10-09T10:05:00Z"):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": model, "usage": usage}}
