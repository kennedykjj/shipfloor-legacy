#!/usr/bin/env bash
# The dashboard keeps a review page's Keep/Change marks on the server and hands them back inside the embedded page.
source "$(dirname "$0")/lib.sh"
AC=setup
assert_contains() { case "$1" in *"$2"*) pass "$AC contains $2" ;; *) fail "$AC missing '$2' in: $1" ;; esac; }
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; W="$(mktemp -d)"
for p in shop blog; do
  mkdir -p "$H/projects/$p/logs" "$H/projects/$p/locks" "$H/projects/$p/reviews"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$H/projects/$p/factory.yml"
  printf '%s\t/x/%s\t/x/wt\tmain\n' "$p" "$p" >> "$H/registry.tsv"
done
export FAKE_GH_DIR="$W" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 CLAUDE_CONFIG_DIR="$(nat "$W")"
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$W/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$W/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$W/out" | tr -d '\r')"; base="${url%%/?t=*}"; tok="${url##*t=}"
H_TOK="X-Shipfloor-Token: $tok"

page() { printf '<html><head><title>%s</title></head><body>review %s</body></html>' "$2" "$2" > "$H/projects/$1/reviews/$3.html"; }
rev() { $PY -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' "$(nat "$H/projects/$1/reviews/$2.html")"; }
# save <project> <n> <body-file> [token header]: the status code
save() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "${4:-$H_TOK}" -d "@$(nat "$3")" "$base/api/card/$1/$2/marks"; }
body() { printf '%s' "$1" > "$W/body.json"; echo "$W/body.json"; }
# the embedded page, fresh from the server
embed() { curl -s "$base/review/$1/$2?embed=1&t=$tok" > "$W/embed-$1-$2.html"; echo "$W/embed-$1-$2.html"; }
# marks <html file>: the injected marks as compact JSON ("NONE" when no block, "BAD" when it does not parse)
marks() {
  $PY -I -c '
import json, sys
h = open(sys.argv[1], encoding="utf-8").read()
k = "window.__shipfloorMarks="
i = h.find(k)
if i < 0:
    print("NONE"); sys.exit()
j = h.find("</script>", i)
try:
    d = json.loads(h[i + len(k):j])
    print(json.dumps({"rev": d["rev"], "marks": d["marks"]}, sort_keys=True, separators=(",", ":")))
except Exception:
    print("BAD")
' "$(nat "$1")"
}
only() {  # only <marks output>: the marks object as compact JSON, "NONE" or "BAD" as given
  $PY -I -c '
import json, sys
try:
    print(json.dumps(json.loads(sys.argv[1])["marks"], sort_keys=True, separators=(",", ":")))
except Exception:
    print(sys.argv[1])
' "$1"
}

page shop "spec seven" 7; r7="$(rev shop 7)"
page shop "spec eight" 8; r8="$(rev shop 8)"
page blog "spec seven of blog" 7; rb7="$(rev blog 7)"

AC=AC-2
# AC-2: what was saved comes back inside a fresh embedded page, as many times as it is opened
m7='{"intro":{"s":"ok","n":""},"ac-1":{"s":"chg","n":"rename the field"}}'
got="$(save shop 7 "$(body "{\"rev\":\"$r7\",\"marks\":$m7}")")"
[ "$got" = 200 ] && pass "AC-2 marks are accepted" || fail "AC-2 marks refused with $got"
f="$(embed shop 7)"; got="$(marks "$f")"
assert_contains "$got" '"ac-1":{"n":"rename the field","s":"chg"}'
assert_contains "$got" '"intro":{"n":"","s":"ok"}'
assert_contains "$got" "\"rev\":\"$r7\""
case "$(cat "$f")" in *"<title>spec seven</title>"*"</head>"*) pass "AC-2 the embedded page is still the page" ;; *) fail "AC-2 the embedded page lost its content" ;; esac
case "$(cat "$f")" in *"window.__shipfloorMarks="*"</head>"*) pass "AC-2 marks are injected in the head, before the page body" ;; *) fail "AC-2 no marks block before </head>" ;; esac
assert_contains "$(marks "$(embed shop 7)")" '"ac-1":{"n":"rename the field","s":"chg"}'
# a later save replaces the earlier one
save shop 7 "$(body "{\"rev\":\"$r7\",\"marks\":{\"ac-2\":{\"s\":\"ok\",\"n\":\"\"}}}")" >/dev/null
got="$(only "$(marks "$(embed shop 7)")")"
[ "$got" = '{"ac-2":{"n":"","s":"ok"}}' ] && pass "AC-2 the last save is what comes back" || fail "AC-2 last save not what came back: $got"
[ -f "$H/projects/shop/reviews/7.marks.json" ] && pass "AC-2 marks live in reviews/<n>.marks.json" || fail "AC-2 no reviews/7.marks.json"

# AC-3: a note holding </script> comes back intact and never closes the injected script
note='close </script><script>alert(1)</script> & <b>"quoted"</b> \ line'
$PY -I -c 'import json,sys; print(json.dumps({"rev": sys.argv[1], "marks": {"ac-3": {"s": "chg", "n": sys.argv[2]}}}))' "$r7" "$note" > "$W/note.json"
got="$(save shop 7 "$W/note.json")"
[ "$got" = 200 ] && pass "AC-3 a note with markup is accepted" || fail "AC-3 note with markup refused with $got"
f="$(embed shop 7)"; got="$(marks "$f")"
want="$($PY -I -c 'import json,sys; print(json.dumps({"rev": sys.argv[1], "marks": {"ac-3": {"s": "chg", "n": sys.argv[2]}}}, sort_keys=True, separators=(",", ":")))' "$r7" "$note")"
[ "$got" = "$want" ] && pass "AC-3 the note comes back intact" || fail "AC-3 note changed: $got"
# scripts <html file>: "ok" when every <script opening has its closing tag and the note's alert(1) is in no script of its own
scripts() {
  $PY -I -c '
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
o = len(re.findall(r"<script\b", h, re.I)); c = len(re.findall(r"</script>", h, re.I))
if o != c:
    print("%d <script openings, %d closings" % (o, c))
elif re.search(r"<script[^>]*>\s*alert\(1\)", h, re.I):
    print("the note alert(1) sits in a script of its own")
else:
    print("ok")
' "$(nat "$1")"
}
# raw <file>: the injected block checked as raw text, "ok" or what is wrong
raw() {
  $PY -I -c '
import sys
h = open(sys.argv[1], encoding="utf-8").read()
k = "window.__shipfloorMarks="
i = h.find(k)
if i < 0:
    print("no injected block"); sys.exit()
j = h.find("</script>", i)
b = h[i + len(k):j]
bad = [s for s in ("\\u003c", "\\u003e", "\\u0026") if s not in b]
rawc = [c for c in "<>&" if c in b]
print("ok" if not bad and not rawc else "missing escapes %s, raw characters %s in: %s" % (bad, rawc, b[:200]))
' "$(nat "$1")"
}
got="$(scripts "$f")"
[ "$got" = ok ] && pass "AC-3 every script is closed once and the note opens none" || fail "AC-3 script structure: $got"
case "$(cat "$f")" in *'alert(1)</script>'*) fail "AC-3 the note's script is live in the page" ;; *) pass "AC-3 the note's markup is escaped" ;; esac
got="$(raw "$f")"
[ "$got" = ok ] && pass "AC-3 <, > and & are written as \\u003c, \\u003e, \\u0026 in the injected JSON" || fail "AC-3 injected JSON not escaped: $got"

AC=AC-5
# AC-5: per card and per project
save shop 7 "$(body "{\"rev\":\"$r7\",\"marks\":$m7}")" >/dev/null
got="$(only "$(marks "$(embed shop 8)")")"
[ "$got" = '{}' ] && pass "AC-5 another card of the project has no marks" || fail "AC-5 card 8 shows: $got"
assert_contains "$(marks "$(embed shop 8)")" "\"rev\":\"$r8\""
got="$(only "$(marks "$(embed blog 7)")")"
[ "$got" = '{}' ] && pass "AC-5 the same number in another project has no marks" || fail "AC-5 blog 7 shows: $got"
save shop 8 "$(body "{\"rev\":\"$r8\",\"marks\":{\"x\":{\"s\":\"chg\",\"n\":\"only eight\"}}}")" >/dev/null
save blog 7 "$(body "{\"rev\":\"$rb7\",\"marks\":{\"y\":{\"s\":\"ok\",\"n\":\"\"}}}")" >/dev/null
got="$(only "$(marks "$(embed shop 7)")")"
[ "$got" = "$($PY -I -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True, separators=(",", ":")))' "$m7")" ] && pass "AC-5 card 7 is unchanged by saves on other cards" || fail "AC-5 card 7 changed: $got"
assert_contains "$(marks "$(embed shop 8)")" '"x":{"n":"only eight","s":"chg"}'
assert_contains "$(marks "$(embed blog 7)")" '"y":{"n":"","s":"ok"}'

AC=AC-6
# AC-6: a rebuilt page starts unmarked, and a save made on the old page is refused
page shop "spec seven reworked" 7; r7b="$(rev shop 7)"
f="$(embed shop 7)"; got="$(marks "$f")"
[ "$r7b" != "$r7" ] && [ "$(only "$got")" = '{}' ] && pass "AC-6 a rebuilt page starts with no marks" || fail "AC-6 rebuilt page shows: $got"
assert_contains "$got" "\"rev\":\"$r7b\""
got="$(save shop 7 "$(body "{\"rev\":\"$r7\",\"marks\":$m7}")")"
[ "$got" = 409 ] && pass "AC-6 a save carrying the old rev answers 409" || fail "AC-6 old rev answered $got, want 409"
got="$(only "$(marks "$(embed shop 7)")")"
[ "$got" = '{}' ] && pass "AC-6 the refused save stored nothing" || fail "AC-6 refused save left: $got"
got="$(save shop 7 "$(body "{\"rev\":\"$r7b\",\"marks\":{\"z\":{\"s\":\"ok\",\"n\":\"\"}}}")")"
[ "$got" = 200 ] && pass "AC-6 a save carrying the new rev is accepted" || fail "AC-6 new rev answered $got"
assert_contains "$(marks "$(embed shop 7)")" '"z":{"n":"","s":"ok"}'
# a marks file left by an older page is ignored, not served
printf '{"rev":"%s","marks":{"old":{"s":"ok","n":""}}}' "$r7" > "$H/projects/shop/reviews/7.marks.json"
got="$(only "$(marks "$(embed shop 7)")")"
[ "$got" = '{}' ] && pass "AC-6 a marks file of another rev is not served" || fail "AC-6 stale file served: $got"
printf 'not json' > "$H/projects/shop/reviews/7.marks.json"
got="$(marks "$(embed shop 7)")"
case "$got" in NONE|BAD) fail "AC-6 an unreadable marks file broke the block: $got" ;; *) [ "$(only "$got")" = '{}' ] && pass "AC-6 an unreadable marks file gives no marks" || fail "AC-6 unreadable file served: $got" ;; esac

AC=AC-7
# AC-7: an empty save deletes the file, and the marks stay gone
save shop 7 "$(body "{\"rev\":\"$r7b\",\"marks\":$m7}")" >/dev/null
assert_contains "$(marks "$(embed shop 7)")" '"ac-1"'
got="$(save shop 7 "$(body "{\"rev\":\"$r7b\",\"marks\":{}}")")"
[ "$got" = 200 ] && pass "AC-7 an empty save is accepted" || fail "AC-7 empty save answered $got"
[ ! -e "$H/projects/shop/reviews/7.marks.json" ] && pass "AC-7 the marks file is deleted" || fail "AC-7 the marks file is still there"
got="$(only "$(marks "$(embed shop 7)")")"
[ "$got" = '{}' ] && pass "AC-7 the marks stay gone after a reload" || fail "AC-7 cleared marks came back: $got"
[ "$(save shop 7 "$(body "{\"rev\":\"$r7b\",\"marks\":{}}")")" = 200 ] && pass "AC-7 clearing nothing is fine" || fail "AC-7 clearing an empty card failed"

# the contract's refusals: 400, 404, 403, and nothing stored
ok1='{"a":{"s":"ok","n":""}}'
chk() { got="$(save shop 7 "$(body "$2")")"; [ "$got" = "$3" ] && pass "$1 answers $3" || fail "$1 answered $got, want $3"; }
chk "contract: an id with capitals" "{\"rev\":\"$r7b\",\"marks\":{\"BAD_ID\":{\"s\":\"ok\",\"n\":\"\"}}}" 400
chk "contract: an empty id" "{\"rev\":\"$r7b\",\"marks\":{\"\":{\"s\":\"ok\",\"n\":\"\"}}}" 400
long="$($PY -I -c 'print("a"*81)')"
chk "contract: an id of 81 characters" "{\"rev\":\"$r7b\",\"marks\":{\"$long\":{\"s\":\"ok\",\"n\":\"\"}}}" 400
chk "contract: s other than ok/chg" "{\"rev\":\"$r7b\",\"marks\":{\"a\":{\"s\":\"maybe\",\"n\":\"\"}}}" 400
chk "contract: a note that is not a string" "{\"rev\":\"$r7b\",\"marks\":{\"a\":{\"s\":\"chg\",\"n\":5}}}" 400
$PY -I -c 'import json,sys; print(json.dumps({"rev": sys.argv[1], "marks": {"a": {"s": "chg", "n": "x" * 2001}}}))' "$r7b" > "$W/longnote.json"
[ "$(save shop 7 "$W/longnote.json")" = 400 ] && pass "contract: a note over 2000 characters answers 400" || fail "contract: a note of 2001 characters was not refused with 400"
$PY -I -c 'import json,sys; print(json.dumps({"rev": sys.argv[1], "marks": {"a": {"s": "chg", "n": "x" * 2000}}}))' "$r7b" > "$W/okote.json"
[ "$(save shop 7 "$W/okote.json")" = 200 ] && pass "contract: a note of 2000 characters is accepted" || fail "contract: a note of 2000 characters was refused"
$PY -I -c 'import json,sys; print(json.dumps({"rev": sys.argv[1], "marks": {"i%d" % k: {"s": "ok", "n": ""} for k in range(501)}}))' "$r7b" > "$W/many.json"
[ "$(save shop 7 "$W/many.json")" = 400 ] && pass "contract: 501 ids answers 400" || fail "contract: 501 ids were not refused with 400"
$PY -I -c 'import json,sys; print(json.dumps({"rev": sys.argv[1], "marks": {"i%d" % k: {"s": "ok", "n": ""} for k in range(500)}}))' "$r7b" > "$W/five.json"
[ "$(save shop 7 "$W/five.json")" = 200 ] && pass "contract: 500 ids are accepted" || fail "contract: 500 ids were refused"
$PY -I -c 'import json,sys; print(json.dumps({"rev": sys.argv[1], "marks": {"a": {"s": "chg", "n": "x" * 2000}, "b": {"s": "chg", "n": "y" * 2000}}, "pad": "p" * 262144}))' "$r7b" > "$W/huge.json"
[ "$(save shop 7 "$W/huge.json")" = 400 ] && pass "contract: a body over 256 KB answers 400" || fail "contract: a body over 256 KB was not refused with 400"
save shop 7 "$(body "{\"rev\":\"$r7b\",\"marks\":{}}")" >/dev/null
chk "contract: a refused save" "{\"rev\":\"$r7b\",\"marks\":{\"BAD\":{\"s\":\"ok\",\"n\":\"\"}}}" 400
got="$(only "$(marks "$(embed shop 7)")")"
[ "$got" = '{}' ] && pass "contract: a refused save stores nothing" || fail "contract: a refused save stored: $got"
got="$(save nope 7 "$(body "{\"rev\":\"$r7b\",\"marks\":$ok1}")")"
[ "$got" = 404 ] && pass "contract: an unknown project answers 404" || fail "contract: unknown project answered $got, want 404"
got="$(save shop 99 "$(body "{\"rev\":\"$r7b\",\"marks\":$ok1}")")"
[ "$got" = 404 ] && pass "contract: a card with no review page answers 404" || fail "contract: card 99 answered $got, want 404"
got="$(save shop 7 "$(body "{\"rev\":\"$r7b\",\"marks\":$ok1}")" "X-Other: 1")"
[ "$got" = 403 ] && pass "contract: no token answers 403" || fail "contract: no token answered $got, want 403"
got="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "@$(nat "$W/body.json")" "$base/api/card/shop/7/marks?t=$tok")"
[ "$got" = 403 ] && pass "contract: the token in the URL does not count" || fail "contract: token in the URL answered $got, want 403"
[ ! -e "$H/projects/shop/reviews/7.marks.json" ] && pass "contract: refused saves left no file" || fail "contract: a refused save left a marks file"

finish
