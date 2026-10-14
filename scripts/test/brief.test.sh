#!/usr/bin/env bash
# brief.sh build writes <reviews>/<n>.brief.json: verdict, flags, proven and facts come from scripts only; the notes give prose (#178).
# Reads: scripts/brief.sh (through sf.py brief).
source "$(dirname "$0")/lib.sh"
BRIEF="$FACTORY_DIR/brief.sh"
N=7
TMPD="$(mktemp -d)"
STUB="$TMPD/bin"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/gh"; chmod +x "$STUB/gh"   # gh pr view answers nothing: facts.pr stays empty
export PATH="$STUB:$PATH"

# jget <file> <python expression over d>: prints the value (lists and dicts as JSON)
jget() { "$FACTORY_PYTHON" -I -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); v=eval(sys.argv[2]); sys.stdout.write(v if isinstance(v,str) else json.dumps(v, sort_keys=True))' "$1" "$2" 2>&1; }
# flagtypes <file>: the initial flag types present, sorted and comma-joined (a flag's id or kind is its type)
flagtypes() { jget "$1" '",".join(sorted(next((x for x in (f.get("kind"), f.get("id")) if x in ("migration","outside-architecture","qa-amended","open-question","security","infra-retry")), str(f.get("id"))) for f in d["flags"]))'; }

# mkspec <path> <architecture text> <open questions> <security>
mkspec() {
  printf '# Spec\n\n## Product\n\n- AC-1 something\n\n## Architecture\n_Tech Lead_\n\n%s\n\n## Security\n_Cybersec_ — %s\n\n## Rollback\nn/a\n\n## Open questions\n%s\n' "$2" "$4" "$3" > "$1"
}
# mkwt <name> <path=content>...: a clone of a fresh origin on main with a feature branch carrying the given files; prints the dir
mkwt() {
  local name="$1" o w kv; shift
  o="$TMPD/$name.origin.git"; git clone -q --bare "$(new_repo)" "$o"
  w="$TMPD/$name.wt"; git clone -q "$o" "$w"
  git -C "$w" config user.email t@t; git -C "$w" config user.name t
  git -C "$w" checkout -q -b feat/7-x
  for kv in "$@"; do mkdir -p "$w/$(dirname "${kv%%=*}")"; printf '%s\n' "${kv#*=}" > "$w/${kv%%=*}"; done
  git -C "$w" add -A; git -C "$w" commit -qm change
  echo "$w"
}
# build <worktree> <spec> <out> [more args]: runs brief.sh build from the worktree; stderr in $TMPD/err, exit code in RC
build() {
  local w="$1" spec="$2" out="$3"; shift 3
  ( cd "$w" && bash "$BRIEF" build "$N" --column "Spec Review" --spec "$spec" --head "$(git rev-parse HEAD)" --notes "$FACTORY_HOME/tmp/$N/brief-notes.json" --out "$out" "$@" ) 2> "$TMPD/err"
  RC=$?
}
notes() { mkdir -p "$FACTORY_HOME/tmp/$N"; printf '%s' "$1" > "$FACTORY_HOME/tmp/$N/brief-notes.json"; }
reset_home() { rm -rf "$FACTORY_HOME/tmp" "$FACTORY_HOME/infra" "$FACTORY_HOME/gate-passes" "$FACTORY_HOME/reviews"; mkdir -p "$FACTORY_HOME/reviews"; }

CLEAN_ARCH='Files: `src/a.txt`.'

# ---- AC-1: a clean card gets a routine brief at <reviews>/<n>.brief.json, the fields computed by the script
reset_home
w="$(mkwt clean 'src/a.txt=one')"; head="$(git -C "$w" rev-parse HEAD)"
mkspec "$TMPD/clean.md" "$CLEAN_ARCH" '- none' 'n/a'
notes '{"what":"Adds a.txt.","suggestions":{}}'
mkdir -p "$FACTORY_HOME/gate-passes"
printf '2026-10-14T10:00:00Z\t%s\tbuild\tmain\n' "$head" > "$FACTORY_HOME/gate-passes/p1"
printf '2026-10-14T10:00:00Z\t%s\tforbidden\tmain\n' "0000000000000000000000000000000000000000" > "$FACTORY_HOME/gate-passes/p2"
( cd "$w" && bash "$BRIEF" build "$N" --column "Spec Review" --spec "$TMPD/clean.md" --head "$head" --notes "$FACTORY_HOME/tmp/$N/brief-notes.json" ) 2> "$TMPD/err"; RC=$?
B="$FACTORY_HOME/reviews/$N.brief.json"
if [ "$RC" -eq 0 ] && [ -f "$B" ]; then pass "AC-1 brief.json exists at <reviews>/<n>.brief.json"; else fail "AC-1 no $B (exit $RC): $(cat "$TMPD/err")"; fi
if [ -f "$B" ]; then
  [ "$(jget "$B" 'd["card"]')" = "$N" ] && pass "AC-1 card is the issue number" || fail "AC-1 card: $(jget "$B" 'd.get("card")')"
  [ "$(jget "$B" 'd["column"]')" = "Spec Review" ] && pass "AC-1 column is Spec Review" || fail "AC-1 column: $(jget "$B" 'd.get("column")')"
  [ "$(jget "$B" 'd["verdict"]')" = "routine" ] && pass "AC-1 verdict is routine without flags and since_request" || fail "AC-1 verdict: $(jget "$B" 'd.get("verdict")')"
  [ "$(jget "$B" 'd["flags"]')" = "[]" ] && pass "AC-1 flags are empty on a clean card" || fail "AC-1 flags: $(jget "$B" 'd.get("flags")')"
  [ "$(jget "$B" 'd["since_request"]')" = "[]" ] && pass "AC-1 since_request is empty when absent" || fail "AC-1 since_request: $(jget "$B" 'd.get("since_request")')"
  [ "$(jget "$B" 'd["what"]["text"]')" = "Adds a.txt." ] && pass "AC-1 what.text comes from the notes" || fail "AC-1 what: $(jget "$B" 'd.get("what")')"
  [ "$(jget "$B" '"build" in d["proven"] and "forbidden" not in d["proven"]')" = "true" ] && pass "AC-1 proven lists the gates recorded for the head only" || fail "AC-1 proven: $(jget "$B" 'd.get("proven")')"
  [ "$(jget "$B" '[d["facts"]["files"], d["facts"]["added"], d["facts"]["removed"]]')" = "[1, 1, 0]" ] && pass "AC-1 facts count files, added and removed from the diff" || fail "AC-1 facts: $(jget "$B" 'd.get("facts")')"
  [ "$(jget "$B" 'sorted(set(["card","column","built","verdict","what","flags","since_request","proven","facts","rest"]) - set(d))')" = "[]" ] && pass "AC-1 every contract field is present" || fail "AC-1 missing fields: $(jget "$B" 'sorted(set(["card","column","built","verdict","what","flags","since_request","proven","facts","rest"]) - set(d))')"
  [ "$(find "$FACTORY_HOME/reviews" -type f | wc -l | tr -d ' ')" = 1 ] && pass "AC-1 written atomically: no temp file left" || fail "AC-1 files in reviews: $(find "$FACTORY_HOME/reviews" -type f)"
fi

# ---- AC-1: Staged column, and since_request makes the verdict look
reset_home
notes '{"what":"Adds a.txt."}'
printf '[{"old":"must be fast","new":"must be fast and cheap"}]' > "$TMPD/since.json"
( cd "$w" && bash "$BRIEF" build "$N" --column Staged --spec "$TMPD/clean.md" --head "$head" --notes "$FACTORY_HOME/tmp/$N/brief-notes.json" --since "$TMPD/since.json" --out "$TMPD/staged.json" ) 2> "$TMPD/err"; RC=$?
if [ -f "$TMPD/staged.json" ]; then
  [ "$(jget "$TMPD/staged.json" 'd["column"]')" = "Staged" ] && pass "AC-1 column is Staged" || fail "AC-1 column: $(jget "$TMPD/staged.json" 'd.get("column")')"
  [ "$(jget "$TMPD/staged.json" 'd["verdict"]')" = "look" ] && pass "AC-1 a non-empty since_request makes the verdict look" || fail "AC-1 verdict: $(jget "$TMPD/staged.json" 'd.get("verdict")')"
  [ "$(jget "$TMPD/staged.json" 'd["since_request"]')" = '[{"new": "must be fast and cheap", "old": "must be fast"}]' ] && pass "AC-1 since_request is the input given" || fail "AC-1 since_request: $(jget "$TMPD/staged.json" 'd.get("since_request")')"
  [ "$(jget "$TMPD/staged.json" 'd["flags"]')" = "[]" ] && pass "AC-1 since_request alone raises no flag" || fail "AC-1 flags: $(jget "$TMPD/staged.json" 'd.get("flags")')"
else
  fail "AC-1 no brief for a Staged card (exit $RC): $(cat "$TMPD/err")"
fi

# ---- AC-3: one case per initial flag type: exactly that flag, verdict look
check_flag() {  # check_flag <type> <out>
  if [ ! -f "$2" ]; then fail "AC-3 $1: no brief built (exit $RC): $(cat "$TMPD/err")"; return; fi
  [ "$(flagtypes "$2")" = "$1" ] && pass "AC-3 $1: exactly that flag" || fail "AC-3 $1: flags are '$(flagtypes "$2")'"
  [ "$(jget "$2" 'd["verdict"]')" = "look" ] && pass "AC-3 $1: verdict is look" || fail "AC-3 $1: verdict $(jget "$2" 'd.get("verdict")')"
}

reset_home; notes '{"what":"w"}'
M=api/src/main/resources/db/migration
w="$(mkwt mig "$M/V2__add.sql=ALTER TABLE a ADD COLUMN b text;")"; head="$(git -C "$w" rev-parse HEAD)"
mkspec "$TMPD/mig.md" "Files: \`$M/V2__add.sql\`." '- none' 'n/a'
mkdir -p "$FACTORY_HOME/gate-passes"; printf '2026-10-14T10:00:00Z\t%s\tmigration\tmain spec.md\n' "$head" > "$FACTORY_HOME/gate-passes/m1"
build "$w" "$TMPD/mig.md" "$TMPD/mig.json"; check_flag migration "$TMPD/mig.json"

reset_home; notes '{"what":"w"}'
w="$(mkwt out 'src/a.txt=one' 'src/b.txt=two')"
mkspec "$TMPD/out.md" "$CLEAN_ARCH" '- none' 'n/a'
build "$w" "$TMPD/out.md" "$TMPD/out.json"; check_flag outside-architecture "$TMPD/out.json"
if [ -f "$TMPD/out.json" ]; then
  [ "$(jget "$TMPD/out.json" '" ".join(json.dumps(f) for f in d["flags"]).count("src/b.txt") > 0')" = "true" ] && pass "AC-3 outside-architecture names the file outside" || fail "AC-3 outside-architecture does not name src/b.txt"
fi

reset_home; notes '{"what":"w"}'
w="$(mkwt qa 'src/a.txt=one')"
mkspec "$TMPD/qa.md" "$CLEAN_ARCH" '- none' 'n/a'
printf '{"issue":7,"pipeline":"develop","outcome":"ok","amendments":["scripts/test/x.test.sh: the test asked for a rendered element"]}' > "$FACTORY_HOME/tmp/$N/report.json"
build "$w" "$TMPD/qa.md" "$TMPD/qa.json"; check_flag qa-amended "$TMPD/qa.json"

reset_home; notes '{"what":"w"}'
w="$(mkwt oq 'src/a.txt=one')"
mkspec "$TMPD/oq.md" "$CLEAN_ARCH" '- Should the limit be 10 or 20?' 'n/a'
build "$w" "$TMPD/oq.md" "$TMPD/oq.json"; check_flag open-question "$TMPD/oq.json"

reset_home; notes '{"what":"w"}'
w="$(mkwt sec 'src/a.txt=one')"
mkspec "$TMPD/sec.md" "$CLEAN_ARCH" '- none' 'Tokens are stored hashed; the endpoint checks the owner.'
build "$w" "$TMPD/sec.md" "$TMPD/sec.json"; check_flag security "$TMPD/sec.json"

reset_home; notes '{"what":"w"}'
w="$(mkwt infra 'src/a.txt=one')"
mkspec "$TMPD/infra.md" "$CLEAN_ARCH" '- none' 'n/a'
mkdir -p "$FACTORY_HOME/infra"; : > "$FACTORY_HOME/infra/$N"
build "$w" "$TMPD/infra.md" "$TMPD/infra.json"; check_flag infra-retry "$TMPD/infra.json"

reset_home; notes '{"what":"w"}'
w="$(mkwt clean2 'src/a.txt=one')"
build "$w" "$TMPD/clean.md" "$TMPD/clean2.json"
if [ -f "$TMPD/clean2.json" ]; then
  [ "$(jget "$TMPD/clean2.json" 'd["flags"]')" = "[]" ] && pass "AC-3 a clean card has no flags" || fail "AC-3 clean card flags: $(jget "$TMPD/clean2.json" 'd["flags"]')"
  [ "$(jget "$TMPD/clean2.json" 'd["verdict"]')" = "routine" ] && pass "AC-3 a clean card is routine" || fail "AC-3 clean card verdict: $(jget "$TMPD/clean2.json" 'd["verdict"]')"
else
  fail "AC-3 clean card: no brief built (exit $RC): $(cat "$TMPD/err")"
fi

# ---- AC-2: notes can only give prose; the gates are the script's
LONG_WHAT="$("$FACTORY_PYTHON" -I -c 'print("w" * 400)')"
LONG_SUG="$("$FACTORY_PYTHON" -I -c 'print("s" * 300)')"

# a clean card whose notes claim flags, a verdict and proven gates
reset_home
notes "{\"what\":\"$LONG_WHAT\",\"verdict\":\"look\",\"flags\":[{\"id\":\"security\",\"kind\":\"security\",\"title\":\"x\"}],\"proven\":[\"fake-gate\"],\"since_request\":[{\"old\":\"a\",\"new\":\"b\"}],\"suggestions\":{\"bogus-flag\":\"do it\",\"security\":\"do it\"}}"
w="$(mkwt n1 'src/a.txt=one')"
build "$w" "$TMPD/clean.md" "$TMPD/n1.json"
if [ -f "$TMPD/n1.json" ]; then
  [ "$(jget "$TMPD/n1.json" 'd["verdict"]')" = "routine" ] && pass "AC-2 a verdict in the notes is ignored" || fail "AC-2 verdict: $(jget "$TMPD/n1.json" 'd.get("verdict")')"
  [ "$(jget "$TMPD/n1.json" 'd["flags"]')" = "[]" ] && pass "AC-2 flags and unknown flag ids in the notes are ignored" || fail "AC-2 flags: $(jget "$TMPD/n1.json" 'd.get("flags")')"
  [ "$(jget "$TMPD/n1.json" '"fake-gate" in d["proven"]')" = "false" ] && pass "AC-2 proven in the notes is ignored" || fail "AC-2 proven: $(jget "$TMPD/n1.json" 'd.get("proven")')"
  [ "$(jget "$TMPD/n1.json" 'd["since_request"]')" = "[]" ] && pass "AC-2 since_request in the notes is ignored" || fail "AC-2 since_request: $(jget "$TMPD/n1.json" 'd.get("since_request")')"
  [ "$(jget "$TMPD/n1.json" 'len(d["what"]["text"]) <= 280 and d["what"]["text"].startswith("w")')" = "true" ] && pass "AC-2 a what over 280 characters is cut" || fail "AC-2 what length: $(jget "$TMPD/n1.json" 'len(d["what"]["text"])')"
else
  fail "AC-2 no brief built from notes with extra fields (exit $RC): $(cat "$TMPD/err")"
fi

# a card with one real flag: unknown ids dropped, long suggestion cut, the gates unchanged
reset_home
notes "{\"what\":\"w\",\"verdict\":\"routine\",\"flags\":[],\"proven\":[\"fake-gate\"],\"suggestions\":{\"bogus-flag\":\"x\",\"open-question\":\"$LONG_SUG\"}}"
w="$(mkwt n2 'src/a.txt=one')"
mkspec "$TMPD/n2.md" "$CLEAN_ARCH" '- Should the limit be 10 or 20?' 'n/a'
build "$w" "$TMPD/n2.md" "$TMPD/n2.json"
if [ -f "$TMPD/n2.json" ]; then
  [ "$(flagtypes "$TMPD/n2.json")" = "open-question" ] && pass "AC-2 an unknown flag id adds no flag and the real flag stays" || fail "AC-2 flags: '$(flagtypes "$TMPD/n2.json")'"
  [ "$(jget "$TMPD/n2.json" 'd["verdict"]')" = "look" ] && pass "AC-2 a routine verdict in the notes does not hide a flag" || fail "AC-2 verdict: $(jget "$TMPD/n2.json" 'd.get("verdict")')"
  [ "$(jget "$TMPD/n2.json" '"fake-gate" in d["proven"]')" = "false" ] && pass "AC-2 proven stays the script's" || fail "AC-2 proven: $(jget "$TMPD/n2.json" 'd.get("proven")')"
  [ "$(jget "$TMPD/n2.json" '0 < len(d["flags"][0].get("suggestion") or "") <= 120 and d["flags"][0]["suggestion"].startswith("s")')" = "true" ] && pass "AC-2 a suggestion over 120 characters is cut at the limit" || fail "AC-2 suggestion: $(jget "$TMPD/n2.json" 'd["flags"][0].get("suggestion")')"
  [ "$(jget "$TMPD/n2.json" 'json.dumps(d).count("bogus-flag")')" = "0" ] && pass "AC-2 the unknown flag id appears nowhere" || fail "AC-2 bogus-flag is in the brief"
else
  fail "AC-2 no brief built (exit $RC): $(cat "$TMPD/err")"
fi

# ---- AC-4: a failing run is one line on stderr and exit 0, never a block
reset_home; notes '{"what":"w"}'
w="$(mkwt f1 'src/a.txt=one')"
oneline_skipped() {  # oneline_skipped <label> <out file that must not exist>
  [ "$RC" -eq 0 ] && pass "AC-4 $1: exit 0" || fail "AC-4 $1: exit $RC"
  [ "$(wc -l < "$TMPD/err" | tr -d ' ')" = 1 ] && pass "AC-4 $1: one line on stderr" || fail "AC-4 $1: stderr is: $(cat "$TMPD/err")"
  case "$(cat "$TMPD/err")" in "brief: skipped: "?*) pass "AC-4 $1: the line says brief: skipped: <reason>" ;; *) fail "AC-4 $1: stderr is: $(cat "$TMPD/err")" ;; esac
  [ ! -e "$2" ] && pass "AC-4 $1: no brief written" || fail "AC-4 $1: $2 exists"
}
build "$w" "$TMPD/does-not-exist.md" "$TMPD/f1.json"; oneline_skipped "a missing spec" "$TMPD/f1.json"
( cd "$w" && bash "$BRIEF" build "$N" --column "No Such Column" --spec "$TMPD/clean.md" --head "$(git -C "$w" rev-parse HEAD)" --notes "$FACTORY_HOME/tmp/$N/brief-notes.json" --out "$TMPD/f2.json" ) 2> "$TMPD/err"; RC=$?
oneline_skipped "an unknown column" "$TMPD/f2.json"
( cd "$w" && bash "$BRIEF" build "$N" --column Staged --spec "$TMPD/clean.md" --head "$(git -C "$w" rev-parse HEAD)" --notes "$FACTORY_HOME/tmp/$N/brief-notes.json" --out "$TMPD/f3.json" --since "$TMPD/does-not-exist.json" ) 2> "$TMPD/err"; RC=$?
[ "$RC" -eq 0 ] && pass "AC-4 a missing --since file: exit 0" || fail "AC-4 a missing --since file: exit $RC"
[ "$(wc -l < "$TMPD/err" | tr -d ' ')" -le 1 ] && pass "AC-4 a missing --since file: at most one line on stderr" || fail "AC-4 a missing --since file: stderr is: $(cat "$TMPD/err")"
( cd "$TMPD" && bash "$BRIEF" build "$N" --column Staged --spec "$TMPD/clean.md" --head abc --notes "$FACTORY_HOME/tmp/$N/brief-notes.json" --out "$TMPD/f4.json" ) 2> "$TMPD/err"; RC=$?
[ "$RC" -eq 0 ] && pass "AC-4 outside a git repository: exit 0" || fail "AC-4 outside a git repository: exit $RC"
[ "$(wc -l < "$TMPD/err" | tr -d ' ')" -le 1 ] && pass "AC-4 outside a git repository: at most one line on stderr" || fail "AC-4 outside a git repository: stderr is: $(cat "$TMPD/err")"
: > "$TMPD/is-a-file"
( cd "$w" && bash "$BRIEF" build "$N" --column Staged --spec "$TMPD/clean.md" --head "$(git -C "$w" rev-parse HEAD)" --notes "$FACTORY_HOME/tmp/$N/brief-notes.json" --out "$TMPD/is-a-file/x/y.json" ) 2> "$TMPD/err"; RC=$?
[ "$RC" -eq 0 ] && pass "AC-4 an unwritable --out: exit 0" || fail "AC-4 an unwritable --out: exit $RC"

finish
