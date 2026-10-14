#!/usr/bin/env bash
# suite: end-to-end
# #173 (RES-01) fault injection on the board's gh calls.
#   AC-1  FAKE_GH_FAIL_AT=<n> / FAKE_GH_FAIL_CMD=<ERE> make the fake gh fail the n-th call / every matching call, and
#         nothing else (both fakes: fake-gh for board.sh and the dispatcher, fake-gh-deploy for deploy.sh)
#   AC-2  gh failing at each point of a board mutation sequence (a column move; the dispatcher's infra hand-over; the
#         deploy's block): the next cycle finishes it or the card is blocked with a reason, never half-moved
# The fakes only inject the failure; the board state (labels, columns, comments) is kept by `sgh` below, which applies
# a mutation only when the fake gh answered it with exit 0. The "next cycle" is the same command without the fault.
# Safety: a failing mktemp aborts the test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/deploy-lib.sh"   # lib.sh, and the base repo of the deploy.sh cases
FAKE="$FACTORY_DIR/test/fake-gh"
FAKE_DEPLOY="$FACTORY_DIR/test/fake-gh-deploy"
INV="$FACTORY_DIR/test/py/chaos_invariant.py"
BOARD="$FACTORY_DIR/board.sh"
D="$FACTORY_DIR/dispatch.sh"
HOLDS=()
cleanup() { local h; for h in "${HOLDS[@]:-}"; do [ -n "$h" ] && rm -f "$h"; done; return 0; }  # releases every held run
trap cleanup EXIT
unset FAKE_GH_FAIL_AT FAKE_GH_FAIL_CMD

# ---------------------------------------------------------------- AC-1
fgh() {  # fgh <fake> <dir> <args...>: one call of the fake gh with FAKE_GH_DIR=<dir>; sets RC, OUT, ERR
  local fake="$1" dir="$2"; shift 2
  OUT="$(FAKE_GH_DIR="$dir" FG="$dir" bash "$fake" "$@" 2>"$dir/err")"; RC=$?; ERR="$(cat "$dir/err")"
}
one_dir() {  # one_dir <fake>: a state dir the fake can run in
  local dir; dir="$(mktemp -d)"
  if [ "$1" = "$FAKE_DEPLOY" ]; then echo "$dir/remote.git" > "$dir/remote"; echo 78 > "$dir/pr"; echo feat/7-x > "$dir/branch"; fi
  printf '7\tSeven\n' > "$dir/titles.tsv"
  echo "$dir"
}
for fake in "$FAKE" "$FAKE_DEPLOY"; do
  name="$(basename "$fake")"
  dir="$(one_dir "$fake")"
  export FAKE_GH_FAIL_AT=2
  fgh "$fake" "$dir" api user; r1=$RC; o1="$OUT"
  fgh "$fake" "$dir" api user; r2=$RC; e2="$ERR"
  fgh "$fake" "$dir" api user; r3=$RC; o3="$OUT"
  fgh "$fake" "$dir" api user; r4=$RC
  unset FAKE_GH_FAIL_AT
  [ "$r1" = 0 ] && [ "$o1" = factory ] && pass "AC-1 $name: FAIL_AT=2, the 1st call behaves as before" || fail "AC-1 $name: 1st call exit $r1 out '$o1'"
  [ "$r2" != 0 ] && pass "AC-1 $name: FAIL_AT=2, the 2nd call exits non-zero" || fail "AC-1 $name: the 2nd call exited 0"
  assert_contains "$e2" "injected failure"
  [ "$r3" = 0 ] && [ "$o3" = factory ] && [ "$r4" = 0 ] && pass "AC-1 $name: FAIL_AT=2, the calls after it behave as before" || fail "AC-1 $name: 3rd/4th call exit $r3/$r4 out '$o3'"

  dir="$(one_dir "$fake")"
  export FAKE_GH_FAIL_CMD='issue (comment|edit)|pr list'
  fgh "$fake" "$dir" issue comment 7 --body x; c1=$RC; e1="$ERR"
  fgh "$fake" "$dir" pr list --state open; c2=$RC
  fgh "$fake" "$dir" issue edit 7 --add-label blocked; c3=$RC
  fgh "$fake" "$dir" issue comment 7 --body y; c4=$RC
  fgh "$fake" "$dir" api user; c5=$RC; o5="$OUT"
  unset FAKE_GH_FAIL_CMD
  [ "$c1" != 0 ] && [ "$c2" != 0 ] && [ "$c3" != 0 ] && [ "$c4" != 0 ] && pass "AC-1 $name: FAIL_CMD fails every call that matches the ERE" || fail "AC-1 $name: exits $c1 $c2 $c3 $c4, want all non-zero"
  assert_contains "$e1" "injected failure"
  [ "$c5" = 0 ] && [ "$o5" = factory ] && pass "AC-1 $name: FAIL_CMD leaves a call that does not match as before" || fail "AC-1 $name: api user exit $c5 out '$o5'"
  fgh "$fake" "$dir" api user; [ "$RC" = 0 ] && [ "$OUT" = factory ] && pass "AC-1 $name: with neither variable set the fake is as before" || fail "AC-1 $name: unset, api user exit $RC out '$OUT'"
done

# ---------------------------------------------------------------- the stateful gh for AC-2
SGHDIR="$(mktemp -d)"
cat > "$SGHDIR/sgh" <<'EOF'
#!/usr/bin/env bash
# fake-gh behind a recorder: every call is logged in $FAKE_GH_DIR/seq; a mutation the fake answered with 0 is applied
# to the board it keeps (labels-<n>, the item's column in items.tsv, the blocked:infra list, comment-log).
d="$FAKE_GH_DIR"; args="$*"
printf '%s\n' "${args//$'\n'/ }" >> "$d/seq"   # one line a call, whatever the query's line breaks
bash "$FAKE_GH_REAL" "$@"; rc=$?
[ "$rc" = 0 ] || exit "$rc"
cols=("👤 Inbox" "👤 Ready for Refinement" "🤖 Technical Refinement" "👤 Spec Review" "👤 Ready for Dev" "🤖 Coding" "🤖 Validation" "👤 Staged" "👤 Ready for Prod" "🤖 Done")
infra() { : > "$d/infra"; local f; for f in "$d"/labels-*; do [ -f "$f" ] && grep -qx 'blocked:infra' "$f" && echo "${f##*/labels-}" >> "$d/infra"; done; return 0; }
case "$args" in
  "api -X POST repos/acme/shop/issues/"*"/labels -f labels[]="*)
    n="${args#*issues/}"; n="${n%%/*}"; l="${args##*labels[]=}"
    grep -qxF "$l" "$d/labels-$n" 2>/dev/null || echo "$l" >> "$d/labels-$n"
    infra ;;
  "api -X DELETE repos/acme/shop/issues/"*"/labels/"*)
    n="${args#*issues/}"; n="${n%%/*}"; l="${args##*/labels/}"
    if [ -f "$d/labels-$n" ]; then grep -vxF "$l" "$d/labels-$n" > "$d/labels.next"; mv "$d/labels.next" "$d/labels-$n"; fi
    infra ;;
  "project item-edit "*)
    item="${args#*--id }"; item="${item%% *}"; opt="${args##*--single-select-option-id opt}"; opt="${opt%% *}"
    awk -F'\t' -v OFS='\t' -v i="$item" -v s="${cols[$((opt - 1))]}" '$1 == i { $3 = s } { print }' "$d/items.tsv" > "$d/items.next" \
      && mv "$d/items.next" "$d/items.tsv" ;;
  "issue comment "*) echo "$3" >> "$d/comment-log" ;;
esac
exit 0
EOF
chmod +x "$SGHDIR/sgh"
export FAKE_GH_REAL="$FAKE"

status_of() { awk -F'\t' -v n="$1" '$2 == n { print $3 }' "$FAKE_GH_DIR/items.tsv"; }   # the column, with its owner mark
seq_n() { if [ -f "$FAKE_GH_DIR/seq" ]; then wc -l < "$FAKE_GH_DIR/seq" | tr -d ' '; else echo 0; fi; }
mutation() { case "$1" in "api -X POST"*|"api -X DELETE"*|"project item-edit"*|"issue comment"*|"api graphql"*) return 0 ;; *) return 1 ;; esac; }
board_file() {  # board_file <file>: the board as the invariant reads it, "<n><TAB><column><TAB><labels>"
  local it n st lab
  : > "$1"
  while IFS=$'\t' read -r it n st; do
    lab="$(tr -d '\r' < "$FAKE_GH_DIR/labels-$n" 2>/dev/null | paste -sd, -)"
    printf '%s\t%s\t%s\n' "$n" "$st" "$lab" >> "$1"
  done < "$FAKE_GH_DIR/items.tsv"
}

# ---------------------------------------------------------------- AC-2: a column move, gh failing at each call of it
export FACTORY_GH="$SGHDIR/sgh" FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
seed_move() {
  export FAKE_GH_DIR="$(mktemp -d)" FACTORY_HOME="$(mktemp -d)"
  printf 'I4\t40\t🤖 Coding\n' > "$FAKE_GH_DIR/items.tsv"
}
seed_move; bash "$BOARD" move 40 Validation >/dev/null 2>&1; rc=$?
K="$(seq_n)"; MOVE_SEQ="$(mktemp)"; cp "$FAKE_GH_DIR/seq" "$MOVE_SEQ"
[ "$rc" = 0 ] && [ "$(status_of 40)" = "🤖 Validation" ] && [ "$K" -gt 0 ] && pass "AC-2 move: the clean run moves the card in $K gh calls" || fail "AC-2 move: clean run exit $rc, column '$(status_of 40)', $K calls"
for n in $(seq 1 "$K"); do
  call="$(sed -n "${n}p" "$MOVE_SEQ")"; call="${call:0:48}"
  seed_move
  FAKE_GH_FAIL_AT=$n bash "$BOARD" move 40 Validation >/dev/null 2>&1; rc=$?
  col="$(status_of 40)"
  if [ "$rc" = 0 ] && [ "$col" = "🤖 Validation" ]; then ok=1
  elif [ "$rc" != 0 ] && [ "$col" = "🤖 Coding" ]; then ok=1
  else ok=0; fi
  [ "$ok" = 1 ] && pass "AC-2 move: gh failing at call $n/$K ($call), the card is moved (exit 0) or untouched (exit $rc), never half-way" \
    || fail "AC-2 move: gh failing at call $n/$K ($call): exit $rc with the card in '$col'"
  case "$call" in "project item-edit"*)  # the move call itself: its failure must reach the caller, and the card stays
    [ "$rc" != 0 ] && [ "$col" = "🤖 Coding" ] && pass "AC-2 move: the move call failing exits non-zero and leaves the card in Coding" || fail "AC-2 move: the move call failed but exit $rc, column '$col'" ;;
  esac
  bash "$BOARD" move 40 Validation >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(status_of 40)" = "🤖 Validation" ] && pass "AC-2 move: after failing at call $n/$K the next try finishes the move" || fail "AC-2 move: after failing at call $n/$K the retry exit $rc, column '$(status_of 40)'"
done

# ---------------------------------------------------------------- AC-2: the dispatcher's blocked:infra hand-over
# Card 70 sits in Validation with blocked:infra. With a retry marker already there the dispatcher hands it to the owner
# (label blocked on, blocked:infra off); without one it cleans up, leaves the marker and takes blocked:infra off so the
# card runs again. gh fails at each mutation (and at the board read) of that cycle; the next cycle must leave the card
# blocked or with a live run.
dsetup() {  # dsetup <marker 0|1>
  T="$(mktemp -d)"; HOLDS+=("$T/hold"); touch "$T/hold"; export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_PROJECT=shop
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$SGHDIR/sgh"
  unset FACTORY_BOARD FACTORY_LOCK_TTL FAKE_GH_NO_JQ FAKE_GH_FAIL_AT FAKE_GH_FAIL_CMD SHIPFLOOR_MAX_PARALLEL
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs" "$FACTORY_HOME/infra"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$SHIPFLOOR_HOME/registry.tsv"
  printf 'pool: 4\nstages: {refine: 1, develop: 1, validate: 1, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
p="$(cat)"; echo "$p" >> "$T/launched"
n=0; while [ -e "$T/hold" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
EOC
  chmod +x "$T/claude"; export FACTORY_CLAUDE="$T/claude"
  printf 'I70\t70\t🤖 Validation\n' > "$FAKE_GH_DIR/items.tsv"
  echo "blocked:infra" > "$FAKE_GH_DIR/labels-70"; echo 70 > "$FAKE_GH_DIR/infra"
  [ "$1" = 0 ] || date +%s > "$FACTORY_HOME/infra/70"
}
cycle() { bash "$D" >"$T/cycle.out" 2>&1; }
no_locks() { [ -z "$(find "$FACTORY_HOME/locks" -mindepth 1 -maxdepth 1 -name '*.lock' 2>/dev/null)" ]; }
settle() { rm -f "$T/hold"; wait_for "the runs to end" no_locks; }

for marker in 1 0; do
  dsetup "$marker"; cycle; rc=$?
  K="$(seq_n)"; seq_file="$(mktemp)"; cp "$FAKE_GH_DIR/seq" "$seq_file"
  [ "$rc" = 0 ] && pass "AC-2 infra (marker $marker): the clean cycle exits 0 after $K gh calls" || fail "AC-2 infra (marker $marker): the clean cycle exits $rc: $(cat "$T/cycle.out")"
  settle
  n=0
  while IFS= read -r call; do
    n=$((n + 1))
    mutation "$call" || continue
    dsetup "$marker"
    FAKE_GH_FAIL_AT=$n cycle; unset FAKE_GH_FAIL_AT
    cycle                                   # the next cycle
    board_file "$T/board.tsv"
    out="$("$FACTORY_PYTHON" -I -B "$INV" --no-dashboard --board "$T/board.tsv" "$SHIPFLOOR_HOME" 2>&1)"; irc=$?
    [ "$irc" = 0 ] && pass "AC-2 infra (marker $marker): gh failing at call $n (${call:0:48}), the next cycle leaves the card running or blocked" \
      || fail "AC-2 infra (marker $marker): gh failing at call $n (${call:0:48}): $out"
    settle
  done < "$seq_file"
done

# ---------------------------------------------------------------- AC-2: the deploy's block (comment, then label)
# No open PR for the card: deploy.sh stops it with a comment saying why and the label blocked. gh fails at each call; a
# card that ends up labelled blocked must carry the comment, one that is not blocked is picked up by the next deploy.
unset FAKE_GH_DIR FACTORY_GH
reason() { grep -q 'Factory deploy stopped' "$FG/comments" 2>/dev/null; }
blocked_label() { grep -qx blocked "$FG/labels" 2>/dev/null; }
setup; touch "$FG/no-pr"; code="$(run 7)"
K="$(wc -l < "$FG/calls" | tr -d ' ')"
[ "$code" = 5 ] && blocked_label && reason && pass "AC-2 deploy: the clean run blocks the card with its reason in $K gh calls" || fail "AC-2 deploy: clean run exit $code, labels '$(cat "$FG/labels" 2>/dev/null)', $K calls: $(cat "$T/out")"
for n in $(seq 1 "$K"); do
  setup; touch "$FG/no-pr"
  export FAKE_GH_DIR="$FG" FAKE_GH_FAIL_AT=$n
  code1="$(run 7)"
  unset FAKE_GH_FAIL_AT
  blocked_label || code2="$(run 7)"          # the next deploy picks the card up unless it is blocked
  if blocked_label && reason; then pass "AC-2 deploy: gh failing at call $n/$K, the card ends blocked with its reason"
  elif blocked_label; then fail "AC-2 deploy: gh failing at call $n/$K (exit $code1), the card is blocked and no comment says why"
  else fail "AC-2 deploy: gh failing at call $n/$K (exit $code1), the next deploy left the card unblocked: $(cat "$T/out")"; fi
done
unset FAKE_GH_DIR
finish
