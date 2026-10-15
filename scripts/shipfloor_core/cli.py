"""cli: the shipfloor command (scripts/shipfloor is its wrapper): installs the factory and manages the projects.

The port of the Bash scripts/shipfloor (#170). The usage text is the wrapper's header (lines 2-10), as before. Commands,
flags, output, exit codes, registry.tsv, accepted.tsv, .source and .origin are the same; every script the Bash CLI ran
(gate.sh, board.sh, setup-board.sh, metrics.sh, install-dispatcher.sh, dashboard.py, shipfloor_health.py, git, gh)
still runs as a process with the same argv.
"""
import fnmatch
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime

import runtimes

from . import fs, proc, project, text

PIPE, DEVNULL, STDOUT = subprocess.PIPE, subprocess.DEVNULL, subprocess.STDOUT


def _logical(path):
    """The path as `cd <dir> && pwd` names it: under $PWD when the working directory is reached through a symlink."""
    cwd, pwd = os.getcwd(), os.environ.get("PWD", "")
    if pwd and os.path.isabs(pwd) and pwd != cwd and (path == cwd or path.startswith(cwd.rstrip(os.sep) + os.sep)):
        try:
            if os.path.samefile(pwd, cwd):
                return pwd.rstrip(os.sep) + path[len(cwd.rstrip(os.sep)):] if path != cwd else pwd
        except OSError:
            pass
    return path


HERE = _logical(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class CliExit(Exception):
    """Leave with this exit code (the Bash script's `exit <code>`)."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def die(msg, code=1):
    _err("shipfloor: " + msg)
    raise CliExit(code)


def _out(s):
    sys.stdout.write(s + "\n")


def _err(s):
    sys.stdout.flush()
    sys.stderr.write(s + "\n")
    sys.stderr.flush()


def _t(b):
    return b.decode("utf-8", "surrogateescape")


def _run(argv, out=None, err=None, cwd=None, env=None):
    """Run a command; (exit code, stdout bytes when out is PIPE). Streams left None are this process's own."""
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        r = subprocess.run(argv, cwd=cwd, env=env, stdout=out, stderr=err)
    except OSError as e:
        if err is None:
            _err("%s: %s" % (argv[0], e.strerror or e))
        return 127, b""
    rc = r.returncode
    return (128 - rc if rc < 0 else rc), (r.stdout or b"")


def _cap(argv, err=None, cwd=None, env=None):
    """$(command): (exit code, stdout without its trailing newlines)."""
    rc, out = _run(argv, out=PIPE, err=err, cwd=cwd, env=env)
    return rc, _t(out).rstrip("\n")


def _git(*args, err=None):
    return _cap(["git", *args], err=err)


def _pass_through(r):
    """Write a captured CompletedProcess's streams to this process's own (what Bash left uncaptured)."""
    sys.stdout.flush()
    if r.stdout:
        sys.stdout.buffer.write(r.stdout)
        sys.stdout.buffer.flush()
    if r.stderr:
        sys.stderr.buffer.write(r.stderr)
        sys.stderr.buffer.flush()


def _write_err(data):
    if data:
        sys.stdout.flush()
        sys.stderr.buffer.write(data)
        sys.stderr.buffer.flush()


def _cfg_value(*query):
    """$(shipfloor_cfg <query>): stdout without trailing newlines; stderr goes through."""
    r = project.cfg(*query)
    _write_err(r.stderr)
    return r.returncode, _t(r.stdout).rstrip("\n")


def _read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def _first_line(path):
    data = _read_bytes(path)
    return None if data is None else _t(data).split("\n", 1)[0]


def _int(s):
    try:
        return int(str(s).strip())
    except ValueError:
        return None


def _touch(path):
    with open(path, "a"):
        pass
    os.utime(path, None)


def _rm(path):
    """rm -rf"""
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            os.unlink(path)
        except OSError:
            pass


# --- the registry ----------------------------------------------------------------------------------------------------

def _home():
    return project.shipfloor_home()


def _registry():
    return os.path.join(_home(), "registry.tsv")


def _installed():
    return os.path.join(_home(), "factory")


def _records():
    """The registry's lines as awk reads them (a last line without its newline counts); [] when there is no file."""
    data = _read_bytes(_registry())
    if data is None:
        return []
    lines = _t(data).split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def _rows():
    """The registry's lines as `while read` sees them: only the ones that end with a newline."""
    data = _read_bytes(_registry())
    return [] if data is None else _t(data).split("\n")[:-1]


def _cut(line, n):
    """cut -f<n>: a line without a tab comes out whole."""
    if "\t" not in line:
        return line
    parts = line.split("\t")
    return parts[n - 1] if len(parts) >= n else ""


def entry(slug):
    """The registry lines whose first field is the slug, newline-joined ("" for none)."""
    return "\n".join(l for l in _records() if l.split("\t")[0] == slug).rstrip("\n")


def use(slug):
    """Export that project's settings or fail."""
    line = entry(slug)
    if not line:
        die("no project '%s' (shipfloor list)" % slug)
    s, repo, wt, main = text.read_tab(line.split("\n")[0], 4)
    project.use(s, repo, wt or None, main or None)


class _ProjectEnv:
    """A subshell's `shipfloor_use ...`: the project's settings, then the environment as it was."""

    def __init__(self, slug, repo, wt, main):
        self.args = (slug, repo, wt or None, main or None)

    def __enter__(self):
        self.saved = dict(os.environ)
        project.use(*self.args)
        return self

    def __exit__(self, *exc):
        os.environ.clear()
        os.environ.update(self.saved)
        return False


def _write_registry(lines):
    fs.write_atomic(_registry(), "".join(l + "\n" for l in lines).encode("utf-8", "surrogateescape"))


def source_dir():
    """The plugin checkout this copy came from."""
    data = _read_bytes(os.path.join(HERE, ".source"))
    if data is not None:
        return _t(data).rstrip("\n")
    return os.path.dirname(HERE)


def main_of(clone):
    """Its main branch, as add reads it."""
    m = _git("-C", clone, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD", err=DEVNULL)[1]
    if m.startswith("origin/"):
        m = m[len("origin/"):]
    return m or "main"


# --- install ---------------------------------------------------------------------------------------------------------

def _same_bytes(a, b):
    x, y = _read_bytes(a), _read_bytes(b)
    return x is not None and x == y


def _tmp_of(to):
    return os.path.join(os.path.dirname(to), "." + os.path.basename(to) + ".install-tmp")


def put_file(src, to):
    """same | added | replaced | failed: copy beside the target (mode and times kept), then rename over it."""
    if os.path.isfile(to):
        if _same_bytes(src, to):
            return "same"
        kind = "replaced"
    else:
        kind = "added"
    tmp = _tmp_of(to)
    try:
        os.makedirs(os.path.dirname(to), exist_ok=True)
        shutil.copy2(src, tmp)
        os.replace(tmp, to)
        return kind
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return "failed"


def _put_text(data, to):
    """put_file for a file whose content is given: same | added | replaced | failed."""
    if os.path.isfile(to):
        if _read_bytes(to) == data:
            return "same"
        kind = "replaced"
    else:
        kind = "added"
    tmp = _tmp_of(to)
    try:
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, to)
        return kind
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return "failed"


def _skipped(rel):
    """What the plugin never ships from scripts/: test/ at its top, a __pycache__ anywhere, a .pyc."""
    parts = rel.split("/")
    return parts[0] == "test" or "__pycache__" in parts or parts[-1].endswith(".pyc")


def _files(root, skip=None):
    """The regular files under root (no symlinks), relative and with /, sorted; `skip` prunes what it names."""
    out = []
    for d, dirs, files in os.walk(root):
        rel = os.path.relpath(d, root).replace(os.sep, "/")
        rel = "" if rel == "." else rel + "/"
        dirs[:] = sorted(x for x in dirs if not (skip and skip(rel + x)))
        for f in sorted(files):
            p = os.path.join(d, f)
            if os.path.islink(p) or not os.path.isfile(p) or (skip and skip(rel + f)):
                continue
            out.append(rel + f)
    return out


def _native(rel):
    return rel.replace("/", os.sep)


def source_state(src):
    """Why the clone is not a clean, current main (reasons: (reason, what to do)), and what it read."""
    st = {"git": False, "reasons": [], "main": "main", "commit": "", "branch": ""}
    if not os.path.exists(os.path.join(src, ".git")):  # in a worktree .git is a file
        return st
    st["git"] = True
    st["main"] = mb = main_of(src)
    st["commit"] = _git("-C", src, "rev-parse", "HEAD")[1]
    st["branch"] = br = _git("-C", src, "symbolic-ref", "-q", "--short", "HEAD")[1]
    reasons = st["reasons"]
    if not br:
        reasons.append(("on a detached HEAD at %s, not %s" % (_git("-C", src, "rev-parse", "--short", "HEAD")[1], mb),
                        "git -C %s checkout %s" % (src, mb)))
    elif br != mb:
        reasons.append(("on branch %s, not %s" % (br, mb), "git -C %s checkout %s" % (src, mb)))
    rc, out = _run(["git", "-C", src, "-c", "core.quotePath=false", "status", "--porcelain", "--untracked-files=no"],
                   out=PIPE)
    changed = [l[3:] for l in _t(out).split("\n")[:-1]]
    if changed:
        listed = ", ".join(changed[:10]) + (", and %d more" % (len(changed) - 10) if len(changed) > 10 else "")
        reasons.append(("%d tracked file(s) with uncommitted changes: %s" % (len(changed), listed), "commit or stash them"))
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    if _run(["git", "-C", src, "fetch", "-q", "origin", mb], err=DEVNULL, env=env)[0] == 0:
        counts = _git("-C", src, "rev-list", "--left-right", "--count", "HEAD...origin/" + mb)[1].split()
        ahead, behind = (_int(counts[0]), _int(counts[1])) if len(counts) >= 2 else (None, None)
        if behind and behind > 0:
            reasons.append(("%d commit(s) behind origin/%s" % (behind, mb), "git -C %s pull" % src))
        if ahead and ahead > 0:
            reasons.append(("%d commit(s) ahead of origin/%s" % (ahead, mb), "they are not merged; push and merge them first"))
    else:
        reasons.append(("could not check the remote (git fetch origin %s failed)" % mb, "check the network and the origin remote"))
    return st


def _generate_codex_home(src, inst, home, bad):
    """The factory's CODEX_HOME, when a runtime of the machine or of a project is codex (runtimes/codex_gen.py)."""
    from runtimes import codex, codex_gen
    import shipfloor_config
    try:
        import yaml
        with open(os.path.join(home, "config.yml"), encoding="utf-8") as f:
            raw = yaml.safe_load(f)
    except (OSError, ValueError, ImportError):
        raw = None
    except Exception:  # YAML that does not parse: doctor and validate say so
        raw = None
    models = shipfloor_config.runtime_setting(raw, None, "models") or {}
    agents = models.get("agents") if isinstance(models, dict) and isinstance(models.get("agents"), dict) else {}
    try:
        n = codex_gen.generate(src, codex.data_dir(), inst, agents)
    except (OSError, ValueError) as e:
        bad("CODEX_HOME (%s)" % (getattr(e, "strerror", None) or e))
        return
    _out("codex: CODEX_HOME %s: %d file%s written" % (codex.data_dir(), n, "" if n == 1 else "s"))


def _generate_opencode_home(src, home, bad):
    """The factory's OPENCODE_CONFIG_DIR, when a runtime of the machine or of a project is opencode (runtimes/opencode_gen.py)."""
    from runtimes import opencode, opencode_gen
    import shipfloor_config
    try:
        import yaml
        with open(os.path.join(home, "config.yml"), encoding="utf-8") as f:
            raw = yaml.safe_load(f)
    except Exception:  # missing, or YAML that does not parse: doctor and validate say so
        raw = None
    models = shipfloor_config.runtime_setting(raw, None, "models") or {}
    agents = models.get("agents") if isinstance(models, dict) and isinstance(models.get("agents"), dict) else {}
    try:
        n = opencode_gen.generate(src, opencode.data_dir(), agents)
    except (OSError, ValueError) as e:
        bad("OPENCODE_CONFIG_DIR (%s)" % (getattr(e, "strerror", None) or e))
        return
    _out("opencode: OPENCODE_CONFIG_DIR %s: %d file%s written" % (opencode.data_dir(), n, "" if n == 1 else "s"))


def cmd_install(args):
    src, force, kind = source_dir(), False, "verified"
    for a in args:
        if a == "--force":
            force = True
        else:
            die("usage: shipfloor install [--force]", 2)
    if not os.path.isfile(os.path.join(src, "scripts", "gate.sh")):
        die("cannot find the plugin at %s" % src)
    st = source_state(src)
    if st["reasons"]:
        if not force:
            _err("shipfloor: not installing from %s:" % src)
            for why, todo in st["reasons"]:
                _err("  %s: %s" % (why, todo))
            _err("install anyway: shipfloor install --force")
            return 1
        kind = "forced"
    home, inst = _home(), _installed()
    for d in (inst, os.path.join(home, "projects"), os.path.join(home, "logs")):
        os.makedirs(d, exist_ok=True)
    counts = {"replaced": 0, "added": 0, "removed": 0, "bad": 0}

    def bad(name):
        counts["bad"] += 1
        _err("shipfloor: could not replace %s" % name)

    # every file goes in by rename, so a running script keeps its old inode and a reader never sees half a file
    for f in _files(inst):  # leftovers of a killed install
        if fnmatch.fnmatchcase(f.rsplit("/", 1)[-1], ".*.install-tmp"):
            try:
                os.unlink(os.path.join(inst, _native(f)))
            except OSError:
                pass
    scripts, templates = os.path.join(src, "scripts"), os.path.join(src, "templates")
    for base, prefix, skip, dest in ((scripts, "", _skipped, inst),
                                     (templates, "templates/", None, os.path.join(inst, "templates"))):
        for f in _files(base, skip):
            put = put_file(os.path.join(base, _native(f)), os.path.join(dest, _native(f)))
            if put == "failed":
                bad(prefix + f)
            elif put != "same":
                counts[put] += 1
    os.makedirs(os.path.join(inst, "templates"), exist_ok=True)

    # drop what the plugin no longer ships (a script or template it renamed or removed): scripts, then templates
    def drop(path, name, count=True):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        except OSError:
            pass
        if os.path.lexists(path):
            if count:
                bad(name)
        elif count:
            counts["removed"] += 1

    for f in _files(inst, lambda rel: rel == "templates" or rel.startswith("templates/")):
        name = f.rsplit("/", 1)[-1]
        if name in (".source", ".origin") or fnmatch.fnmatchcase(name, ".*.install-tmp"):
            continue
        if _skipped(f):  # never shipped, never counted
            drop(os.path.join(inst, _native(f)), f, count=False)
        elif not os.path.isfile(os.path.join(scripts, _native(f))):
            drop(os.path.join(inst, _native(f)), f)
    for f in _files(os.path.join(inst, "templates")):
        if fnmatch.fnmatchcase(f.rsplit("/", 1)[-1], ".*.install-tmp"):
            continue
        if not os.path.isfile(os.path.join(templates, _native(f))):
            drop(os.path.join(inst, "templates", _native(f)), "templates/" + f)
    keep = os.path.normcase(os.path.join(inst, "templates"))
    for d, _dirs, _files_ in os.walk(inst, topdown=False):  # only the empty ones go
        if os.path.normcase(d) in (keep, os.path.normcase(inst)):
            continue
        try:
            os.rmdir(d)
        except OSError:
            pass

    # .origin, then .source last and only when all is in place: doctor then never says "matches" for a half copy
    if counts["bad"] == 0:
        origin = os.path.join(inst, ".origin")
        if st["git"]:
            line = "%s\t%s\t%s\n" % (st["commit"], st["branch"] or "detached", kind)
            if _put_text(line.encode("utf-8", "surrogateescape"), origin) == "failed":
                bad(".origin")
        else:
            try:
                os.unlink(origin)
            except OSError:
                pass
        # by rename too: other commands read it while an install runs
        if _put_text((src + "\n").encode("utf-8", "surrogateescape"), os.path.join(inst, ".source")) == "failed":
            bad(".source")
    if counts["bad"] == 0 and "codex" in _runtimes_in_use():
        _generate_codex_home(src, inst, home, bad)
    if counts["bad"] == 0 and "opencode" in _runtimes_in_use():
        _generate_opencode_home(src, home, bad)
    _out("installed %s → %s: %d replaced, %d added, %d removed" % (src, inst, counts["replaced"], counts["added"],
                                                                  counts["removed"]))
    if re.match(r"(MINGW|MSYS|CYGWIN)", proc.uname_s()):
        _out('next: shipfloor add <repo>; then (Windows) powershell -File "%s/installer/install-dispatcher.ps1"' % src)
    else:
        _out('next: shipfloor add <repo>; then bash "%s/installer/install-dispatcher.sh"' % src)
    if kind == "forced":
        why = "; ".join(r[0] for r in st["reasons"])
        _out("WARN installed copy is not a verified %s: branch %s, commit %s (%s)"
             % (st["main"], st["branch"] or "detached", _git("-C", src, "rev-parse", "--short", "HEAD")[1], why))
    return 0 if counts["bad"] == 0 else 1


# --- doctor ----------------------------------------------------------------------------------------------------------

def _have(tool):
    """command -v <tool>"""
    if shutil.which(tool):
        return True
    if os.name == "nt":  # a script without an extension, which Git Bash runs and which() does not see
        return _run(["bash", "-c", 'command -v "$0"', tool], out=DEVNULL, err=DEVNULL)[0] == 0
    return False


def _same_tree(a, b, skip):
    """diff -rq -x <each of skip> a b finds nothing."""
    if not (os.path.isdir(a) and os.path.isdir(b)):
        return False
    try:
        na = set(os.listdir(a)) - skip
        nb = set(os.listdir(b)) - skip
    except OSError:
        return False
    if na != nb:
        return False
    for n in na:
        pa, pb = os.path.join(a, n), os.path.join(b, n)
        if os.path.isdir(pa) and os.path.isdir(pb):
            if not _same_tree(pa, pb, skip):
                return False
        elif os.path.isfile(pa) and os.path.isfile(pb):
            if not _same_bytes(pa, pb):
                return False
        else:
            return False
    return True


def _validate():
    """shipfloor_validate: the config is valid and every pattern works with grep -E."""
    r = project.cfg("validate")
    _pass_through(r)
    if r.returncode != 0:
        return False
    r = project.cfg("patterns")
    _write_err(r.stderr)
    ok = True
    for raw in r.stdout.split(b"\0")[:-1]:
        p = _t(raw)
        try:
            text.ere_match(p, "")
        except ValueError:
            _err("shipfloor-config: %s: '%s' is not a valid grep -E pattern" % (os.environ.get("FACTORY_CONFIG", ""), p))
            ok = False
    return ok


def _doctor_project(slug):
    """What doctor says about one valid project, in its own settings (the Bash subshell)."""
    before = os.environ.get("FACTORY_LANGUAGE")
    os.environ["FACTORY_LANGUAGE"] = ""  # FACTORY_LANGUAGE="" shipfloor_cfg language: what the repository or machine says
    r = project.cfg("language")
    if before is None:
        del os.environ["FACTORY_LANGUAGE"]
    else:
        os.environ["FACTORY_LANGUAGE"] = before
    lcode, lfrom, lname = text.read_tab(_t(r.stdout).replace("\r", "").split("\n", 1)[0], 3)
    if lcode:
        _out("ok   %s: writes in %s (%s), from %s" % (slug, lname, lcode, "this machine" if lfrom == "machine" else "the repository"))
    stale = len(project.stale_tmp())
    if stale > 0:
        _out("WARN %s: %d tmp dir(s) of finished cards; run: shipfloor clean %s" % (slug, stale, slug))
    home = os.environ["FACTORY_HOME"]
    skipped = os.path.join(home, "SKIPPED")
    if os.path.isfile(skipped) and os.path.getsize(skipped) > 0:
        since, why = text.read_tab(_first_line(skipped) or "", 2)
        _out("WARN %s: the dispatcher skips it since %s: %s" % (slug, since, why))
    control, main = os.path.join(home, "control"), os.environ["FACTORY_MAIN"]
    if os.path.exists(os.path.join(control, ".git")) and \
            _git("-C", control, "rev-parse", "HEAD", err=DEVNULL)[1] != \
            _git("-C", os.environ["FACTORY_REPO"], "rev-parse", "origin/" + main, err=DEVNULL)[1]:
        _out("WARN %s: control checkout is behind origin/%s; the next dispatcher cycle should move it "
             "(see ~/.shipfloor/logs/dispatcher.log if it does not)" % (slug, main))
    repo, b = _cfg_value("get", "project.repo")[1], _cfg_value("get", "project.main")[1]
    rc, out = _run(proc.gh_argv("api", "repos/%s/branches/%s/protection" % (repo, b), "--jq",
                                ".required_status_checks.strict"), out=PIPE, err=STDOUT)
    strict = _t(out).rstrip("\n") if out or rc != 127 else "command not found"  # no gh: what Bash said, after its last ": "
    if strict == "true":
        _out("ok   %s: %s requires up-to-date branches" % (slug, b))
    else:
        _out("WARN %s: %s does not require up-to-date branches (%s); a hand merge can race the deploy"
             % (slug, b, strict.rsplit(": ", 1)[-1]))


def _agents():
    """The agent of each implementing layer of the project in use."""
    found = []
    layers = _cfg_value("layers", "--implementers")[1]
    for layer in layers.split():
        r = project.cfg("layer", layer, "agent")
        _write_err(r.stderr)
        data = _t(r.stdout)
        parts = data.split("\n") if data else []
        if data.endswith("\n"):
            parts.pop()
        found += parts
    return found


def _limits_hint(src, home, got):
    """WARN when config.yml asks for limits the installed unit does not carry (systemd only)."""
    try:
        sys.path.insert(0, os.path.join(src, "scripts"))
        import shipfloor_config
        cfg = os.path.join(home, "config.yml")
        raw = shipfloor_config.load(cfg) if os.path.isfile(cfg) else None
        lim = shipfloor_config.machine_limits(raw.get("limits") if isinstance(raw, dict) else None)
    except Exception:  # no config or an invalid one: the installer says so itself
        return got
    want = "none" if all(v == "none" for v in lim.values()) else \
        "memory_max=%(memory_max)s cpu_weight=%(cpu_weight)s cpu_quota=%(cpu_quota)s" % lim
    if got.startswith("not supported"):  # "not supported" matters only when limits are configured
        return got if want != "none" else "none"
    if want not in ("none", got):
        _out("WARN config.yml asks for limits (%s) the installed dispatcher does not carry; reinstall: bash %s/installer/install-dispatcher.sh" % (want, src))
    return got


def _fs_type(path, mounts="/proc/self/mounts"):
    """The filesystem type of the longest mount point containing path (or its nearest existing parent); None when
    the mount table is unreadable."""
    try:
        with open(mounts, encoding="utf-8", errors="replace") as f:
            rows = [ln.split() for ln in f]
    except OSError:
        return None
    p = os.path.abspath(path)
    while not os.path.exists(p) and os.path.dirname(p) != p:
        p = os.path.dirname(p)
    best, kind = -1, None
    for row in rows:
        if len(row) < 3:
            continue
        mp = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), row[1])
        if (p == mp or p.startswith(mp.rstrip("/") + "/")) and len(mp) > best:
            best, kind = len(mp), row[2]
    return kind


def _runtimes_in_use():
    """The runtimes the machine config and every registered project's factory.yml name; claude-code when none."""
    found = []

    def add(r):
        for name in _t(r.stdout).split("\0"):
            if name and name in runtimes.NAMES and name not in found:
                found.append(name)

    add(project.machine("runtimes"))
    reg = _registry()
    if os.path.isfile(reg) and os.path.getsize(reg) > 0:
        for row in _rows():
            slug, repo, wt, main = text.read_tab(row, 4)
            if not slug:
                continue
            with _ProjectEnv(slug, repo, wt, main):
                cfg = os.environ.get("FACTORY_CONFIG", "")
                if cfg and os.path.isfile(cfg):
                    add(project.machine("runtimes", proc.native_path(cfg)))
    return found or [runtimes.NAMES[0]]


def _pace_words(pace):
    """'every 30 seconds' stays; 'every 180 seconds' reads 'every 3 minutes', 'every 60 seconds' 'every 1 minute'."""
    m = re.fullmatch(r"every (\d+) seconds", pace)
    if not m or int(m.group(1)) < 60 or int(m.group(1)) % 60:
        return pace
    n = int(m.group(1)) // 60
    return "every %d minute%s" % (n, "" if n == 1 else "s")


def cmd_doctor(args):
    bad, agents, warned = 0, [], False
    for t in ("git", "gh"):
        if _have(t):
            _out("ok   " + t)
        else:
            _out("FAIL %s not found" % t)
            bad = 1
    for name in _runtimes_in_use():
        for found, line, *failed in runtimes.get(name).doctor():  # a runtime may say its own FAIL text
            if found == "WARN":
                _out("WARN " + line)
            elif found:
                _out("ok   " + line)
            else:
                _out("FAIL " + (failed[0] if failed else "%s not found" % line))
                bad = 1
    try:
        import yaml  # noqa: F401  (the factory's Python is the one running this)
        _out("ok   python + PyYAML")
    except Exception:
        _out("FAIL python 3 with PyYAML (pip install pyyaml)")
        bad = 1
    v = sys.version_info
    found = "%d.%d.%d" % tuple(v[:3])
    if tuple(v[:2]) >= (3, 11):
        _out("ok   python %s (3.11 or later)" % found)
    else:
        _out("FAIL python %s is too old: Shipfloor needs Python 3.11 or later (set FACTORY_PYTHON to one)" % found)
        bad = 1
    if _run(proc.gh_argv("auth", "status"), out=DEVNULL, err=DEVNULL)[0] == 0:
        _out("ok   gh authenticated")
    else:
        _out("FAIL gh auth login")
        bad = 1
    src, inst, home = source_dir(), _installed(), _home()
    if not os.path.isdir(inst):
        _out("FAIL not installed (shipfloor install)")
        bad = 1
    elif _same_tree(os.path.join(src, "scripts"), inst, {"test", ".source", ".origin", "__pycache__", "templates"}) \
            and _same_tree(os.path.join(src, "templates"), os.path.join(inst, "templates"), set()):
        _out("ok   installed copy matches " + src)
    else:
        _out("WARN installed copy differs from %s (shipfloor install)" % src)
    dst, dkind = _cap(["bash", os.path.join(src, "installer", "install-dispatcher.sh"), "--status"], err=DEVNULL)
    if dst == 0:
        rows = dkind.splitlines()
        dkind = rows[0] if dkind.strip() else dkind
        _out("ok   dispatcher registered (%s)" % (dkind[len("registered: "):] if dkind.startswith("registered: ") else dkind))
        got = rows[1][len("limits: "):] if len(rows) > 1 and rows[1].startswith("limits: ") else ""
        if got:
            _out("ok   dispatcher limits: " + _limits_hint(src, home, got))
        pace = next((r[len("pace: "):] for r in rows if r.startswith("pace: ")), "")
        if pace:
            _out("ok   dispatcher pace: " + _pace_words(pace))
    elif dst == 1:
        _out("WARN no dispatcher registered; run: bash %s/installer/install-dispatcher.sh" % src)
    if os.path.isdir(inst):
        mb = main_of(src)
        oc = ob = ov = ""
        line = _first_line(os.path.join(inst, ".origin"))
        if line is not None:
            oc, ob, ov = text.read_tab(line, 3)
        if ov == "verified":
            _out("ok   installed from %s at %s" % (ob, oc[:7]))
        elif ov == "forced":
            _out("WARN installed copy was forced from branch %s at %s, not a verified %s (shipfloor install from a clean %s)"
                 % (ob, oc[:7], mb, mb))
        else:
            _out("WARN installed copy has no recorded commit (not a git clone, or installed before this check)")
    tmpdir = os.path.join(home, "tmp")
    if _fs_type(tmpdir) == "tmpfs":
        _out("WARN dispatcher TMPDIR %s is on tmpfs (inode cap); move SHIPFLOOR_HOME off tmpfs" % tmpdir)
    rc, alerts = _cap([sys.executable, "-I", os.path.join(HERE, "shipfloor_health.py"), "alerts", "--home", home],
                      err=DEVNULL)
    for alert in alerts.replace("\r", "").split("\n"):
        if alert:
            _out("WARN health: %s (~/.shipfloor/logs/health-*.jsonl)" % alert)
    reg = _registry()
    if os.path.isfile(reg) and os.path.getsize(reg) > 0:
        for row in _rows():
            slug, repo, wt, main = text.read_tab(row, 4)
            if not slug:
                continue
            with _ProjectEnv(slug, repo, wt, main):
                ok = _validate()
            if not ok:
                _out("FAIL project %s: invalid or missing config" % slug)
                bad = 1
                continue
            _out("ok   project " + slug)
            with _ProjectEnv(slug, repo, wt, main):
                _doctor_project(slug)
            with _ProjectEnv(slug, repo, wt, main):
                agents += _agents()
    else:
        _out("WARN no projects (shipfloor add <repo>)")
    r = project.machine("models-check", *agents)
    for line in _t(r.stdout + r.stderr).replace("\r", "").split("\n")[:-1]:
        if line:
            _out("WARN models: " + line)
            warned = True
    # models.stages is Claude Code's: set for a stage that runs on another runtime, it does nothing
    seen = set()
    cfgs = [""]
    if os.path.isfile(reg) and os.path.getsize(reg) > 0:
        for row in _rows():
            slug, repo, wt, main = text.read_tab(row, 4)
            if slug:
                with _ProjectEnv(slug, repo, wt, main):
                    cfg = os.environ.get("FACTORY_CONFIG", "")
                    cfgs.append(proc.native_path(cfg) if cfg and os.path.isfile(cfg) else "")
    for cfg in cfgs:
        r = project.machine("models-stages-check", *([cfg] if cfg else []))
        for line in _t(r.stdout).replace("\r", "").split("\n"):
            if line and line not in seen:
                seen.add(line)
                _out("WARN models: " + line)
                warned = True
    if not warned:
        _out("ok   models")
    return bad


# --- the projects ----------------------------------------------------------------------------------------------------

def cmd_add(args):
    repo = args[0] if args else ""
    wt = main = ""
    rest, i = args[1:], 0
    while i < len(rest):
        if rest[i] == "--worktrees":
            wt = rest[i + 1] if i + 1 < len(rest) else ""
        elif rest[i] == "--main":
            main = rest[i + 1] if i + 1 < len(rest) else ""
        else:
            die("add: unknown option %s" % rest[i], 2)
        i += 2
    if not repo:
        die("usage: shipfloor add <repo> [--worktrees DIR] [--main BRANCH]", 2)
    rc, top = _git("-C", repo, "rev-parse", "--show-toplevel", err=DEVNULL)
    repo = top
    if rc != 0:
        die("%s is not a git repository" % repo)  # repo is already the (empty) answer, as in the Bash script
    if not main:
        m = _git("-C", repo, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD", err=DEVNULL)[1]
        main = "\n".join(l[len("origin/"):] if l.startswith("origin/") else l for l in m.split("\n")) if m else ""
    main = main or "main"
    if _run(["git", "-C", repo, "fetch", "-q", "origin", main])[0] != 0:
        die("cannot fetch origin/%s in %s" % (main, repo))
    fd, cfg = tempfile.mkstemp()
    os.close(fd)
    saved = os.environ.get("FACTORY_CONFIG")
    try:
        p = ".shipfloor/factory.yml"
        if _run(["git", "-C", repo, "cat-file", "-e", "origin/%s:%s" % (main, p)], err=DEVNULL)[0] != 0:
            die("origin/%s has no .shipfloor/factory.yml" % main)
        rc, data = _run(["git", "-C", repo, "show", "origin/%s:%s" % (main, p)], out=PIPE, err=DEVNULL)
        with open(cfg, "wb") as f:
            f.write(data)
        if rc != 0:
            die("cannot read %s on origin/%s" % (p, main))
        os.environ["FACTORY_CONFIG"] = cfg
        if not _validate():
            die("invalid %s on origin/%s" % (p, main))
        slug = _cfg_value("get", "project.name")[1]
    finally:
        if saved is None:
            os.environ.pop("FACTORY_CONFIG", None)
        else:
            os.environ["FACTORY_CONFIG"] = saved
        try:
            os.unlink(cfg)
        except OSError:
            pass
    current = "\n".join(_cut(l, 2) for l in entry(slug).split("\n")) if entry(slug) else ""
    if current and project.git_common(current) != project.git_common(repo):
        die("project '%s' is already registered for %s" % (slug, current))
    home = os.path.join(_home(), "projects", slug)
    if not wt:  # adding again keeps the registered worktrees
        wt = "\n".join(_cut(l, 3) for l in entry(slug).split("\n")).rstrip("\n") if entry(slug) else ""
    wt = wt or os.path.join(home, "wt")
    os.makedirs(home, exist_ok=True)
    os.makedirs(wt, exist_ok=True)
    control = os.path.join(home, "control")
    if not os.path.exists(os.path.join(control, ".git")):
        if _run(["git", "-C", repo, "worktree", "add", "-q", "--detach", control, "origin/" + main])[0] != 0:
            die("cannot create %s" % control)
    elif _run(["git", "-C", control, "checkout", "-q", "--detach", "origin/" + main])[0] != 0:
        die("cannot move %s to origin/%s" % (control, main))
    project.use(slug, repo, wt, main)
    if not project.snapshot():
        die("cannot read .shipfloor/factory.yml from %s" % control)
    _write_registry([l for l in _records() if l.split("\t")[0] != slug] + ["%s\t%s\t%s\t%s" % (slug, repo, wt, main)])
    _out("registered %s (%s, worktrees in %s)" % (slug, repo, wt))
    return 0


def cmd_remove(args):
    slug = args[0] if args else ""
    use(slug)
    home = os.environ["FACTORY_HOME"]
    control = os.path.join(home, "control")
    if _run(["git", "-C", os.environ["FACTORY_REPO"], "worktree", "remove", "--force", control], err=DEVNULL)[0] != 0:
        _rm(control)
    _write_registry([l for l in _records() if l.split("\t")[0] != slug])
    _out("removed %s (logs and reports stay in %s)" % (slug, home))
    return 0


def cmd_list(args):
    reg = _registry()
    if not (os.path.isfile(reg) and os.path.getsize(reg) > 0):
        _out("no projects")
        return 0
    if os.path.lexists(os.path.join(_home(), "PAUSE")):
        _out("(all paused)")
    for row in _rows():
        slug, repo, wt, _main = text.read_tab(row, 4)
        if not slug:
            continue
        state = "paused" if os.path.lexists(os.path.join(_home(), "projects", slug, "PAUSE")) else "active"
        _out("%s\t%s\t%s\t%s" % (slug, state, repo, wt))
    return 0


def cmd_pause(args):
    if not (args and args[0]):
        os.makedirs(_home(), exist_ok=True)
        _touch(os.path.join(_home(), "PAUSE"))
        return 0
    use(args[0])
    os.makedirs(os.environ["FACTORY_HOME"], exist_ok=True)
    _touch(os.path.join(os.environ["FACTORY_HOME"], "PAUSE"))
    return 0


def cmd_resume(args):
    if not (args and args[0]):
        _rm(os.path.join(_home(), "PAUSE"))
        return 0
    use(args[0])
    _rm(os.path.join(os.environ["FACTORY_HOME"], "PAUSE"))
    return 0


def _machine(*args):
    r = project.machine(*args)
    _pass_through(r)
    return r.returncode


def _div60(n):
    q = abs(n) // 60
    return q if n >= 0 else -q


def cmd_pool(args):
    """pool | pool set <n> | pool stage <stage> <n> | pool stacks <n>: the machine-wide agent pool."""
    sub = args[0] if args else ""
    arg = lambda i: args[i] if len(args) > i else ""
    if sub == "set":
        return _machine("set", "pool", arg(1))
    if sub == "stage":
        return _machine("set", "stages." + arg(1), arg(2))
    if sub == "stacks":
        return _machine("set", "stacks", arg(1))
    if sub != "":
        die("usage: shipfloor pool [set <n> | stage <refine|develop|validate|deploy> <n> | stacks <n>]", 2)
    r = project.machine("show")
    _write_err(r.stderr)
    if r.returncode != 0:
        return r.returncode
    home = _home()
    for line in _t(r.stdout).rstrip("\n").split("\n"):
        m = re.match(r"  ([a-z]+): ", line)
        if m:
            n = sum(1 for lock in glob.glob(os.path.join(glob.escape(home), "projects", "*", "locks", m.group(1) + "-*.lock"))
                    if os.path.isdir(lock))
            if n > 0:
                line += " (%d running)" % n
        _out(line)
    first = next((l.split("\t")[0] for l in _records() if l), "")
    if not first:
        return 0
    # use the first project and read its stack status; an empty queue is not a failure,
    # so the exit is the stack command's own (or 2 for a non-integer queue count)
    saved = dict(os.environ)
    try:
        use(first)
        fh = os.environ["FACTORY_HOME"]
        if not os.path.isdir(fh):
            _err("shipfloor: cd: %s: No such file or directory" % fh)
            left, data = 1, b""
        else:
            left, data = _run(["bash", os.path.join(HERE, "gate.sh"), "stack", "status"], out=PIPE, cwd=fh)
    except CliExit as e:
        left, data = e.code, b""
    finally:
        os.environ.clear()
        os.environ.update(saved)
    right = 0
    for line in _t(data).split("\n")[:-1]:
        k, st, owner, held, why = text.read_tab(line, 5)
        if k == "queue":
            n = _int(st)
            if n is None:
                _err("shipfloor: [: %s: integer expression expected" % st)
                right = 2
            elif n > 0:
                _out("  queue: %s waiting" % st)
        else:
            _out("  slot %s: %s%s%s%s" % (k, st, " " + owner if owner else "",
                                          "" if st == "free" else " (%dm)" % _div60(_int(held) or 0),
                                          " — " + why if why else ""))
            right = 0
    return right or left


def cmd_clean(args):
    use(args[0] if args else "")
    for removed in project.sweep_tmp():
        _out("removed " + removed)
    return 0


def cmd_dashboard(args):
    """dashboard [--port N] [--no-open] [--token T]: serves the local dashboard until Ctrl+C."""
    argv = [sys.executable, "-I", os.path.join(HERE, "dashboard.py"), "--home", _home(), *args]
    sys.stdout.flush()
    try:
        p = subprocess.Popen(argv)
    except OSError as e:
        _err("%s: %s" % (argv[0], e.strerror or e))
        return 127
    while True:
        try:
            rc = p.wait()
            return 128 - rc if rc < 0 else rc
        except KeyboardInterrupt:  # Ctrl+C reached the dashboard too: wait for it to stop
            continue


def cmd_accept(args):
    """accept <slug> <n> <reason...>: the owner reviewed how card <n>'s acceptance files changed after the QA commit
    (a merge from main resolved by hand, a setup line main forced, a stub deleted) and takes them as they stand. The gate
    then passes those exact contents; any later edit blocks again. Recorded in the project's home."""
    slug = args[0] if args else ""
    n = args[1] if len(args) > 1 else ""
    reason = " ".join(args[2:] if len(args) >= 2 else args)
    if not (slug and re.fullmatch(r"[0-9]+", n) and reason):
        die("usage: shipfloor accept <project> <n> <reason>", 2)
    use(slug)
    home = os.environ["FACTORY_HOME"]
    wt = os.path.join(os.environ["FACTORY_WT_ROOT"], n)
    if not os.path.exists(os.path.join(wt, ".git")):
        die("no worktree for card %s at %s" % (n, wt))
    gate = os.path.join(HERE, "gate.sh")
    qa = _cap(["bash", gate, "-C", wt, "qa-commit", n], err=DEVNULL)[1]
    if not qa:
        die('no QA commit ("acceptance tests for #%s") on %s' % (n, _git("-C", wt, "rev-parse", "--abbrev-ref", "HEAD")[1]))
    accepted = os.path.join(home, "accepted.tsv")
    todo = []
    # every QA commit's files, each with the newest QA commit that wrote it: acceptance-intact guards them all, so a
    # file only an earlier QA round wrote (and a merge from main later deleted or rewrote) must be acceptable too
    qas = _git("-C", wt, "log", "--format=%H", "-E", "--grep", "acceptance tests for #%s([^0-9]|$)" % n, "HEAD")[1].split() or [qa]
    owner_of = {}
    for c in qas:
        for f in _git("-C", wt, "-c", "core.quotePath=false", "show", "--name-only", "--format=", "--diff-filter=d", c)[1].split("\n"):
            if f and f not in owner_of:
                owner_of[f] = c
    for f, qa in owner_of.items():
        if _run(["git", "-C", wt, "diff", "--quiet", qa, "HEAD", "--", f])[0] == 0:
            continue  # untouched since QA
        rc, blob = _git("-C", wt, "rev-parse", "-q", "--verify", "HEAD:" + f)
        if rc != 0:
            blob = "deleted"  # a stub the real code replaced
        key = blob  # the card's own edit when the gate can isolate it: a later merge from main elsewhere keeps the record
        if blob != "deleted":
            rc, own = _cap(["bash", gate, "-C", wt, "acceptance-own", qa, f], err=DEVNULL)
            key = own if rc == 0 else blob
        have = _t(_read_bytes(accepted) or b"")
        if (f + "\t" + key + "\t") in have or (f + "\t" + blob + "\t") in have:
            continue  # already accepted as it stands
        if _git("-C", wt, "status", "--porcelain", "--", f)[1]:
            die("%s has uncommitted changes in %s" % (f, wt))
        todo.append((f, key, blob, qa))
    # all or nothing: every file was checked before the first line is written
    when = datetime.now().astimezone().isoformat(timespec="seconds")
    clean = reason.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    for f, key, blob, _qa in todo:
        with open(accepted, "a", encoding="utf-8", errors="surrogateescape", newline="\n") as out:
            out.write("%s\t%s\t#%s\t%s\t%s\n" % (f, key, n, when, clean))
        _out("accepted the deletion of %s" % f if blob == "deleted" else "accepted %s at %s" % (f, blob[:12]))
    if not todo:
        _out("nothing to accept: acceptance-intact already passes for card %s" % n)
        return 0
    lines = ["**shipfloor accept** — card #%s" % n, ""]
    lines += ["- `%s` → `%s` (QA `%s`)" % (f, key, q[:12]) for f, key, _blob, q in todo]
    lines += ["", "Reason: %s" % clean, "Date: %s" % when, ""]
    problem = _post_accept_comment(n, "\n".join(lines))
    if problem:
        _err("accepted locally; the copy on issue #%s was not posted: %s" % (n, problem))
    return 0


def _post_accept_comment(n, body):
    """Posts the accept record on issue <n> through the REST API (not GraphQL); the reason it failed, or ''."""
    repo = _cfg_value("get", "project.repo")[1]
    if not repo:
        return "project.repo is not set"
    fd, path = tempfile.mkstemp(suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        try:
            rc, out = _run(proc.gh_argv("api", "-X", "POST", "repos/%s/issues/%s/comments" % (repo, n), "-F", "body=@" + path),
                           out=DEVNULL)
        except OSError as e:
            return str(e)
        return "" if rc == 0 else "gh exited %s" % rc
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _with_weight(lines, line):
    """The spec's lines with one weight line after the header's last **Field:** line (or before the first section)."""
    sec = last = 0
    for i, row in enumerate(lines, 1):
        if not sec and row.startswith("## "):
            sec = i
        if not sec and re.match(r"\*\*[^*]+:\*\*", row) and not row.startswith("**Weight:**"):
            last = i
    at = last if last else (sec - 1 if sec else len(lines))
    out, done = [], False
    if at == 0:
        out.append(line)
        done = True
    for i, row in enumerate(lines, 1):
        if (not sec or i < sec) and row.startswith("**Weight:**"):
            continue
        out.append(row)
        if i == at and not done:
            out.append(line)
            done = True
    return out


def cmd_weight(args):
    """weight <slug> <n> <light|standard|heavy>: the owner sets card <n>'s weight in its spec header, from Spec Review.
    One commit on the card's branch, pushed; the review page is not rebuilt, so the owner's marks stay."""
    slug, n, w = (list(args) + ["", "", ""])[:3]
    if not (slug and re.fullmatch(r"[0-9]+", n) and len(args) == 3):
        die("usage: shipfloor weight <project> <n> <light|standard|heavy>", 2)
    if w not in ("light", "standard", "heavy"):
        die("'%s' is not a weight (light, standard, heavy)" % w, 2)
    use(slug)
    home = os.environ["FACTORY_HOME"]
    wt = os.path.join(os.environ["FACTORY_WT_ROOT"], n)
    if _cap(["bash", os.path.join(HERE, "board.sh"), "status", n], err=DEVNULL)[1] != "Spec Review":
        die("the card is no longer in Spec Review.", 3)
    for d in sorted(glob.glob(os.path.join(glob.escape(home), "locks", "[a-z]*-%s.lock" % n))):
        if not os.path.isdir(d):
            continue
        info = _first_line(os.path.join(d, "info"))
        pid = info.split()[0] if info and info.split() else ""
        if not pid or proc.alive(pid):
            die("a run is working on card %s now; try again when it ends" % n, 3)
    spec = project.card_spec(n)
    if not spec:
        die("no spec for card %s under %s" % (n, wt))
    branch = _git("-C", wt, "rev-parse", "--abbrev-ref", "HEAD")[1]
    if _git("-C", wt, "status", "--porcelain", "--", spec)[1]:
        die("%s has uncommitted changes" % spec)
    data = _t(_read_bytes(spec) or b"")
    lines = data.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    head = []
    for row in lines:
        if row.startswith("## "):
            break
        if row.startswith("**Weight:**"):
            head.append(row.replace("\r", ""))
    line = "**Weight:** " + w
    if "\n".join(head) == line:
        _out("weight " + w)
        return 0
    tmp = spec + ".weight-tmp"
    try:
        with open(tmp, "wb") as f:
            f.write("".join(l + "\n" for l in _with_weight(lines, line)).encode("utf-8", "surrogateescape"))
        os.replace(tmp, spec)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die("could not write %s" % spec)
    prefix = "feat/%s-" % n
    scope = branch[len(prefix):] if branch.startswith(prefix) else branch
    if not (_run(["git", "-C", wt, "add", "--", spec])[0] == 0 and
            _run(["git", "-C", wt, "commit", "-q", "-m", "docs(%s): weight %s for #%s" % (scope, w, n), "--", spec])[0] == 0):
        _run(["git", "-C", wt, "checkout", "-q", "--", spec])
        die("could not commit the weight")
    rc, out = _run(["git", "-C", wt, "push", "-q", "origin", "HEAD:" + branch], out=PIPE, err=STDOUT)
    if rc != 0:
        _run(["git", "-C", wt, "reset", "-q", "--hard", "HEAD~1"])
        said = _t(out).rstrip("\n")
        first = next((l for l in said.split("\n") if re.match(r"(fatal|error|remote|!)", l)), said.split("\n")[0])
        die("could not push %s: %s" % (branch, first))
    _out("weight " + w)
    return 0


def cmd_setup_board(args):
    use(args[0] if args else "")
    control = os.path.join(os.environ["FACTORY_HOME"], "control")
    if not os.path.isdir(control):
        _err("shipfloor: cd: %s: No such file or directory" % control)
        return 1
    return _run(["bash", os.path.join(HERE, "setup-board.sh")], cwd=control)[0]


def cmd_metrics(args):
    use(args[0] if args else "")
    return _run(["bash", os.path.join(HERE, "metrics.sh")])[0]


def cmd_init(args):
    """init [<repo>] [--yes]: install, config, add, board, dispatcher and doctor in one guided run (#174)."""
    from . import init
    return init.run(args)


def usage():
    """The wrapper's header lines 2-10, comment marks off, on stderr."""
    data = _read_bytes(os.path.join(HERE, "shipfloor"))
    if data is not None:
        lines = _t(data).replace("\r\n", "\n").split("\n")[1:10]
        sys.stderr.write("".join(re.sub(r"^# ?", "", l) + "\n" for l in lines))
    return 2


def cmd_demo(args):
    """demo [--no-dashboard] [--keep]: a fake card crosses the factory on a temporary home (no network, no LLM)."""
    from . import demo
    return demo.main(args)


COMMANDS = {"demo": cmd_demo, "init": cmd_init, "install": cmd_install, "doctor": cmd_doctor, "add": cmd_add, "remove": cmd_remove, "list": cmd_list,
            "pool": cmd_pool, "clean": cmd_clean, "accept": cmd_accept, "weight": cmd_weight, "pause": cmd_pause,
            "resume": cmd_resume, "setup-board": cmd_setup_board, "dashboard": cmd_dashboard, "metrics": cmd_metrics}


def main(argv):
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    cmd = argv[0] if argv else ""
    try:
        if cmd not in COMMANDS:
            return usage()
        return COMMANDS[cmd](list(argv[1:]))
    except CliExit as e:
        return e.code
    except KeyboardInterrupt:
        return 130
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
