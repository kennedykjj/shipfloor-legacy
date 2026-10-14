#!/usr/bin/env bash
# #160 AC-4: the dispatcher's own lines in the machine's language, and the board.tsv temp file per PID.
#  - language pt-BR (machine config.yml): the dispatcher's lines come out through the MLANG translation (lang/pt-BR.sed);
#    "== start" / "== end" / "== step-up" markers in a run's log stay English; with no language the lines are English
#  - dispatch.sh reads the board into board.tsv.<pid>.tmp and moves it over board.tsv: two dispatches at once for the
#    same project each write their own temp file and neither clobbers the other's
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path
# that a later git -C "", rm -rf or sed -i would act on in the current (real) repository. Defined before lib.sh so lib's
# own mktemp (REPO_TEMPLATE, new_repo) is covered too; kill because an exit inside $(...) only ends the subshell.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"; MD="$FACTORY_DIR/shipfloor-dispatch.sh"
BASE_CONFIG="$FACTORY_CONFIG"
PIDS=()
cleanup() {
  local p
  rm -f "$T"/holdsnap 2>/dev/null
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  return 0
}
trap cleanup EXIT

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3: no '$2' in: ${1:0:500}" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3: found '$2' in: ${1:0:500}" ;; *) pass "$3" ;; esac; }

fresh() {  # fresh [machine config text]: a new home and a fake board / claude; nothing queued
  T="$(mktemp -d)"; export T
  export FACTORY_HOME="$(mktemp -d)" SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  unset BOARD_FAIL SHIPFLOOR_NOW SNAP54
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  { printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n'; [ -z "${1:-}" ] || printf '%s\n' "$1"; } > "$SHIPFLOOR_HOME/config.yml"
  # the board: card 54 waits in Ready for Dev (Q_DEV) or sits in Coding (Q_CODING); the snapshot waits while $T/holdsnap exists
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "snapshot ")
    : > "$T/snap-started.$PPID"
    n=0; while [ -e "$T/holdsnap" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
    if [ -n "${BOARD_FAIL:-}" ]; then echo partial; exit 1; fi
    printf '%s\tCoding\tI_1\n' "$PPID"
    if [ -n "${SNAP54:-}" ]; then printf '54\tCoding\tI_54\n'; fi ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Coding") echo "${Q_CODING:-}" ;;
  "eligible "*|"label "*) ;;
  *) echo 0 ;;
esac
EOB
  # the run: its gate's verdict goes to the run's lock, where gate.sh writes it
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "build\\tFAIL\\n" > "$SHIPFLOOR_RUN_LOCK/last-gate"\n' > "$T/claude"
  chmod +x "$T/board" "$T/claude"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude" Q_DEV= Q_CODING=
}
log_of() { cat "$FACTORY_HOME"/logs/*-"$2-$1.log" 2>/dev/null | tr -d '\r'; }

# ---- AC-4: pt-BR
# a recent usage limit (a run's log, written now)
usage_log() { printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit · resets 6pm\n' > "$FACTORY_HOME/logs/x-5-develop.log"; }
fresh $'language: pt-BR'; usage_log
out="$(bash "$D" 2>&1)"; rc=$?
has "$out" "dispatch: limite de uso do Claude atingido há pouco; aguardando" "AC-4 pt-BR: the usage-limit line comes out in Portuguese"
lacks "$out" "usage limit hit recently" "AC-4 pt-BR: ... and not in English"
t "AC-4 pt-BR: the usage limit still exits 0" test "$rc" = 0
fresh; usage_log
out="$(bash "$D" 2>&1)"
has "$out" "dispatch: Claude usage limit hit recently; waiting" "AC-4 no language: the usage-limit line is English"
fresh $'language: en'; usage_log
out="$(bash "$D" 2>&1)"
has "$out" "dispatch: Claude usage limit hit recently; waiting" "AC-4 language en: the usage-limit line is English"

fresh $'language: pt-BR\nhours: ["08:00-09:00"]'
out="$(SHIPFLOOR_NOW=12:00 bash "$D" 2>&1)"
has "$out" "dispatch: fora do horário de trabalho; as execuções voltam a começar às 08:00" "AC-4 pt-BR: the working-hours line is in Portuguese, the time kept"
lacks "$out" "outside working hours" "AC-4 pt-BR: ... and not in English"
fresh $'hours: ["08:00-09:00"]'
out="$(SHIPFLOOR_NOW=12:00 bash "$D" 2>&1)"
has "$out" "dispatch: outside working hours; runs start again at 08:00" "AC-4 no language: the working-hours line is English"

fresh $'language: pt-BR'; export BOARD_FAIL=1
out="$(bash "$D" 2>&1)"; rc=$?
has "$out" "dispatch: a leitura do quadro falhou" "AC-4 pt-BR: the board-read failure (stderr) is in Portuguese"
t "AC-4 pt-BR: ... and the dispatch exits 1" test "$rc" = 1
unset BOARD_FAIL

# a develop run that ends on a failed gate: the dispatcher's step-up lines, in Portuguese; the run's log stays English
fresh $'language: pt-BR'; export Q_DEV=54 SNAP54=1
out="$(run_dispatch 2>&1)"
has "$out" "dispatch: #54 falhou no gate build em sonnet; a próxima execução é em opus" "AC-4 pt-BR: the step-up line names the gate and both models in Portuguese"
lacks "$out" "failed gate build on sonnet" "AC-4 pt-BR: ... and not in English"
log="$(log_of develop 54)"
has "$log" "== start /sf:develop 54" "AC-4 pt-BR: the == start marker in the run's log stays English"
has "$log" "== end /sf:develop 54 exit=0" "AC-4 pt-BR: the == end marker stays English"
has "$log" "== step-up /sf:develop 54 sonnet -> opus: gate build failed" "AC-4 pt-BR: the == step-up marker in the log stays English"
export Q_DEV= Q_CODING=54
out="$(run_dispatch 2>&1)"
has "$out" "dispatch: #54 roda em opus, um modelo acima, depois que sonnet falhou no gate build" "AC-4 pt-BR: the line that says why the model changed is in Portuguese"
fresh; export Q_DEV=54 SNAP54=1
out="$(run_dispatch 2>&1)"
has "$out" "dispatch: #54 failed gate build on sonnet; the next run is on opus" "AC-4 no language: the step-up line is English"

# a line before the language is read comes out in English whatever the language is (today: MLANG is set after the config checks)
fresh $'language: pt-BR'; printf 'project: {name: broken}\n' > "$T/factory.yml"; export FACTORY_CONFIG="$T/factory.yml"
out="$(bash "$D" 2>&1)"; rc=$?
has "$out" "dispatch: invalid config $T/factory.yml" "AC-4 pt-BR: the invalid-config line is printed before MLANG is read, so in English (today)"
t "AC-4 ... and the dispatch exits 2" test "$rc" = 2
fresh $'language: pt-BR\npool: 0'
out="$(bash "$D" 2>&1)"; rc=$?
has "$out" "dispatch: invalid $SHIPFLOOR_HOME/config.yml" "AC-4 pt-BR: the invalid machine-config line is also English (today)"
t "AC-4 ... and the dispatch exits 2" test "$rc" = 2

# shipfloor-dispatch.sh: the same catalog, for the cycle's own lines
shop_project() {
  local remote r; remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.shipfloor"; cp "$FACTORY_DIR/test/fixture/factory.yml" "$r/.shipfloor/factory.yml"
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  printf 'shop\t%s\t%s\tmain\n' "$r" "$SHIPFLOOR_HOME/projects/shop/wt" > "$SHIPFLOOR_HOME/registry.tsv"
}
for lang in pt-BR en; do
  fresh "language: $lang"; unset FACTORY_CONFIG FACTORY_HOME FACTORY_WT_ROOT; shop_project
  mkdir -p "$SHIPFLOOR_HOME/projects/shop/logs"
  printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit · resets 6pm\n' > "$SHIPFLOOR_HOME/projects/shop/logs/x-5-develop.log"
  out="$(bash "$MD" 2>&1)"
  if [ "$lang" = pt-BR ]; then has "$out" "shipfloor: limite de uso do Claude atingido há pouco; aguardando" "AC-4 pt-BR: shipfloor-dispatch's usage-limit line is in Portuguese"
  else has "$out" "shipfloor: Claude usage limit hit recently; waiting" "AC-4 en: shipfloor-dispatch's usage-limit line is English"; fi
done

# ---- AC-4: board.tsv temp file per PID; two dispatches at once for the same project
fresh; touch "$T/holdsnap"
bash "$D" >"$T/a.out" 2>&1 &
A=$!; PIDS+=("$A")
bash "$D" >"$T/b.out" 2>&1 &
B=$!; PIDS+=("$B")
wait_for "dispatch A to be reading the board" test -e "$T/snap-started.$A"
wait_for "dispatch B to be reading the board" test -e "$T/snap-started.$B"
t "AC-4 two dispatches at once have different PIDs" test "$A" != "$B"
t "AC-4 dispatch A writes board.tsv.<its pid>.tmp" test -e "$FACTORY_HOME/board.tsv.$A.tmp"
t "AC-4 dispatch B writes its own board.tsv.<its pid>.tmp" test -e "$FACTORY_HOME/board.tsv.$B.tmp"
t "AC-4 while both read, board.tsv is not there yet (the temp files are moved at the end)" test ! -e "$FACTORY_HOME/board.tsv"
t "AC-4 exactly two temp files, one per PID" test "$(find "$FACTORY_HOME" -maxdepth 1 -name 'board.tsv.*.tmp' | grep -c .)" = 2
rm -f "$T/holdsnap"
wait "$A"; ra=$?; wait "$B"; rb=$?
t "AC-4 dispatch A exits 0" test "$ra" = 0
t "AC-4 dispatch B exits 0" test "$rb" = 0
t "AC-4 no temp file is left" test "$(find "$FACTORY_HOME" -maxdepth 1 -name 'board.tsv.*.tmp' | grep -c .)" = 0
t "AC-4 board.tsv is one whole read: one line in the board's format" grep -Eq "^($A|$B)	Coding	I_1\$" "$FACTORY_HOME/board.tsv"
t "AC-4 ... and nothing else (no clobbered or doubled content)" test "$(grep -c . "$FACTORY_HOME/board.tsv")" = 1

# a failed read leaves the board.tsv before it alone and no temp file
fresh; printf '7\tCoding\tI_7\n' > "$FACTORY_HOME/board.tsv"; export BOARD_FAIL=1
out="$(bash "$D" 2>&1)"; rc=$?
t "AC-4 a failed board read exits 1" test "$rc" = 1
t "AC-4 ... leaves the previous board.tsv as it was" test "$(cat "$FACTORY_HOME/board.tsv")" = "$(printf '7\tCoding\tI_7')"
t "AC-4 ... removes its temp file (the partial read does not stay)" test "$(find "$FACTORY_HOME" -maxdepth 1 -name 'board.tsv.*.tmp' | grep -c .)" = 0
has "$out" "dispatch: board read failed" "AC-4 no language: the failure line is English"
unset BOARD_FAIL
finish
