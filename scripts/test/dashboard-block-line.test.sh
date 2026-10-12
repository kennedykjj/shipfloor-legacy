#!/usr/bin/env bash
# #119 AC-1 to AC-3: a blocked card says why in the list. The server reads the factory's note and gives each card
# of GET /api/overview `block_line` (the owner's call, or "Failed gate: <name>", or "") and `block_cost`; the page
# writes <p class="pwhy"> only when there is a reason, and an infrastructure block reads its own sentence.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews" "$P/cost" "$C/projects"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"

# a gh of this test: the label lists and the comments of each card are files, so each card has its own note
G="$FAKE_GH_DIR/gh"
cat > "$G" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_GH_DIR"; args="$*"
case "$args" in
  *issueOrPullRequest*)
    out=""; sep=""
    for n in $(echo "$args" | grep -o 'issueOrPullRequest(number: [0-9]*' | grep -o '[0-9]*$'); do out="$out$sep\"i$n\":{\"title\":\"Card $n\"}"; sep=","; done
    echo "{\"data\":{\"repository\":{$out}}}" ;;
  "api user") echo '{"login":"factory"}' ;;
  "api repos/acme/shop/issues?labels=blocked:infra"*) cat "$d/infra" ;;
  "api repos/acme/shop/issues?labels=blocked&"*) cat "$d/owner" ;;
  "api repos/acme/shop/issues/"*"/comments"*)
    n="$(echo "$args" | sed -E 's#.*issues/([0-9]+)/comments.*#\1#')"
    printf '[[%s]]\n' "$(cat "$d/comments-$n" 2>/dev/null)" ;;
  *) echo "gh stand-in: unexpected: $args" >&2; exit 9 ;;
esac
EOF
chmod +x "$G"
echo '[{"number":24}]' > "$FAKE_GH_DIR/infra"
echo '[{"number":21},{"number":22},{"number":23},{"number":25},{"number":26},{"number":28}]' > "$FAKE_GH_DIR/owner"
note() { printf '[{"body":"%s"}]' "$2" > "$FAKE_GH_DIR/comments-$1"; }
note 21 'Factory validate, step 2 (gates): blocked.\n- **Owner must decide:** keep the `48h` rule or drop it\nTried: a diff of the files.'
note 22 'Factory validate, step 2 (gates): blocked.\n**Failed gate:** e2e\nTried: a rerun.'
note 23 'Factory validate, step 2 (gates): blocked.\nTried: a rerun; nothing changed.'
note 24 '**Validate blocked (infrastructure)**: stack down'
note 25 'Cost limit: blocked.\nOwner must decide: raise the limit or stop.'
note 26 'Cost limit: blocked.\nSpent more than the limit.'
note 28 "Factory validate, step 2 (gates): blocked.\nOwner must decide: $(printf 'x%.0s' $(seq 1 700))"
printf '{"total": 9.5, "limit": 5, "baseline": 4.0}\n' > "$P/cost/25.json"
printf '21\tCoding\n22\tCoding\n23\tCoding\n24\tCoding\n25\tCoding\n26\tCoding\n27\tCoding\n28\tCoding\n' > "$P/board.tsv"

export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$G"
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
curl -s -H "X-Shipfloor-Token: $tok" "$base/api/overview" > "$FAKE_GH_DIR/overview.json"

out="$($PY -I - "$FAKE_GH_DIR/overview.json" "$FACTORY_DIR/dashboard.html" <<'PY'
import json, re, sys
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
try:
    cards = {c["issue"]: c for c in json.load(open(sys.argv[1], encoding="utf-8"))["projects"][0]["cards"]}
except Exception as e:
    cards = {}
    res.append(f"no the overview could not be read: {e}")
def get(n, k): return cards.get(n, {}).get(k, "<absent>")
h = open(sys.argv[2], encoding="utf-8").read()
def src(start):
    i = h.find(start)
    if i < 0: return ""
    j = h.find("\n}", i)
    return h[i:j + 2] if j > 0 else h[i:]

# AC-1: the owner's call is the line
check("AC-1 block_line is the owner's call without its label, first letter in capitals", get(21, "block_line") == "Keep the 48h rule or drop it", f"card 21 block_line = {get(21, 'block_line')!r}")
check("AC-1 with no owner's call, block_line names the failed gate", get(22, "block_line") == "Failed gate: e2e", f"card 22 block_line = {get(22, 'block_line')!r}")
check("AC-1 block_line is bounded at 500 characters", get(28, "block_line") != "<absent>" and 100 < len(get(28, "block_line")) <= 500, f"card 28 block_line has {len(str(get(28, 'block_line')))} characters")
ps = src("function passHtml")
check("AC-1 passHtml writes <p class=\"pwhy\"> from c.block_line", 'class="pwhy"' in ps and "block_line" in ps, "passHtml has no p.pwhy fed by c.block_line")
check("AC-1 the whole reason is in title, the text goes through esc", bool(re.search(r"pwhy[^`]*title=[^`]*block_line", ps)) and bool(re.search(r"esc\(\s*c\.block_line", ps)), "p.pwhy has no title with c.block_line, or its text is not escaped")
check("AC-1 the line sits above the stub row, outside the title button", 0 <= ps.find("pwhy") < ps.find('class="stub"', ps.find("pwhy")) and ps.find("pwhy") > ps.find("</button>"), "p.pwhy is not between the title button and div.stub")
check("AC-1 .pwhy is one line cut by CSS", bool(re.search(r"\.pwhy\s*\{[^}]*white-space:\s*nowrap", h)) and bool(re.search(r"\.pwhy\s*\{[^}]*overflow:\s*hidden", h)) and bool(re.search(r"\.pwhy\s*\{[^}]*text-overflow:\s*ellipsis", h)), ".pwhy has no nowrap / hidden / ellipsis rule")
check("AC-1 the caption stays Blocked · waits for your call", "Blocked · waits for your call" in ps, "the blocked caption changed")
check("AC-1 a cost block says Blocked · cost limit with the spend sentence", "Blocked · cost limit" in ps and "block_cost" in ps, "passHtml does not tell a cost block from block_cost")
check("AC-1 the overview carries block_cost for a cost block", isinstance(get(25, "block_cost"), dict) and get(25, "block_cost").get("total") == 5.5 and get(25, "block_cost").get("limit") == 5 and get(25, "block_cost").get("baseline") == 4.0, f"card 25 block_cost = {get(25, 'block_cost')!r}")

# AC-2: no reason, no line
check("AC-2 a note with neither the owner's call nor a failed gate gives block_line \"\"", get(23, "block_line") == "", f"card 23 block_line = {get(23, 'block_line')!r}")
check("AC-2 a card that is not blocked has block_line \"\" and block_cost null", get(27, "block_line") == "" and get(27, "block_cost") is None, f"card 27 = {get(27, 'block_line')!r}, {get(27, 'block_cost')!r}")
check("AC-2 passHtml writes the line only when block_line is not empty", bool(re.search(r"c\.block_line\s*\?|if\s*\(\s*c\.block_line|c\.block_line\s*&&", ps)), "passHtml does not test c.block_line before writing p.pwhy")
check("AC-2 a cost block with no readable marker has block_cost null", get(26, "block_cost") is None and get(26, "block_line") == "", f"card 26 = {get(26, 'block_line')!r}, {get(26, 'block_cost')!r}")

# AC-3: infrastructure
check("AC-3 an infrastructure block has block_line \"\" and block_cost null", get(24, "blocked") == "infra" and get(24, "block_line") == "" and get(24, "block_cost") is None, f"card 24 = {get(24, 'blocked')!r}, {get(24, 'block_line')!r}, {get(24, 'block_cost')!r}")
check("AC-3 a cost block has block_line \"\" (block_cost tells it)", get(25, "block_line") == "", f"card 25 block_line = {get(25, 'block_line')!r}")
ww = src("function whyWaits")
check("AC-3 the waiting tile says Infrastructure failed; the factory retries once", "Infrastructure failed; the factory retries once" in ww, "whyWaits(infra) does not say 'Infrastructure failed; the factory retries once'")
check("AC-3 the old infrastructure sentence is gone", "Blocked by infrastructure; the factory retries it" not in h, "the old sentence is still in the page")
m = re.search(r'const RAW = "([^"]*)"', h)
check("AC-3 an infrastructure card does not enter Yours", 'blocked === "owner"' in h[h.find("const waiting"):h.find("const waiting") + 400], "waiting() no longer filters on blocked owner")
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
