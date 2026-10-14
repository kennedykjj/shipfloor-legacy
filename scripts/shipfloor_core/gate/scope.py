"""The scope and forbidden gates: which changed files a role may touch, and which no agent may touch."""
from .. import text
from . import changes


def grep(ctx, pattern, lines, invert=False):
    """The lines the real `grep -E` (`-Ev`) keeps; an invalid pattern keeps none, and grep's complaint goes to the
    gate's stderr, as it did in the Bash gate."""
    kept, err = text.grep_lines(pattern, lines, invert)
    ctx.err_bytes(err)
    return kept


def _quiet_config(*query):
    """(exit code, answer without trailing newlines) of a config query whose stderr nobody hears."""
    r = changes._cfg(query)
    return r.returncode, r.stdout.decode("utf-8", "surrogateescape").rstrip("\n")


def _bad(lines):
    """The offending lines as `$(...)` hands them on: joined, trailing newlines gone; empty = none."""
    return "\n".join(lines).rstrip("\n")


def check_forbidden(ctx, base, pattern=None, changed=None):
    """The forbidden gate. `pattern` is the config's ERE and `changed` the sorted changed names when the caller (fast)
    has them already; else both are asked for here."""
    changes.require_rev(ctx, base)
    if pattern is None:
        pattern = changes.config_query(ctx, "regex", "forbidden")
    if changes.odd_names(ctx, base):
        ctx.err("forbidden: a changed file name has a control character (newline, tab...)")
        return 1
    files = changes.changed_files(ctx, base) if changed is None else changed
    bad = _bad(grep(ctx, pattern, files))
    if not bad:
        return 0
    ctx.err("forbidden: these paths are off-limits to agents:")
    ctx.err(bad)
    return 1


def forbidden(ctx, args):
    return check_forbidden(ctx, args[0] if args else "")


def scope(ctx, args):
    role = args[0] if args else ""
    base = args[1] if len(args) > 1 else ""
    if not role:
        ctx.err("scope: role required")
        return 2
    code, allowed = _quiet_config("regex", "scope", role)
    if code != 0:
        ctx.err("scope: unknown role '%s'" % role)
        return 2
    if not allowed:
        ctx.err("scope: role '%s' has no area in the config" % role)
        return 2
    changes.require_rev(ctx, base)
    files = changes.changed_files(ctx, base)
    bad = _bad(grep(ctx, allowed, [f for f in files if f], invert=True))
    if bad:
        ctx.err("scope: %s touched files outside its area:" % role)
        ctx.err(bad)
        return 1
    if role not in ("po", "ux", "techlead", "qa"):
        lines = files or [""]  # printf '%s\n' "$files" always makes one line
        test_config = changes.config_query(ctx, "regex", "test-config")
        if test_config:
            bad = _bad(grep(ctx, test_config, lines))
            if bad:
                ctx.err("scope: test runner config is off-limits to implementers:")
                ctx.err(bad)
                return 1
        qa_only = changes.config_query(ctx, "regex", "tests-only")
        if qa_only:
            bad = _bad(grep(ctx, qa_only, lines))
            if bad:
                ctx.err("scope: only QA writes in tests-only layers:")
                ctx.err(bad)
                return 1
    return check_forbidden(ctx, base)
