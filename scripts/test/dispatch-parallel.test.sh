#!/usr/bin/env bash
# Up to 2 refine/mylos:develop runs at once (within WIP), 1 deploy, one run per card.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export FACTORY_HOME="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" Q_REF= Q_DEV= Q_PROD= W_SR=0 W_CV=0 SNAP_TSV=
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 $2" in
  "snapshot ") printf '%b' "${SNAP_TSV:-}" ;;
  "count Spec Review") echo "${W_SR:-0}" ;;
  "count Coding") echo "${W_CV:-0}" ;;
  "eligible Ready for Refinement") for n in ${Q_REF:-}; do echo "$n"; done ;;
  "eligible Ready for Dev") for n in ${Q_DEV:-}; do echo "$n"; done ;;
  "eligible Ready for Prod") for n in ${Q_PROD:-}; do echo "$n"; done ;;
  *) echo ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat) $*" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
  printf '#!/usr/bin/env bash
echo "/mylos:deploy $*" >> "%s/launched"
' "$tmp" > "$tmp/deploy"; chmod +x "$tmp/deploy"; export FACTORY_DEPLOY="$tmp/deploy"
}
launched() { grep -o '/mylos:[a-z]* [0-9]*' "$tmp/launched" | sort | tr '\n' ' '; }
fresh_lock() { mkdir -p "$FACTORY_HOME/locks/$1.lock"; echo "$$ $(date +%s) ${1##*-}" > "$FACTORY_HOME/locks/$1.lock/info"; }

setup; Q_DEV="26 27"; run_dispatch; assert_contains "$(launched)" "/mylos:develop 26 /mylos:develop 27"
setup; Q_DEV="26 27 28" W_CV=3; run_dispatch; out="$(launched)"; assert_contains "$out" "/mylos:develop 26"
case "$out" in *27*) fail "exceeded WIP: $out" ;; *) pass "respects WIP 4" ;; esac
setup; Q_DEV="27 28" W_CV=1 SNAP_TSV='26\tCoding\tI26\n'; fresh_lock develop-26
run_dispatch; out="$(launched)"; assert_contains "$out" "/mylos:develop 27"
case "$out" in *28*) fail "third concurrent run: $out" ;; *) pass "max 2 develop" ;; esac
setup; Q_DEV="26" ; fresh_lock develop-26; run_dispatch; [ -z "$(launched)" ] && pass "never twice on one card" || fail "relaunched card 26"
setup; Q_PROD="47 48"; run_dispatch; out="$(launched)"; assert_contains "$out" "/mylos:deploy 47"
case "$out" in *48*) fail "parallel deploys: $out" ;; *) pass "one deploy at a time" ;; esac
setup; Q_REF="25 26" W_SR=1 SNAP_TSV='30\tTechnical Refinement\tI30\n'; fresh_lock refine-30
run_dispatch; [ -z "$(launched)" ] && pass "in-flight refinement counts toward Spec Review WIP" || fail "overfilled Spec Review: $(launched)"
finish
