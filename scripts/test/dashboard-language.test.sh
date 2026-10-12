#!/usr/bin/env bash
# Settings > Language: the page's language (language in config.yml) and, read-only, the language the factory writes
# in for each project (language in factory.yml). Every server here runs with SHIPFLOOR_SCHEDULER set to a stub:
# a test never touches the real ShipfloorDispatcher task, nor the real ~/.shipfloor.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
C="$(mktemp -d)"; PIDS=""
trap 'kill $PIDS 2>/dev/null' EXIT
BASH_N="$(nat "$(command -v bash)")"

printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$(nat "$C")/stub-ok" > "$C/ok-stub.sh"
OK_CMD="\"$BASH_N\" \"$(nat "$C")/ok-stub.sh\""

# fresh_home: a home with two projects: shop (factory.yml with no language key) and blog (language: pt-BR)
fresh_home() {
  H="$(mktemp -d)"; mkdir -p "$H/logs" "$H/projects/shop/logs" "$H/projects/shop/locks" "$H/projects/blog/logs" "$H/projects/blog/locks"
  printf 'shop\t/x/shop\t/x/wt\tmain\nblog\t/x/blog\t/x/wt2\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$H/projects/shop/factory.yml"
  { printf 'language: pt-BR\n'; cat "$FACTORY_DIR/test/fixture/factory.yml"; } > "$H/projects/blog/factory.yml"
  rm -f "$C/stub-ok"
}
start_dash() {
  SHIPFLOOR_SCHEDULER="$2" SHIPFLOOR_BASH="$BASH_N" FAKE_GH_NO_JQ=1 FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_DIR="$C" \
    $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$C/out-$1" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do grep -qs 'http://' "$C/out-$1" && break; sleep 0.1; done
  url="$(grep -o 'http://[^ ]*' "$C/out-$1")"; base="${url%%/?t=*}"; tok="${url##*t=}"
}
post() { curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H "X-Shipfloor-Token: $tok" -d "$1" "$base/api/settings/machine"; }
get() { curl -s -H "X-Shipfloor-Token: $tok" "$base$1"; }
jget() { printf '%s' "$1" | $PY -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>&1 | tail -n 1; }
page_has() { if curl -s "$base/" | grep -qF -- "$1"; then pass "$2: the page carries '$1'"; else fail "$2: the page does not carry '$1'"; fi; }
cat_has() { if grep -qF -- "$1" "$FACTORY_DIR/lang/dashboard.pt-BR.json"; then pass "$2: the pt-BR catalog carries '$1'"; else fail "$2: the pt-BR catalog does not carry '$1'"; fi; }
# cfgrest: config.yml as JSON without its language key
cfgrest() { $PY -I -c 'import sys,yaml,json; d=yaml.safe_load(open(sys.argv[1])) or {}; d.pop("language",None); print(json.dumps(d,sort_keys=True))' "$(nat "$H/config.yml")" 2>&1; }
cfglang() { $PY -I -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print(d.get("language"))' "$(nat "$H/config.yml")" 2>&1; }

# --- AC-5: no language key in config.yml or in a project's factory.yml: en, the factory default
fresh_home; printf 'pool: 6\n' > "$H/config.yml"; start_dash a "$OK_CMD"
s="$(get /api/settings)"
[ "$(jget "$s" 'd["machine"].get("language")')" = "en" ] && pass "AC-5 config.yml with no language key shows en" || fail "AC-5 machine.language was: $(jget "$s" 'd["machine"].get("language")') (want en)"
got="$(jget "$s" '[(p["language"]["code"], p["language"]["set"]) for p in d["projects"] if p["slug"]=="shop"][0]')"
[ "$got" = "('en', False)" ] && pass "AC-5 a project whose factory.yml has no language key shows en, not set" || fail "AC-5 shop language was: $got (want ('en', False))"

# --- AC-2: one row per registered project: the language the factory writes in and the file that sets it
got="$(jget "$s" '[(p["slug"], p["language"]["code"], p["language"]["set"], p["language"]["file"]) for p in d["projects"] if p["slug"]=="blog"][0]')"
[ "$got" = "('blog', 'pt-BR', True, '.shipfloor/factory.yml')" ] && pass "AC-2 a project with the key shows its language, set, and .shipfloor/factory.yml" || fail "AC-2 blog language was: $got (want ('blog', 'pt-BR', True, '.shipfloor/factory.yml'))"
[ "$(jget "$s" 'len([p for p in d["projects"] if "language" in p])')" = "2" ] && pass "AC-2 every registered project carries a language" || fail "AC-2 projects with a language: $(jget "$s" 'len([p for p in d["projects"] if "language" in p])') (want 2)"
page_has "What the factory writes" "AC-2"
page_has "Read-only here" "AC-2"
page_has ".shipfloor/factory.yml" "AC-2"

# --- AC-4: the options are the keys of LANGS, each with its name; the page lists no language of its own
want="$($PY -I -c 'import sys,json; sys.path.insert(0,sys.argv[1]); import shipfloor_config as c; print(json.dumps(c.LANGS))' "$(nat "$FACTORY_DIR")" 2>&1)"
got="$(jget "$s" 'json.dumps(d.get("languages"))')"
[ "$got" = "$want" ] && pass "AC-4 /api/settings languages is LANGS, in its own order" || fail "AC-4 languages was: $got (want $want)"
page_has 'id="lang"' "AC-4"
page_has "languages" "AC-4"
if curl -s "$base/" | grep -qE 'pt-BR|Brazilian'; then fail "AC-4 the page names a language code or name of its own"; else pass "AC-4 the page names no language code or name of its own"; fi

# --- AC-3: a language outside LANGS is refused with the reason, config.yml byte for byte as before
fresh_home; printf 'language: en\npool: 6\n' > "$H/config.yml"; cp "$H/config.yml" "$C/config.before"; start_dash b "$OK_CMD"
resp="$(post '{"language":"xx"}')"; code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
[ "$code" = 400 ] && pass "AC-3 saving xx answers 400" || fail "AC-3 saving xx answered $code: $resp"
case "$(jget "$body" 'd.get("error")')" in *"language must be one of en, pt-BR"*) pass "AC-3 the reason says language must be one of en, pt-BR";; *) fail "AC-3 the reason was: $(jget "$body" 'd.get("error")')";; esac
cmp -s "$H/config.yml" "$C/config.before" && pass "AC-3 config.yml is byte-identical" || fail "AC-3 config.yml changed: $(cat "$H/config.yml")"
page_has "The language was not changed" "AC-3"
cat_has "O idioma não foi alterado" "AC-3"
cat_has "language deve ser um de" "AC-3"

# --- AC-1: pick Portuguese and save: config.yml holds it, /api/lang answers pt-BR with its catalog, agents' text stays raw
fresh_home; printf 'language: en\n' > "$H/config.yml"; start_dash c "$OK_CMD"
resp="$(post '{"language":"pt-BR"}')"; code="${resp##*$'\n'}"
[ "$code" = 200 ] && pass "AC-1 saving pt-BR answers 200" || fail "AC-1 saving pt-BR answered $code: $resp"
[ "$(cfglang)" = "pt-BR" ] && pass "AC-1 config.yml holds language: pt-BR" || fail "AC-1 config.yml language is: $(cfglang)"
l="$(get /api/lang)"
[ "$(jget "$l" 'd.get("language")')" = "pt-BR" ] && pass "AC-1 /api/lang answers pt-BR" || fail "AC-1 /api/lang language was: $(jget "$l" 'd.get("language")') (want pt-BR)"
[ "$(jget "$l" 'd["exact"].get("Language")')" = "Idioma" ] && pass "AC-1 the catalog translates the section's nav entry" || fail "AC-1 exact[Language] was: $(jget "$l" 'd["exact"].get("Language")') (want Idioma)"
[ "$(jget "$l" 'd["exact"].get("What the factory writes")')" = "O que a fábrica escreve" ] && pass "AC-1 the catalog translates the second group" || fail "AC-1 exact[What the factory writes] was: $(jget "$l" 'd["exact"].get("What the factory writes")')"
[ "$(jget "$l" 'd["exact"].get("Language of this dashboard")')" = "Idioma deste dashboard" ] && pass "AC-1 the catalog translates the row title" || fail "AC-1 exact[Language of this dashboard] was: $(jget "$l" 'd["exact"].get("Language of this dashboard")')"
[ "$(jget "$l" 'd["exact"].get("This dashboard")')" = "Este dashboard" ] && pass "AC-1 the catalog translates the first group" || fail "AC-1 exact[This dashboard] was: $(jget "$l" 'd["exact"].get("This dashboard")')"
[ "$(jget "$l" 'd["exact"].get("The language shows after a reload.")')" = "O idioma aparece depois de recarregar." ] && pass "AC-1 the catalog translates the reload sentence" || fail "AC-1 exact[The language shows after a reload.] was: $(jget "$l" 'd["exact"].get("The language shows after a reload.")')"
[ "$(jget "$l" 'd["exact"].get("English")')" = "Inglês" ] && [ "$(jget "$l" 'd["exact"].get("Brazilian Portuguese")')" = "Português do Brasil" ] && pass "AC-1 the catalog translates both language names" || fail "AC-1 language names were: $(jget "$l" 'd["exact"].get("English")') / $(jget "$l" 'd["exact"].get("Brazilian Portuguese")')"
cat_has "Salvo como" "AC-1"
[ "$(jget "$(get /api/settings)" 'd["machine"].get("language")')" = "pt-BR" ] && pass "AC-1 /api/settings answers pt-BR" || fail "AC-1 /api/settings machine.language was: $(jget "$(get /api/settings)" 'd["machine"].get("language")')"
raw="$(curl -s "$base/" | grep -F 'const RAW =')"
case "$raw" in *.says*.did*.ttitle*|*.ttitle*.says*.did*|*.ttitle*.did*.says*) pass "AC-1 RAW still lists the agents' text (.ttitle, .says, .did)";; *) fail "AC-1 RAW no longer lists the agents' text: $raw";; esac
page_has 'id="lang"' "AC-1"
[ -z "$(cat "$C/stub-ok" 2>/dev/null)" ] && pass "AC-1 a language change does not call the scheduler" || fail "AC-1 the scheduler was called: $(cat "$C/stub-ok")"

# --- AC-6: only language changes in config.yml
fresh_home
printf 'language: en\npool: 6\nstages:\n  refine: 3\n  develop: 1\nstacks: 2\nstack_wait: 90\ndispatcher:\n  every_min: 5\n' > "$H/config.yml"
before="$(cfgrest)"; start_dash d "$OK_CMD"
resp="$(post '{"language":"pt-BR"}')"; code="${resp##*$'\n'}"
[ "$code" = 200 ] && pass "AC-6 saving a language answers 200" || fail "AC-6 saving a language answered $code: $resp"
[ "$(cfglang)" = "pt-BR" ] && pass "AC-6 language is now pt-BR" || fail "AC-6 language is: $(cfglang) (want pt-BR)"
[ "$(cfgrest)" = "$before" ] && pass "AC-6 every other key of config.yml is as before" || fail "AC-6 the other keys changed: before $before, after $(cfgrest)"

# --- AC-7: the section says the text a product shows its own users is not a factory setting
page_has "text a product shows its own users is not a factory setting" "AC-7"
cat_has "não é uma configuração da fábrica" "AC-7"
finish
