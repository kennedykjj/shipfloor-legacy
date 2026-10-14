"""gate.sh's dispatch: -C, usage, the project, the language, one gate, and the verdict it ends with."""
import importlib
import os
import re
import sys

from .. import project, text
from .context import Context, GateExit

USAGE = """usage: gate.sh [-C <worktree>] <gate> ...
  test-plan <spec>                         every AC of the spec has a test its layer's runner can run
  weight <spec>                            the spec's header names one weight: light, standard or heavy
  scope <po|ux|techlead|qa|layer> <base>   only that role's files changed since <base>
  qa-commit <n> [--head]                   prints card <n>'s QA commit; --head: it must be the last commit
  qa-amend <n>                             QA's amendment of its own acceptance tests is honest
  acceptance-intact <qa>                   the acceptance tests are as QA committed them
  forbidden <base>                         no forbidden file changed since <base>
  migration <base> <spec>                  applied migrations untouched, destructive ones have a rollback
  build <base>                             each layer changed since <base> builds (reuses a pass recorded on this commit)
  red <layer> <selector>                   the tests fail on an assertion (before the implementation)
  green <layer> <selector>                 the tests ran and pass (reuses a pass recorded on this commit)
  stack up <owner> | down <owner> | status
<base> and <qa> are commits. Exit: 0 pass, 1 blocked, 2 bad usage or revision, 3 infrastructure.
A gate's last line on stderr is its verdict: "gate <name>: pass", "FAIL (exit 1)" or "INFRA (exit 3)".
In a factory run (SHIPFLOOR_RUN_LOCK), the verdict is also written to <lock>/last-gate for the dispatcher.
"""

# gate name -> (module in this package, function(ctx, args) -> exit code). The module is loaded when the gate runs.
GATES = {
    "scope": ("scope", "scope"),
    "forbidden": ("scope", "forbidden"),
    "test-plan": ("spec", "test_plan"),
    "weight": ("spec", "weight"),
    "acceptance-intact": ("acceptance", "acceptance_intact"),
    "acceptance-own": ("acceptance", "acceptance_own"),
    "qa-commit": ("acceptance", "qa_commit"),
    "qa-amend": ("acceptance", "qa_amend"),
    "migration": ("migration", "migration"),
    "fast": ("migration", "fast"),
    "build": ("run", "build"),
    "red": ("run", "red"),
    "green": ("run", "green"),
    "stack": ("run", "stack_gate"),
}

NO_VERDICT = ("acceptance-own", "stack")  # their stdout/exit is read by a caller: no verdict line

_LANG_RE = re.compile(r"^language:[ \t\r\n\f\v]*[\"']?([A-Za-z-]*)")


def _stderr(msg):
    sys.stderr.flush()
    sys.stderr.buffer.write(msg.encode("utf-8", "surrogateescape") + b"\n")
    sys.stderr.buffer.flush()


def _first_language(path):
    """The value of the first `language:` line of a file; "" when there is none or the file cannot be read.
    Like `while read`, a last line with no newline is not seen."""
    try:
        with open(path, "rb") as f:
            lines = f.read().split(b"\n")[:-1]
    except OSError:
        return ""
    for line in lines:
        m = _LANG_RE.match(line.decode("utf-8", "replace"))
        if m:
            return m.group(1)
    return ""


def language():
    """FACTORY_LANGUAGE (set when the run started) wins; else this machine's overrides.yml, then factory.yml."""
    lang = os.environ.get("FACTORY_LANGUAGE", "")
    config = os.environ.get("FACTORY_CONFIG", "")
    cut = max(config.rfind("/"), config.rfind("\\"))
    folder = config[:cut] if cut >= 0 else config
    for path in (folder + "/overrides.yml", config):
        if lang:
            break
        lang = _first_language(path)
    return lang


def _translated(lang, data):
    """What a gate said on stderr, in the project's language (the phrases the catalog knows; the rest as it is)."""
    if not data or lang in ("", "en"):
        return data
    try:
        return text.say(lang, data.decode("utf-8")).encode("utf-8")
    except (UnicodeError, RuntimeError, OSError):
        return data


def _verdict(cmd, code):
    """The English line a gate ends with, and the same in <lock>/last-gate for the dispatcher."""
    if code == 0:
        word, line = "pass", "gate %s: pass" % cmd
    elif code == 3:
        word, line = "INFRA", "gate %s: INFRA (exit 3)" % cmd
    else:
        word, line = "FAIL", "gate %s: FAIL (exit %d)" % (cmd, code)
    _stderr(line)
    lock = os.environ.get("SHIPFLOOR_RUN_LOCK", "")
    if lock and os.path.isdir(lock):
        try:
            with open(os.path.join(lock, "last-gate"), "wb") as f:
                f.write(("%s\t%s\n" % (cmd, word)).encode("utf-8", "surrogateescape"))
        except OSError:
            pass


def _run(ctx, cmd, args):
    if cmd not in GATES:
        ctx.err(USAGE.rstrip("\n"))
        return 2
    module, name = GATES[cmd]
    fn = getattr(importlib.import_module("." + module, __package__), name)
    try:
        return fn(ctx, args) or 0
    except GateExit as e:  # an `exit` inside a check ends the whole gate
        return e.code


def main(argv):
    """The gate named by argv (what follows `gate.sh`); returns the exit code: 0 pass, 1 blocked, 2 usage, 3 infrastructure."""
    args = list(argv)
    handed = os.environ.pop("SHIPFLOOR_GATE_PY", "")  # the SHIPFLOOR_PY gate.sh was started with (lib/py.sh replaced it)
    if handed:
        os.environ["SHIPFLOOR_PY"] = handed
    if args[:1] == ["-C"]:
        folder = args[1] if len(args) > 1 else ""
        if folder:
            try:
                os.chdir(folder)
            except OSError:
                _stderr("gate: cannot enter '%s'" % folder)
                return 2
        args = args[2:] if len(args) > 1 else args
    cmd = args[0] if args else ""
    if cmd in ("-h", "--help", "help"):
        sys.stdout.write(USAGE)
        sys.stdout.flush()
        return 0
    if cmd == "":
        sys.stderr.write(USAGE)
        sys.stderr.flush()
        return 2
    # Paths, layers and commands come from the project's config (its control checkout), never from the worktree
    # under test. No project or a broken config is exit 2, never a pass.
    try:
        project.resolve(".")
    except project.ProjectError as e:
        _stderr(str(e))
        return 2
    ctx = Context()
    code = _run(ctx, cmd, args[1:])
    sys.stderr.flush()
    data = _translated(language(), ctx.stderr_bytes())
    if data:
        sys.stderr.buffer.write(data)
        sys.stderr.buffer.flush()
    if cmd not in NO_VERDICT:
        _verdict(cmd, code)
    return code
