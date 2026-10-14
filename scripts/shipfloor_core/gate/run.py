"""The gates that run a layer's commands: build, red, green, and stack (what scripts/lib/gate-run.sh did, behaving the
same): the layer's dependencies installed once per content, the runner's output read for the verdict, a layer with
needs_stack run on its own stack slot (shipfloor_core.stack), and the pass cache that lets build and green answer
for a commit they already passed on."""
import contextlib
import datetime
import hashlib
import os
import re
import signal
import subprocess
import sys
import time

from .. import proc, stack, text
from . import changes

_SCRIPTS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_CORE = os.path.join(_SCRIPTS, "shipfloor_core")

SETUP_ERRORS = ("compilation (error|failure)|unresolved reference|cannot find module|syntaxerror|error TS[0-9]+|"
                "could not resolve|transform failed|is not a function|is not defined|ERR_CONNECTION|ECONNREFUSED|"
                "failed to load applicationcontext|beancreationexception|Errors: [1-9]|^ERROR: ")
ASSERTIONS = (r"AssertionFailedError|AssertionError|expected: ?<.*> but was|expect\(.*\)\.[A-Za-z]+\(.*\) failed|"
              r"^[[:space:]]*Received:")
STAMP = ".code"  # in the pass store: the hash of the gate's code its records were made with
_INT = re.compile(r"-?[0-9]+")


def _text(data):
    return data.decode("utf-8", "surrogateescape")


def _enc(text):
    return text.encode("utf-8", "surrogateescape")


def _int(value):
    value = (value or "").strip()
    return int(value) if _INT.fullmatch(value) else 0


def _git(*args):
    """git's stdout without trailing newlines ("" when it fails); its stderr is nobody's."""
    try:
        r = proc.git(*args)
    except OSError:
        return ""
    return _text(r.stdout).rstrip("\n") if r.returncode == 0 else ""


def _grep(ctx, flags, pattern, data):
    """`... | grep <flags> -- <pattern>` on data (bytes): (exit code, stdout bytes); grep's complaint goes to the gate."""
    r = text.grep(flags, pattern, data)
    ctx.err_bytes(r.stderr)
    return r.returncode, r.stdout


def _head(data, n):
    return b"".join(data.splitlines(keepends=True)[:n])


def _tail(data, n):
    return b"".join(data.splitlines(keepends=True)[-n:])


def ere_ok(pattern):
    """grep -E accepts the pattern (exit 2 = invalid)."""
    r = text.grep("-E", pattern, b"", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode != 2


def root():
    return _git("rev-parse", "--show-toplevel") or os.getcwd()


@contextlib.contextmanager
def _stderr_to(ctx, live=False):
    """What shipfloor_core.stack writes on stderr goes to the gate's stderr (translated with the rest at the end); live:
    out at once, translated line by line (`gate.sh stack up` waiting in the queue says where it is while it waits)."""
    real = sys.stderr
    if live:
        from .main import _translated, language
        lang = language()

    def put(data):
        if live:
            real.buffer.write(_translated(lang, data))
            real.buffer.flush()
        else:
            ctx.err_bytes(data)

    class _Bytes:
        def write(self, data):
            put(bytes(data))
            return len(data)

        def flush(self):
            pass

    class _Text(_Bytes):
        buffer = _Bytes()

        def write(self, text):
            put(_enc(text))
            return len(text)

    sys.stderr.flush()
    saved, sys.stderr = sys.stderr, _Text()
    try:
        yield
    finally:
        sys.stderr = saved


def layer_fields(ctx, layer, *fields):
    """The layer's fields from the config, or None (and 'unknown layer' said) when it has no such layer."""
    r = changes._cfg(("fields", layer, *fields))
    parts = r.stdout.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    if len(parts) != len(fields):
        ctx.err("gate: unknown layer '%s'" % layer)
        return None
    return [_text(p) for p in parts]


def _in(path):
    return os.path.join(root(), path)


def _missing_dir(ctx, path):
    ctx.err("cd: %s: No such file or directory" % path)


def ensure_deps(ctx, path, install):
    """The layer's dependencies, installed by the gate, not by an agent: once per content of the layer's directory (its
    tree at HEAD), remembered inside the git dir so the worktree stays clean. 0, or 3 when the install fails."""
    if not install:
        return 0
    gitdir = _git("rev-parse", "--absolute-git-dir")
    mark = gitdir + "/shipfloor-install-" + _text(re.sub(rb"[^A-Za-z0-9]", b"_", _enc(path)))
    tree = path[:-1] if path.endswith("/") else path
    key = _git("rev-parse", "-q", "--verify", "HEAD:" + tree) + " " + install
    try:
        with open(mark, encoding="utf-8", errors="surrogateescape") as f:
            if f.read().rstrip("\n") == key:
                return 0
    except OSError:
        pass
    folder = _in(path)
    if not os.path.isdir(folder):
        _missing_dir(ctx, folder)
        rc = 1
    else:
        r = subprocess.run(["bash", "-c", install], cwd=folder, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        ctx.err_bytes(r.stdout)
        rc = r.returncode
    if rc != 0:
        ctx.err("gate: install failed in %s: %s" % (path, install))
        return 3
    try:
        with open(mark, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.write(key)
    except OSError:
        pass
    return 0


# ---- the pass cache: a pass recorded on a clean tree answers the same gate on the same inputs

def code_hash():
    """The hash of the gate's code: every file under shipfloor_core/ (names and contents, __pycache__ left out) and
    sf.py. An upgrade that changes any of them stops the passes recorded before from answering."""
    h = hashlib.sha1()
    for top, dirs, files in os.walk(_CORE):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for name in sorted(files):
            if name.endswith((".pyc", ".pyo")):
                continue
            path = os.path.join(top, name)
            with open(path, "rb") as f:
                data = f.read()
            h.update(_enc(os.path.relpath(path, _SCRIPTS).replace(os.sep, "/")) + b"\0")
            h.update(hashlib.sha1(data).digest())
    with open(os.path.join(_SCRIPTS, "sf.py"), "rb") as f:
        h.update(b"sf.py\0" + hashlib.sha1(f.read()).digest())
    return h.hexdigest()


def _real(path):
    try:
        return os.path.realpath(path) if path and os.path.isdir(path) else ""
    except OSError:
        return ""


def _inside(path, top):
    return (path + "/").startswith(top.rstrip("/") + "/")


def _hash_object(*args, data=None):
    r = subprocess.run(["git", "hash-object", *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return _text(r.stdout).strip() if r.returncode == 0 else ""


def _stamped(store):
    """The store's records were made with this code; a store stamped by other code is emptied first (an upgrade).
    A store with no stamp yet (records of the Bash gate, whose keys no longer match) keeps its records."""
    stamp = os.path.join(store, STAMP)
    code = code_hash()
    try:
        with open(stamp, encoding="utf-8") as f:
            had = f.read().strip()
    except OSError:
        had = None
    if had == code:
        return
    if had is not None:
        for name in os.listdir(store):
            path = os.path.join(store, name)
            if not name.startswith(".") and os.path.isfile(path):
                try:
                    os.unlink(path)
                except OSError:
                    pass
    tmp = "%s.%d.tmp" % (stamp, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(code + "\n")
        os.replace(tmp, stamp)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


class Pass:
    """Where this call's pass is recorded (file "" = run, record nothing)."""
    file = ""
    head = ""

    def __init__(self, gate, args):
        self.gate, self.args = gate, args


def pass_key(gate, args, *lines):
    """Only a clean worktree, a store outside it and no SHIPFLOOR_GATE_FRESH=1 count. The key (HEAD, the gate, its key
    lines, the config's and gate.sh's hashes) is read before the command runs; the store is stamped with the code."""
    p = Pass(gate, args)
    home = os.environ.get("FACTORY_HOME", "")
    if os.environ.get("SHIPFLOOR_GATE_FRESH") == "1" or not home or _git("status", "--porcelain"):
        return p
    top = _real(_git("rev-parse", "--show-toplevel"))
    home = _real(home)
    if not top or not home or _inside(home, top):
        return p
    try:
        os.makedirs(os.path.join(home, "gate-passes"), exist_ok=True)
    except OSError:
        return p
    store = _real(os.path.join(home, "gate-passes"))
    if not store or _inside(store, top):
        return p
    cfg = _hash_object("--no-filters", "--", os.environ.get("FACTORY_CONFIG", ""))
    me = _hash_object("--no-filters", "--", os.path.join(_SCRIPTS, "gate.sh"))
    head = _git("rev-parse", "HEAD")
    if not cfg or not me or not head:
        return p
    _stamped(store)
    key = _hash_object("--stdin", data=_enc("".join(v + "\n" for v in (head, gate, *lines, cfg, me))))
    if key:
        p.file, p.head = os.path.join(store, key), head
    return p


def pass_reused(ctx, p):
    """A pass recorded under p.file answers for the gate."""
    if not p.file or not os.path.isfile(p.file):
        return False
    try:
        with open(p.file, encoding="utf-8", errors="surrogateescape", newline="") as f:
            content = f.read()
    except OSError:
        return False
    if "\n" not in content:
        return False
    at = content.split("\n", 1)[0].split("\t", 1)[0]
    ctx.err("%s: reused the pass on %s recorded %s; nothing ran" % (p.gate, p.head[:12], at))
    return True


def pass_record(p):
    """After exit 0: one file per pass, moved into place (mv, as the Bash gate did); records older than 14 days go."""
    if not p.file:
        return
    tmp = "%s.%d.tmp" % (p.file, os.getpid())
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
            f.write("%s\t%s\t%s\t%s\n" % (stamp, p.head, p.gate, p.args))
        try:
            moved = subprocess.run(["mv", tmp, p.file], stderr=subprocess.DEVNULL).returncode == 0
        except OSError:
            os.replace(tmp, p.file)
            moved = True
        if not moved:
            os.unlink(tmp)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    now = time.time()
    for top, _dirs, files in os.walk(os.path.dirname(p.file)):
        for name in files:
            path = os.path.join(top, name)
            if top == os.path.dirname(p.file) and name == STAMP:
                continue
            try:
                if int((now - os.stat(path).st_mtime) // 86400) > 14:  # find -mtime +14
                    os.unlink(path)
            except OSError:
                pass


# ---- build

def _build(ctx, path, cmd):
    """The layer's build from its own directory: its stdout is the gate's, its stderr the gate's stderr."""
    folder = _in(path)
    if not os.path.isdir(folder):
        _missing_dir(ctx, folder)
        return 1
    sys.stdout.flush()
    r = subprocess.run(["bash", "-c", cmd], cwd=folder, stderr=subprocess.PIPE)
    ctx.err_bytes(r.stderr)
    return r.returncode


def build_run(ctx, base):
    """Each implementer layer with changes runs its build from its own directory."""
    changes.config_query(ctx, "layers")
    implementers = changes.config_query(ctx, "layers", "--implementers")
    files = _enc("\n".join(changes.changed_files(ctx, base)) + "\n")
    for layer in implementers.split():
        f = layer_fields(ctx, layer, "_path_re", "path", "build", "install", "retry")
        if f is None:
            ctx.exit(2)
        path_re, path, cmd, install, retry = f
        if not cmd or _grep(ctx, "-Eq", path_re, files)[0] != 0:
            continue
        if ensure_deps(ctx, path, install) != 0:
            ctx.exit(3)
        if _build(ctx, path, cmd) == 0:
            continue
        # a layer with retry: 1 builds once more, as green does: a build that passes the second time broke on the
        # machine (a database that was slow to start, a worker that did not come up), not on the code
        if _int(retry) >= 1 and _build(ctx, path, cmd) == 0:
            ctx.out("flaky: %s build" % layer)
            continue
        ctx.err("build: %s build failed" % layer)
        return 1
    return 0


def build(ctx, args):
    """build <base>: answered by a recorded pass, else build_run."""
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    base = args[0] if args else ""
    changes.require_rev(ctx, base)
    main = os.environ.get("FACTORY_MAIN") or "main"
    p = pass_key("build", base, _git("rev-parse", base + "^{commit}"),
                 _git("rev-parse", "-q", "--verify", "origin/%s^{commit}" % main))
    if pass_reused(ctx, p):
        return 0
    code = build_run(ctx, base)
    if code == 0:
        pass_record(p)
    return code


# ---- red and green

class Layer:
    def __init__(self, name, fields):
        self.name = name
        self.path, self.test, self.ran, self.assertions, self.setup, self.stack, retry, self.install = fields
        self.retry = retry or "0"


def load_layer(ctx, name):
    """The layer's fields with its dependencies installed; None (2) for an unknown layer or a pattern grep refuses."""
    f = layer_fields(ctx, name, "path", "test", "ran", "assertions", "setup_errors", "needs_stack", "retry", "install")
    if f is None:
        return None
    layer = Layer(name, f)
    if ensure_deps(ctx, layer.path, layer.install) != 0:
        ctx.exit(3)
    for p in (layer.ran, layer.assertions, layer.setup):  # a pattern grep -E rejects reads as "no match"
        if p and not ere_ok(p):
            ctx.err("gate: layer '%s' has an invalid grep -E pattern: %s" % (name, p))
            return None
    return layer


def run_selector(layer, selector):
    """(runner output, exit code). The selector reaches the runner as "$1" of `bash -c`, never as shell code."""
    os.environ["NO_COLOR"], os.environ["FORCE_COLOR"] = "1", "0"  # runners print plain text so the patterns match
    folder = _in(layer.path)
    if not os.path.isdir(folder):
        return b"gate: layer directory %s not found" % _enc(layer.path), 1
    r = subprocess.run(["bash", "-c", layer.test.replace("{selector}", '"$1"'), "_", selector], cwd=folder,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.rstrip(b"\n"), r.returncode


def red_run(ctx, layer, selector):
    """Never retried: a test that must fail cannot be flaky."""
    setup = SETUP_ERRORS + ("|" + layer.setup if layer.setup else "")
    assertions = ASSERTIONS + ("|" + layer.assertions if layer.assertions else "")
    out, code = run_selector(layer, selector)
    if code == 0:
        ctx.err("red: tests passed before implementation; they prove nothing")
        return 1
    out += b"\n"
    if _grep(ctx, "-Eiq", setup, out)[0] == 0:
        ctx.err("red: tests fail for setup/compile reasons, not behavior:")
        ctx.err_bytes(_head(_grep(ctx, "-Ei", setup, out)[1], 5))
        return 1
    if _grep(ctx, "-Eq", assertions, out)[0] != 0:
        ctx.err("red: no assertion failure found in test output")
        return 1
    ctx.out_bytes(_head(_grep(ctx, "-E", assertions, out)[1], 20))
    return 0


def green_run(ctx, layer, selector):
    """A layer with retry: 1 runs a failed selector once more."""
    out, code = run_selector(layer, selector)
    if code != 0 and _int(layer.retry) >= 1:
        out, code = run_selector(layer, selector)
        if code == 0:
            ctx.out("flaky: %s %s" % (layer.name, selector))
    out += b"\n"
    if code != 0:
        ctx.err("green: acceptance tests fail:")
        ctx.err_bytes(_tail(out, 20))
        return 1
    if _grep(ctx, "-Eq", layer.ran, out)[0] != 0:
        ctx.err("green: no acceptance test ran for '%s'" % selector)
        return 1
    return 0


def _raise(signum, frame):
    raise stack.Interrupted()


def stack_around(ctx, layer, fn):
    """fn() on the layer's own stack slot when it needs one (owner gate-<pid>); 3 = infrastructure. INT or TERM gives
    the ticket or the slot back and ends the gate with 3 (and its INFRA verdict)."""
    if layer.stack != "true":
        return fn()
    owner = "gate-%d" % os.getpid()
    with _stderr_to(ctx):
        s = stack.read_settings()
    held = stack._Held()
    saved = {sig: signal.signal(sig, _raise) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with _stderr_to(ctx):
            url = stack.up(s, owner, held)
        if url is None:
            return 3
        os.environ.update((n, v) for n, v in stack.slot_vars(s, held.k) if stack._IDENT.fullmatch(n))
        code = fn()
    except stack.Interrupted:
        for sig in saved:
            signal.signal(sig, signal.SIG_IGN)
        with _stderr_to(ctx):
            if held.ticket:
                stack._rm(held.ticket)
            stack._give_back(s, held)
            stack.down(s, owner)
        ctx.exit(3)
    finally:
        for sig, handler in saved.items():
            signal.signal(sig, handler)
    with _stderr_to(ctx):
        stack.down(s, owner)
    return code


def red(ctx, args):
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    if len(args) < 2 or not args[1]:
        ctx.err("red: selector required")
        return 2
    layer = load_layer(ctx, args[0])
    if layer is None:
        return 2
    return stack_around(ctx, layer, lambda: red_run(ctx, layer, args[1]))


def green(ctx, args):
    """The acceptance tests must run (the layer's `ran` pattern) and pass."""
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    if len(args) < 2 or not args[1]:
        ctx.err("green: selector required")
        return 2
    name, selector = args[0], args[1]
    p = pass_key("green", "%s %s" % (name, selector), name, selector)
    if pass_reused(ctx, p):
        return 0
    layer = load_layer(ctx, name)
    if layer is None:
        return 2
    code = stack_around(ctx, layer, lambda: green_run(ctx, layer, selector))
    if code == 0:
        pass_record(p)
    return code


def stack_gate(ctx, args):
    """gate.sh stack up <owner> | down <owner> | status (shipfloor_core.stack)."""
    word = args[0] if args else ""
    if word in ("up", "down"):
        if len(args) < 2 or not args[1]:
            return 2
        argv = [word, args[1]]
    elif word == "status":
        argv = ["status"]
    else:
        ctx.err("stack: up <owner> | down <owner> | status")
        return 2
    with _stderr_to(ctx, live=True):
        return stack.main(argv)
