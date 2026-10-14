"""The changed set the static gates look at, and the helpers they share: revisions and config answers."""
import os
import subprocess

from .. import project, proc

_CONTROL = frozenset(list(range(1, 32)) + [127])


def _text(data):
    return data.decode("utf-8", "surrogateescape")


def git(ctx, *args):
    """git with names never C-quoted; its stderr goes to the gate's (as it would in the Bash gate). Returns stdout bytes."""
    r = proc.git("-c", "core.quotePath=false", *args)
    ctx.err_bytes(r.stderr)
    return r.stdout


def require_rev(ctx, rev):
    """Exit 2 unless `rev` names a commit."""
    if not rev or proc.git("rev-parse", "--verify", "-q", rev + "^{commit}").returncode != 0:
        ctx.err("gate: bad revision '%s'" % (rev or ""))
        ctx.exit(2)


def raw_changes(ctx, base):
    """NUL-separated names: committed since base, uncommitted, and untracked that are not ignored (never C-quoted)."""
    return b"".join([
        git(ctx, "diff", "-z", "--name-only", "--no-renames", base, "HEAD"),
        git(ctx, "diff", "-z", "--name-only", "--no-renames", "HEAD"),
        git(ctx, "ls-files", "-z", "--others", "--exclude-standard"),
    ])


def odd_names(ctx, base):
    """True when a changed name has a control character (it could hide from the line-based checks)."""
    return any(b in _CONTROL for b in raw_changes(ctx, base))


def _sort_u(lines):
    """`sort -u` as this machine's sort does it (its locale decides the order)."""
    if not lines:
        return []
    r = subprocess.run(["sort", "-u"], input=b"\n".join(lines) + b"\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return [l for l in r.stdout.split(b"\n") if l]


def changed_files(ctx, base):
    """The changed names, one per entry, sorted and unique. A name with a newline is split in two, as the line-based
    checks have always seen it (forbidden refuses names with control characters)."""
    names = [n for n in raw_changes(ctx, base).replace(b"\0", b"\n").split(b"\n") if n]
    return [_text(n) for n in _sort_u(names)]


def _cfg(query, input=None):
    """shipfloor_config.py asked as lib/project.sh does: through SHIPFLOOR_PY when a caller handed one down
    (input: bytes on its stdin)."""
    py = os.environ.get("SHIPFLOOR_PY")
    if not py:
        return project.cfg(*query, input=input)
    home = os.environ.get("FACTORY_HOME", "")
    wt = os.environ.get("FACTORY_WT_ROOT", "")
    argv = [py, "-I", proc.native_path(project._CONFIG_PY), "--config", proc.native_path(os.environ.get("FACTORY_CONFIG", "")),
            "--home", proc.native_path(home) if home else "", "--worktrees", proc.native_path(wt) if wt else "", *query]
    return subprocess.run(argv, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def config_query(ctx, *query):
    """One config answer (trailing newlines cut); a failing query ends the gate with exit 2."""
    r = _cfg(query)
    ctx.err_bytes(r.stderr)
    if r.returncode != 0:
        ctx.err("gate: config query failed: " + " ".join(query))
        ctx.exit(2)
    return _text(r.stdout).rstrip("\n")
