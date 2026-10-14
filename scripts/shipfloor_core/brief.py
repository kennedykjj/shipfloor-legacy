"""brief.sh build: writes <reviews>/<n>.brief.json (#178).

verdict, flags, proven and facts come from scripts only; the notes file gives prose (`what`, `suggestions`).
Any internal error is one `brief: skipped: <reason>` line on stderr and exit 0: a brief never blocks a card.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

from . import fs

COLUMNS = ("Spec Review", "Staged")
FLAG_TYPES = ("migration", "outside-architecture", "qa-amended", "open-question", "security", "infra-retry")
WHAT_MAX = 280
SUGGESTION_MAX = 120
_MIGRATION_RE = re.compile(r"(^|/)(db/)?migrations?/|(^|/)V\d+__[^/]*\.sql$", re.IGNORECASE)


class Skip(Exception):
    pass


def _git(*args):
    try:
        r = subprocess.run(("git",) + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as e:
        raise Skip("git: %s" % e)
    if r.returncode != 0:
        raise Skip("git %s failed" % (args[0] if args else ""))
    return r.stdout.decode("utf-8", "replace")


def _parse(args):
    if not args or args[0] != "build" or len(args) < 2:
        raise Skip("usage: brief.sh build <n> --column <column> --spec <spec> --head <sha> --notes <file>")
    opts = {"n": args[1]}
    i = 2
    while i < len(args):
        key = args[i]
        if key not in ("--column", "--spec", "--head", "--notes", "--since", "--out") or i + 1 >= len(args):
            raise Skip("bad argument %s" % key)
        opts[key[2:]] = args[i + 1]
        i += 2
    for need in ("column", "spec", "head"):
        if not opts.get(need):
            raise Skip("missing --%s" % need)
    if opts["column"] not in COLUMNS:
        raise Skip("unknown column %s" % opts["column"])
    return opts


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _section(text, name):
    m = re.search(r"^##[ \t]+%s[ \t]*$(.*?)(?=^##[ \t]|\Z)" % re.escape(name), text, re.MULTILINE | re.DOTALL)
    return m.group(1).strip() if m else ""


def _body(section):
    """The section's text without the `_Role_` line marker (and a dash after it)."""
    lines = []
    for line in section.splitlines():
        line = re.sub(r"^_[^_\n]+_\s*[—–-]?\s*", "", line.strip())
        if line:
            lines.append(line)
    return "\n".join(lines)


def _numstat(base, head):
    files, added, removed, names = 0, 0, 0, []
    for line in _git("diff", "--numstat", "%s...%s" % (base, head)).splitlines():
        parts = line.split("\t", 2)
        if len(parts) < 3:
            continue
        files += 1
        added += int(parts[0]) if parts[0].isdigit() else 0
        removed += int(parts[1]) if parts[1].isdigit() else 0
        names.append(parts[2])
    return files, added, removed, names


def _named(arch, path):
    for token in re.findall(r"`([^`\n]+)`", arch):
        token = token.strip()
        if path == token or (token.endswith("/") and path.startswith(token)) or path.startswith(token + "/"):
            return True
    return False


def _pr(head):
    try:
        r = subprocess.run(["gh", "pr", "view", "--json", "url"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           check=False, timeout=20)
        if r.returncode == 0:
            return json.loads(r.stdout.decode("utf-8", "replace")).get("url") or ""
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return ""


def _proven(home, head):
    gates = []
    for p in glob.glob(os.path.join(home, "gate-passes", "*")):
        try:
            with open(p, encoding="utf-8") as f:
                parts = f.readline().rstrip("\n").split("\t")
        except OSError:
            continue
        if len(parts) >= 3 and parts[1] == head and parts[2] not in gates:
            gates.append(parts[2])
    return sorted(gates)


def _flag(kind, title, detail="", hunk="", source=""):
    return {"id": kind, "kind": kind, "title": title, "detail": detail, "hunk": hunk, "source": source,
            "suggestion": ""}


def _flags(n, home, spec_text, names):
    flags = []
    mig = [x for x in names if _MIGRATION_RE.search(x)]
    if mig:
        flags.append(_flag("migration", "Adds or changes a migration", ", ".join(mig), source="gate migration"))
    arch = _section(spec_text, "Architecture")
    outside = [x for x in names if not x.startswith("docs/superpowers/") and not _named(arch, x)]
    if outside:
        flags.append(_flag("outside-architecture", "Changes files outside the Architecture section",
                           ", ".join(outside), source="git diff"))
    report = _read_json(os.path.join(home, "tmp", str(n), "report.json"))
    amendments = report.get("amendments") if isinstance(report, dict) else None
    if amendments:
        flags.append(_flag("qa-amended", "QA amended an acceptance test",
                           "; ".join(str(a) for a in amendments), source="develop report"))
    oq = _body(_section(spec_text, "Open questions"))
    if oq and oq.lower().strip("-* .") not in ("none", "n/a"):
        flags.append(_flag("open-question", "The spec has open questions", oq, source="spec"))
    sec_raw = _section(spec_text, "Security")
    sec = _body(sec_raw)
    if (sec and sec.lower().strip("-* .") not in ("n/a", "none")) or "\U0001F534" in sec_raw:
        flags.append(_flag("security", "The spec has security notes", sec, source="spec"))
    if os.path.exists(os.path.join(home, "infra", str(n))):
        flags.append(_flag("infra-retry", "The card was retried after an infrastructure failure",
                           source="infra marker"))
    return flags


def _notes(path):
    data = _read_json(path) if path else None
    if not isinstance(data, dict):
        return "", {}
    what = data.get("what")
    what = what[:WHAT_MAX] if isinstance(what, str) else ""
    sug = data.get("suggestions")
    out = {}
    if isinstance(sug, dict):
        for k, v in sug.items():
            if k in FLAG_TYPES and isinstance(v, str):
                out[k] = v[:SUGGESTION_MAX]
    return what, out


def _since(path):
    data = _read_json(path) if path else None
    if not isinstance(data, list):
        return []
    return [{"old": str(x.get("old", "")), "new": str(x.get("new", ""))} for x in data if isinstance(x, dict)]


def build(args):
    o = _parse(args)
    home = os.environ.get("FACTORY_HOME", "")
    if not home:
        raise Skip("FACTORY_HOME is not set")
    try:
        with open(o["spec"], encoding="utf-8") as f:
            spec_text = f.read()
    except OSError as e:
        raise Skip("cannot read the spec: %s" % (e.strerror or e))
    head = o["head"]
    base = "origin/%s" % (os.environ.get("FACTORY_MAIN") or "main")
    files, added, removed, names = _numstat(base, head)
    what, suggestions = _notes(o.get("notes"))
    flags = _flags(o["n"], home, spec_text, names)
    for f in flags:
        f["suggestion"] = suggestions.get(f["id"], "")
    since = _since(o.get("since"))
    brief = {
        "card": int(o["n"]) if o["n"].isdigit() else o["n"],
        "column": o["column"],
        "built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "verdict": "look" if flags or since else "routine",
        "what": {"text": what, "by": "agent"},
        "flags": flags,
        "since_request": since,
        "proven": _proven(home, head),
        "facts": {"pr": _pr(head), "files": files, "added": added, "removed": removed, "statements": 0},
        "rest": [],
    }
    out = o.get("out") or os.path.join(home, "reviews", "%s.brief.json" % o["n"])
    try:
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        fs.write_atomic(out, json.dumps(brief, ensure_ascii=False, indent=2) + "\n")
    except OSError as e:
        raise Skip("cannot write %s: %s" % (out, e.strerror or e))


def main(args):
    try:
        build(args)
    except Skip as e:
        print("brief: skipped: %s" % " ".join(str(e).split()), file=sys.stderr)
    except Exception as e:  # a brief never blocks a card
        print("brief: skipped: %s" % " ".join(("%s: %s" % (type(e).__name__, e)).split()), file=sys.stderr)
    return 0
