#!/usr/bin/env bash
# suite: integration
# The decision brief on today's screen (#179). A Spec Review or Staged card with a brief (<reviews>/<n>.brief.json,
# made by #178) shows it in the drawer above the decision: verdict, what you approve, what needs your eyes, what changed
# since the request, what the gates proved, the folded rest; each block with its origin. The server reads it
# defensively (card()'s brief, the overview's verdict and flags); the list row says the verdict in one word.
# Server cases run a real dashboard on a fixture home; page cases run briefHTML and passHtml in node when there is one.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews" "$P/cost"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
# 7 Spec Review + 2 flags, 8 Staged routine, 9 Spec Review no brief, 10 unreadable, 11 not an object, 12 Coding with a brief
for n in 7:"Spec Review" 8:Staged 9:"Spec Review" 10:"Spec Review" 11:Staged 12:Coding; do printf '%s\t%s\n' "${n%%:*}" "${n#*:}"; done > "$P/board.tsv"
echo '[]' > "$FAKE_GH_DIR/label-blocked"
cat > "$P/reviews/7.brief.json" <<'JSON'
{"card":7,"column":"Spec Review","built":"2026-10-14T10:00:00Z","verdict":"look",
 "what":{"text":"Adds the brief to the drawer","by":"product owner"},
 "flags":[{"id":"f1","kind":"scope","title":"Touches auth","detail":"Why","hunk":"@@ -1 +1 @@","source":"review","suggestion":"Drop the auth change"},
          {"id":"f2","kind":"gate","title":"Coverage fell","detail":"d","hunk":"","source":"gate"}],
 "since_request":[{"old":"The note is optional","new":"The note is required"}],
 "proven":["build","acceptance-intact"],"facts":{"pr":12,"files":3,"added":10,"removed":2,"statements":4},"rest":["Renames a helper"]}
JSON
cat > "$P/reviews/8.brief.json" <<'JSON'
{"card":8,"column":"Staged","built":"2026-10-14T10:00:00Z","verdict":"routine","what":{"text":"Fixes a typo","by":"review agent"},
 "flags":[],"since_request":[],"proven":["build"],"facts":{"pr":13,"files":1,"added":1,"removed":1,"statements":0},"rest":[]}
JSON
printf '{ not json' > "$P/reviews/10.brief.json"
printf '[1, 2]' > "$P/reviews/11.brief.json"
cp "$P/reviews/8.brief.json" "$P/reviews/12.brief.json"

export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
curl -s -H "X-Shipfloor-Token: $tok" "$base/api/overview" > "$FAKE_GH_DIR/overview.json"
for n in 7 8 9 10 11 12; do curl -s -H "X-Shipfloor-Token: $tok" "$base/api/card/shop/$n" > "$FAKE_GH_DIR/card-$n.json"; done
want() { [ "$2" = "$3" ] && pass "$1" || fail "$1: got '$2', want '$3'"; }
brief() {  # brief <n>: card()'s brief as compact JSON, "<missing>" when the key is absent
  $PY -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(json.dumps(d["brief"], sort_keys=True) if "brief" in d else "<missing>")' "$(nat "$FAKE_GH_DIR/card-$1.json")" | tr -d '\r'
}
row() {  # row <n>: "verdict|flags" of the card in the overview
  $PY -c 'import json,sys; c=next(c for c in json.load(open(sys.argv[1], encoding="utf-8"))["projects"][0]["cards"] if c["issue"]==int(sys.argv[2])); print(str(c.get("verdict","<missing>"))+"|"+str(c.get("flags","<missing>")))' "$(nat "$FAKE_GH_DIR/overview.json")" "$1" | tr -d '\r'
}
file_json() { $PY -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), sort_keys=True))' "$(nat "$1")" | tr -d '\r'; }

# AC-1: the card carries the brief as the file says it
want "AC-1 a Spec Review card carries its brief" "$(brief 7)" "$(file_json "$P/reviews/7.brief.json")"
want "AC-1 a Staged card carries its brief" "$(brief 8)" "$(file_json "$P/reviews/8.brief.json")"
# AC-2: no brief, an unreadable one, or one that is not an object: null, no error
want "AC-2 no file: the brief is null" "$(brief 9)" "null"
want "AC-2 an unparseable file: the brief is null" "$(brief 10)" "null"
want "AC-2 a file that is not an object: the brief is null" "$(brief 11)" "null"
# AC-7: the list row knows the verdict and the number of flags, only for the cards waiting on the owner
want "AC-7 a look brief: verdict and flag count" "$(row 7)" "look|2"
want "AC-7 a routine brief: verdict, no flags" "$(row 8)" "routine|0"
want "AC-7 no brief: no verdict" "$(row 9)" "None|0"
want "AC-7 an unreadable brief: no verdict" "$(row 10)" "None|0"
want "AC-7 a card the factory holds has no verdict, brief or not" "$(row 12)" "None|0"

# the page, in node: briefHTML and passHtml are run on their own
cat > "$FAKE_GH_DIR/page.js" <<'JS'
const fs = require("fs");
const [, , htmlPath, enPath] = process.argv;
const h = fs.readFileSync(htmlPath, "utf8"), EN = JSON.parse(fs.readFileSync(enPath, "utf8")).messages;
const out = [];
const check = (name, cond, why) => out.push(cond ? "ok " + name : "no " + name + ": " + String(why).replace(/\s+/g, " "));
const grab = (re) => { let s = ""; for (const m of h.matchAll(re)) { const i = m.index; s += h.slice(i, h.indexOf("\n}", i) + 2) + "\n"; } return s; };
const core = h.slice(h.indexOf("const LANG = "), h.indexOf("// the static markup"));
const dollar = () => ({ textContent: JSON.stringify({ language: "en", messages: EN, en: EN }) });
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const strip = (s) => s.replace(/<[^>]*>/g, "").replace(/&middot;/g, "·");

// ---- briefHTML
const bsrc = grab(/^function brief\w*\(/gm);
let render = null;
if (bsrc) { try { render = new Function("$", "esc", core + bsrc + "return briefHTML;")(dollar, esc); } catch (e) { check("briefHTML loads on its own, with only t and esc", false, String(e)); } }
else check("briefHTML exists", false, "no function briefHTML in the page");
const run = (b) => { try { return render(b); } catch (e) { return "THROW " + e; } };

const look = { card: 7, column: "Spec Review", built: "2026-10-14T10:00:00Z", verdict: "look", what: { text: "Adds the brief to the drawer", by: "product owner" },
  flags: [{ id: "f1", kind: "scope", title: "Touches auth", detail: "Why", hunk: "@@ -1 +1 @@", source: "review", suggestion: "Drop the auth change" },
          { id: "f2", kind: "gate", title: "Coverage fell", detail: "d", hunk: "", source: "gate" }],
  since_request: [{ old: "The note is optional", new: "The note is required" }], proven: ["build", "acceptance-intact"],
  facts: { pr: 12, files: 3, added: 10, removed: 2, statements: 4 }, rest: ["Renames a helper", "Fixes a comment"] };
const routine = { card: 8, column: "Staged", built: "2026-10-14T10:00:00Z", verdict: "routine", what: { text: "Fixes a typo", by: "review agent" },
  flags: [], since_request: [], proven: ["build"], facts: { pr: 13, files: 1, added: 1, removed: 1, statements: 0 }, rest: ["Renames a helper"] };
const CAPS = ["What you approve", "Needs your eyes", "Since your request", "What the gates proved"];
const restCap = /The rest \(\d+\)/;
const tagRe = /<[a-z]+[^>]*class="[^"]*\btag\b[^"]*"[^>]*>([\s\S]*?)<\/[a-z]+>/;
const clone = (o, patch) => Object.assign(JSON.parse(JSON.stringify(o)), patch);

if (render) {
  const L = run(look), R = run(routine);
  // AC-1: starts with the verdict pill, ok for routine, accent for look
  const pill = (s) => { const m = s.match(tagRe); return m ? { open: m[0].slice(0, m[0].indexOf(">") + 1), text: strip(m[1]).trim(), at: m.index } : null; };
  const lp = pill(L), rp = pill(R);
  check("AC-1 the brief starts with the verdict pill, before the first block", !!lp && lp.at < L.indexOf("What you approve") && !strip(L.slice(0, lp.at)).trim(), L.slice(0, 200));
  check("AC-1 a look brief with 2 flags says '2 points'", lp?.text === "2 points", lp?.text);
  check("AC-1 a look pill takes the accent (sand)", /sand/.test(lp?.open || ""), lp?.open);
  check("AC-1 a routine pill says 'routine' in the ok color", rp?.text === "routine" && /\bok\b/.test(rp?.open || ""), JSON.stringify(rp));
  const one = pill(run(clone(look, { flags: [look.flags[0]] })));
  check("AC-1 one flag reads '1 point'", one?.text === "1 point", one?.text);
  check("AC-1 the blocks follow the pill in order", CAPS.every((c) => L.includes(c)) && CAPS.map((c) => L.indexOf(c)).every((v, i, a) => !i || a[i - 1] < v) && L.search(restCap) > L.indexOf("What the gates proved"), CAPS.map((c) => L.indexOf(c)).join(","));
  check("AC-1 the content shows: what, flag title, old and new statement, gate names, rest", ["Adds the brief to the drawer", "Touches auth", "The note is optional", "The note is required", "acceptance-intact", "Renames a helper"].every((x) => L.includes(x)), "something is missing");
  // AC-2: no brief, or a brief that gives nothing to show
  check("AC-2 no brief renders nothing", run(null) === "" && run(undefined) === "", JSON.stringify([run(null), run(undefined)]));
  const junk = run({ verdict: "look", what: 5, flags: "x", since_request: {}, proven: "a", rest: 3 });
  check("AC-2 mistyped fields drop their blocks and never throw", !junk.startsWith("THROW") && !CAPS.some((c) => junk.includes(c)) && !restCap.test(junk), junk.slice(0, 200));
  // AC-3: a block only with content; the rest starts folded
  const bare = run(clone(look, { since_request: [], proven: [], rest: [] }));
  check("AC-3 empty since/proven/rest leave out the block, caption included", bare.includes("What you approve") && bare.includes("Needs your eyes") && !bare.includes("Since your request") && !bare.includes("What the gates proved") && !restCap.test(bare), bare.slice(0, 300));
  const noWhat = run(clone(look, { what: null, flags: [] }));
  check("AC-3 no what and no flags: neither block", !noWhat.includes("What you approve") && !noWhat.includes("Needs your eyes"), noWhat.slice(0, 300));
  const det = L.match(/<details\b[^>]*>/);
  check("AC-3 the rest is a <details> that starts closed", !!det && !/\bopen\b/.test(det[0]) && L.search(restCap) > L.indexOf("<details") && L.includes("Fixes a comment"), det?.[0]);
  check("AC-3 the rest says how many items it holds", /The rest \(2\)/.test(L), L.match(restCap)?.[0]);
  // AC-4: routine
  check("AC-4 routine shows the verdict, what you approve, the gates proved and the folded rest", R.includes("What you approve") && R.includes("What the gates proved") && /The rest \(1\)/.test(R) && !/<details\b[^>]*\bopen\b/.test(R) && rp?.text === "routine", R.slice(0, 300));
  check("AC-4 routine has no 'Needs your eyes' and no 'Since your request'", !R.includes("Needs your eyes") && !R.includes("Since your request") && !/data-suggest/.test(R), R.slice(0, 300));
  // AC-5: every block carries its origin chip
  const at = [...CAPS, null].map((c) => c && L.indexOf(c)).filter((v) => v !== null && v >= 0);
  const marks = [...CAPS.map((c) => L.indexOf(c)), L.search(restCap)].sort((a, b) => a - b);
  const segs = marks.map((m, i) => L.slice(m, marks[i + 1] ?? L.length));
  check("AC-5 every block of the brief carries a chip (.tag) with its caption", segs.length === 5 && segs.every((s) => tagRe.test(s)), segs.map((s) => tagRe.test(s)).join(","));
  const seg = (c) => segs.find((s) => s.startsWith(c)) || "";
  check("AC-5 what you approve says who wrote it", /written by the (product owner|review agent)/.test(seg("What you approve")), strip(seg("What you approve")).slice(0, 120));
  check("AC-5 the gates proved says 'computed, not claimed'", seg("What the gates proved").includes("computed, not claimed"), strip(seg("What the gates proved")).slice(0, 120));
  check("AC-5 since your request says 'diff computed'", seg("Since your request").includes("diff computed"), strip(seg("Since your request")).slice(0, 120));
  check("AC-5 needs your eyes names its origin", /flagged by the gates|written by the (product owner|review agent)/.test(seg("Needs your eyes")), strip(seg("Needs your eyes")).slice(0, 120));
  check("AC-5 the chip is shown for the routine brief's blocks too", /written by the (product owner|review agent)/.test(R) && R.includes("computed, not claimed"), strip(R).slice(0, 200));
  const wild = run(clone(look, { what: { text: '<img src=x onerror=1> & "act.approve" {n}', by: "review agent" } }));
  check("AC-5 agent text is escaped and shown as written, never a message", !wild.includes("<img") && wild.includes("&lt;img") && wild.includes("act.approve") && wild.includes("{n}"), wild.slice(0, 300));
  // AC-6: one suggestion button per flag that has one
  const sug = [...L.matchAll(/<button\b[^>]*data-suggest[^>]*>([\s\S]*?)<\/button>/g)];
  check("AC-6 one 'Use this point' button per flag with a suggestion, none for the others", sug.length === 1 && /btn/.test(sug[0][0]) && /ghost/.test(sug[0][0]) && strip(sug[0][1]).trim() === "Use this point", sug.map((m) => m[0]).join("|").slice(0, 200));
  check("AC-6 the button's title says nothing is sent", !!sug[0] && sug[0][0].includes('title="Fills the note. Nothing is sent."'), sug[0]?.[0]);
}

// ---- the click, the placement and the row (page source)
const rd = grab(/^function renderDecide\(/gm);
check("AC-1 renderDecide draws the brief inside .decide, above the decision row, from S.card.brief",
  /briefHTML\(/.test(rd) && /S\.card\??\.brief/.test(rd) && rd.indexOf("briefHTML(") < rd.indexOf('class="decide-a"') && rd.indexOf("briefHTML(") > rd.indexOf('class="decide"'), rd.slice(0, 120));
check("AC-2 the brief is drawn only when the card has one", /S\.card\??\.brief\s*(\?|&&)/.test(rd) || /\bbriefHTML\(S\.card\??\.brief\)/.test(rd), "no guard on S.card.brief");
const body = h.slice(h.indexOf("<script>"));
const hit = [...body.matchAll(/(\[data-suggest\]|dataset\.suggest|data-suggest)/g)].map((m) => m.index).filter((i) => !/function brief/.test(body.slice(Math.max(0, i - 3000), i).split("\n}").pop()));
const win = hit.length ? body.slice(hit[0], hit[0] + 1100) : "";
check("AC-6 a data-suggest click handler exists", hit.length > 0, "nothing in the page handles data-suggest");
check("AC-6 the click fills #changes, unfolds it, focuses it with the cursor at the end", /changes/.test(win) && /\.value\s*=/.test(win) && /\bshow\b/.test(win) && /focus\(\)/.test(win) && /setSelectionRange|selectionStart/.test(win), win.slice(0, 200));
check("AC-6 the click sends nothing and writes the notice", !/\bapi\(|act\(|request-changes|fetch\(/.test(win) && /notice/i.test(win), win.slice(0, 200));

// ---- the Yours row
const psrc = grab(/^function passHtml\(/gm);
if (psrc) {
  let pass = null;
  try {
    pass = new Function("$", "esc", "S", "OWNER", "colName", "usd", "dur", "gh", "UNTITLED", "costLine", core + psrc + "return passHtml;")(dollar, esc,
      { pending: {}, note: {}, editing: null }, { "Spec Review": ["Coding", "Spec"], Staged: ["Done", "Coding"] }, (c) => c, (x) => "$" + x, () => "", () => "", "", () => "");
  } catch (e) { check("passHtml loads with stubs", false, String(e)); }
  if (pass) {
    const card = (extra) => Object.assign({ key: "shop/7", issue: 7, title: "T", column: "Spec Review", cost: 0, since: null, blocked: null }, extra);
    const meta = (c) => { const html = pass(c), i = html.indexOf('class="cap"'); return i < 0 ? "" : strip(html.slice(i, html.indexOf('<span class="ptext"', i))).replace(/\s+/g, " ").trim(); };
    check("AC-7 a routine card's row says '· routine' after the column", meta(card({ verdict: "routine", flags: 0 })) === "Spec Review · routine" || /· routine$/.test(meta(card({ verdict: "routine", flags: 0 }))), meta(card({ verdict: "routine", flags: 0 })));
    check("AC-7 a card with one flag says '· 1 point'", /· 1 point$/.test(meta(card({ verdict: "look", flags: 1 }))), meta(card({ verdict: "look", flags: 1 })));
    check("AC-7 a card with 3 flags says '· 3 points'", /· 3 points$/.test(meta(card({ verdict: "look", flags: 3, column: "Staged" }))), meta(card({ verdict: "look", flags: 3, column: "Staged" })));
    check("AC-7 without a brief the row is unchanged", pass(card({})) === pass(card({ verdict: null, flags: 0 })) && !/routine|point/.test(meta(card({ verdict: null, flags: 0 }))), meta(card({ verdict: null, flags: 0 })));
  }
} else check("AC-7 passHtml exists", false, "no passHtml");
console.log(out.join("\n"));
JS
if command -v node >/dev/null; then
  res="$(node "$(nat "$FAKE_GH_DIR/page.js")" "$(nat "$FACTORY_DIR/dashboard.html")" "$(nat "$FACTORY_DIR/lang/dashboard.en.json")" 2>&1)"
  while IFS= read -r line; do
    case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "node: $line" ;; esac
  done <<< "$res"
else
  h="$(cat "$FACTORY_DIR/dashboard.html")"
  assert_contains "$h" "function briefHTML("
  assert_contains "$h" "data-suggest"
fi
finish
