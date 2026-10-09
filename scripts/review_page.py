"""Turns a factory spec (markdown) into the interactive review page: one reviewable row per statement."""
import json, re, sys
from datetime import date

spec_path, issue, branch, out_path, template_path, spec_label = sys.argv[1:7]
project = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else "factory"
text = open(spec_path, encoding="utf-8").read()

def plain(s):
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    return s.replace("`", "").strip()

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
html = open(template_path, encoding="utf-8").read()
for k, v in {"__DATA__": json.dumps(data, ensure_ascii=False), "__ISSUE__": issue, "__TITLE__": title,
             "__BRANCH__": branch, "__SPEC__": spec_label, "__DATE__": date.today().strftime("%d/%m/%Y"),
             "__KEY__": f"{project}-spec-{issue}-review"}.items():
    html = html.replace(k, v)
open(out_path, "w", encoding="utf-8", newline="\n").write(html)
