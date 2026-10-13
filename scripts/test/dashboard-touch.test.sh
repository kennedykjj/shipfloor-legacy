#!/usr/bin/env bash
# On a coarse pointer the dashboard hides the keyboard hints, and a stepper keeps its width in a stacked Settings row (#118).
# Static: reads the CSS and the script of dashboard.html. How it renders at 390px is seen by the owner in review.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0] + "/test"); import page_text  # the page's text is a catalog by key (#122)
h = page_text.english(h)
css = "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", h, re.S))
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
js = "\n".join(re.findall(r"<script[^>]*>(.*?)</script>", h, re.S))

def match_brace(s, i):
    d = 0
    for j in range(i, len(s)):
        if s[j] == "{": d += 1
        elif s[j] == "}":
            d -= 1
            if d == 0: return j
    return len(s) - 1

def split_top(s, sep):
    parts, d, cur = [], 0, ""
    for ch in s:
        if ch == "(": d += 1
        elif ch == ")": d -= 1
        if ch == sep and d == 0: parts.append(cur); cur = ""
        else: cur += ch
    return parts + [cur]

def decls(body):
    o = []
    for d in split_top(body, ";"):
        if ":" not in d: continue
        k, v = d.split(":", 1)
        v = re.sub(r"\s*!important", "", " ".join(v.split()))
        o.append((k.strip().lower(), v))
    return o

def parse(text):  # -> (rules outside any @-block, [(media header, inner text)])
    rules, media, i = [], [], 0
    while True:
        o = text.find("{", i)
        if o < 0: break
        head = text[i:o].strip()
        c = match_brace(text, o)
        if head.startswith("@media"): media.append((" ".join(head.split()), text[o + 1:c]))
        elif head.startswith("@"): pass
        else:
            sels = [" ".join(x.split()) for x in split_top(head, ",") if x.strip()]
            rules.append((sels, decls(text[o + 1:c])))
        i = c + 1
    return rules, media

wide, media = parse(css)

def hits(rules, target):
    return [d for sels, ds in rules for s in sels if s == target for d in ds]
def last(ds, prop):
    v = [x for k, x in ds if k == prop]
    return v[-1] if v else None
def hides(rules, target):
    return last(hits(rules, target), "display") == "none"
def ok(cond, name, why):
    print(("ok|" + name) if cond else ("FAIL|" + name + ": " + why))

coarse = [parse(m)[0] for h_, m in media if re.fullmatch(r"@media \(pointer: ?coarse\)", h_)]
coarse_rules = [r for blk in coarse for r in blk]
width_blocks = [(h_, parse(m)[0]) for h_, m in media if "width" in h_]
other_blocks = [(h_, parse(m)[0]) for h_, m in media if not re.fullmatch(r"@media \(pointer: ?coarse\)", h_)]

# AC-1
ok(hides(coarse_rules, ".foot"), "AC-1 .foot is display: none inside @media (pointer: coarse)",
   "AC-1: .foot is not hidden inside @media (pointer: coarse)")

# AC-2
ok(hides(coarse_rules, ".iopt kbd"), "AC-2 .iopt kbd is display: none inside @media (pointer: coarse)",
   "AC-2: the number on an option button (.iopt kbd) is not hidden inside @media (pointer: coarse)")

# AC-3: the whole footer goes, nothing else is declared, and it wins over the .foot rule
ds = [d for _, dd in coarse_rules for d in dd]
only_none = bool(coarse_rules) and all(d == ("display", "none") for d in ds)
ok(hides(coarse_rules, ".foot") and only_none,
   "AC-3 the coarse block hides .foot itself and declares nothing but display: none",
   f"AC-3: the footer is not hidden as a whole on a coarse pointer (hairline and padding would stay as an empty row); coarse blocks: {len(coarse)}, declarations {ds}")
sels = [s for sels_, _ in coarse_rules for s in sels_]
ok(bool(coarse_rules) and all(s in (".foot", ".iopt kbd") for s in sels),
   "AC-3 the coarse block hides the .foot parent, not only .keys-list / .keys-inbox / kbd",
   f"AC-3: the coarse block is missing or targets other selectors: {sels}")
cm = re.search(r"@media \(pointer: ?coarse\)", css)
fm = [m.start() for m in re.finditer(r"(?m)^\s*\.foot\s*\{", css)]
ok(bool(cm) and bool(fm) and cm.start() > max(fm),
   "AC-3 the coarse block comes after the .foot rule, so it wins",
   "AC-3: no @media (pointer: coarse) block after the .foot rule")

# AC-4: the hints hide only on a coarse pointer; a fine pointer at any width shows them as today
nowhere = not any(hides(r, ".foot") or hides(r, ".iopt kbd") for r in [wide] + [b for _, b in width_blocks])
ok(bool(coarse_rules) and nowhere,
   "AC-4 the hints are hidden only inside @media (pointer: coarse), in no width query and no top-level rule",
   f"AC-4: the coarse block is missing, or a width query or top-level rule hides .foot / .iopt kbd (coarse blocks: {len(coarse)})")
bad_q = [h_ for h_, b in other_blocks if hides(b, ".foot") or hides(b, ".iopt kbd")]
ok(not bad_q and not re.search(r"@media[^{]*(any-pointer|hover)[^{]*\{[^{}]*\{[^}]*(\.foot|\.iopt kbd)", css),
   "AC-4 (guard, passes today) no any-pointer or hover query hides the hints", f"AC-4: hidden under {bad_q}")
ok(last(hits(wide, ".foot"), "display") == "flex",
   "AC-4 (guard, passes today) outside media blocks .foot is still display: flex", f"AC-4: .foot display is {last(hits(wide, '.foot'), 'display')!r}")
ok(last(hits(wide, ".yours.maxed .foot .keys-inbox"), "display") == "flex",
   "AC-4 (guard, passes today) .yours.maxed .foot .keys-inbox still shows",
   "AC-4: .yours.maxed .foot .keys-inbox is no longer display: flex")
ok(hides(wide, ".foot[hidden]"),
   "AC-4 (guard, passes today) .foot[hidden] still hides the footer when nothing waits",
   "AC-4: the .foot[hidden] rule is gone")

# AC-5: the shortcuts stay bound on every device
ok(not re.search(r"matchMedia\([^)]*(pointer|hover)", js),
   "AC-5 (guard, passes today) the script has no matchMedia on pointer or hover",
   "AC-5: the script switches on the pointer; the shortcuts must stay bound on every device")
ok(re.search(r'k === "n"', js), "AC-5 (guard, passes today) the key handler still handles N", "AC-5: N is no longer handled")
ok(re.search(r'\ba:\s*[\'"]\[data-q="approve"\]', js) and re.search(r'\br:\s*[\'"]\[data-go="review"\]', js) and re.search(r'\bl:\s*[\'"]\[data-go="log"\]', js),
   "AC-5 (guard, passes today) the key handler still maps A approve, R review, L log", "AC-5: A, R or L no longer map to their buttons")
ok("/^[1-9]$/" in js, "AC-5 (guard, passes today) the key handler still handles 1-9", "AC-5: 1-9 is no longer handled")
ok(len(re.findall(r'e\.key === "Escape"', js)) >= 2, "AC-5 (guard, passes today) the key handler still handles Escape", "AC-5: Escape is no longer handled")

# AC-6: a stacked Settings row keeps the stepper at its content width, at the left edge
blk = [parse(m)[0] for h_, m in media if h_ == "@media (max-width: 1180px)" and
       any(s == ".srow" and ("grid-template-columns", "minmax(0, 1fr)") in d for sl, d in parse(m)[0] for s in sl)]
srow = blk[0] if blk else []
js_start = last(hits(srow, ".srow > .stp"), "justify-self")
ok(js_start == "start",
   "AC-6 in the Settings block (max-width: 1180px) .srow > .stp has justify-self: start",
   f"AC-6: .srow > .stp does not have justify-self: start in the Settings block, it is {js_start!r}" if blk else "AC-6: the Settings @media (max-width: 1180px) block (.srow one column) is missing")

# AC-7: the stepper works as on desktop (guards)
ok(re.search(r'data-step="\$\{k\}"[^`]*aria-label="\$\{label\}"', js) and 'b(-1, "Less"' in js and 'b(1, "More"' in js,
   "AC-7 (guard, passes today) the stepper template still gives minus and plus their aria-label",
   "AC-7: the stepper buttons lost data-step or their aria-label")
ok(re.search(r"else if \(t\.dataset\.step\) setStep\(t\)", js) and "function setStep(" in js,
   "AC-7 (guard, passes today) a click on a stepper button still calls setStep", "AC-7: the click no longer reaches setStep")
b = hits(wide, ".stp button")
ok(last(b, "width") == "34px" and last(b, "height") == "34px",
   "AC-7 (guard, passes today) .stp button is 34px by 34px", f"AC-7: .stp button is {last(b,'width')!r} by {last(b,'height')!r}")
ok(last(hits(wide, ".stp.dirty output"), "color") == "var(--sand)",
   "AC-7 (guard, passes today) a dirty stepper value is --sand", "AC-7: .stp.dirty output is not var(--sand)")
ok("t.dataset.step" in js and 'class="stp${k in SET.draft ? " dirty" : ""}' in js,
   "AC-7 (guard, passes today) a stepper still marks the change as dirty", "AC-7: the dirty class on .stp is gone")

# AC-8: above 1180px with a fine pointer nothing moves
stp = hits(wide, ".stp")
bad = [k for k, _ in stp if k in ("width", "flex", "justify-self", "flex-basis", "flex-grow")]
ok(not bad, "AC-8 (guard, passes today) outside media blocks .stp has no width, flex or justify-self", f"AC-8: .stp declares {bad} outside media blocks")
ok(last(hits(wide, ".srow"), "grid-template-columns") == "minmax(0, 1fr) auto",
   "AC-8 (guard, passes today) .srow keeps its two columns outside media blocks",
   f"AC-8: .srow columns are {last(hits(wide, '.srow'), 'grid-template-columns')!r}")
PY
)"
while IFS= read -r line; do
  case "$line" in
    ok\|*) pass "${line#ok|}" ;;
    FAIL\|*) fail "${line#FAIL|}" ;;
    *) fail "unexpected output: $line" ;;
  esac
done <<< "$out"
finish
