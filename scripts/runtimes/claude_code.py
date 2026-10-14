"""The claude-code runtime: how the factory starts `claude`, how a run's end is classified, and how its transcripts
(one .jsonl per session under ~/.claude/projects) are read for cost, Live and Sessions."""
import json
import os
import re
import shutil
import sys
from collections import deque
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # `python -I` leaves the script's folder out of the path

from inbox_hook import INTRO
from runtimes import TOKEN_KINDS
from shipfloor_core.defaults import TRAILER  # the commit trailer of the runs' commits

NAME = "claude-code"
LABEL = "Claude"  # how a line for the owner names it
BINARY = os.environ.get("FACTORY_CLAUDE") or "claude"
MODELS = ("opus", "sonnet", "haiku", "fable")  # what `claude --model` and the Agent tool's model take
LADDER = ("haiku", "sonnet", "opus")  # a run that fails a gate steps one up; fable is not on it: the factory cannot rank it
LIMIT_TEXT = "hit your session limit"

LEGACY_STAGES = {"refinar": "refine", "desenvolver": "develop", "validar": "validate", "deployar": "deploy"}  # legacy mylos
COMMAND = re.compile(r"<command-name>/(?:sf|aghanim|mylos):([a-z]+)</command-name>\s*<command-args>(\d+)</command-args>")  # legacy aghanim, legacy mylos


def read_rule(path):
    """The permission rule that lets a run read under <path>, never write; None when it does not exist."""
    if not os.path.isdir(path):
        return None
    return "Read(/%s/**)" % os.path.abspath(path)  # a rule's absolute path opens with two slashes


def command(run):
    """(argv without the binary, environment assignments, stdin) of one run. run: stage, issue, model, plugin,
    write (folders it may write), read (folders it may read), envs (assignments the factory adds), system_prompt."""
    argv = ["-p", "--permission-mode", "acceptEdits"]
    for d in run["write"]:
        argv += ["--add-dir", d]
    # Only the project's settings and this plugin: the owner's personal plugins, MCP servers and output style
    # cost every run ~19k tokens of context and steer its agents.
    argv += ["--setting-sources", "project,local", "--strict-mcp-config", "--plugin-dir", run["plugin"]]
    rules = [r for r in map(read_rule, run["read"]) if r]
    if rules:
        argv += ["--allowedTools", *rules]
    # PowerShell is refused in every headless run; without the tool no turn is spent finding that out.
    argv += ["--disallowedTools", "PowerShell", "--append-system-prompt", run["system_prompt"]]
    if run.get("model"):
        argv += ["--model", run["model"]]
    # the stdout is a stream-json the factory reads (shipfloor_core/telemetry.py): the log gets the text a plain -p printed
    argv += ["--output-format", "stream-json", "--verbose"]
    # print mode stops background subagents 10 min after the last turn and ends the run half done; 0 waits.
    # The owner's personal CLAUDE.md is loaded whatever the setting sources are: its memory is not for a run.
    envs = [*run["envs"], "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0", "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"]
    return argv, envs, "/sf:%s %s" % (run["stage"], run["issue"])


def outcome(rc, block):
    """usage_limit when the run's block says the limit (whatever the exit code), else ok on exit 0, else fail."""
    text = block.decode("utf-8", "replace") if isinstance(block, (bytes, bytearray)) else block
    if LIMIT_TEXT in text:
        return "usage_limit"
    return "ok" if rc == 0 else "fail"


def doctor():
    """[(found, "claude-code: claude")]"""
    return [(shutil.which("claude") is not None, "%s: claude" % NAME)]


# --- cost and sessions -----------------------------------------------------------------------------------------------

def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def doing(block):
    """One line for what an assistant block does: its own words, or the tool it calls and on what."""
    if block.get("type") == "text":
        line = next((x.strip() for x in block.get("text", "").splitlines() if x.strip()), "")
        return {"kind": "says", "text": line[:200]} if line else None
    if block.get("type") == "tool_use":
        i = block.get("input") or {}
        what = i.get("description") or i.get("file_path") or i.get("pattern") or i.get("command") or i.get("prompt") or ""
        return {"kind": block.get("name") or "tool", "text": " ".join(str(what).split())[:160]}
    return None


def parse(session):
    """The card a session ran for (its first user message is the dispatcher's /sf:<stage> <n>),
    its tokens per model and the last few things it did."""
    stage = issue = start = end = None
    first_user, usage, activity = True, {}, deque(maxlen=4)
    with open(session, encoding="utf-8", errors="replace") as f:
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
            if o.get("type") == "assistant" and isinstance(msg.get("content"), list):
                for block in msg["content"]:
                    did = isinstance(block, dict) and doing(block)
                    if did:
                        activity.append(dict(did, ts=o.get("timestamp")))
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
    return {"stage": stage, "issue": issue, "start": start, "end": end, "tokens": tokens, "activity": list(activity)}


def events(session):
    """What a session said and did, in order, and the owner's messages it was handed (inbox_hook.py)."""
    out = []
    with open(session, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            ts, content, att = o.get("timestamp"), (o.get("message") or {}).get("content"), o.get("attachment") or {}
            if o.get("type") == "assistant" and isinstance(content, list):
                for block in content:
                    did = isinstance(block, dict) and doing(block)
                    if did and did["kind"] == "says":
                        did["text"] = block["text"].strip()[:4000]
                    if did:
                        out.append(dict(did, ts=ts))
            elif att.get("type") == "hook_additional_context":
                out += [{"kind": "owner", "text": c[len(INTRO):].strip(), "ts": ts}
                        for c in att.get("content") or [] if isinstance(c, str) and c.startswith(INTRO)]
    return out


def data_dir():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def session_files(data, slug):
    """[(id, transcript, [its subagents' transcripts])] of the sessions the dispatcher ran for a project."""
    out = []
    for d in (Path(data) / "projects").glob(f"*-projects-{slug}-control"):
        for f in d.glob("*.jsonl"):
            out.append((f.stem, f, sorted((d / f.stem / "subagents").glob("*.jsonl"))))
    return out


def stamp(session):
    """What changes when the transcript does: [size, mtime in ns]."""
    st = Path(session).stat()
    return [st.st_size, st.st_mtime_ns]
