"""The project helpers: what scripts/lib/project.sh does, behaving the same (resolve, use, snapshot, tmp, specs)."""
import glob
import os
import re
import shutil
import subprocess
import sys

from . import proc

_SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_CONFIG_PY = os.path.join(_SCRIPTS, "shipfloor_config.py")


class ProjectError(RuntimeError):
    """The project cannot be found; the message is the one the Bash helper prints."""


def shipfloor_home():
    return os.environ.get("SHIPFLOOR_HOME") or os.path.join(os.path.expanduser("~"), ".shipfloor")


def _text(b):
    return b.decode("utf-8", "replace")


def git_common(path):
    """The git common dir of a checkout (absolute), or "" when it is not one."""
    try:
        r = proc.git("-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    except OSError:
        return ""
    if r.returncode != 0:
        return ""
    return _text(r.stdout).rstrip("\r\n")


def use(slug, repo, worktrees=None, main=None):
    """Export one registered project's settings."""
    home = os.path.join(shipfloor_home(), "projects", slug)
    os.environ["FACTORY_PROJECT"] = slug
    os.environ["FACTORY_REPO"] = repo
    os.environ["FACTORY_MAIN"] = main or "main"
    os.environ["FACTORY_HOME"] = home
    os.environ["FACTORY_WT_ROOT"] = worktrees or os.path.join(home, "wt")
    os.environ["FACTORY_CONFIG"] = os.path.join(home, "factory.yml")
    return dict(project=slug, repo=repo, main=os.environ["FACTORY_MAIN"], home=home,
                wt_root=os.environ["FACTORY_WT_ROOT"], config=os.environ["FACTORY_CONFIG"])


def _current():
    return dict(project=os.environ.get("FACTORY_PROJECT", ""), repo=os.environ.get("FACTORY_REPO", ""),
                main=os.environ.get("FACTORY_MAIN", ""), home=os.environ.get("FACTORY_HOME", ""),
                wt_root=os.environ.get("FACTORY_WT_ROOT", ""), config=os.environ.get("FACTORY_CONFIG", ""))


def resolve(directory="."):
    """Export the project the directory belongs to (env first, then the registry); ProjectError when unknown."""
    if os.environ.get("FACTORY_CONFIG"):
        return _current()
    here = git_common(directory)
    registry = os.path.join(shipfloor_home(), "registry.tsv")
    if here and os.path.isfile(registry):
        with open(registry, encoding="utf-8", errors="replace", newline="") as f:
            for line in f.read().split("\n"):
                parts = re.split("\t+", line.strip("\t"), maxsplit=3) if line.strip("\t") else []
                if not parts or not parts[0]:
                    continue
                parts += [""] * (4 - len(parts))
                slug, repo, wt, main = parts
                if git_common(repo) == here:
                    return use(slug, repo, wt, main)
    raise ProjectError("shipfloor: %s is not in a registered project (shipfloor add <repo>)" % os.getcwd())


def cfg(*query, input=None):
    """Ask shipfloor_config.py about the resolved project (input: bytes on its stdin); a CompletedProcess (bytes)."""
    config = os.environ.get("FACTORY_CONFIG", "")
    home = os.environ.get("FACTORY_HOME", "")
    wt = os.environ.get("FACTORY_WT_ROOT", "")
    argv = [sys.executable, "-I", _CONFIG_PY, "--config", proc.native_path(config),
            "--home", proc.native_path(home) if home else "",
            "--worktrees", proc.native_path(wt) if wt else "", *query]
    return subprocess.run(argv, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def machine(*args):
    """The machine-wide agent pool (config.yml in the Shipfloor home); a CompletedProcess (bytes)."""
    env = dict(os.environ)
    env["SHIPFLOOR_MACHINE_CONFIG"] = proc.native_path(os.path.join(shipfloor_home(), "config.yml"))
    return subprocess.run([sys.executable, "-I", proc.native_path(_CONFIG_PY), "machine", *args], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def snapshot():
    """FACTORY_CONFIG = the project config as committed at control's HEAD. True on success."""
    config = os.environ["FACTORY_CONFIG"]
    tmp = "%s.%d.tmp" % (config, os.getpid())
    control = proc.native_path(os.path.join(os.environ["FACTORY_HOME"], "control"))
    rel = ".shipfloor/factory.yml"
    ok = False
    try:
        if proc.git("-C", control, "cat-file", "-e", "HEAD:" + rel).returncode != 0:
            return False
        r = proc.git("-C", control, "show", "HEAD:" + rel)
        if r.returncode != 0:
            return False
        with open(tmp, "wb") as f:
            f.write(r.stdout)
        try:
            os.replace(tmp, config)
            ok = True
        except OSError:  # a reader has it open (Windows): an unchanged config is still the config
            try:
                with open(tmp, "rb") as a, open(config, "rb") as b:
                    ok = a.read() == b.read()
            except OSError:
                ok = False
        return ok
    except OSError:
        return False
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _board(home):
    """The board rows as (number, status) in file order, or None when no row starts with a digit."""
    try:
        with open(os.path.join(home, "board.tsv"), encoding="utf-8", errors="replace", newline="") as f:
            lines = f.read().split("\n")
    except OSError:
        return None
    if not any(l[:1].isdigit() for l in lines):
        return None
    rows = []
    for l in lines:
        cols = l.split("\t")
        if len(cols) >= 2:
            rows.append((cols[0], cols[1]))
    return rows


def _status(rows, n):
    return "\n".join(s for k, s in rows if k == n)


def clean_tmp(n):
    """Remove the worktrees a run left under the project's tmp/<n>/, then the directory."""
    t = os.path.join(os.environ["FACTORY_HOME"], "tmp", str(n))
    if not os.path.isdir(t):
        return
    repo = os.environ.get("FACTORY_REPO") or "."
    needle = proc.native_path(t) + "/"
    r = proc.git("-C", repo, "worktree", "list", "--porcelain")
    if r.returncode == 0:
        for line in _text(r.stdout).splitlines():
            if line.startswith("worktree ") and needle in line[len("worktree "):]:
                proc.git("-C", repo, "worktree", "remove", "--force", line[len("worktree "):])
    proc.git("-C", repo, "worktree", "prune")
    shutil.rmtree(t, ignore_errors=True)


def _dirs(home):
    return sorted(glob.glob(os.path.join(glob.escape(home), "tmp", "*")))


def stale_tmp():
    """Card numbers whose tmp/<n>/ outlived them (Done or off the board)."""
    home = os.environ["FACTORY_HOME"]
    rows = _board(home)
    if rows is None:
        return []
    out = []
    for d in _dirs(home):
        n = os.path.basename(d)
        if not os.path.isdir(d) or not re.fullmatch(r"[0-9]+", n):
            continue
        if glob.glob(os.path.join(glob.escape(home), "locks", "*-%s.lock" % n)):
            continue
        st = _status(rows, n)
        if st == "" or st == "Done":
            out.append(n)
    return out


def _fresh(path, days=3):
    """find -mtime -3: something at or under the path changed less than 3 days ago."""
    import time
    limit = days * 86400
    now = time.time()

    def young(p):
        try:
            return int((now - os.lstat(p).st_mtime) // 86400) < days and now - os.lstat(p).st_mtime < limit
        except OSError:
            return False
    if young(path):
        return True
    if os.path.isdir(path) and not os.path.islink(path):
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                if young(os.path.join(root, name)):
                    return True
    return False


def sweep_tmp():
    """Remove what outlived its card under the project's tmp/; the list of each as tmp/<name>."""
    home = os.environ["FACTORY_HOME"]
    rows = _board(home)
    if rows is None:
        return []
    out = []
    for n in stale_tmp():
        clean_tmp(n)
        out.append("tmp/" + n)
    for e in _dirs(home):
        if not os.path.lexists(e):
            continue
        name = os.path.basename(e)
        if os.path.isdir(e) and re.fullmatch(r"[0-9]+", name):
            continue
        if _fresh(e):
            continue
        m = re.search(r"[0-9]+", name)
        if m:
            st = _status(rows, m.group(0))
            if st != "" and st != "Done":
                continue
        try:
            if os.path.isdir(e) and not os.path.islink(e):
                shutil.rmtree(e)
            else:
                os.unlink(e)
        except OSError:
            continue
        out.append("tmp/" + name)
    return out


def card_spec(n, specs=None):
    """The card's spec in its worktree (<worktrees>/<n>/<specs>*-<slug>-design.md); None when there is none."""
    n = str(n)
    wt = os.path.join(os.environ.get("FACTORY_WT_ROOT", ""), n)
    if not os.path.exists(os.path.join(wt, ".git")):
        return None
    r = proc.git("-C", wt, "rev-parse", "--abbrev-ref", "HEAD")
    if r.returncode != 0:
        return None
    branch = _text(r.stdout).strip("\r\n")
    prefix = "feat/%s-" % n
    if not branch.startswith(prefix) or len(branch) == len(prefix):
        return None
    if not specs:
        c = cfg("get", "paths.specs")
        if c.returncode != 0:
            return None
        specs = _text(c.stdout).rstrip("\n")
    slug = branch[len(prefix):]
    pattern = glob.escape(wt + "/") + specs + "*-" + glob.escape(slug) + "-design.md"
    for f in sorted(glob.glob(pattern)):
        if os.path.isfile(f):
            return f
    return None


def spec_weight(path):
    """The weight a spec's header names; standard when none, two, or another value."""
    try:
        with open(path, "rb") as f:
            lines = f.read().decode("utf-8", "replace").split("\n")
    except OSError:
        return "standard"
    found = []
    for l in lines:
        if l.startswith("## "):
            break
        if l.startswith("**Weight:**"):
            found.append(l.replace("\r", "").replace("`", ""))
    if len(found) != 1:
        return "standard"
    w = re.sub(r"\s", "", found[0][len("**Weight:**"):])
    return w if w in ("light", "standard", "heavy") else "standard"


def card_weight(n):
    """The weight of card <n>'s spec; standard when there is no worktree, spec or weight line."""
    spec = card_spec(n)
    return spec_weight(spec) if spec else "standard"


def config_path(d, rev):
    """The config path committed at <rev> in the git dir <d>, or None."""
    rel = ".shipfloor/factory.yml"
    try:
        return rel if proc.git("-C", d, "cat-file", "-e", "%s:%s" % (rev, rel)).returncode == 0 else None
    except OSError:
        return None


# ---- the command line behind lib/project.sh (sf.py project <command>) and shipfloor-config.sh (sf.py config)

_EXPORTS = ("FACTORY_PROJECT", "FACTORY_REPO", "FACTORY_MAIN", "FACTORY_HOME", "FACTORY_WT_ROOT", "FACTORY_CONFIG")


def _exports():
    """What the shim evals: one `export` of the project's six variables, each value quoted for the shell."""
    import shlex
    return "export " + " ".join("%s=%s" % (k, shlex.quote(os.environ.get(k, ""))) for k in _EXPORTS)


def _config_module():
    sys.path.insert(0, _SCRIPTS)
    import shipfloor_config
    return shipfloor_config


def _cfg_in_process(query):
    """shipfloor_cfg: shipfloor_config.py's answer for the resolved project, in this process (one Python start)."""
    config = os.environ.get("FACTORY_CONFIG", "")
    home = os.environ.get("FACTORY_HOME", "")
    wt = os.environ.get("FACTORY_WT_ROOT", "")
    return _config_module().run(["--config", proc.native_path(config), "--home", proc.native_path(home) if home else "",
                                 "--worktrees", proc.native_path(wt) if wt else "", *query])


def _machine_in_process(args):
    """shipfloor_machine: the machine-wide settings (config.yml in the Shipfloor home), in this process."""
    os.environ["SHIPFLOOR_MACHINE_CONFIG"] = proc.native_path(os.path.join(shipfloor_home(), "config.yml"))
    return _config_module().run(["machine", *args])


def _validate():
    from . import cli
    return 0 if cli._validate() else 1


def _say(lang):
    """shipfloor_say: stdin, written in English, comes out in that language (lang/<language>.sed)."""
    from . import text
    data = sys.stdin.buffer.read()
    rc, out, err = text.say_bytes(lang, data)
    sys.stdout.buffer.write(out)
    sys.stderr.buffer.write(err)
    return rc


def _lines(items):
    for i in items:
        print(i)
    return 0


def main(args):
    """sf.py project <command> [args]: the functions of lib/project.sh, for the shell that sourced it."""
    from . import text
    cmd, rest = (args[0], args[1:]) if args else ("", [])
    arg = lambda i: rest[i] if len(rest) > i else ""
    if cmd == "resolve":
        if os.environ.get("FACTORY_CONFIG"):
            return 0
        try:
            resolve(rest[0] if rest and rest[0] else ".")
        except ProjectError as e:
            print(e, file=sys.stderr)
            print("return 1")
            return 1
        print(_exports())
        return 0
    if cmd == "use" and len(rest) >= 2:
        use(rest[0], rest[1], arg(2) or None, arg(3) or None)
        print(_exports())
        return 0
    if cmd == "cfg":
        return _cfg_in_process(rest)
    if cmd == "machine":
        return _machine_in_process(rest)
    if cmd == "validate":
        return _validate()
    if cmd == "native":
        print(proc.native_path(arg(0)))
        return 0
    if cmd == "git-common":
        out = git_common(arg(0))
        if out:
            print(out)
        return 0 if out else 1
    if cmd == "config-path" and len(rest) == 2:
        p = config_path(rest[0], rest[1])
        if p:
            print(p)
        return 0 if p else 1
    if cmd == "ere-ok":
        try:
            text.ere_match(arg(0), "")
        except ValueError:
            return 1
        return 0
    if cmd == "snapshot":
        return 0 if snapshot() else 1
    if cmd == "clean-tmp":
        clean_tmp(arg(0))
        return 0
    if cmd == "stale-tmp":
        return _lines(stale_tmp())
    if cmd == "sweep-tmp":
        return _lines(sweep_tmp())
    if cmd == "card-spec":
        spec = card_spec(arg(0), arg(1) or None)
        if spec:
            print(spec)
        return 0
    if cmd == "spec-weight":
        print(spec_weight(arg(0)))
        return 0
    if cmd == "card-weight":
        print(card_weight(arg(0)))
        return 0
    if cmd == "say":
        return _say(arg(0) or "en")
    print("usage: sf.py project resolve|use|cfg|machine|validate|native|git-common|config-path|ere-ok|snapshot|"
          "clean-tmp|stale-tmp|sweep-tmp|card-spec|spec-weight|card-weight|say ...", file=sys.stderr)
    return 2


def config_main(args):
    """sf.py config <query...>: shipfloor-config.sh past its step fast path. `machine` needs no project; anything else
    needs the resolved project (exit 2 when there is none); `validate` also checks every pattern with grep -E."""
    if args[:1] == ["machine"]:
        return _machine_in_process(args[1:])
    try:
        resolve(".")
    except ProjectError as e:
        print(e, file=sys.stderr)
        return 2
    if args[:1] == ["validate"]:
        return _validate()
    return _cfg_in_process(args)
