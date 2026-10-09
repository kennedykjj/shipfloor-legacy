#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"
  export FACTORY_HOME="$(mktemp -d)" FACTORY_REPO="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  tmp="$(mktemp -d)"
  # fake board: answers from env vars Q_REF, Q_DEV, Q_PROD (first issue) and W_SR, W_CV (counts)
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
[ -n "${BOARD_FAIL:-}" ] && exit 1
case "$1 $2" in
  "count Spec Review") echo "${W_SR:-0}" ;;
  "count Coding") echo "${W_CV:-0}" ;;
  "eligible Ready for Refinement") echo "${Q_REF:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Ready for Prod") echo "${Q_PROD:-}" ;;
  "eligible "*) ;;
  *) echo 0 ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat) $*" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"
  export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
  : > "$tmp/launched"
}
launched() { sleep 1; cat "$tmp/launched"; }

setup; export Q_REF=25 Q_DEV=40 Q_PROD=47 W_SR=0 W_CV=0
bash "$D"; out="$(launched)"
assert_contains "$out" "/mylos:refinar 25"; assert_contains "$out" "/mylos:desenvolver 40"; assert_contains "$out" "/mylos:deployar 47"

setup; export Q_REF=25 W_SR=2 Q_DEV= Q_PROD=
bash "$D"; [ -z "$(launched)" ] && pass "spec review full → nothing" || fail "launched with full WIP"

setup; export Q_REF= Q_DEV=40 W_CV=4 Q_PROD=
bash "$D"; [ -z "$(launched)" ] && pass "coding+validation full → nothing" || fail "launched with full WIP"

setup; export Q_REF=25 W_SR=0 Q_DEV= Q_PROD=; mkdir -p "$FACTORY_HOME"; touch "$FACTORY_HOME/PAUSE"
bash "$D"; [ -z "$(launched)" ] && pass "PAUSE → nothing" || fail "ran while paused"

setup; export Q_REF=25 W_SR=0 Q_DEV= Q_PROD=
mkdir -p "$FACTORY_HOME/locks/refinar-25.lock"; echo "1 $(date +%s) 26" > "$FACTORY_HOME/locks/refinar-25.lock/info"
bash "$D"; [ -z "$(launched)" ] && pass "fresh lock respected" || fail "ignored fresh lock"

setup; export Q_REF=25 W_SR=0 Q_DEV= Q_PROD=
mkdir -p "$FACTORY_HOME/locks/refinar-25.lock"; echo "1 $(( $(date +%s) - 20000 )) 26" > "$FACTORY_HOME/locks/refinar-25.lock/info"
bash "$D"; assert_contains "$(launched)" "/mylos:refinar 25"

setup; export Q_REF=25 W_SR=0 BOARD_FAIL=1
assert_exit 1 bash "$D"
[ -z "$(launched)" ] && pass "board failure → nothing" || fail "launched despite board failure"
[ ! -d "$FACTORY_HOME/locks/refinar-25.lock" ] && pass "no lock left" || fail "left a lock"
unset BOARD_FAIL
finish
