"""The migration gate (applied migrations are immutable, destructive ones need a rollback) and fast (forbidden +
migration + acceptance-intact on one config start)."""
import os
import re

from .. import proc, text
from . import acceptance, changes, scope
from .spec import _lines, _read_tabs

_SPACE = " \t\n\r\f\v"
_DESTRUCTIVE = r"\b(drop|rename|truncate|delete)\b"
_NO_ROLLBACK = r"não se aplica|^[-* ]*(n/a|none|not applicable)[. ]*$"
_COMMENT = re.compile(r"<!--.*-->")


def _text(data):
    return data.decode("utf-8", "surrogateescape")


def _ok(*args):
    return proc.git(*args).returncode == 0


def _names(data):
    """NUL-separated names as `tr '\\0' '\\n'` hands them on, one per line (a name with a newline is two)."""
    lines = _text(data.replace(b"\0", b"\n")).split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def rollback_section(spec):
    """The body of '## Rollback', without HTML comments and blank lines ("" when the spec cannot be read)."""
    body, on = [], False
    for line in _lines(spec):
        if line.startswith("## "):
            on = line.startswith("## Rollback")
            continue
        if on:
            line = _COMMENT.sub("", line)
            if line.strip(_SPACE):
                body.append(line)
    return "\n".join(body)


def code_lines(path, comment):
    """The lines of a file that are not comments (the comment prefix after leading blanks)."""
    return [l for l in _lines(path) if comment == "" or not l.lstrip(_SPACE).startswith(comment)]


def _matching(ctx, pattern, names):
    """The names `grep -E` keeps, one grep per name as the Bash loop ran it when grep has something to say."""
    kept, err = text.grep_lines(pattern, names)
    if not err:
        return kept
    out = []
    for n in names:
        one, err = text.grep_lines(pattern, [n])
        ctx.err_bytes(err)
        out += one
    return out


def migration_versions(ctx, layer, base, pattern, main):
    """Unique versions, new ones after every existing one (shipfloor_config.py migration-check). E = on the base or on
    origin/<main> (merged, maybe applied); N = the card's own. Parallel cards collide here, even before the card merges
    main: origin/<main> is read directly."""
    main_ref = "origin/" + main if _ok("rev-parse", "-q", "--verify", "origin/%s^{commit}" % main) else ""
    existing = []
    for rev in [base] + ([main_ref] if main_ref else []):
        kept, err = text.grep_lines(pattern, _names(changes.git(ctx, "ls-tree", "-r", "-z", "--name-only", rev)))
        ctx.err_bytes(err)
        existing += kept
    feed = ["E\t" + _text(n) for n in changes._sort_u([n.encode("utf-8", "surrogateescape") for n in existing])]
    tracked = changes.git(ctx, "ls-files", "-z") + changes.git(ctx, "ls-files", "-z", "--others", "--exclude-standard")
    listed = [_text(n) for n in changes._sort_u([n.encode("utf-8", "surrogateescape") for n in _names(tracked)])]
    kept, err = text.grep_lines(pattern, listed)
    ctx.err_bytes(err)
    for f in kept:
        if not os.path.isfile(f) or _ok("cat-file", "-e", "%s:%s" % (base, f)):
            continue
        if main_ref and _ok("cat-file", "-e", "%s:%s" % (main_ref, f)):
            continue
        feed.append("N\t" + f)
    data = "".join(l + "\n" for l in feed).encode("utf-8", "surrogateescape")
    r = changes._cfg(("migration-check", layer), input=data)
    ctx.out_bytes(r.stdout)
    ctx.err_bytes(r.stderr)
    if r.returncode != 0:
        ctx.err("migration: versions of layer '%s' must be unique and newer than the base's" % layer)
        return False
    return True


def check_migration(ctx, base, spec, plan=None, changed=None):
    """The migration gate. `plan` (the config's migration-layers) and `changed` come from fast when it has them."""
    changes.require_rev(ctx, base)
    # the order check trusts the base: it must be on this branch's history
    if not _ok("merge-base", "--is-ancestor", base, "HEAD"):
        ctx.err("migration: base %s is not an ancestor of HEAD" % base)
        ctx.exit(2)
    if plan is None:
        plan = changes.config_query(ctx, "migration-layers")  # first line: main branch; then <layer> <ERE> <comment>
    lines = plan.split("\n")
    main = lines[0]
    rows = lines[1:]
    if rows and rows[-1] == "":  # `printf '%s\n' "$plan" | tail -n +2`: a last newline makes no extra row
        rows.pop()
    files = [f for f in (changes.changed_files(ctx, base) if changed is None else changed) if f]
    destructive = ""
    for row in rows:
        layer, pattern, comment = _read_tabs(row)
        if not layer:
            continue
        for f in _matching(ctx, pattern, files):
            if _ok("cat-file", "-e", "%s:%s" % (base, f)):
                ctx.err("migration: %s already exists on the base; applied migrations are immutable (add a new file)" % f)
                return 1
            if not os.path.isfile(f):
                continue
            if text.ere_match(_DESTRUCTIVE, "".join(l + "\n" for l in code_lines(f, comment)), ignore_case=True):
                destructive += " " + f
        if not migration_versions(ctx, layer, base, pattern, main):
            return 1
    if not destructive:
        return 0
    body = rollback_section(spec)
    if not body or text.ere_match(_NO_ROLLBACK, body, ignore_case=True):
        ctx.err("migration: destructive migration(s)%s need a filled '## Rollback' section in %s" % (destructive, spec))
        return 1
    return 0


def migration(ctx, args):
    return check_migration(ctx, args[0] if args else "", args[1] if len(args) > 1 else "")


def fast(ctx, args):
    """fast <base> <spec> [qa]: forbidden + migration + acceptance-intact in one process, on one config start
    (gate-fast: the forbidden ERE, the migration plan, acceptance_assertions); alone, each gate asks for its own."""
    r = changes._cfg(("gate-fast",))
    ctx.err_bytes(r.stderr)
    answers = _text(r.stdout).split("\0")
    if answers and answers[-1] == "":
        answers.pop()
    if len(answers) != 3:
        ctx.err("gate: config query failed: gate-fast")
        ctx.exit(2)
    forbidden_re, plan, keep = answers
    base = args[0] if args else ""
    spec = args[1] if len(args) > 1 else ""
    qa = args[2] if len(args) > 2 else ""
    changes.require_rev(ctx, base)
    changed = changes.changed_files(ctx, base)
    code = scope.check_forbidden(ctx, base, pattern=forbidden_re, changed=changed)
    if code:
        return code
    code = check_migration(ctx, base, spec, plan=plan, changed=changed)
    if code:
        return code
    return acceptance.check_acceptance_intact(ctx, qa, keep=keep) if qa else 0
