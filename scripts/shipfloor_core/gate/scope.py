"""The scope and forbidden gates: which changed files a role may touch, and which no agent may touch."""
import re
import warnings

from . import changes

_CLASSES = {
    "alpha": "a-zA-Z", "digit": "0-9", "alnum": "a-zA-Z0-9", "upper": "A-Z", "lower": "a-z",
    "space": " \\t\\n\\r\\f\\v", "blank": " \\t", "xdigit": "0-9A-Fa-f", "cntrl": "\\x00-\\x1f\\x7f",
    "print": "\\x20-\\x7e", "graph": "\\x21-\\x7e", "punct": "!-/:-@\\[-`{-~",
}


def _bracket(pat, i):
    """Translate the POSIX bracket expression that starts at pat[i] == "["; returns (python text, index after it)."""
    j = i + 1
    out = "["
    if j < len(pat) and pat[j] == "^":
        out += "^"
        j += 1
    first = True
    while True:
        if j >= len(pat):
            raise re.error("unterminated bracket")
        c = pat[j]
        if c == "]" and not first:
            return out + "]", j + 1
        first = False
        if c == "[" and pat[j + 1:j + 2] == ":":
            end = pat.find(":]", j + 2)
            name = pat[j + 2:end] if end >= 0 else ""
            if name not in _CLASSES:
                raise re.error("bad class")
            out += _CLASSES[name]
            j = end + 2
        elif c == "[" and pat[j + 1:j + 2] in (".", "="):
            raise re.error("collating symbols are not supported")
        else:
            out += "\\" + c if c in "\\[]^&~|" else c
            j += 1


def ere(pat):
    """A POSIX extended regular expression as Python's re reads it (the part of ERE the config uses)."""
    out = ""
    i = 0
    while i < len(pat):
        c = pat[i]
        if c == "\\":
            if i + 1 >= len(pat):
                raise re.error("trailing backslash")
            n = pat[i + 1]
            out += "\\b" if n in "<>" else c + n
            i += 2
        elif c == "[":
            piece, i = _bracket(pat, i)
            out += piece
        else:
            out += c
            i += 1
    return out


def compile_ere(pattern):
    """The compiled alternatives of a grep -E pattern (a newline separates patterns); None when grep would refuse it."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            return [re.compile(ere(p)) for p in pattern.split("\n")]
    except (re.error, RecursionError, OverflowError):
        return None


def grep(pattern, lines, invert=False):
    """The lines `grep -E pattern` (or `grep -Ev`) keeps; none when the pattern is not a valid ERE (grep exits 2)."""
    compiled = compile_ere(pattern)
    if compiled is None:
        return []
    return [l for l in lines if any(c.search(l) for c in compiled) != invert]


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
    bad = _bad(grep(pattern, files))
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
    bad = _bad(grep(allowed, [f for f in files if f], invert=True))
    if bad:
        ctx.err("scope: %s touched files outside its area:" % role)
        ctx.err(bad)
        return 1
    if role not in ("po", "ux", "techlead", "qa"):
        lines = files or [""]  # printf '%s\n' "$files" always makes one line
        test_config = changes.config_query(ctx, "regex", "test-config")
        if test_config:
            bad = _bad(grep(test_config, lines))
            if bad:
                ctx.err("scope: test runner config is off-limits to implementers:")
                ctx.err(bad)
                return 1
        qa_only = changes.config_query(ctx, "regex", "tests-only")
        if qa_only:
            bad = _bad(grep(qa_only, lines))
            if bad:
                ctx.err("scope: only QA writes in tests-only layers:")
                ctx.err(bad)
                return 1
    return check_forbidden(ctx, base)
