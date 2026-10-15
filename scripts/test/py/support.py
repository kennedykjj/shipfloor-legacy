"""Shared helpers for the in-process tests: a private temp dir per test, a scrubbed factory environment and a
recording double for an external program (gh, git, claude) put first on PATH."""
import json
import os
import datetime
import shutil
import stat
import sys
import tempfile
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(SCRIPTS, "test", "fixture")


class Case(unittest.TestCase):
    """A test with its own temp dir (self.tmp, removed after) and an environment with no factory variables of the
    real machine: FACTORY_HOME and SHIPFLOOR_HOME point inside self.tmp."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(saved)))
        for k in [k for k in os.environ if k.startswith(("FACTORY_", "SHIPFLOOR_", "AGHANIM_"))]:
            del os.environ[k]
        os.environ["FACTORY_HOME"] = self.path("home")
        os.environ["SHIPFLOOR_HOME"] = self.path("shome")
        os.environ["SHIPFLOOR_INSTALLER_STATUS"] = "none"  # never this machine's dispatcher registration (a test sets a stub)
        os.environ["FACTORY_CONFIG"] = os.path.join(FIXTURE, "factory.yml")
        os.environ["FACTORY_PYTHON"] = sys.executable

    def path(self, *parts):
        p = os.path.join(self.tmp, *parts)
        os.makedirs(p if not os.path.splitext(p)[1] else os.path.dirname(p), exist_ok=True)
        return p

    def write(self, rel, text):
        p = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        return p

    def double(self, name, script):
        """A program `name` first on PATH: a Python script body that sees `argv` (list) and `log(obj)`, which appends
        a JSON line to <tmp>/<name>.calls. Returns a function giving the recorded calls."""
        bindir = self.path("bin")
        calls = os.path.join(self.tmp, name + ".calls")
        body = ("#!%s\nimport json, sys\nargv = sys.argv[1:]\n"
                "def log(o):\n    open(%r, 'a').write(json.dumps(o) + '\\n')\nlog(argv)\n%s\n") % (sys.executable, calls, script)
        p = os.path.join(bindir, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        if not os.environ.get("PATH", "").startswith(bindir + os.pathsep):
            os.environ["PATH"] = bindir + os.pathsep + os.environ.get("PATH", "")
        return lambda: [json.loads(l) for l in open(calls)] if os.path.exists(calls) else []


def codex_rollout(home, sid, cwd, stage=None, issue=None, model="gpt-6-sol", usage=None, says=(), commands=(),
                  owner=(), parent=None, start=None):
    """A Codex rollout, <home>/sessions/YYYY/MM/DD/rollout-<time>-<sid>.jsonl, as `codex exec --json` leaves it: the
    session_meta (cwd; a subagent names its parent thread), the turn_context (model), the stage prompt as the first
    user message (the generated prompt's `<!-- sf:stage=... -->` marker and `Card: #<n>`), what the agent said and ran,
    the messages the owner sent (owner: full texts, handed over as user messages) and one token_count with
    usage = (input_tokens, cached_input_tokens, output_tokens), input_tokens counting the cached ones as Codex does."""
    t0 = start or (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10))
    n = [0]

    def line(kind, payload):
        n[0] += 1
        ts = (t0 + datetime.timedelta(seconds=n[0])).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        return json.dumps({"timestamp": ts, "type": kind, "payload": payload})

    def message(role, kind, text):
        return line("response_item", {"type": "message", "role": role, "content": [{"type": kind, "text": text}]})

    meta = {"id": sid, "timestamp": t0.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "cwd": cwd, "originator": "codex_exec",
            "cli_version": "0.200.0", "source": "exec"}
    if parent:  # a subagent: where it came from, in the two places a reader may look
        meta["source"] = {"subagent": {"thread_spawn": {"parent_thread_id": parent, "depth": 1}}}
        meta["parent_thread_id"] = parent
    rows = [line("session_meta", meta), line("turn_context", {"cwd": cwd, "model": model})]
    if stage:
        rows.append(message("user", "input_text", "<!-- sf:stage=%s -->\nThe stage's instructions.\n\nCard: #%s" % (stage, issue)))
    for i, text in enumerate(says):
        rows.append(message("assistant", "output_text", text))
    for i, cmd in enumerate(commands):
        rows.append(line("response_item", {"type": "function_call", "name": "shell", "call_id": "c%d" % i,
                                           "arguments": json.dumps({"command": ["bash", "-lc", cmd], "cmd": cmd, "workdir": cwd})}))
        rows.append(line("response_item", {"type": "function_call_output", "call_id": "c%d" % i, "output": "done"}))
    for text in owner:
        rows.append(message("user", "input_text", text))
    if usage:
        u = {"input_tokens": usage[0], "cached_input_tokens": usage[1], "output_tokens": usage[2],
             "reasoning_output_tokens": 0, "total_tokens": usage[0] + usage[2]}
        rows.append(line("event_msg", {"type": "token_count", "info": {"total_token_usage": u, "last_token_usage": u}}))
    d = os.path.join(home, "sessions", t0.strftime("%Y"), t0.strftime("%m"), t0.strftime("%d"))
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "rollout-%s-%s.jsonl" % (t0.strftime("%Y-%m-%dT%H-%M-%S"), sid))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(rows) + "\n")
    return path
