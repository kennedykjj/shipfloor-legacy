"""telemetry: what a run did inside, from the agent's stream (claude -p --output-format stream-json --verbose).

The supervisor (dispatch.supervise) reads the agent's stdout line by line through run_agent:
  - the run log gets the same human text a plain `claude -p` printed: the final result, else the last assistant text;
    a line that is not JSON (an older CLI, a test's fake claude, a crash message) goes to it as it came, and stderr goes
    to it unchanged. Everything that reads the run log (== start / == end, the usage limit, the dashboard) is untouched.
  - <log without .log>.events.jsonl gets every event as it arrived: {"t": <epoch s>, "pid": <run pid>, "event": {...}}.
  - <project home>/logs/runs.jsonl gets one summary line when the run ends (see Run.summary).
Both files appear only when the stream carried JSON. Telemetry never fails a run: a write or parse error is counted
(parse_errors) or dropped, the agent's output still reaches the log, and the exit code is the agent's.
"""
import json
import os
import re
import subprocess
import threading
import time

PIPE = subprocess.PIPE
BASH_KINDS = (("gate", re.compile(r"\bgate\.sh\b")), ("board", re.compile(r"\bboard\.sh\b")),
              ("gh", re.compile(r"(^|[\s;&|(`$])gh\s")))
# The Claude usage limit, as the run log's readers look for it (dispatch.usage_limited, cycle, the dashboard). In
# stream-json it may come in an event whose text the log does not get (an assistant turn before the last, a system
# event): seen in the CLI's own events, it is written to the log once, so those readers keep pausing the factory.
USAGE_LIMIT = b"hit your session limit"
TOKENS = (("input", "input_tokens"), ("output", "output_tokens"), ("cache_read", "cache_read_input_tokens"),
          ("cache_creation", "cache_creation_input_tokens"))


def _limit_in(ev, stripped):
    """Whether the event says the usage limit itself. Content the agent read or wrote (a tool result, a tool call's
    input) is not the CLI speaking: a run that reads a test or a doc quoting the message is not a run that hit it."""
    kind = ev.get("type")
    if kind == "user":
        return False
    if kind == "assistant":
        content = (ev.get("message") or {}).get("content")
        if isinstance(content, list):
            text = "\n".join(b.get("text") or "" for b in content if isinstance(b, dict) and b.get("type") == "text")
            return USAGE_LIMIT.decode() in text
    return USAGE_LIMIT in stripped


def events_path(log):
    return (log[:-len(".log")] if log.endswith(".log") else log) + ".events.jsonl"


def bash_kind(command):
    """What a Bash call was, for the summary: gate (gate.sh), board (board.sh), gh, else other."""
    for kind, rx in BASH_KINDS:
        if rx.search(command or ""):
            return kind
    return "other"


def _add(table, key, seconds):
    row = table.setdefault(key, {"n": 0, "s": 0.0})
    row["n"] += 1
    row["s"] = round(row["s"] + seconds, 3)


class Run:
    """The stream of one run: the text for its log, and what its summary adds up."""

    def __init__(self, meta, events=None, clock=time.time):
        self.meta, self.events_file, self.clock = meta, events, clock
        self.started = clock()
        self.events = self.parse_errors = 0
        self.result = None
        self.last_text = ""
        self.pending = {}  # tool_use id -> (received at, tool name, bash kind or None)
        self.tools, self.bash = {}, {}
        self.wrote_text = False
        self.limit_logged = False
        self.denied = 0  # tool calls the permission gate refused: no human is there to approve them

    def feed(self, raw, at=None):
        """One stdout line: the bytes for the run log now (b"" for none)."""
        if self.meta.get("raw"):  # a runtime whose stream is not Claude's: the log keeps it as it comes
            return raw
        at = self.clock() if at is None else at
        stripped = raw.strip()
        if not stripped.startswith(b"{"):
            return raw
        try:
            ev = json.loads(stripped.decode("utf-8", "surrogateescape"))
        except ValueError:
            self.parse_errors += 1
            return raw
        if not isinstance(ev, dict):
            return raw
        self.events += 1
        if ev.get("type") == "system" and ev.get("subtype") == "permission_denied":
            self.denied += 1
        self._record(ev, at)
        try:
            self._account(ev, at)
        except Exception:  # an event of a shape not seen before is counted, never fatal
            self.parse_errors += 1
        out = b""
        if ev.get("type") == "result":
            self.result = ev
            text = ev.get("result")
            if not isinstance(text, str) or not text:
                text = self.last_text
            if text:
                self.wrote_text = True
                out = (text.rstrip("\n") + "\n").encode("utf-8", "surrogateescape")
        if USAGE_LIMIT in out:
            self.limit_logged = True
        elif not self.limit_logged and _limit_in(ev, stripped):
            self.limit_logged = True
            out += b"claude: " + USAGE_LIMIT + b" (from the agent's stream)\n"
        return out

    def finish(self):
        """The bytes for the log once the stream ended: the last assistant text when no result carried any."""
        if self.events and not self.wrote_text and self.last_text:
            self.wrote_text = True
            return (self.last_text.rstrip("\n") + "\n").encode("utf-8", "surrogateescape")
        return b""

    def _record(self, ev, at):
        if self.events_file is None:
            return
        try:
            self.events_file.write(json.dumps({"t": round(at, 3), "pid": self.meta.get("pid"), "event": ev},
                                              ensure_ascii=False) + "\n")
            self.events_file.flush()
        except (OSError, ValueError, TypeError):
            self.events_file = None  # a full disk drops the events, not the run

    def _account(self, ev, at):
        kind = ev.get("type")
        content = (ev.get("message") or {}).get("content")
        if not isinstance(content, list):
            return
        if kind == "assistant":
            texts = []
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text" and isinstance(block.get("text"), str):
                    texts.append(block["text"])
                elif block.get("type") == "tool_use" and block.get("id"):
                    name = block.get("name") or "?"
                    inp = block.get("input") if isinstance(block.get("input"), dict) else {}
                    self.pending[block["id"]] = (at, name, bash_kind(inp.get("command")) if name == "Bash" else None)
            if texts and not ev.get("parent_tool_use_id"):  # a subagent's text is not the run's answer
                self.last_text = "".join(texts)
        elif kind == "user":
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    use = self.pending.pop(block.get("tool_use_id"), None)
                    if use:
                        seconds = max(0.0, at - use[0])
                        _add(self.tools, use[1], seconds)
                        if use[2]:
                            _add(self.bash, use[2], seconds)

    def summary(self, rc, ended=None):
        """One line of runs.jsonl: who ran, how long, what the CLI reported (time in the API, turns, cost, tokens), and
        the seconds per tool (Bash split into gate, board, gh and other). Tools still open at the end are counted in
        `unfinished`."""
        ended = self.clock() if ended is None else ended
        r = self.result or {}
        usage = r.get("usage") if isinstance(r.get("usage"), dict) else {}
        m = self.meta
        return {
            "stage": m.get("stage"), "card": m.get("card"), "pid": m.get("pid"), "model": m.get("model") or None,
            "weight": m.get("weight"), "start": m.get("start"), "end": m.get("end"),
            "seconds": round(ended - self.started, 3), "exit": rc,
            "result": r.get("subtype"), "is_error": r.get("is_error"), "session_id": r.get("session_id"),
            "duration_ms": r.get("duration_ms"), "duration_api_ms": r.get("duration_api_ms"),
            "num_turns": r.get("num_turns"), "cost_usd": r.get("total_cost_usd"),
            "tokens": {k: usage.get(field) for k, field in TOKENS},
            "tools": self.tools, "bash": self.bash, "unfinished": len(self.pending),
            "events": self.events, "parse_errors": self.parse_errors,
        }


def _append_line(path, obj):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except (OSError, ValueError, TypeError):
        pass


class _ResultGuard:
    """Stops an agent that printed its final result and then neither exits nor says anything: a headless claude
    that keeps waiting for background work holds the run's lock (and the card) until the lock's TTL. It fires only
    after `result`, with no tool call unfinished, and SHIPFLOOR_RESULT_GRACE_SEC (default 300; 0 = never) of silence;
    any later event (a background agent waking the session for another turn) restarts the wait."""

    def __init__(self, p, run, clock=time.time):
        try:
            self.grace = int(os.environ.get("SHIPFLOOR_RESULT_GRACE_SEC", "300"))
        except ValueError:
            self.grace = 300
        self.p, self.run, self.clock = p, run, clock
        self.last = clock()
        self.fired = False
        self._done = threading.Event()

    def touch(self):
        self.last = self.clock()

    def start(self):
        if self.grace > 0:
            threading.Thread(target=self._watch, daemon=True).start()

    def stop(self):
        self._done.set()

    def _watch(self):
        step = min(1.0, self.grace / 4.0)
        while not self._done.wait(step):
            if self.run.result is None or self.run.pending or self.clock() - self.last < self.grace:
                continue
            self.fired = True
            try:
                self.p.terminate()
                if not self._done.wait(10):
                    self.p.kill()
            except OSError:
                pass
            return


def run_agent(argv, log, cwd, env, prompt, meta, runs, iso=None, stopped=None):
    """Start the agent with `prompt` on stdin, its stdout read as a stream into `log` (see the module's docstring),
    its stderr straight to `log`. The agent's exit code (128 - signal for a signal, 127 when it cannot start, with the
    shell's line in the log), as `dispatch._run` gives it."""
    with open(log, "ab") as f:
        try:
            p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=PIPE, stdout=PIPE, stderr=f)
        except OSError as e:
            f.write(("%s: %s\n" % (argv[0], e.strerror or e)).encode("utf-8", "surrogateescape"))
            return 127
        try:
            p.stdin.write(prompt)
            p.stdin.close()
        except OSError:  # an agent that exits before reading its prompt
            pass
        events = None
        run = Run(meta)
        guard = _ResultGuard(p, run)
        guard.start()
        for raw in iter(p.stdout.readline, b""):
            guard.touch()
            if run.events_file is None and events is None and not meta.get("raw") and raw.lstrip().startswith(b"{"):
                try:
                    events = run.events_file = open(events_path(log), "a", encoding="utf-8")
                except OSError:
                    events = False
            out = run.feed(raw)
            if out:
                f.write(out)
                f.flush()
        p.stdout.close()
        rc = p.wait()
        guard.stop()
        rc = 128 - rc if rc < 0 else rc
        if guard.fired:  # the run had finished its work and only the process stayed: its result decides
            f.write(("== agent still alive %ds after its result; stopped\n" % guard.grace).encode("utf-8"))
            rc = 1 if (run.result or {}).get("is_error") else 0
        tail = run.finish()
        if tail:
            f.write(tail)
    if events:
        try:
            events.close()
        except OSError:
            pass
    if run.events:
        if iso:
            meta = dict(meta, end=iso())
            run.meta = meta
        row = run.summary(rc)
        if stopped:  # why the run did not do its stage ("" = it did; None = not judged)
            try:
                row["stopped"] = stopped(rc, denied=run.denied) or ""
            except Exception:
                row["stopped"] = ""
        _append_line(runs, row)
    return rc
