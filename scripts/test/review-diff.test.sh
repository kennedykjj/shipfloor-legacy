#!/usr/bin/env bash
# #177 (UX-03): incremental re-review. A card back in Spec Review shows what changed since the version the owner read.
# Offline: the page is built by review-page.sh and read as text; the theme and the language are checked on the template
# and the catalogs, never in a browser.
source "$(dirname "$0")/lib.sh"
GEN="$FACTORY_DIR/review-page.sh"
d="$(mktemp -d)"

cat > "$d/v1.md" <<'EOS'
# [A1] Thing — spec

## Product
_Product Owner_

- alpha stays the same
- beta says one thing
- gamma goes away

## Open questions
- **Q:** which one?
EOS
cat > "$d/v2.md" <<'EOS'
# [A1] Thing — spec

## Product
_Product Owner_

- alpha stays the same
- beta says another thing

## Security
_Cybersec_

- delta is brand new

## Open questions
- **Q:** which one?
EOS
printf 'please make beta clearer and drop gamma\n' > "$d/request.txt"

# the items' marks as the page carries them: every value under a "mark" key of the page's data, in document order
marks() { [ -f "$1" ] || return 0; "$FACTORY_PYTHON" -I -c "
import re,sys,json
h=open(sys.argv[1],encoding='utf-8').read()
d=json.loads(re.search(r'const S=(\[.*?\]);',h,re.S).group(1))
out=[]
def walk(x):
    if isinstance(x,dict):
        for k,v in x.items():
            if k=='mark': out.append('' if v in (None,False) else str(v))
            else: walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d)
print(';'.join(out))" "$(cygpath -w "$1" 2>/dev/null || echo "$1")"; }
# the summary line: a line of the page that speaks of "since" and holds the count as a number
since_has() { [ -f "$1" ] || return 1; "$FACTORY_PYTHON" -I -c "
import re,sys
h=open(sys.argv[1],encoding='utf-8').read()
sys.exit(0 if any(re.search(r'(?i)since[^\n]*(?<![\w.])'+sys.argv[2]+r'(?![\w.])',l) for l in h.splitlines()) else 1)" "$(cygpath -w "$1" 2>/dev/null || echo "$1")" "$2"; }
nonempty() { printf '%s' "$1" | tr ';' '\n' | grep -c .; }

# ---- first review: AC-1
mkdir -p "$d/first"
assert_exit 0 bash "$GEN" "$d/v1.md" 31 feat/31-x "$d/first/31.html" --request-file "$d/request.txt"
first="$(cat "$d/first/31.html")"
[ -f "$d/first/31.published.md" ] && pass "AC-1 the build keeps the published spec as the baseline" || fail "AC-1 no 31.published.md beside the page"
[ ! -e "$d/first/31.read.md" ] && pass "AC-1 a first review has no version the owner read" || fail "AC-1 a first review wrote 31.read.md"
[ "$(nonempty "$(marks "$d/first/31.html")")" = 0 ] && pass "AC-1 no statement carries a mark on a first review" || fail "AC-1 marks on a first review: $(marks "$d/first/31.html")"
case "$first" in *"drop gamma"*) fail "AC-1 a first review quotes a request" ;; *) pass "AC-1 a first review shows no quote of the request" ;; esac
case "$first" in *__SINCE__*|*__DATA__*) fail "AC-1 a placeholder is left in the page" ;; *) pass "AC-1 no placeholder left in the page" ;; esac
mkdir -p "$d/plain"
assert_exit 0 bash "$GEN" "$d/v1.md" 31 feat/31-x "$d/plain/31.html"
since_has "$d/first/31.html" 0 && fail "AC-1 the first review carries a count of changes" || pass "AC-1 the first review carries no 'changed since' count"

# ---- back in Spec Review: AC-2, AC-3
assert_exit 0 bash "$GEN" "$d/v2.md" 31 feat/31-x "$d/first/31.html" --request-file "$d/request.txt"
back="$(cat "$d/first/31.html")"
cmp -s "$d/v1.md" "$d/first/31.read.md" && pass "AC-2 the version the owner read is kept as 31.read.md" || fail "AC-2 31.read.md is not the previous spec"
cmp -s "$d/v2.md" "$d/first/31.published.md" && pass "AC-2 the new spec is the published one" || fail "AC-2 31.published.md is not the new spec"
m="$(marks "$d/first/31.html")"
distinct="$(printf '%s' "$m" | tr ';' '\n' | grep . | sort -u | wc -l)"
[ "$distinct" -ge 3 ] && pass "AC-2 new, changed and untouched statements carry three distinct marks" || fail "AC-2 marks are not told apart: $m"
case "$back" in *"gamma goes away"*) pass "AC-2 the removed statement is listed" ;; *) fail "AC-2 the removed statement is not in the page" ;; esac
case "$back" in *"beta says one thing"*) pass "AC-2 the previous text of a changed statement is kept for the owner" ;; *) fail "AC-2 the previous text of the changed statement is missing" ;; esac
# 3 = beta changed, delta new, gamma removed; alpha is untouched
case "$back" in *"drop gamma"*) pass "AC-3 the page quotes the owner's request" ;; *) fail "AC-3 the request is not quoted" ;; esac
since_has "$d/first/31.html" 3 && pass "AC-3 the summary counts new, changed and removed (3)" || fail "AC-3 the summary does not carry the count 3"
# the same spec built again changes nothing
cp "$d/first/31.html" "$d/first/31.before.html"
assert_exit 0 bash "$GEN" "$d/v2.md" 31 feat/31-x "$d/first/31.html" --request-file "$d/request.txt"
cmp -s "$d/first/31.before.html" "$d/first/31.html" && pass "AC-2 building the same spec twice gives the same page" || fail "AC-2 a second build of the same spec changed the page"
cmp -s "$d/v1.md" "$d/first/31.read.md" && pass "AC-2 building the same spec twice keeps the version the owner read" || fail "AC-2 a second build rotated the baseline"

# no request available: the count only
mkdir -p "$d/norq"
cp "$d/v1.md" "$d/norq/32.published.md"
assert_exit 0 bash "$GEN" "$d/v2.md" 32 feat/32-x "$d/norq/32.html"
norq="$(cat "$d/norq/32.html")"
since_has "$d/norq/32.html" 3 && pass "AC-3 with no request the summary still counts (3)" || fail "AC-3 with no request the summary lacks the count"
case "$norq" in *"drop gamma"*) fail "AC-3 a request was quoted that nobody passed" ;; *) pass "AC-3 with no request there is no quote" ;; esac

# ---- an identical spec: AC-5
mkdir -p "$d/same"
cp "$d/v2.md" "$d/same/33.read.md"
cp "$d/v2.md" "$d/same/33.published.md"
assert_exit 0 bash "$GEN" "$d/v2.md" 33 feat/33-x "$d/same/33.html" --request-file "$d/request.txt"
sm="$(marks "$d/same/33.html")"
total="$(printf '%s' "$sm" | tr ';' '\n' | wc -l)"
one="$(printf '%s' "$sm" | tr ';' '\n' | sort -u)"
[ "$(nonempty "$sm")" = "$total" ] && [ "$(printf '%s\n' "$one" | wc -l)" = 1 ] && pass "AC-5 every statement carries the same mark" || fail "AC-5 marks on an identical spec: $sm"
[ "$(printf '%s' "$m" | tr ';' '\n' | grep -cx -- "$one")" = 2 ] && pass "AC-5 that mark is the one of the two untouched statements of AC-2 (alpha, the open question)" || fail "AC-5 the mark '$one' is not the untouched mark of AC-2 ($m)"
since_has "$d/same/33.html" 0 && pass "AC-5 the summary says 0 statements changed" || fail "AC-5 the summary does not carry the count 0"
cmp -s "$d/v2.md" "$d/same/33.read.md" && pass "AC-5 the baseline is untouched by an identical build" || fail "AC-5 the baseline moved"

# ---- AC-4 and AC-6 on the template
TPL="$FACTORY_DIR/review-template.html"
"$FACTORY_PYTHON" -I - "$TPL" "$FACTORY_DIR" <<'PY' > "$d/tpl.out"
import re, sys, json, subprocess
from pathlib import Path
tpl = Path(sys.argv[1]).read_text(encoding="utf-8")
here = Path(sys.argv[2])
ok = lambda n: print("ok   " + n)
no = lambda n: print("FAIL " + n)
def check(name, cond): (ok if cond else no)(name)

# AC-4 untouched rows stay visible and are demoted by color, never by opacity or display
rules = re.findall(r"([^{}]*\.same[^{}]*)\{([^{}]*)\}", tpl)
body = " ".join(r[1] for r in rules)
check("AC-4 the template has a rule for untouched rows (.item.same)", bool(rules))
check("AC-4 untouched rows are demoted with the --muted color", "color:var(--muted)" in body.replace(" ", ""))
check("AC-4 untouched rows are demoted by color, not by opacity or hiding", not re.search(r"opacity|display\s*:\s*none|visibility", body))

# AC-6 what the owner's change added to the template uses only the themed variables of the page
base = subprocess.run(["git", "-C", str(here), "merge-base", "HEAD", "origin/main"], capture_output=True, text=True).stdout.strip() or "origin/main"
old = subprocess.run(["git", "-C", str(here), "show", f"{base}:{'scripts/' if (here / 'scripts').is_dir() else ''}review-template.html"], capture_output=True, text=True).stdout
if not old:
    old = subprocess.run(["git", "-C", str(here), "show", f"{base}:scripts/review-template.html"], capture_output=True, text=True).stdout
added = [l for l in tpl.splitlines() if l not in set(old.splitlines())]
css = "\n".join(l for l in added if "{" in l and ":" in l and "var(" in l or "tag" in l.lower() and "{" in l)
check("AC-6 the template gained styles for the marks and the summary", bool(css.strip()))
used = set(re.findall(r"var\(--([a-z-]+)\)", "\n".join(added)))
check("AC-6 the new styles use only the themed variables (page, sheet, surface, ink, muted, rule)", bool(used) and used <= {"page", "sheet", "surface", "ink", "muted", "rule", "body", "mono", "display"})
check("AC-6 the new styles do not borrow --gold, --chg or --ok", not re.search(r"var\(--(gold|gold-ink|chg|chg-bg|ok|ok-bg|linen)\)", "\n".join(l for l in added if "{" in l and "var(" in l)))
check("AC-6 the new styles hold no fixed color", not re.search(r"#[0-9a-fA-F]{3,8}\b|rgba?\(", "\n".join(l for l in added if "{" in l and ":" in l and not l.lstrip().startswith(("--", ":root", "html")))))

# AC-6 the catalogs: en and pt-BR carry the labels, other languages fall back to English
msgs = lambda c: json.loads((here / "lang" / f"dashboard.{c}.json").read_text(encoding="utf-8"))["messages"]
en, pt = msgs("en"), msgs("pt-BR")
def has(cat, *needles): return all(any(n in v for v in cat.values()) for n in needles)
check("AC-6 the en catalog carries the summary, the caption, the tags and the fold",
      has(en, "changed since your request", "statements changed since your request", "Your request", "Before")
      and all(t in en.values() for t in ("New", "Changed", "Removed", "Before", "Your request")))
check("AC-6 the en summary has a singular form", any("1 statement changed since your request" in v or ("plural" in v and "statement changed since your request" in v) for v in en.values()))
check("AC-6 the pt-BR catalog carries the summary, the caption, the tags and the fold",
      all(t in pt.values() for t in ("Nova", "Alterada", "Removida", "Antes", "Seu pedido")) and has(pt, "desde o seu pedido", "afirmações mudaram", "afirmação mudou"))
keys = {k for k, v in en.items() if v in ("Your request", "New", "Changed", "Removed")}
check("AC-6 the labels are one key each in en and in pt-BR", len(keys) == 4 and all(k in pt for k in keys))
sys.path.insert(0, str(here))
import dashboard as dash
for code in ("de", "ja", "ru"):
    cat = dash.catalog(code)
    shown = {k: cat.get(k, en[k]) for k in keys}
    check(f"AC-6 {code} shows the English labels", all(shown[k] == en[k] for k in keys))
PY
cat "$d/tpl.out"
while IFS= read -r l; do case "$l" in "FAIL "*) FAILS=$((FAILS+1)) ;; esac; done < "$d/tpl.out"
[ -s "$d/tpl.out" ] || fail "AC-4/AC-6 the template and catalog checks printed nothing"

# the page the dashboard embeds is built the same way: --request-file is one more argument, nothing else changes
assert_exit 2 bash "$GEN" "$d/v2.md" 31 feat/31-x
assert_exit 2 bash "$GEN" "$d/v2.md" 31 feat/31-x "$d/x.html" extra

# ---- AC-7: --diff prints JSON entries and writes no page
mkdir -p "$d/cwd"
(cd "$d/cwd" && bash "$GEN" --diff "$d/v1.md" "$d/v2.md" > "$d/diff.json" 2> "$d/diff.err"); rc=$?
[ "$rc" = 0 ] && pass "AC-7 --diff exits 0" || fail "AC-7 --diff exited $rc: $(cat "$d/diff.err")"
[ -z "$(ls -A "$d/cwd")" ] && pass "AC-7 --diff writes no page and no baseline" || fail "AC-7 --diff wrote: $(ls -A "$d/cwd")"
"$FACTORY_PYTHON" -I - "$d/diff.json" "$FACTORY_DIR" <<'PY' > "$d/diff.out"
import json, sys
from pathlib import Path
ok = lambda n: print("ok   " + n)
no = lambda n: print("FAIL " + n)
def check(name, cond): (ok if cond else no)(name)
try:
    e = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception as x:
    check(f"AC-7 --diff prints JSON ({x})", False); sys.exit(0)
check("AC-7 --diff prints a JSON list of entries", isinstance(e, list) and all(isinstance(i, dict) for i in e))
e = e if isinstance(e, list) else []
check("AC-7 every entry is {section, status, old, new}", all(set(i) == {"section", "status", "old", "new"} for i in e))
check("AC-7 the status is new, changed, untouched or removed", all(i.get("status") in ("new", "changed", "untouched", "removed") for i in e))
by = {(i.get("section"), i.get("status")): i for i in e}
check("AC-7 an identical statement is untouched, with both texts", by.get(("product", "untouched"), {}).get("old") == "alpha stays the same" == by.get(("product", "untouched"), {}).get("new"))
check("AC-7 a rewritten statement is changed, old and new", (by.get(("product", "changed"), {}).get("old"), by.get(("product", "changed"), {}).get("new")) == ("beta says one thing", "beta says another thing"))
check("AC-7 a statement that left is removed, with no new text", ("product", "removed") in by and by[("product", "removed")]["old"] == "gamma goes away" and by[("product", "removed")]["new"] in (None, ""))
check("AC-7 a statement of a new section is new, with no old text", ("security", "new") in by and by[("security", "new")]["new"] == "delta is brand new" and by[("security", "new")]["old"] in (None, ""))
check("AC-7 four statements of the product and security sections plus the open question: five entries", len(e) == 5)
sys.path.insert(0, str(Path(sys.argv[2]) / "shipfloor_core" / ".."))
try:
    from shipfloor_core import review_page as rp
    t1 = Path(sys.argv[1]).parent / "v1.md"; t2 = Path(sys.argv[1]).parent / "v2.md"
    r = rp.statement_diff(t1.read_text(encoding="utf-8"), t2.read_text(encoding="utf-8"))
    check("AC-7 statement_diff gives the same entries as --diff", r == e)
except Exception as x:
    check(f"AC-7 statement_diff(old_text, new_text) exists ({x})", False)
PY
cat "$d/diff.out"
while IFS= read -r l; do case "$l" in "FAIL "*) FAILS=$((FAILS+1)) ;; esac; done < "$d/diff.out"
[ -s "$d/diff.out" ] || fail "AC-7 the diff checks printed nothing"
assert_exit 2 bash "$GEN" --diff "$d/v1.md"
assert_exit 2 bash "$GEN" --diff "$d/v1.md" "$d/missing.md"
finish
