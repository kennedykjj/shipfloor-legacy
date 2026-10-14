"""Turns a factory spec (markdown) into the interactive review page: one reviewable row per statement."""
import json
import os
import re
import sys
from datetime import date

USAGE = "usage: review-page.sh <spec.md> <issue> <branch> <out.html>"


def plain(s):
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    return s.replace("`", "").strip()


def build(spec, issue, branch, out, template, label, project):
    project = project or "factory"
    with open(spec, encoding="utf-8") as f:
        text = f.read()
    title = plain(re.sub(r"\s+—\s+spec\s*$", "", text.splitlines()[0].lstrip("# ")))
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

    data = [s for s in sections if s["items"]]
    # Only open questions are for the owner to decide; everything else is shown read-only.
    # "dúvidas" is the legacy (Portuguese) title.
    for s in data:
        s["ro"] = s["t"].strip().lower() not in ("open questions", "dúvidas")
    data.sort(key=lambda s: s["ro"])  # questions first
    with open(template, encoding="utf-8") as f:
        html = f.read()
    for k, v in {"__DATA__": json.dumps(data, ensure_ascii=False), "__ISSUE__": issue, "__TITLE__": title,
                 "__BRANCH__": branch, "__SPEC__": label, "__DATE__": date.today().strftime("%d/%m/%Y"),
                 "__KEY__": f"{project}-spec-{issue}-review"}.items():
        html = html.replace(k, v)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)


def main(argv):
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
    build(spec, issue, branch, out, template, spec, os.environ.get("FACTORY_PROJECT", ""))
    return 0
