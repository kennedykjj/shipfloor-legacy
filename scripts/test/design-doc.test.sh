#!/usr/bin/env bash
# DESIGN.md after the belt (#181, AC-8): The Belt replaces the Lifecycle Band and the Line Peek, and the belt is recorded as the
# third continuous motion, allowed because it carries state and stopped under reduced motion.
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$FACTORY_DIR/.." && pwd)"
out="$("$FACTORY_PYTHON" -I - "$ROOT" <<'PY'
import os, re, sys
design = open(os.path.join(sys.argv[1], "DESIGN.md"), encoding="utf-8", newline=None).read()
res = []
def check(name, cond, why): res.append(("PASS " + name) if cond else ("FAIL " + name + ": " + why))
def section(title):
    m = re.search(r"^(#{2,3})[ \t]*%s[ \t]*\n(.*?)(?=^#{1,3}[ \t]|\Z)" % re.escape(title), design, flags=re.S | re.M)
    return m.group(2) if m else ""

heads = re.findall(r"^#{2,3}[ \t]*(.+?)[ \t]*$", design, flags=re.M)
check("AC-8 the Lifecycle Band section is gone", "Lifecycle Band" not in heads, "DESIGN.md still has a Lifecycle Band heading")
check("AC-8 the Line Peek section is gone", "Line Peek" not in heads, "DESIGN.md still has a Line Peek heading")
check("AC-8 a section The Belt replaces them", "The Belt" in heads, "no heading 'The Belt'; headings: %s" % heads[:30])
belt = section("The Belt")
check("AC-8 The Belt describes the tokens, the rail and the status sentence", all(re.search(w, belt, flags=re.I) for w in ("token", "rail", "status")), "The Belt section: %s" % belt[:120].replace("\n", " "))
check("AC-8 The Belt says it stops under reduced motion", re.search(r"reduced motion|prefers-reduced-motion", belt, flags=re.I) is not None, "The Belt never mentions reduced motion")
check("AC-8 nothing still points at the lifecycle band or the line peek", re.search(r"lifecycle band|line peek", design, flags=re.I) is None,
      "DESIGN.md still says: %s" % (re.search(r"[^\n]*(?:lifecycle band|line peek)[^\n]*", design, flags=re.I) or [""])[0][:100])
sents = re.split(r"(?<=[.!?])\s+|\n", design)
third = [s for s in sents if re.search(r"third continuous motion", s, flags=re.I)]
check("AC-8 the belt is recorded as the third continuous motion", any(re.search(r"\bbelt\b", s, flags=re.I) for s in third), "no sentence calls the belt the third continuous motion")
check("AC-8 it is allowed because it carries state and stops under reduced motion", any(re.search(r"\bstate\b", s) and re.search(r"reduced", s) for s in third) or
      (bool(third) and re.search(r"carr(?:ies|y)[^.]*state", design) is not None and re.search(r"stopped under reduced motion|stops under reduced motion", design) is not None),
      "the third-motion sentence names neither its state nor reduced motion")
check("AC-8 the old rule 'two continuous motions only' is gone", re.search(r"two continuous motions", design, flags=re.I) is None, "DESIGN.md still says two continuous motions")
check("AC-8 the Don'ts no longer cap the page at a third continuous animation", re.search(r"third continuous animation", design, flags=re.I) is None, "a Don't still forbids 'a third continuous animation'")
check("AC-8 the Do's name the dial, the pulse and the belt as the continuous motion", any(re.search(r"\bdial\b", l) and re.search(r"pulse", l) and re.search(r"\bbelt\b", l) and re.search(r"continuous", l) for l in design.splitlines()), "no line names the dial, the dot's pulse and the belt as the continuous motion")
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
