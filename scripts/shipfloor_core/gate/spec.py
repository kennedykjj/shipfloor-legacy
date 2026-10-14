"""The gates that read the spec: test-plan (every AC has a test its layer can run) and weight (one weight in the header)."""
import os
import re

from . import changes, scope
from .context import GateExit

_SPACE = " \t\n\r\f\v"
_AC_HEADER = re.compile(r"[ \t\n\r\f\v]*AC[ \t\n\r\f\v]*")
_AC_BLANK = re.compile(r"[ \t\n\r\f\v:-]*")
_ROW = re.compile(r"[ \t\n\r\f\v]*\|")
_BACKTICKED = re.compile(r"`[^`]+`")
_AC_ID = re.compile(r"\bAC-[0-9]+\b")
_WEIGHT = re.compile(r"\*\*Weight:\*\*[ \t\n\r\f\v]*`?(light|standard|heavy)`?[ \t\n\r\f\v]*")


def _lines(path):
    """The lines of a file as awk reads them (a last line with no newline counts)."""
    try:
        with open(path, "rb") as f:
            data = f.read().decode("utf-8", "surrogateescape")
    except OSError:
        return []
    parts = data.split("\n")
    if parts and parts[-1] == "":
        parts.pop()
    return parts


def _rows(spec):
    """(ACs, layer, first `path` of the file cell) per row of the '## Test plan' table, as the awk of the Bash gate cut them."""
    rows = []
    on = False
    for line in _lines(spec):
        if line.startswith("## "):
            on = line.startswith("## Test plan")
            continue
        if not on or not _ROW.match(line):
            continue
        f = line.split("|")
        f += [""] * (4 - len(f))
        if _AC_HEADER.fullmatch(f[1]) or _AC_BLANK.fullmatch(f[1]):
            continue
        m = _BACKTICKED.search(f[3])
        rows.append((f[1], f[2].strip(_SPACE), m.group(0)[1:-1] if m else ""))
    return rows


def _read_tabs(row):
    """`IFS=$'\\t' read -r acs layer path` of one row: runs of tabs are one separator, the last name takes the rest."""
    s = row.lstrip("\t")
    out = []
    for _ in range(2):
        cut = s.find("\t")
        if cut < 0:
            out.append(s)
            s = ""
            break
        out.append(s[:cut])
        s = s[cut:].lstrip("\t")
    out.append(s.rstrip("\t"))
    while len(out) < 3:
        out.append("")
    return out[0], out[1], out[2]


_ESC = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\"}


def _percent_b(s):
    """printf '%b' of a string: its backslash escapes expanded."""
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 >= len(s):
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        if n in _ESC:
            out.append(_ESC[n])
            i += 2
        elif n == "c":
            break
        elif n == "x":
            m = re.compile(r"[0-9A-Fa-f]{1,2}").match(s, i + 2)
            if m:
                out.append(chr(int(m.group(0), 16)))
                i = m.end()
            else:
                out.append("\\x")
                i += 2
        elif n in "01234567":
            m = re.compile(r"[0-7]{1,3}").match(s, i + 2 if n == "0" else i + 1)
            out.append(chr(int(m.group(0), 8)) if m else "\0")
            i = m.end() if m else i + 2
        else:
            out.append("\\" + n)
            i += 2
    return "".join(out)


def test_plan(ctx, args):
    spec = args[0] if args else ""
    all_layers = changes.config_query(ctx, "layers")
    changes.config_query(ctx, "layers", "--implementers")
    if not os.path.isfile(spec):
        ctx.err("test-plan: spec '%s' not found" % spec)
        return 2
    rows = _rows(spec)
    if not rows:
        ctx.err("test-plan: '## Test plan' has no rows in %s" % spec)
        return 1
    names = all_layers.split() or [""]
    bad = ""
    for row in rows:
        acs, layer, path = _read_tabs("\t".join(row))
        if layer == "manual":
            continue
        if layer not in names:
            bad += "\\n%s: unknown layer '%s' (layers: %s, or manual)" % (acs, layer, " ".join(all_layers.split()))
            continue
        code, data = _fields(layer)
        if code != 0:
            ctx.err("gate: unknown layer '%s'" % layer)
            return 2
        if not path or not scope.grep(ctx, data, [path]):
            try:
                tests = changes.config_query(ctx, "layer", layer, "tests").replace("\n", " ")
            except GateExit:  # the `$(...)` the Bash gate asked in is a subshell: its exit ends only itself
                tests = ""
            bad += "\\n%s: '%s' is not a test file of layer '%s' (its tests: %s)" % (acs, path or "no path", layer, tests)
    in_product = False
    ids = set()
    for line in _lines(spec):
        if line.startswith("## "):
            in_product = line.startswith("## Product")
        elif in_product:
            ids.update(_AC_ID.findall(line))
    firsts = ["\t".join(r).split("\t")[0] for r in rows]  # cut -f1
    for ac in changes._sort_u([i.encode() for i in ids]):
        ac = ac.decode()
        if not any(re.search(r"\b" + ac + r"\b", a) for a in firsts):
            bad += "\\n%s: no row in '## Test plan'" % ac
    if not bad:
        return 0
    ctx.err("test-plan: the pipeline cannot run these acceptance tests (paths are repo-relative):")
    ctx.err(_percent_b(bad[2:]))
    return 1


def _fields(layer):
    """(0, the layer's _tests_re) or (2, "") when the config knows no such layer."""
    r = changes._cfg(("fields", layer, "_tests_re"))
    parts = r.stdout.split(b"\0") if r.returncode == 0 else []
    if parts and parts[-1] == b"":
        parts.pop()
    if len(parts) != 1:
        return 2, ""
    return 0, parts[0].decode("utf-8", "surrogateescape")


def weight(ctx, args):
    spec = args[0] if args else ""
    if not os.path.isfile(spec):
        ctx.err("weight: spec '%s' not found" % spec)
        return 2
    found = []
    for line in _lines(spec):
        if line.startswith("## "):
            break
        if line.startswith("**Weight:**"):
            found.append(line.replace("\r", ""))
    text = "\n".join(found).rstrip("\n")
    if not text:
        ctx.err("weight: the spec header has no '**Weight:** light|standard|heavy' line (%s)" % spec)
        return 1
    if text.count("\n") + 1 > 1:
        ctx.err("weight: the spec header has more than one weight line:")
        ctx.err(text)
        return 1
    if _WEIGHT.fullmatch(text):
        return 0
    ctx.err("weight: '%s' names no weight the factory knows (light, standard, heavy)" % text)
    return 1
