#!/usr/bin/env bash
# AC-4 of #165: the Python static gates say their stderr in the project's language, picked in this order of precedence:
# FACTORY_LANGUAGE, `language:` in overrides.yml beside FACTORY_CONFIG, `language:` in FACTORY_CONFIG. Stderr goes through
# the sed catalog (scripts/lang/<code>.sed); stdout carries only data; the verdict line stays English.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
FIX="$FACTORY_DIR/test/fixture/factory.yml"
[ -f "$FACTORY_DIR/test/fixtures/gate.bash.sh" ] && [ "$(git hash-object "$FACTORY_DIR/test/fixtures/gate.bash.sh")" = 5e5faa4675c8b4caceaafece8859253a00da76b0 ] || { fail "AC-4 the reference Bash gate fixture is missing or not the pre-port gate.sh"; exit 1; }
REF="$(plugin_copy)"; cp "$FACTORY_DIR/test/fixtures/gate.bash.sh" "$REF/scripts/gate.sh"
refgate() { bash "$REF/scripts/gate.sh" "$@"; }
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
pygate --help >/dev/null 2>&1 || { fail "AC-4 the Python gate is missing: 'sf.py gate --help' fails, so it translates nothing"; exit 1; }

EN_MSG="acceptance-intact: acceptance tests changed after the QA commit"
PT_MSG="acceptance-intact: os testes de aceitação mudaram depois do commit do QA"
lastline() { printf '%s' "${1##*$'\n'}"; }

r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/13-x
echo 'test' > api/src/test/ATest.kt; git add -A; git commit -qm "test(x): acceptance tests for #13"; qa="$(git rev-parse HEAD)"
echo 'weakened' > api/src/test/ATest.kt; git commit -qam weaken

say() {  # say <label> <expected text> <not expected text> <gate args...>: the Python gate's stderr (exit 1 expected)
  local label="$1" want="$2" notwant="$3" err code; shift 3
  err="$(pygate "$@" 2>&1 >"$T/out")"; code=$?
  case "$err" in "usage: sf.py"*) fail "AC-4 $label: sf.py has no gate command"; return ;; esac
  if [ "$code" != 1 ]; then fail "AC-4 $label: exit $code, want 1: $err"
  elif [[ "$err" != *"$want"* ]]; then fail "AC-4 $label: no '$want' in: $err"
  elif [[ -n "$notwant" && "$err" == *"$notwant"* ]]; then fail "AC-4 $label: '$notwant' in: $err"
  elif [ "$(lastline "$err")" != "gate acceptance-intact: FAIL (exit 1)" ]; then fail "AC-4 $label: the verdict is not the English line: $(lastline "$err")"
  else pass "AC-4 $label"; fi
}

# ---- no language anywhere: English
say "no language: English" "$EN_MSG" "os testes" acceptance-intact "$qa"

# ---- language: in FACTORY_CONFIG
PT="$T/pt.yml"; { cat "$FIX"; echo "language: pt-BR"; } > "$PT"
( export FACTORY_CONFIG="$PT"; say "language: pt-BR in the config is pt-BR" "$PT_MSG" "$EN_MSG" acceptance-intact "$qa" )
PTQ="$T/ptq.yml"; { cat "$FIX"; echo 'language: "pt-BR"'; } > "$PTQ"
( export FACTORY_CONFIG="$PTQ"; say "a quoted language: \"pt-BR\" in the config is pt-BR" "$PT_MSG" "$EN_MSG" acceptance-intact "$qa" )

# ---- overrides.yml beside the config, over the config; the config file is left as it was
OD="$T/od"; mkdir "$OD"; cp "$FIX" "$OD/factory.yml"; cp "$OD/factory.yml" "$OD/factory.before"
printf 'language: pt-BR\n' > "$OD/overrides.yml"
( export FACTORY_CONFIG="$OD/factory.yml"; say "overrides.yml pt-BR over a config with no language" "$PT_MSG" "$EN_MSG" acceptance-intact "$qa" )
cmp -s "$OD/factory.yml" "$OD/factory.before" && pass "AC-4 factory.yml is byte-identical" || fail "AC-4 factory.yml changed"
OD2="$T/od2"; mkdir "$OD2"; cp "$PT" "$OD2/factory.yml"; printf 'language: en\n' > "$OD2/overrides.yml"
( export FACTORY_CONFIG="$OD2/factory.yml"; say "overrides.yml en wins over language: pt-BR in the config" "$EN_MSG" "os testes" acceptance-intact "$qa" )

# ---- FACTORY_LANGUAGE wins over both
( export FACTORY_CONFIG="$OD/factory.yml" FACTORY_LANGUAGE=en; say "FACTORY_LANGUAGE=en wins over an overrides.yml pt-BR" "$EN_MSG" "os testes" acceptance-intact "$qa" )
( export FACTORY_CONFIG="$PT" FACTORY_LANGUAGE=en; say "FACTORY_LANGUAGE=en wins over language: pt-BR in the config" "$EN_MSG" "os testes" acceptance-intact "$qa" )
( export FACTORY_LANGUAGE=pt-BR; say "FACTORY_LANGUAGE=pt-BR wins over a config with no language" "$PT_MSG" "$EN_MSG" acceptance-intact "$qa" )
rm "$OD/overrides.yml"
( export FACTORY_CONFIG="$OD/factory.yml" FACTORY_LANGUAGE=pt-BR; say "FACTORY_LANGUAGE=pt-BR holds once overrides.yml is gone" "$PT_MSG" "$EN_MSG" acceptance-intact "$qa" )

# ---- a language the factory does not have: the Bash gate decides, the Python one does the same
( export FACTORY_LANGUAGE=klingon
  refgate acceptance-intact "$qa" >"$T/ro" 2>"$T/re"; rc=$?
  pygate acceptance-intact "$qa" >"$T/po" 2>"$T/pe"; pc=$?
  if [ "$rc" = "$pc" ] && cmp -s "$T/re" "$T/pe" && cmp -s "$T/ro" "$T/po"; then pass "AC-4 an unknown FACTORY_LANGUAGE behaves as in the Bash gate"
  else fail "AC-4 klingon: python exit $pc stderr '$(cat "$T/pe")' vs bash exit $rc stderr '$(cat "$T/re")'"; fi )

# ---- other messages go through the catalog too
( export FACTORY_LANGUAGE=pt-BR
  err="$(pygate scope e2e "$(git rev-parse HEAD)" 2>&1 >/dev/null)"
  case "$err" in *"scope: papel desconhecido 'e2e'"*) pass "AC-4 scope's unknown role is translated" ;; *) fail "AC-4 scope in pt-BR: $err" ;; esac
  [ "$(lastline "$err")" = "gate scope: FAIL (exit 2)" ] && pass "AC-4 the verdict stays 'gate scope: FAIL (exit 2)' in pt-BR" || fail "AC-4 scope verdict: $(lastline "$err")"
  err="$(pygate qa-amend 13 2>&1 >/dev/null)"
  case "$err" in *"qa-amend: the last commit is not a QA commit"*) fail "AC-4 qa-amend was not translated: $err" ;; "usage: sf.py"*) fail "AC-4 sf.py has no gate command" ;; *) pass "AC-4 qa-amend's message is translated" ;; esac )

# ---- stdout carries only data, in every language
data_same() {  # data_same <label> <want stdout> <gate args...>
  local label="$1" want="$2" lang got; shift 2
  for lang in en pt-BR; do
    got="$(FACTORY_LANGUAGE=$lang pygate "$@" 2>/dev/null)"
    if [ "$got" = "$want" ]; then pass "AC-4 $label: stdout is only the data ($lang)"; else fail "AC-4 $label ($lang): stdout '$got', want '$want'"; fi
  done
}
data_same "qa-commit" "$qa" qa-commit 13
data_same "qa-commit --head" "" qa-commit 13 --head
own="$(refgate acceptance-own "$qa" api/src/test/ATest.kt 2>/dev/null)"
[[ "$own" =~ ^own:[0-9a-f]{40,64}$ ]] && pass "AC-4 the reference prints an own: key" || fail "AC-4 reference own: '$own'"
data_same "acceptance-own" "$own" acceptance-own "$qa" api/src/test/ATest.kt
# the translated stderr never leaks to stdout and stdout never reaches the catalog
out="$(FACTORY_LANGUAGE=pt-BR pygate acceptance-intact "$qa" 2>/dev/null)"
[ -z "$out" ] && pass "AC-4 a blocked gate in pt-BR has an empty stdout" || fail "AC-4 stdout of a blocked gate: $out"
finish
