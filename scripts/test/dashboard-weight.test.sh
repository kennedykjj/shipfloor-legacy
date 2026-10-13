#!/usr/bin/env bash
# #133 AC-6: the owner changes a card's weight in Spec Review (the drawer's decision, POST .../weight, `shipfloor weight`):
# one commit on the card's branch, pushed; the card shows the new weight and the next run takes its model.
# #133 AC-8: the card shows its weight, and the Sessions tab (and the Feed) the model each session ran on, the
# stepped-up one included.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
W="$(mktemp -d)"   # the project's worktrees
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
printf 'shop\t%s\t%s\tmain\n' "$(new_repo)" "$W" > "$H/registry.tsv"

# card 7: its branch on a bare origin, its worktree with a spec refined before weights existed
ORIGIN="$(mktemp -d)"; git init -q --bare "$ORIGIN"
git clone -q "$(new_repo)" "$W/7" 2>/dev/null; git -C "$W/7" checkout -q -b feat/7-the-thing
git -C "$W/7" config user.email t@t; git -C "$W/7" config user.name t
SPEC="docs/superpowers/specs/2026-10-12-the-thing-design.md"; mkdir -p "$W/7/docs/superpowers/specs"
printf '# The thing — spec\n\n**Issue:** #7 · **Branch:** `feat/7-the-thing` · **Date:** 2026-10-12\n**Roles:** PO, Tech Lead\n\n## Product\n- **AC-1** — x\n\n## Decisions\n- **Weight:** kept out of the header on purpose\n' > "$W/7/$SPEC"
git -C "$W/7" add -A; git -C "$W/7" commit -qm "docs(the-thing): spec for #7"
git -C "$W/7" remote set-url origin "$ORIGIN"; git -C "$W/7" push -q -u origin feat/7-the-thing 2>/dev/null
# card 8: a worktree, no spec yet (Refine has not ended)
git clone -q "$(new_repo)" "$W/8" 2>/dev/null; git -C "$W/8" checkout -q -b feat/8-other
printf '7\tSpec Review\n8\tTechnical Refinement\n' > "$P/board.tsv"
printf 'PVTI_7\t7\t👤 Spec Review\nPVTI_8\t8\t🤖 Technical Refinement\n' > "$FAKE_GH_DIR/items.tsv"
# the owner's review marks and the review page: a weight change touches neither
printf '<html><head></head><body>review</body></html>' > "$P/reviews/7.html"
printf '{"rev":"r1","marks":{"a":{"s":"ok","n":""}}}' > "$P/reviews/7.marks.json"
before_page="$(cat "$P/reviews/7.html")"; before_marks="$(cat "$P/reviews/7.marks.json")"

# AC-8: two develop runs of card 7 today: sonnet failed build and stepped up, the second ran on opus
T="$C/projects/C--x--shipfloor-projects-shop-control"; mkdir -p "$T"
at() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
R1="$(at '-3 hours')" R1E="$(at '-170 minutes')" R2="$(at '-2 hours')" R2E="$(at '-110 minutes')"
{ echo "== start /sf:develop 7 $R1 pid=11 model=sonnet weight=standard"
  echo "== end /sf:develop 7 exit=0 $R1E"
  echo "== step-up /sf:develop 7 sonnet -> opus: gate build failed $R1E"
  echo "== start /sf:develop 7 $R2 pid=12 model=opus weight=standard"
  echo "== end /sf:develop 7 exit=0 $R2E"; } > "$P/logs/$(date +%F)-7-develop.log"
sess() {  # sess <id> <start> <transcript model>
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<command-name>/sf:develop</command-name>\\n<command-args>7</command-args>"}}\n' "$2" > "$T/$1.jsonl"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"m-%s","model":"%s","usage":{"input_tokens":1000,"output_tokens":10}}}\n' "$2" "$1" "$3" >> "$T/$1.jsonl"
}
sess s1 "$(at '-179 minutes')" claude-sonnet-5-5
sess s2 "$(at '-119 minutes')" claude-opus-5-5

export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
H_TOK="X-Shipfloor-Token: $tok"
card() { curl -s -H "$H_TOK" "$base/api/card/shop/$1" | $PY -c '
import json, sys
c = json.load(sys.stdin)
try:
    print(eval(sys.argv[1]))
except Exception as e:
    print("ERR", type(e).__name__, e, str(c)[:300])' "$2" 2>&1; }
post() { local out; out="$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d "$2" "$base/api/card/shop/$1/weight")"; CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"; }
is() { [ "$1" = "$2" ] && pass "$3" || fail "$3: got '${1:0:300}', want '$2'"; }
lines() { grep -c '^\*\*Weight:\*\*' "$W/7/$SPEC"; }
weight_of() { (export FACTORY_CONFIG="$P/factory.yml" FACTORY_HOME="$P" FACTORY_WT_ROOT="$W"; bash -c "source '$FACTORY_DIR/lib/project.sh'; shipfloor_card_weight $1"); }

# AC-8: the card shows its weight; a spec with no weight line reads as standard, and says so
AC="AC-8"
is "$(card 7 '(c["weight"], c["weight_set"])')" "('standard', False)" "AC-8 a spec with no weight line: the card shows standard, not set"
is "$(card 7 'c["weight_models"]')" "{'light': 'sonnet', 'standard': 'sonnet', 'heavy': 'opus'}" "AC-8 the card says which model Develop takes for each weight"
is "$(card 8 '(c["weight"], c["weight_set"])')" "(None, False)" "AC-8 a card with no spec yet shows no weight"
is "$(card 9 'c["weight"]')" "None" "AC-8 a card with no worktree shows no weight"
is "$(card 7 '[(s["model"], s["stepped"]) for s in c["sessions"]]')" "[('sonnet', None), ('opus', {'from': 'sonnet', 'to': 'opus', 'gates': ['build']})]" "AC-8 Sessions: the model each session ran on, the stepped-up one with where it came from and the gate"
is "$(card 7 '[(r["model"], r["again"]) for r in c["runs"]]')" "[('sonnet', 'opus'), ('opus', None)]" "AC-8 the runs carry their model, the failed one what runs again"
got="$(curl -s -H "$H_TOK" "$base/api/feed" | $PY -c 'import json,sys; print([(e.get("model"), e.get("stepped"), e.get("again")) for e in json.load(sys.stdin)["events"] if e.get("issue") == 7])')"
is "$got" "[('sonnet', None, 'opus'), ('opus', {'from': 'sonnet', 'to': 'opus', 'gates': ['build']}, None)]" "AC-8 the Feed names both models and the gate"
# a session whose run named no model shows the transcript's
printf '== start /sf:validate 7 %s pid=13\n' "$(at '-1 hours')" > "$P/logs/$(date +%F)-7-validate.log"
printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<command-name>/sf:validate</command-name>\\n<command-args>7</command-args>"}}\n{"type":"assistant","timestamp":"%s","message":{"id":"m-v","model":"claude-haiku-5-5","usage":{"input_tokens":5,"output_tokens":1}}}\n' "$(at '-59 minutes')" "$(at '-59 minutes')" > "$T/v1.jsonl"
is "$(card 7 '[s["model"] for s in c["sessions"] if s["stage"] == "validate"]')" "['claude-haiku-5-5']" "AC-8 with no model on the start line, the transcript's main model"
rm -f "$P/logs/$(date +%F)-7-validate.log" "$T/v1.jsonl"

# AC-6: the owner sets heavy: one header line, one commit, pushed; the card and the next run follow it
AC="AC-6"
post 7 '{"weight":"heavy"}'
is "$CODE" 200 "AC-6 setting the weight answers 200"
is "$BODY" '{"weight": "heavy", "model": "opus"}' "AC-6 the answer names the weight and the model Develop takes for it"
is "$(lines)" 1 "AC-6 the spec has one weight line"
is "$(sed -n '5p' "$W/7/$SPEC")" "**Weight:** heavy" "AC-6 the line sits under the header's last field"
is "$(git -C "$W/7" log -1 --format=%s)" "docs(the-thing): weight heavy for #7" "AC-6 one commit, named for the card"
is "$(git -C "$ORIGIN" log -1 --format=%s feat/7-the-thing)" "docs(the-thing): weight heavy for #7" "AC-6 the commit is pushed to the card's branch"
is "$(git -C "$W/7" status --porcelain)" "" "AC-6 the worktree is left clean"
is "$(card 7 '(c["weight"], c["weight_set"])')" "('heavy', True)" "AC-6 the card shows the new weight"
is "$(weight_of 7)" heavy "AC-6 the next run reads heavy (and starts on its model)"
post 7 '{"weight":"light"}'
is "$(lines)" 1 "AC-6 a second change replaces the line"
is "$(weight_of 7)" light "AC-6 the next run follows the newest weight"
is "$(git -C "$W/7" log --format=%s | grep -c 'weight .* for #7')" 2 "AC-6 one commit per change"
is "$(cat "$P/reviews/7.html")" "$before_page" "AC-6 the review page is not rebuilt"
is "$(cat "$P/reviews/7.marks.json")" "$before_marks" "AC-6 the owner's review marks stay"
# the refine skill tells a weight commit from a spec commit
case "$(cat "$FACTORY_DIR/../skills/refine/SKILL.md")" in *'`weight ... for #<n>` commit is not one'*) pass "AC-6 refine's rework rule skips the owner's weight commit" ;; *) fail "AC-6 the refine skill does not tell a weight commit from a spec commit" ;; esac

# refused: another value, a card out of Spec Review, a live run, a push that fails (the commit is undone)
post 7 '{"weight":"medium"}'
is "$CODE" 400 "AC-6 a value that is not a weight is refused"
head="$(git -C "$W/7" rev-parse HEAD)"
printf 'PVTI_7\t7\t👤 Ready for Dev\n' > "$FAKE_GH_DIR/items.tsv"
post 7 '{"weight":"heavy"}'
is "$CODE" 409 "AC-6 a card no longer in Spec Review is refused with 409"
is "$BODY" '{"error": "the card is no longer in Spec Review."}' "AC-6 the 409 says why"
printf 'PVTI_7\t7\t👤 Spec Review\n' > "$FAKE_GH_DIR/items.tsv"
mkdir -p "$P/locks/refine-7.lock"; printf '%s %s 7\n' "$$" "$(date +%s)" > "$P/locks/refine-7.lock/info"
post 7 '{"weight":"heavy"}'
is "$CODE" 409 "AC-6 a card with a live run is refused"
rm -rf "$P/locks/refine-7.lock"
git -C "$W/7" remote set-url origin "$ORIGIN.gone"
post 7 '{"weight":"heavy"}'
is "$CODE" 500 "AC-6 a push that fails answers 500"
case "$BODY" in *"could not push feat/7-the-thing"*) pass "AC-6 the 500 names the push" ;; *) fail "AC-6 the 500 says: ${BODY:0:300}" ;; esac
is "$(git -C "$W/7" rev-parse HEAD)" "$head" "AC-6 a failed push undoes the commit"
is "$(weight_of 7)" light "AC-6 and leaves the weight as it was"
git -C "$W/7" remote set-url origin "$ORIGIN"
is "$(card 7 'c["weight"]')" light "AC-6 the card still shows the weight that was saved"
# the command itself, outside the dashboard
out="$(SHIPFLOOR_HOME="$H" bash "$FACTORY_DIR/shipfloor" weight shop 7 huge 2>&1)"; rc=$?
is "$rc" 2 "AC-6 shipfloor weight refuses another value with exit 2"
out="$(SHIPFLOOR_HOME="$H" bash "$FACTORY_DIR/shipfloor" weight shop 7 standard 2>&1)"; rc=$?
is "$rc:$out" "0:weight standard" "AC-6 shipfloor weight sets it from the command line"
case "$(bash "$FACTORY_DIR/shipfloor" 2>&1)" in *"weight <slug> <n> <light|standard|heavy>"*) pass "AC-6 shipfloor's usage lists weight" ;; *) fail "AC-6 shipfloor's usage has no weight line" ;; esac

# the page carries the drawer's weight, the Sessions tag and the Feed's pieces; the pt-BR catalog has them
page="$(curl -s "$base/")"
for s in 'id="weight"' "weight: " "Develop will run on " "Saving…" "Weight is now " "The weight was not changed: " "stepped up" "Ran one model up after " "stepped up from " "runs again on " "/weight\`"; do
  case "$page" in *"$s"*) pass "AC-8 the page carries '$s'" ;; *) fail "AC-8 the page has no '$s'" ;; esac
done
got="$($PY -I -c '
import json, re, sys
sys.stdout.reconfigure(encoding="ascii", errors="backslashreplace")
cat = json.load(open(sys.argv[1], encoding="utf-8"))
def tr(s):
    if s in cat["exact"]:
        return cat["exact"][s]
    for pat, to in cat["rx"]:
        s = re.sub(pat, re.sub(r"\$(\d)", r"\\\1", to), s)
    return s
for s, want in (("weight: heavy", "peso: pesado"), ("weight: standard", "peso: normal"), ("Light (weight)", "Leve"), ("Standard (weight)", "Normal"),
                ("Heavy (weight)", "Pesado"), ("Weight", "Peso"), ("stepped up", "subiu de modelo"),
                ("Develop will run on Sonnet.", "O Develop vai rodar em Sonnet."),
                ("Weight is now heavy. Develop will run on Opus.", "O peso agora " + chr(233) + " pesado. O Develop vai rodar em Opus."),
                ("The weight was not changed: the card is no longer in Spec Review.", "O peso n" + chr(227) + "o foi alterado: o card n" + chr(227) + "o est" + chr(225) + " mais em Revis" + chr(227) + "o da spec."),
                ("stepped up from Sonnet to Opus: the run before failed", "subiu de Sonnet para Opus: a execu" + chr(231) + chr(227) + "o anterior falhou em"),
                ("runs again on Opus", "roda de novo em Opus"), ("Model for Develop, heavy cards", "Modelo de Develop, cards pesados"),
                ("Heavy: default is Opus", "Pesado: o padr" + chr(227) + "o " + chr(233) + " Opus"),
                ("The spec names no weight, so the card runs as standard.", "A spec n" + chr(227) + "o diz o peso, ent" + chr(227) + "o o card roda como normal.")):
    print("ok" if tr(s) == want else "%r comes out %r, want %r" % (s, tr(s), want))' "$(nat "$FACTORY_DIR/lang/dashboard.pt-BR.json")" 2>&1)"
while IFS= read -r line; do
  line="${line%$'\r'}"
  [ "$line" = ok ] && pass "AC-8 pt-BR catalog entry" || fail "AC-8 pt-BR catalog: $line"
done <<< "$got"
finish
