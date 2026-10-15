"""The opencode runtime: how the factory starts `opencode run`, and how a run's end is classified. The factory has its
own config folder (OPENCODE_CONFIG_DIR, generated at `shipfloor install`): the owner's personal opencode config and the
project's own are never read. The run's permissions and its self-hosted provider travel in OPENCODE_CONFIG_CONTENT, an
environment value that never holds a key (the provider's apiKey is `{env:<NAME>}`, opencode reads the variable)."""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import quote

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # `python -I` leaves the script's folder out of the path

from inbox_hook import INTRO
from runtimes import TOKEN_KINDS
from runtimes import provider as provider_mod
from shipfloor_core.defaults import OPENCODE_TRAILER

NAME = "opencode"
LABEL = "opencode"  # how a line for the owner names it
BINARY = os.environ.get("SHIPFLOOR_OPENCODE") or "opencode"
MODELS = ()  # the name is free: whatever `opencode run -m` takes (provider/model)
LADDER = ()  # the owner's runtime.ladder, when there is one
TRAILER = OPENCODE_TRAILER
PROVIDER_ID = "sf"  # the provider id the factory gives runtime.provider in the generated config
LIMIT_TYPES = ("provider.quota", "provider.rate-limit")  # the types of an `error` event that mean the account cannot run


def data_dir():
    """The factory's OPENCODE_CONFIG_DIR."""
    return Path(os.environ.get("SHIPFLOOR_OPENCODE_HOME") or Path.home() / ".shipfloor" / "runtimes" / "opencode")


def permissions(write, read):
    """The run's permission rules, a list of {permission, pattern, action}; the last match wins. Everything is allowed
    except: a directory outside the folders it may write or read, writing the folders it may only read, the web."""
    rules = [{"permission": "*", "pattern": "*", "action": "allow"},
             {"permission": "external_directory", "pattern": "*", "action": "deny"}]
    for d in [*write, *read]:
        rules.append({"permission": "external_directory", "pattern": d.rstrip("/") + "/**", "action": "allow"})
    for d in read:
        rules.append({"permission": "edit", "pattern": d.rstrip("/") + "/**", "action": "deny"})
    for tool in ("webfetch", "websearch"):
        rules.append({"permission": tool, "pattern": "*", "action": "deny"})
    return rules


def config_content(run):
    """The JSON of OPENCODE_CONFIG_CONTENT for one run."""
    cfg = {"permissions": permissions(run["write"], run.get("read") or [])}
    provider = run.get("provider")
    if provider:
        key_env = provider.get("key_env") or ""
        settings = {"baseURL": provider["base_url"]}
        if key_env:
            settings["apiKey"] = "{env:%s}" % key_env
        models = {}
        model = run.get("model") or ""
        if model.startswith(PROVIDER_ID + "/") and len(model) > len(PROVIDER_ID) + 1:
            models[model[len(PROVIDER_ID) + 1:]] = {"capabilities": {"tools": True}}
        cfg["providers"] = {PROVIDER_ID: {"package": "@ai-sdk/openai-compatible", "settings": settings, "models": models}}
        cfg["experimental"] = {"policies": [{"use": [PROVIDER_ID]}]}  # only the factory's provider may serve the run
    return cfg


def command(run):
    """(argv without the binary, environment assignments, stdin) of one run. run: stage, issue, model, control (its
    folder), write (folders it may write), read (folders it may only read), envs (assignments the factory adds),
    provider ({base_url, key_env} of runtime.provider, or None). The run starts in the control checkout (the
    dispatcher's cwd)."""
    argv = ["run", "--standalone", "--auto", "--agent", "sf-" + run["stage"], "--format", "json"]
    if run.get("model"):
        argv += ["-m", run["model"]]
    envs = [*run["envs"],
            "OPENCODE_CONFIG_DIR=" + str(data_dir()),
            "OPENCODE_DISABLE_PROJECT_CONFIG=1",
            "OPENCODE_DISABLE_MODELS_FETCH=1",
            "OPENCODE_DISABLE_AUTOUPDATE=1",
            "OPENCODE_CONFIG_CONTENT=" + json.dumps(config_content(run), separators=(",", ":"))]
    return argv, envs, "Card: #%s\n" % run["issue"]


def outcome(rc, block):
    """usage_limit when the run's JSON lines carry an `error` event of a limit type (whatever the exit code), else ok on
    exit 0, else fail. Only a top-level `error` event is the CLI speaking: what the agent says or reads is not."""
    text = block.decode("utf-8", "replace") if isinstance(block, (bytes, bytearray)) else block
    for line in text.split("\n"):
        if not line.lstrip().startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        err = ev.get("error") if isinstance(ev, dict) and ev.get("type") == "error" else None
        if isinstance(err, dict) and err.get("type") in LIMIT_TYPES:
            return "usage_limit"
    return "ok" if rc == 0 else "fail"


def _version(binary):
    try:
        r = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", r.stdout)
    return tuple(int(x) for x in m.groups()) if m else None


def _machine_runtime():
    """(runtime mapping, its provider mapping or None) of the machine config; ({}, None) when there is none or doctor
    reports on it elsewhere."""
    try:
        import yaml
        import shipfloor_config
        from shipfloor_core import project
        with open(os.path.join(project.shipfloor_home(), "config.yml"), encoding="utf-8") as f:
            raw = yaml.safe_load(f)
        if not isinstance(raw, dict) or shipfloor_config.runtime_problems(raw.get("runtime")):
            return {}, None
        provider = shipfloor_config.runtime_setting(raw, None, "provider")
        runtime = raw.get("runtime") if isinstance(raw.get("runtime"), dict) else {}
        return runtime, provider if isinstance(provider, dict) and provider.get("base_url") else None
    except Exception:
        return {}, None


def _model_names(cfg):
    """The model names a runtime/provider mapping uses, in order: its stages' (every weight), its agents', its ladder."""
    models = cfg.get("models") if isinstance(cfg.get("models"), dict) else {}
    names = []
    for group in ("stages", "agents"):
        for v in (models.get(group) or {}).values():
            names += list(v.values()) if isinstance(v, dict) else [v]
    names += cfg.get("ladder") or []
    return list(dict.fromkeys(n for n in names if isinstance(n, str) and n))


def _auth_providers(binary):
    """The provider ids `opencode auth list` shows a credential for (the first word of each line); None when it fails."""
    try:
        r = subprocess.run([binary, "auth", "list"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return {line.split()[0].lower() for line in r.stdout.splitlines() if line.split()}


def doctor():
    """[(found, "opencode: opencode"[, what to say when not found])]: the binary and its version (2.x; 1.x is told how to
    move), the generated OPENCODE_CONFIG_DIR, and either the runtime.provider's endpoint (chat completions) or the
    credentials `opencode auth list` shows for the providers of the configured models."""
    binary, home = shutil.which(BINARY), data_dir()
    out = [(binary is not None, "%s: opencode" % NAME)]
    if binary is None:
        return out
    version = _version(binary)
    if version is not None and version[0] < 2:
        out.append((False, "%s: opencode version" % NAME, "%s: opencode %s is 1.x, which is not supported; migrate to opencode 2.x "
                    "(install the 2.x CLI, see docs/install.md)" % (NAME, ".".join(map(str, version)))))
    made = (home / "opencode.json").is_file() and any((home / "agents").glob("sf-*.md"))
    out.append((made, "%s: generated config in OPENCODE_CONFIG_DIR %s" % (NAME, home),
                "%s: OPENCODE_CONFIG_DIR %s is not generated; run shipfloor install" % (NAME, home)))
    runtime, provider = _machine_runtime()
    if provider:
        names = [n[len(PROVIDER_ID) + 1:] if n.startswith(PROVIDER_ID + "/") else n for n in _model_names(provider)]
        for kind, text in provider_mod.check(provider["base_url"], names, provider.get("api_key_env") or "", wire="chat"):
            out.append((True, text) if kind == "ok" else (False, text, text))
        ignored = [k for k in ("models", "ladder") if runtime.get(k)]
        if ignored:
            out.append(("WARN", "runtime.%s ignored: there is a runtime.provider (its own models and ladder count)"
                        % "/runtime.".join(ignored)))
    else:
        wanted = list(dict.fromkeys(n.split("/", 1)[0].lower() for n in _model_names(runtime) if "/" in n))
        if wanted:
            have = _auth_providers(binary)
            for p in wanted:
                out.append((have is not None and p in have, "%s: credential for provider %s" % (NAME, p),
                            "%s: no credential for provider %s; run opencode auth login" % (NAME, p)))
    return out


# --- cost and sessions: read from opencode's own database --------------------------------------------------------------

# A session has no file: its path is a Ref, "<opencode.db>#<session id>", and its stamp is the session's updated_at.

COMMAND = None
CARD = re.compile(r"Card: #(\d+)")
AGENT = re.compile(r"^sf-([a-z]+)$")
SHELLS = ("shell", "bash")


class Ref(str):
    """A session of an opencode.db: "<db>#<id>". stat() answers what changes when the session does."""

    @property
    def db(self):
        return str(self).rsplit("#", 1)[0]

    @property
    def sid(self):
        return str(self).rsplit("#", 1)[1]

    def stat(self):
        row = _query(self.db, "select updated_at from session_v2 where id = ?", (self.sid,))
        if not row:
            raise OSError("no such session: %s" % self)
        return SimpleNamespace(st_size=int(row[0][0] or 0), st_mtime=int(row[0][0] or 0) / 1000.0)


def db_path():
    """opencode's own database (OPENCODE_DB, else its default place)."""
    return Path(os.environ.get("OPENCODE_DB") or Path.home() / ".local" / "share" / "opencode" / "opencode.db")


def _query(db, sql, args=()):
    """The rows of a read-only query; OSError when the database is absent, locked or not an opencode.db."""
    if not os.path.isfile(db):
        raise OSError("no database: %s" % db)
    try:
        con = sqlite3.connect("file:%s?mode=ro" % quote(str(db)), uri=True, timeout=2)
        try:
            return con.execute(sql, args).fetchall()
        finally:
            con.close()
    except sqlite3.Error as e:
        raise OSError("%s: %s" % (db, e))


def parse_ts(s):
    from runtimes import codex
    return codex.parse_ts(s)


def _iso(ms):
    return datetime.fromtimestamp(int(ms or 0) / 1000.0, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def doing(payload):
    """One line for a message part: what the agent says, or the tool it calls and on what."""
    kind = payload.get("type")
    if kind == "text":
        line = next((x.strip() for x in str(payload.get("text") or "").splitlines() if x.strip()), "")
        return {"kind": "says", "text": line[:200]} if line else None
    if kind == "tool":
        name = payload.get("tool") or "tool"
        args = payload.get("input")
        if isinstance(args, dict):
            what = args.get("command") or args.get("filePath") or args.get("path") or args.get("pattern") or json.dumps(args)
        else:
            what = args or ""
        return {"kind": "Bash" if name in SHELLS else name, "text": " ".join(str(what).split())[:160]}
    return None


def session_files(data, slug):
    """[(id, ref, [its subagents' refs])] of the sessions the dispatcher ran for a project: the lead sessions whose
    directory is the project's control checkout. No database, or one that is not opencode's, is no session."""
    db = str(db_path())
    try:
        rows = _query(db, "select id, parent_id, directory from session_v2 order by created_at, id")
    except OSError:
        return []
    kids = {}
    for sid, parent, _ in rows:
        if parent:
            kids.setdefault(parent, []).append(sid)

    def below(sid, seen=()):
        out = []
        for k in kids.get(sid, []):
            if k not in seen:
                out += [k] + below(k, seen + (sid,))
        return out

    return [(sid, Ref("%s#%s" % (db, sid)), [Ref("%s#%s" % (db, k)) for k in below(sid)])
            for sid, parent, directory in rows
            if not parent and str(directory or "").replace("\\", "/").rstrip("/").endswith("/projects/%s/control" % slug)]


def stamp(session):
    """What changes when the session does: [updated_at, updated_at]."""
    st = Ref(session).stat()
    return [st.st_size, int(st.st_mtime * 1000)]


def _messages(session):
    ref = Ref(session)
    head = _query(ref.db, "select agent, cost, created_at, updated_at from session_v2 where id = ?", (ref.sid,))
    if not head:
        raise OSError("no such session: %s" % session)
    rows = _query(ref.db, "select created_at, data from session_message where session_id = ? order by created_at, id", (ref.sid,))
    out = []
    for ts, data in rows:
        try:
            d = json.loads(data)
        except (TypeError, ValueError):
            continue
        if isinstance(d, dict):
            out.append((ts, d))
    return head[0], out


def parse(session):
    """The card a session ran for (agent `sf-<stage>`, `Card: #<n>` in its first user message), its tokens per model
    (reasoning counted as output), the cost the CLI itself reports (`cost`, kept apart) and the last few things it did."""
    (agent, reported, created, updated), msgs = _messages(session)
    m = AGENT.match(str(agent or ""))
    stage, issue, usage, activity = m.group(1) if m else None, None, {}, deque(maxlen=4)
    for ts, d in msgs:
        parts = [p for p in d.get("parts") or [] if isinstance(p, dict)]
        if d.get("role") == "user":
            if issue is None:
                c = CARD.search(text_of(parts))
                issue = int(c.group(1)) if c else None
            continue
        for p in parts:
            did = doing(p)
            if did:
                activity.append(dict(did, ts=_iso(ts)))
        tk = d.get("tokens")
        if isinstance(tk, dict):
            cache = tk.get("cache") if isinstance(tk.get("cache"), dict) else {}
            t = usage.setdefault(str(d.get("model") or "unknown"), dict.fromkeys(TOKEN_KINDS, 0))
            t["input"] += int(tk.get("input") or 0)
            t["output"] += int(tk.get("output") or 0) + int(tk.get("reasoning") or 0)
            t["cache_read"] += int(cache.get("read") or 0)
            t["cache_write_5m"] += int(cache.get("write") or 0)
    tokens = {k: t for k, t in usage.items() if any(t.values())}
    return {"stage": stage, "issue": issue, "start": _iso(created), "end": _iso(updated), "tokens": tokens,
            "cost": float(reported or 0), "activity": list(activity)}


def events(session):
    """What a session said and did, in order, and the owner's messages it was handed (inbox_hook.py)."""
    out = []
    _, msgs = _messages(session)
    for ts, d in msgs:
        parts = [p for p in d.get("parts") or [] if isinstance(p, dict)]
        if d.get("role") == "user":
            text = text_of(parts)
            if INTRO in text:
                out.append({"kind": "owner", "text": text.split(INTRO, 1)[1].strip(), "ts": _iso(ts)})
            continue
        for p in parts:
            did = doing(p)
            if did and did["kind"] == "says":
                did["text"] = str(p.get("text") or "").strip()[:4000]
            if did:
                out.append(dict(did, ts=_iso(ts)))
    return out
