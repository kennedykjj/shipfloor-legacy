"""Turns a factory spec (markdown) into the interactive review page: one reviewable row per statement.
A card back in Spec Review also gets what changed since the version the owner read (#177)."""
import copy
import json
import os
import re
import shutil
import sys
from datetime import date

USAGE = ("usage: review-page.sh <spec.md> <issue> <branch> <out.html> [--request-file F]\n"
         "       review-page.sh --diff <old.md> <new.md>")


def plain(s):
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    return s.replace("`", "").strip()


def parse_statements(text):
    """(title, sections): each section {id, t, intro, items}, the items being the statements of the spec."""
    title = plain(re.sub(r"\s+—\s+spec\s*$", "", text.splitlines()[0].lstrip("# "))) if text.strip() else ""
    sections, cur = [], None
    for line in text.splitlines()[1:]:
        if line.startswith("## "):
            cur = {"id": re.sub(r"[^a-z0-9]+", "-", line[3:].lower()).strip("-") or f"s{len(sections)}",
                   "t": line[3:].strip(), "intro": "", "items": []}
            sections.append(cur)
            continue
        if cur is None or not line.strip():
            continue
        s = line.strip()
        if s.startswith("_") and s.endswith(("_", "n/a", "não se aplica")):
            cur["intro"] = plain(s.strip("_").replace("_ —", " —"))
            continue
        if s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            if all(re.fullmatch(r":?-+:?", c) for c in cells) or cells[0] in ("AC", "CA", "Papel", "Role"):
                continue
            cur["items"].append(plain(" · ".join(cells)))
            continue
        if s.lower() in ("n/a", "- none", "não se aplica", "- nenhuma"):
            continue
        if re.fullmatch(r"\*\*[^*]+\*\*:?", s):  # a bold label alone ("**Acceptance criteria**")
            continue
        cur["items"].append(plain(s[2:] if s.startswith("- ") else s))
    return title, sections


def _pair(old, new):
    """{section id: [(status, old text, new text)]}: per section, an identical statement is untouched, the i-th unmatched
    old one pairs with the i-th unmatched new one (changed), the rest are new / removed. The new statements come in
    their order, the removed ones last; the sections are the new ones, then those only the old spec had."""
    def group(sections):
        g = {}
        for s in sections:
            g.setdefault(s["id"], []).extend(s["items"])
        return g
    go, gn = group(old), group(new)
    out = {}
    for sid in [*gn, *(k for k in go if k not in gn)]:
        pool, texts = list(go.get(sid, [])), gn.get(sid, [])
        same = []
        for t in texts:
            if t in pool:
                pool.remove(t)
                same.append(True)
            else:
                same.append(False)
        rows, k = [], 0
        for t, is_same in zip(texts, same):
            if is_same:
                rows.append(("untouched", t, t))
            elif k < len(pool):
                rows.append(("changed", pool[k], t))
                k += 1
            else:
                rows.append(("new", None, t))
        rows += [("removed", t, None) for t in pool[k:]]
        out[sid] = rows
    return out


def statement_diff(old_text, new_text):
    """[{section, status, old, new}] of the spec the owner read against the one now built; status is new, changed,
    untouched or removed."""
    pairs = _pair(parse_statements(old_text)[1], parse_statements(new_text)[1])
    return [{"section": sid, "status": st, "old": o, "new": n} for sid, rows in pairs.items() for st, o, n in rows]


def _json(v):
    """JSON safe inside a <script>: < > & never close it."""
    return json.dumps(v, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _marked(sections, old_sections):
    """Gives each statement of the sections its mark against the old spec (items become {t, mark[, old]}; an untouched
    one has an empty mark) and lists what was removed. Returns the sections and how many statements changed."""
    pairs = _pair(old_sections, sections)
    taken, gone_done, changes = {}, set(), 0
    for s in sections:
        rows = [r for r in pairs[s["id"]] if r[2] is not None]
        at = taken.get(s["id"], 0)
        taken[s["id"]] = at + len(s["items"])
        items = []
        for st, o, n in rows[at:at + len(s["items"])]:
            it = {"t": n, "mark": "" if st == "untouched" else st}
            if st == "changed":
                it["old"] = o
            changes += st != "untouched"
            items.append(it)
        s["items"] = items
        if s["id"] not in gone_done:
            gone_done.add(s["id"])
            s["gone"] = [{"t": o, "mark": "removed"} for st, o, n in pairs[s["id"]] if st == "removed"]
            changes += len(s["gone"])
    ids = {s["id"] for s in sections}
    for s in old_sections:
        if s["id"] not in ids and s["id"] not in gone_done:
            gone_done.add(s["id"])
            gone = [{"t": o, "mark": "removed"} for st, o, n in pairs[s["id"]] if st == "removed"]
            changes += len(gone)
            sections.append({"id": s["id"], "t": s["t"], "intro": "", "items": [], "gone": gone})
    return sections, changes


def build(spec, issue, branch, out, template, label, project, request_file=None):
    project = project or "factory"
    text = _read(spec)
    title, sections = parse_statements(text)

    # the baseline: the spec as last published, rotated to <n>.read.md once the spec changes
    folder = os.path.dirname(out) or "."
    published, read = os.path.join(folder, f"{issue}.published.md"), os.path.join(folder, f"{issue}.read.md")
    if os.path.isfile(published) and _read(published) != text:
        shutil.copyfile(published, read)
    if not os.path.isfile(published) or _read(published) != text:
        with open(published, "w", encoding="utf-8", newline="") as f:
            f.write(text)

    since = None
    if os.path.isfile(read):
        old_sections = parse_statements(_read(read))[1]
        request = ""
        if request_file and os.path.isfile(request_file):
            request = _read(request_file).strip()
        marked, changes = _marked(copy.deepcopy(sections), old_sections)
        if changes:
            sections = marked
        since = {"n": changes, "request": request or None}

    data = [s for s in sections if s["items"] or s.get("gone")]
    # Only open questions are for the owner to decide; everything else is shown read-only.
    # "dúvidas" is the legacy (Portuguese) title.
    for s in data:
        s["ro"] = s["t"].strip().lower() not in ("open questions", "dúvidas")
    data.sort(key=lambda s: s["ro"])  # questions first
    html = _read(template)
    subst = {"__DATA__": _json(data), "__SINCE__": _json(since), "__ISSUE__": issue, "__TITLE__": title,
             "__BRANCH__": branch, "__SPEC__": label, "__DATE__": date.today().strftime("%d/%m/%Y"),
             "__KEY__": f"{project}-spec-{issue}-review"}
    html = re.sub(r"__[A-Z]+__", lambda m: subst.get(m.group(0), m.group(0)), html)  # one pass: a value is never re-read
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)


def main(argv):
    argv = list(argv)
    if argv[:1] == ["--diff"]:
        if len(argv) != 3 or not all(os.path.isfile(p) for p in argv[1:]):
            print(USAGE if len(argv) != 3 else f"review-page: not a file: {' '.join(p for p in argv[1:] if not os.path.isfile(p))}", file=sys.stderr)
            return 2
        print(json.dumps(statement_diff(_read(argv[1]), _read(argv[2])), ensure_ascii=False))
        return 0
    request_file = None
    if "--request-file" in argv:
        i = argv.index("--request-file")
        if i + 1 >= len(argv):
            print(USAGE, file=sys.stderr)
            return 2
        request_file = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) != 4:
        print(USAGE, file=sys.stderr)
        return 2
    spec, issue, branch, out = argv
    if not os.path.isfile(spec):
        print(f"review-page: spec not found: {spec}", file=sys.stderr)
        return 2
    folder = os.path.dirname(out)
    if folder:
        os.makedirs(folder, exist_ok=True)
    template = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "review-template.html")
    build(spec, issue, branch, out, template, spec, os.environ.get("FACTORY_PROJECT", ""), request_file)
    return 0
