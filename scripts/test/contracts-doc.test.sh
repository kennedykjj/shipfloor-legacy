#!/usr/bin/env bash
# docs/contracts.md covers every script: a section per file that lists each subcommand of its usage line, as the doc's
# top says this test enforces. Reads: scripts/*.sh, scripts/lib/*.sh, scripts/shipfloor, docs/contracts.md.
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$FACTORY_DIR/.." && pwd)"
out="$("$FACTORY_PYTHON" -I - "$ROOT" <<'PY'
import glob, os, re, sys, tempfile

root = sys.argv[1]
res = []
def ok(name): res.append(f"PASS {name}")
def bad(name, msg): res.append(f"FAIL {name}: {msg}")
def check(name, cond, msg):
    ok(name) if cond else bad(name, msg)

def rd(p):
    with open(p, encoding="utf-8", newline=None) as f:
        return f.read().replace("\r\n", "\n")

# ---- the scripts: every scripts/*.sh, scripts/lib/*.sh and the shipfloor CLI, named as the doc's heading names them
scripts = sorted(os.path.relpath(p, os.path.join(root, "scripts")).replace(os.sep, "/")
                 for p in glob.glob(os.path.join(root, "scripts", "*.sh")) + glob.glob(os.path.join(root, "scripts", "lib", "*.sh")))
scripts.append("shipfloor")

def words(text):
    """The subcommand words of a usage fragment: no <arg>, no flags, no ..., no script names."""
    text = re.sub(r"<[^<>]*>", " ", text)
    out = []
    for tok in re.split(r"[\s|\[\]]+", text):
        if re.fullmatch(r"[a-z][a-z0-9-]*", tok):
            out.append(tok)
    return out

def subcommands(name):
    src = rd(os.path.join(root, "scripts", name))
    base = os.path.basename(name)
    found = []
    lines = src.split("\n")
    # `usage: <script> ...` strings and comments
    for line in lines:
        m = re.search(r"usage: (.*)", line)
        if not m:
            continue
        frag = m.group(1)
        frag = re.split(r'"', frag)[0]
        frag = re.sub(r"^\s*\S+", "", frag, count=1) if re.match(r"\s*(?:\S*/)?%s\b" % re.escape(base.replace(".sh", "")), frag) else frag
        found += words(frag)
    # the `usage` heredoc: the command column of each indented line
    in_usage = False
    for i, line in enumerate(lines):
        if re.match(r"usage\(\)\s*\{", line):
            in_usage = True
        if in_usage and re.match(r"\s*cat <<'?EOF'?", line):
            for l in lines[i + 1:]:
                if l.strip() == "EOF":
                    break
                if re.match(r"  \S", l):
                    found += words(re.split(r"\s{3,}", l.strip())[0])
            in_usage = False
    seen, uniq = set(), []
    for w in found:
        if w not in seen and w != base.replace(".sh", "") and w != "usage":
            seen.add(w); uniq.append(w)
    return uniq

def sections(doc):
    """heading name -> body; a heading is `## name`, optionally in backticks and followed by a note."""
    out = {}
    parts = re.split(r"^## +(.*)$", doc, flags=re.M)
    for i in range(1, len(parts), 2):
        head = parts[i].replace("`", "").strip()
        out.setdefault(head, parts[i + 1])
        out.setdefault(head.split(" ")[0], parts[i + 1])
    return out

def missing(doc, usage):
    """['<script>: <subcommand>', ...] for each usage word the script's section does not list in backticks."""
    secs = sections(doc)
    bad_ = []
    for s in scripts:
        body = secs.get(s)
        if body is None:
            continue
        for w in usage[s]:
            if "`%s`" % w not in body:
                bad_.append(f"{s}: {w}")
    return bad_

usage = {s: subcommands(s) for s in scripts}

# the extraction itself must see what the usage lines say, or AC-3 would pass on nothing
check("the usage of gate.sh yields red, green and stack subcommands", {"red", "green", "stack", "up", "down", "status"} <= set(usage["gate.sh"]),
      f"found {usage['gate.sh']}")
check("the usage of board.sh yields move, label and issue", {"move", "label", "issue", "items"} <= set(usage["board.sh"]), f"found {usage['board.sh']}")
check("the usage of shipfloor yields install, add, pool, accept and weight", {"install", "add", "pool", "accept", "weight"} <= set(usage["shipfloor"]),
      f"found {usage['shipfloor']}")
check("the usage of shipfloor pool yields set, stage and stacks", {"set", "stage", "stacks"} <= set(usage["shipfloor"]), f"found {usage['shipfloor']}")

doc_path = os.path.join(root, "docs", "contracts.md")
if not os.path.isfile(doc_path):
    for ac in ("AC-1", "AC-3", "AC-4"):
        bad(f"{ac} docs/contracts.md exists", "docs/contracts.md does not exist")
    doc = None
else:
    doc = rd(doc_path)

if doc is not None:
    secs = sections(doc)

    # AC-1: a section for every script and the CLI
    for s in scripts:
        check(f"AC-1 section \"## {s}\"", s in secs, f"docs/contracts.md has no \"## {s}\" section")

    # AC-3: every usage subcommand is listed
    miss = missing(doc, usage)
    for s in scripts:
        if s in secs:
            lost = [m for m in miss if m.startswith(s + ": ")]
            check(f"AC-3 {s} lists every subcommand of its usage line", not lost, "not listed: " + ", ".join(lost))

    # AC-4: the same check on a copy with one subcommand removed fails and names script and subcommand
    tmp = tempfile.mkdtemp()
    for s, w in (("gate.sh", "red"), ("board.sh", "move"), ("shipfloor", "weight")):
        body = secs.get(s)
        if body is None or "`%s`" % w not in body:
            bad(f"AC-4 removing `{w}` from {s} is caught", f"the {s} section does not list `{w}` to remove")
            continue
        copy = doc.replace(body, body.replace("`%s`" % w, w), 1)
        p = os.path.join(tmp, "contracts.md")
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(copy)
        got = missing(rd(p), usage)
        check(f"AC-4 removing `{w}` from {s} fails the check and names \"{s}: {w}\"", f"{s}: {w}" in got,
              f"the check on the copy said: {got or 'nothing (it passed)'}")
        check(f"AC-4 removing `{w}` from {s} names no other script", all(g.startswith(s + ": ") for g in got), f"the check said: {got}")

# AC-5 (#178): the brief.sh section documents the brief.json contract
if doc is not None:
    bsec = sections(doc).get("brief.sh")
    check("AC-5 docs/contracts.md has a \"## brief.sh\" section", bsec is not None, "docs/contracts.md has no \"## brief.sh\" section")
    bsec = bsec or ""
    check("AC-5 the brief.sh section names brief.json", "brief.json" in bsec, "the brief.sh section does not name brief.json")
    for fld in ("verdict", "flags", "proven", "facts", "since_request", "what", "rest"):
        check(f"AC-5 the brief.sh section documents the field `{fld}`", re.search(r"`%s`" % fld, bsec) is not None,
              f"the brief.sh section does not list `{fld}` in backticks")
    check("AC-5 the brief.sh section says since_request is accepted as input and empty when absent",
          re.search(r"since_request", bsec) is not None and re.search(r"\bempty\b", bsec, flags=re.I) is not None
          and re.search(r"input|--since", bsec, flags=re.I) is not None,
          "the brief.sh section does not say since_request is an input and empty when absent")
    check("AC-5 the brief.sh section says who writes each field (script vs agent notes)",
          re.search(r"notes", bsec, flags=re.I) is not None and re.search(r"script|brief\.py", bsec, flags=re.I) is not None,
          "the brief.sh section does not say which fields the script computes and which the notes give")
    check("AC-5 the files table has a brief.json row", re.search(r"^\|[^\n]*brief\.json[^\n]*\|", doc, flags=re.M) is not None,
          "docs/contracts.md has no table row for brief.json")

print("\n".join(res))
PY
)"
if [ -z "$out" ]; then fail "the check printed nothing"; fi
while IFS= read -r line; do
  case "$line" in
    PASS\ *) pass "${line#PASS }" ;;
    FAIL\ *) fail "${line#FAIL }" ;;
  esac
done <<< "$out"
finish
