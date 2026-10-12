#!/usr/bin/env bash
# The dashboard's link survives a restart, and a tab whose link is refused stops asking and says what to do.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$(mktemp -d)"; T="$(mktemp -d)"; export FAKE_GH_DIR="$T"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
export CLAUDE_CONFIG_DIR="$(nat "$T")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
srv=""; trap 'kill $srv 2>/dev/null' EXIT
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

start() {  # start <port>: sets url, base, tok, port of a dashboard on the temp home
  rm -f "$T/out"
  $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port "$1" --no-open > "$T/out" 2>&1 &
  srv=$!
  for _ in $(seq 1 50); do grep -qs 'http://' "$T/out" && break; sleep 0.1; done
  url="$(grep -o 'http://[^ ]*' "$T/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"; port="${base##*:}"
}
stop() { kill $srv 2>/dev/null; wait $srv 2>/dev/null; sleep 0.3; }
is_token() { [[ "$1" =~ ^[A-Za-z0-9_-]{22}$ ]]; }
fmode() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 1 ;; esac; return 0; }

# AC-1: stopped and started again on the same home and port, the URL is the same
start 0; url1="$url"; tok1="$tok"; port1="$port"
stop
start "$port1"; url2="$url"; tok2="$tok"
[ -n "$url1" ] && [ "$url1" = "$url2" ] && pass "AC-1 the URL after a restart is the one printed before" || fail "AC-1 the URL changed across a restart: '$url1' then '$url2'"

# AC-2: the token of the first run opens the second run's API (the open tab's polling then shows the factory again)
H1="X-Shipfloor-Token: $tok1"
got="$(code -H "$H1" "$base/api/overview")"
[ "$got" = 200 ] && pass "AC-2 the first run's token gets the overview from the restarted server" || fail "AC-2 the first run's token got $got from the restarted server, want 200"

# AC-6: no token and a wrong token are refused, on a GET and on a POST; a token in a POST's URL does not count
assert_contains "$(code "$base/api/overview")" 403
assert_contains "$(code -H "X-Shipfloor-Token: wrong" "$base/api/overview")" 403
assert_contains "$(code -X POST -d '{}' "$base/api/settings/pause")" 403
assert_contains "$(code -X POST -d '{}' -H "X-Shipfloor-Token: wrong" "$base/api/settings/pause")" 403
got="$(code -X POST -d '{}' "$base/api/settings/pause?t=$tok")"
[ "$got" = 403 ] && pass "AC-6 a POST with the token only in the URL is refused" || fail "AC-6 a POST with the token in the URL got $got, want 403"
got="$(code "$base/api/overview?t=$tok")"
[ "$got" = 403 ] && pass "AC-6 a GET with the token only in the URL is refused" || fail "AC-6 a GET with the token in the URL got $got, want 403"
stop

# AC-5: no saved secret (deleted, or damaged): a new one is made, the old link is refused, the file is back
tokfile="$H/dashboard.token"
check_new() {  # check_new <label> <what the file held before>
  start 0
  is_token "$tok" && pass "AC-5 $1: a URL with a token is printed" || fail "AC-5 $1: no URL with a 22-character token was printed: '$url'"
  [ "$tok" != "$2" ] && [ "$tok" != "$tok1" ] && pass "AC-5 $1: the token is a new one" || fail "AC-5 $1: the token is not new"
  [ "$(code -H "X-Shipfloor-Token: $tok1" "$base/api/overview")" = 403 ] && pass "AC-5 $1: the old token gets 403" || fail "AC-5 $1: the old token is still accepted"
  [ "$(code -H "X-Shipfloor-Token: $tok" "$base/api/overview")" = 200 ] && pass "AC-5 $1: the new token gets 200" || fail "AC-5 $1: the new token is not accepted"
  [ -f "$tokfile" ] && [ "$(tr -d '\r\n' < "$tokfile")" = "$tok" ] && [ "$(wc -c < "$tokfile" | tr -d ' ')" = 23 ] \
    && pass "AC-5 $1: dashboard.token is back, the token and a newline" || fail "AC-5 $1: dashboard.token is missing or does not hold the token and a newline"
  if fmode; then
    [ "$(stat -c %a "$tokfile" 2>/dev/null)" = 600 ] && pass "AC-5 $1: the file is 600" || fail "AC-5 $1: the file is not 600: '$(stat -c %a "$tokfile" 2>/dev/null)'"
  fi
  stop
}
rm -f "$tokfile"; check_new "deleted" ""
: > "$tokfile"; check_new "empty" ""
printf 'abc\n' > "$tokfile"; check_new "too short" "abc"
printf 'aaaaaaaaaaaaaaaaaaaa!!\n' > "$tokfile"; check_new "other characters" "aaaaaaaaaaaaaaaaaaaa!!"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$tokfile"; check_new "too long" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# AC-3, AC-4, AC-7: the page, read from its source (there is no JavaScript runtime in this layer)
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
cat = json.load(open(sys.argv[2], encoding="utf-8"))
AC = {"one fetch": "AC-3", "the fetch": "AC-3", "S.refused is": "AC-3", "api() answers": "AC-3", "a 403": "AC-3", "the catch branch leaves": "AC-7", "the catch branch still": "AC-7", "a function": "AC-3"}
def res(name, ok, why=""):
    ac = next((v for k, v in AC.items() if name.startswith(k)), "AC-4")
    print(("ok " if ok else "FAIL ") + ac + " " + name + ("" if ok else ": " + why))
fetches = [m.start() for m in re.finditer(r"\bfetch\(", h)]
a = h.index("async function api(")
end = h.index("\nfunction setOffline", a)
api = h[a:end]
res("one fetch in the page", len(fetches) == 1, f"{len(fetches)} fetch( calls")
res("the fetch is inside api()", len(fetches) == 1 and a < fetches[0] < end, "fetch is outside api()")
res("S.refused is false at load", re.search(r"const S = \{[^\n]*\brefused:\s*false", h) is not None, "S has no refused: false")
guard = re.search(r"if\s*\(\s*S\.refused\s*\)\s*return\s*\{\s*status:\s*403\s*,\s*body:\s*\{\s*\}\s*\}", api)
res("api() answers 403 without a request when S.refused is set, before the fetch", guard is not None and guard.start() < api.index("fetch("), "no S.refused guard before the fetch in api()")
ci = api.index("catch")
tried, caught = api[:ci], api[ci:]
res("a 403 response sets S.refused and calls refuse()", re.search(r"403", tried) is not None and re.search(r"S\.refused\s*=\s*true", tried) is not None and re.search(r"\brefuse\(\)", tried) is not None, "api() does not set S.refused and call refuse() on a 403")
res("the catch branch leaves S.refused alone", "S.refused" not in caught and "refuse(" not in caught and "setOffline(true)" in caught, "the catch branch touches S.refused or lost the Offline flag")
res("the catch branch still reports status 0 (the server is not answering)", re.search(r"status:\s*0", caught) is not None, "no status 0 in the catch")
res("a function refuse() exists", re.search(r"function refuse\(", h) is not None, "no refuse()")
res("the old sentence is gone", "belongs to an earlier run" not in h, "the page still says 'belongs to an earlier run'")
res("the first line is a strong: This link is no longer valid", re.search(r"<strong>\s*This link is no longer valid\s*</strong>", h) is not None, "no <strong>This link is no longer valid</strong>")
res("the sentence with the way to the current link", "The dashboard does not accept it any more, so this page stopped updating. To get the current link, run in a terminal:" in h, "sentence missing")
res("the command is a code of its own", re.search(r"<code>\s*shipfloor dashboard\s*</code>", h) is not None, "no <code>shipfloor dashboard</code>")
res("the closing sentence", "Then open the URL it prints. This tab stays as it is." in h, "closing sentence missing")
res("the command is selected whole by one click", re.search(r"user-select:\s*all", h) is not None, "no user-select: all")
res("the refused message is announced and takes focus", 'role", "alert"' in h or 'role="alert"' in h or "role='alert'" in h, "no role alert")
body = h[h.index("function refuse("):h.index("function refuse(") + 3000] if "function refuse(" in h else ""
res("the refused message is focusable and takes focus", re.search(r"tabindex[\"']?\s*[,=]\s*[\"']?-1", body) is not None and ".focus()" in body, "refuse() sets no tabindex -1 and focus")
ex = cat.get("exact", {})
res("pt-BR: the first line", ex.get("This link is no longer valid") == "Este link não é mais válido", "entry missing or different")
res("pt-BR: the sentence", ex.get("The dashboard does not accept it any more, so this page stopped updating. To get the current link, run in a terminal:") == "O dashboard não o aceita mais, então esta página parou de atualizar. Para pegar o link atual, rode no terminal:", "entry missing or different")
res("pt-BR: the closing sentence", ex.get("Then open the URL it prints. This tab stays as it is.") == "Depois abra a URL que ele imprimir. Esta aba fica como está.", "entry missing or different")
PY
)"
while IFS= read -r line; do
  case "$line" in ok\ *) pass "${line#ok }" ;; FAIL\ *) fail "${line#FAIL }" ;; esac
done <<< "$out"
case "$out" in *ok*) ;; *) fail "AC-3 the page checks printed nothing: $out" ;; esac

finish
