"""The runtime contract: one module per agent CLI the factory can start (claude_code.py), and the one rule that reads
a run's log for a usage limit. NAMES is read at call time: the first name is the default runtime.

A runtime module has NAME, LABEL, BINARY, MODELS, LADDER, TRAILER and command(run) -> (argv, envs, stdin),
outcome(rc, block) -> "ok" | "fail" | "usage_limit", doctor() -> [(ok, "<name>: <binary>")], and its cost and session
readers: COMMAND, text_of, doing, parse, events, data_dir, session_files, stamp."""
import importlib
import os
import re
import sys

sys.dont_write_bytecode = True  # importing the adapters must not leave a __pycache__ in the installed factory
_HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _HERE not in sys.path:  # `python -I` leaves the script's folder out of the path
    sys.path.insert(0, _HERE)

NAMES = ("claude-code", "codex", "opencode")
TOKEN_KINDS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")
OUTCOMES = ("ok", "fail", "usage_limit")
_OUTCOME = re.compile(r"^== end .* outcome=(\w+)\s*$", re.M)
_RUNTIME = re.compile(r"\bruntime=([\w-]+)\s*$")
_LIMIT_TEXT = "hit your session limit"  # legacy: a log written before `outcome=` says the limit only in the CLI's words


def get(name):
    """The module of runtime <name>; KeyError when nobody knows it."""
    if name not in NAMES:
        raise KeyError(name)
    return importlib.import_module("runtimes." + name.replace("-", "_"))


def sessions(slug, read, dirs=None):
    """The sessions of every runtime for a project, oldest first: dicts with runtime, id, path, subagent_paths and what
    read(path, parse) parsed (stage, issue, start, tokens, subagents); parse is the runtime's own reader of a
    transcript. dirs: {runtime name: its data folder}; a missing one is the runtime's own data_dir()."""
    out = []
    for name in NAMES:
        rt = get(name)
        base = (dirs or {}).get(name) or rt.data_dir()
        for sid, path, subs in rt.session_files(base, slug):
            try:  # a runtime may delete a transcript under us, or a line may carry a bad time
                s = read(path, rt.parse)
                if s["start"]:
                    rt.parse_ts(s["start"])
                if s["stage"] and s["start"]:
                    out.append(dict(s, runtime=name, id=sid, path=path, subagent_paths=subs,
                                    subagents=[read(a, rt.parse) for a in subs]))
            except (OSError, ValueError):
                continue
    return sorted(out, key=lambda s: s["start"])


def _text(block):
    return block.decode("utf-8", "replace") if isinstance(block, (bytes, bytearray)) else block


def outcome_of(block):
    """The outcome the last `== end` line of a run's log block carries, None when it has none (a log from before)."""
    found = _OUTCOME.findall(_text(block))
    return found[-1] if found else None


def limited_runtime(block):
    """The runtime whose usage limit a log says, None when it pauses nothing: the last `== start` run of the text.
    A run with an outcome pauses on usage_limit alone; a run without one (old log, or still running) pauses when it
    says the limit in words (Claude Code's). The runtime is the start line's `runtime=`; a log from before has none."""
    text = _text(block)
    i = text.rfind("== start")
    run = text[max(i, 0):]
    outcome = outcome_of(run)
    if outcome is not None:
        limited = outcome == "usage_limit"
    else:
        limited = _LIMIT_TEXT in run
    if not limited:
        return None
    m = _RUNTIME.search(run.split("\n", 1)[0])
    return m.group(1) if m and m.group(1) in NAMES else NAMES[0]


def usage_limited(block):
    """Whether a log pauses the factory (see limited_runtime)."""
    return limited_runtime(block) is not None


def label(name):
    """How a runtime is named in a line for the owner: Claude, Codex."""
    try:
        return get(name).LABEL
    except KeyError:
        return name
