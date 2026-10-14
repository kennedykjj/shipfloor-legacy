#!/usr/bin/env bash
# Characterization of gate.sh's pass cache (pass_key, pass_reused, pass_record): the key, the record, its pruning
# (AC-4 of #158). These pin what the Bash gate does today, before the Python port: every assertion passes against
# the current code. gate-reuse.test.sh covers when a pass is reused; this file covers how it is stored.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
trap 'rm -rf "$T" "${LIBTMP[@]}"' EXIT
unset SHIPFLOOR_GATE_FRESH   # lib.sh sets it so the other tests keep running the command; this file tests the cache
GATE="$FACTORY_DIR/gate.sh"
FIXTURE="$FACTORY_DIR/test/fixture/factory.yml"

mkcfg() {  # mkcfg <file> <marks dir>: the fixture, with the web layer's build and tests leaving a mark
  local out="$1" marks="$2" line
  while IFS= read -r line; do
    case "$line" in
      *"exec tsc"*)         printf '%s\n' "    build: 'echo b >> \"$marks/build\"; [ ! -e \"$marks/failflag\" ]'" ;;
      *"exec vitest run"*)  printf '%s\n' "    test: 'echo \"\$1\" >> \"$marks/green\"; echo \" Tests  1 passed (1)\"'" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$FIXTURE" > "$out"
}
scenario() {  # scenario: fresh home, marks, config and repo; base <- c1 (HEAD); cwd is the repo
  export FACTORY_HOME; FACTORY_HOME="$(mktemp -d)"
  MARKS="$(mktemp -d)"
  CFG="$(mktemp)"; mkcfg "$CFG" "$MARKS"; export FACTORY_CONFIG="$CFG"
  r="$(new_repo)"; cd "$r" || exit 1
  base="$(git rev-parse HEAD)"
  mkdir -p web; echo x > web/a.ts; echo t > web/a.test.ts; git add -A; git commit -qm c1
  head="$(git rev-parse HEAD)"
}
runs() { if [ -f "$MARKS/$1" ]; then wc -l < "$MARKS/$1" | tr -d ' '; else echo 0; fi; }
expect_runs() {  # expect_runs <mark> <want> <what>
  local got; got="$(runs "$1")"
  if [ "$got" = "$2" ]; then pass "$3"; else fail "$3: $got runs of the layer's command, want $2"; fi
}
store() { ls "$FACTORY_HOME/gate-passes" 2>/dev/null; }
stored() { store | wc -l | tr -d ' '; }

# ---- AC-4: the record is one tab-separated line, in a file named by the key
scenario
bash "$GATE" build "$base" >/dev/null 2>&1; bash "$GATE" green web web/a.test.ts >/dev/null 2>&1
[ "$(stored)" = 2 ] && pass "AC-4 a build pass and a green pass are two records" || fail "AC-4 $(stored) records, want 2"
cfg_h="$(git hash-object --no-filters -- "$FACTORY_CONFIG")"; me_h="$(git hash-object --no-filters -- "$GATE")"
key_build="$({ printf '%s\n' "$head" build "$(git rev-parse "$base^{commit}")" "" "$cfg_h" "$me_h"; } | git hash-object --stdin)"
key_green="$({ printf '%s\n' "$head" green web web/a.test.ts "$cfg_h" "$me_h"; } | git hash-object --stdin)"
[ -f "$FACTORY_HOME/gate-passes/$key_build" ] && pass "AC-4 the build record is named by the hash of HEAD, gate, base, origin/main (empty), config hash and gate.sh hash" || fail "AC-4 no build record named $key_build in: $(store | tr '\n' ' ')"
[ -f "$FACTORY_HOME/gate-passes/$key_green" ] && pass "AC-4 the green record is named by the hash of HEAD, gate, layer, selector, config hash and gate.sh hash" || fail "AC-4 no green record named $key_green in: $(store | tr '\n' ' ')"
line="$(cat "$FACTORY_HOME/gate-passes/$key_build" 2>/dev/null)"
IFS=$'\t' read -r f1 f2 f3 f4 f5 <<< "$line"
[[ "$f1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && pass "AC-4 the record starts with a UTC time (YYYY-MM-DDTHH:MM:SSZ)" || fail "AC-4 record time: '$f1'"
[ "$f2" = "$head" ] && [ "$f3" = build ] && [ "$f4" = "$base" ] && [ -z "$f5" ] && pass "AC-4 the build record is '<time> <HEAD> build <base argument>' and nothing after" || fail "AC-4 build record: $line"
line="$(cat "$FACTORY_HOME/gate-passes/$key_green" 2>/dev/null)"
IFS=$'\t' read -r f1 f2 f3 f4 f5 <<< "$line"
[ "$f2" = "$head" ] && [ "$f3" = green ] && [ "$f4" = "web web/a.test.ts" ] && [ -z "$f5" ] && pass "AC-4 the green record is '<time> <HEAD> green <layer> <selector>'" || fail "AC-4 green record: $line"
[ "$(wc -l < "$FACTORY_HOME/gate-passes/$key_build" | tr -d ' ')" = 1 ] && pass "AC-4 a record is exactly one line" || fail "AC-4 record is not one line"

# ---- AC-4: the record is written to <record>.<pid>.tmp and renamed into place
scenario
real_mv="$(command -v mv)"; stubs="$(mktemp -d)"
cat > "$stubs/mv" <<EOF
#!/usr/bin/env bash
case "\$1" in *.tmp) printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$([ -e "\$2" ] && echo yes || echo no)" "\$(wc -c < "\$1" | tr -d ' ')" >> "$stubs/mv.log" ;; esac
exec "$real_mv" "\$@"
EOF
chmod +x "$stubs/mv"
PATH="$stubs:$PATH" bash "$GATE" build "$base" >/dev/null 2>&1
rec="$FACTORY_HOME/gate-passes/$(store | head -1)"
IFS=$'\t' read -r src dst existed size < "$stubs/mv.log" 2>/dev/null
[ -n "$src" ] && pass "AC-4 the record is moved into place with mv" || fail "AC-4 mv never moved a .tmp file"
[[ "$src" =~ ^.*/gate-passes/[0-9a-f]+\.[0-9]+\.tmp$ ]] && [ "${src%.*.tmp}" = "$dst" ] && pass "AC-4 the temp file is '<record>.<pid>.tmp' in the store" || fail "AC-4 temp file '$src' for record '$dst'"
[ "$dst" -ef "$rec" ] && pass "AC-4 the rename's target is the record the gate leaves" || fail "AC-4 renamed to '$dst', record is '$rec'"
[ "$existed" = no ] && pass "AC-4 the record did not exist before the rename" || fail "AC-4 the record existed before the rename: $existed"
[ "${size:-0}" -gt 40 ] && pass "AC-4 the temp file was complete (time, HEAD, gate, args) before the rename" || fail "AC-4 temp file size $size"
[ "$(store | grep -c '\.tmp$')" = 0 ] && pass "AC-4 no .tmp file is left in the store" || fail "AC-4 a .tmp file is left: $(store | tr '\n' ' ')"

# ---- AC-4: records older than 14 days go when a pass is recorded
scenario
mkdir -p "$FACTORY_HOME/gate-passes"
printf 'old\n' > "$FACTORY_HOME/gate-passes/old15"; touch -d '15 days ago' "$FACTORY_HOME/gate-passes/old15"
printf 'old\n' > "$FACTORY_HOME/gate-passes/old40"; touch -d '40 days ago' "$FACTORY_HOME/gate-passes/old40"
printf 'new\n' > "$FACTORY_HOME/gate-passes/new13"; touch -d '13 days ago' "$FACTORY_HOME/gate-passes/new13"
printf 'new\n' > "$FACTORY_HOME/gate-passes/new1"; touch -d '1 day ago' "$FACTORY_HOME/gate-passes/new1"
# a gate that fails prunes nothing
: > "$MARKS/failflag"; bash "$GATE" build "$base" >/dev/null 2>&1
[ -f "$FACTORY_HOME/gate-passes/old15" ] && [ -f "$FACTORY_HOME/gate-passes/old40" ] && pass "AC-4 a failing gate prunes nothing" || fail "AC-4 a failing gate pruned: $(store | tr '\n' ' ')"
rm -f "$MARKS/failflag"
bash "$GATE" build "$base" >/dev/null 2>&1
[ ! -e "$FACTORY_HOME/gate-passes/old15" ] && [ ! -e "$FACTORY_HOME/gate-passes/old40" ] && pass "AC-4 recording a pass removes the records older than 14 days" || fail "AC-4 old records kept: $(store | tr '\n' ' ')"
[ -f "$FACTORY_HOME/gate-passes/new13" ] && [ -f "$FACTORY_HOME/gate-passes/new1" ] && pass "AC-4 records of the last 14 days stay" || fail "AC-4 recent records removed: $(store | tr '\n' ' ')"
[ "$(stored)" = 3 ] && pass "AC-4 the new record is there beside the two recent ones" || fail "AC-4 $(stored) records, want 3: $(store | tr '\n' ' ')"
# a pass answered from the store is not a recording: it prunes nothing
printf 'old\n' > "$FACTORY_HOME/gate-passes/old20"; touch -d '20 days ago' "$FACTORY_HOME/gate-passes/old20"
bash "$GATE" build "$base" >/dev/null 2>&1
expect_runs build 2 "AC-4 (control) the second passing build answered from the store"
[ -f "$FACTORY_HOME/gate-passes/old20" ] && pass "AC-4 a reused pass prunes nothing" || fail "AC-4 a reused pass pruned"
# the next real recording prunes it
bash "$GATE" green web web/a.test.ts >/dev/null 2>&1
[ ! -e "$FACTORY_HOME/gate-passes/old20" ] && pass "AC-4 the next recorded pass (green) prunes it" || fail "AC-4 old20 kept after a green was recorded"

# ---- AC-4: pass_key with FACTORY_HOME unset: nothing is read or recorded, the gate just runs
scenario
for i in 1 2; do
  out="$(env -u FACTORY_HOME bash "$GATE" build "$base" 2>&1 >/dev/null)"; code=$?
  [ "$code" = 0 ] && pass "AC-4 build with FACTORY_HOME unset passes ($i)" || fail "AC-4 FACTORY_HOME unset: exit $code: $out"
done
expect_runs build 2 "AC-4 with FACTORY_HOME unset the build ran both times (no pass to reuse)"
case "$out" in *"unbound variable"*) fail "AC-4 FACTORY_HOME unset: $out" ;; *) pass "AC-4 FACTORY_HOME unset trips no unbound variable" ;; esac
case "$out" in *"reused"*) fail "AC-4 FACTORY_HOME unset reused a pass: $out" ;; *) pass "AC-4 FACTORY_HOME unset never reuses a pass" ;; esac
[ "$(stored)" = 0 ] && pass "AC-4 with FACTORY_HOME unset nothing is recorded in the other home" || fail "AC-4 $(stored) records written"
[ "${out##*$'\n'}" = "gate build: pass" ] && pass "AC-4 with FACTORY_HOME unset the verdict is still 'gate build: pass'" || fail "AC-4 verdict: $out"
env -u FACTORY_HOME bash "$GATE" green web web/a.test.ts >/dev/null 2>&1; code=$?
[ "$code" = 0 ] && pass "AC-4 green with FACTORY_HOME unset passes" || fail "AC-4 green with FACTORY_HOME unset: exit $code"
[ "$(stored)" = 0 ] && [ ! -e /gate-passes ] && pass "AC-4 green with FACTORY_HOME unset records nothing" || fail "AC-4 green with FACTORY_HOME unset recorded"

# ---- AC-4: the key changes when gate.sh changes (its content, not its path)
scenario
pc="$(plugin_copy)"; G2="$pc/scripts/gate.sh"
bash "$G2" build "$base" >/dev/null 2>&1
expect_runs build 1 "AC-4 a gate.sh copied elsewhere runs the build"
err="$(bash "$G2" build "$base" 2>&1 >/dev/null)"
expect_runs build 1 "AC-4 the same gate.sh reuses its pass"
case "$err" in *"reused the pass"*) pass "AC-4 ...and says so" ;; *) fail "AC-4 no reuse line: $err" ;; esac
bash "$GATE" build "$base" >/dev/null 2>&1
expect_runs build 1 "AC-4 another gate.sh with the same content reuses it (the key is the content, not the path)"
[ "$(stored)" = 1 ] && pass "AC-4 one record so far" || fail "AC-4 $(stored) records, want 1"
printf '\n# a change that does nothing\n' >> "$G2"
bash "$G2" build "$base" >/dev/null 2>&1
expect_runs build 2 "AC-4 after gate.sh changes the build runs again"
[ "$(stored)" = 2 ] && pass "AC-4 ...under a new key (two records)" || fail "AC-4 $(stored) records, want 2"
bash "$G2" build "$base" >/dev/null 2>&1
expect_runs build 2 "AC-4 the changed gate.sh reuses its own new pass"
finish
