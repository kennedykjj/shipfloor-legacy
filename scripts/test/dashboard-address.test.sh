#!/usr/bin/env bash
# suite: unit
# The address (#183, AC-3, AC-4) and the docs for the push link (AC-8). The page's pure functions parseHash(hash) -> {card},
# {at} or null and hashOf(sel) run in node on their own, and selectCard runs with a stub history to see what a selection
# writes to the address (skipped without node, like dashboard-brief.test.sh).
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
T="$(mktemp -d)"
cat > "$T/page.js" <<'JS'
const fs = require("fs");
const [, , htmlPath, langDir] = process.argv;
const h = fs.readFileSync(htmlPath, "utf8");
const EN = JSON.parse(fs.readFileSync(`${langDir}/dashboard.en.json`, "utf8")).messages;
const out = [];
const check = (name, cond, why) => out.push(cond ? "ok " + name : "no " + name + ": " + String(why).replace(/\s+/g, " "));
const grab = (re) => { let s = ""; for (const m of h.matchAll(re)) { const i = m.index; s += h.slice(i, h.indexOf("\n}", i) + 2) + "\n"; } return s; };
const line = (re) => [...h.matchAll(re)].map((m) => m[0]).join("\n") + "\n";
const core = h.slice(h.indexOf("const LANG = "), h.indexOf("// the static markup"));
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const dollar = () => ({ textContent: JSON.stringify({ language: "en", messages: EN, en: EN }) });
const NAMES = ["parseHash", "hashOf", "selectCard"];
// the functions under test and the helpers they may lean on (hash*, addr*, setAddress, pad, hm4): the rest of the page stays out
const FN = /^function (parseHash|hashOf|selectCard|setAddress|pad|hm4|(?:hash[A-Z]|addr)\w*)\(/gm, CONST = /^const (pad|hm4|hashMin|(?:hash[A-Z]|addr)\w*) =.*$/gm;
const calls = [], S = { work: { key: null, skipped: new Set() }, project: "shop", view: "board", open: null, moving: {}, overview: { projects: [{ slug: "shop", cards: [{ issue: 120, column: "Coding" }] }] } };
const loc = { pathname: "/", search: "?t=secret", hash: "" };
const history = { pushState: (s, t, u) => calls.push(["push", u]), replaceState: (s, t, u) => calls.push(["replace", u]) };
const win = { location: loc, history, addEventListener() {}, matchMedia: () => ({ matches: false }) };
let P = {};
try {
  const body = core + line(CONST) + grab(FN) + `return {${NAMES.map((n) => `${n}: typeof ${n} === "function" ? ${n} : undefined`)}};`;
  P = new Function("$", "esc", "S", "location", "history", "window", "renderBoard", "renderWork", "renderStrip", "R", body)(dollar, esc, S, loc, history, win, () => {}, () => {}, () => {}, { at: null });
} catch (e) { check("the page's address functions load on their own", false, String(e)); }
const call = (f, ...a) => { try { return f(...a); } catch (e) { return "THROW " + e; } };

// AC-4: what a hash can mean; anything else is the default view (null), never an error
if (!P.parseHash) check("AC-4 parseHash exists", false, "no function parseHash in the page");
else {
  const c = call(P.parseHash, "#card/120");
  check("AC-4 #card/120 is card 120", c && typeof c === "object" && +c.card === 120 && c.at == null, JSON.stringify(c));
  const a = call(P.parseHash, "#@0940");
  check("AC-4 a replay hash (#@0940) is a time, not a card, and not an error", a && typeof a === "object" && a.at != null && a.card == null, JSON.stringify(a));
  const bad = ["", "#", "#card", "#card/", "#card/abc", "#card/0", "#card/-3", "#card/12x", "#card/120/extra", "#card/1.5", "#unknown", "#@", "#@9", "#@2560", "#@abcd", "#@0940x", undefined, null];
  const wrong = bad.filter((b) => call(P.parseHash, b) !== null);
  check("AC-4 malformed or unknown hashes are null (the default view)", wrong.length === 0, "not null for: " + wrong.map((b) => JSON.stringify(b) + "=>" + JSON.stringify(call(P.parseHash, b))).join(", "));
}
// AC-3: a selection has an address that reads back as the same card
if (!P.hashOf) check("AC-3 hashOf exists", false, "no function hashOf in the page");
else {
  const want = "#card/120", tries = ["shop/120", 120, { card: 120 }, { key: "shop/120" }];
  const ok = tries.find((s) => call(P.hashOf, s) === want);
  check("AC-3 hashOf names the selected card #card/<n> (the work area's key shop/120, or the number)", ok !== undefined, tries.map((s) => JSON.stringify(s) + "=>" + JSON.stringify(call(P.hashOf, s))).join(", "));
  if (P.parseHash && ok !== undefined) { const back = call(P.parseHash, call(P.hashOf, ok)); check("AC-3 what hashOf writes parseHash reads back", back && +back.card === 120, JSON.stringify(back)); }
  const none = call(P.hashOf, null);
  check("AC-3 no selection has no card in its address", !/card/.test(String(none)), JSON.stringify(none));
}
// AC-3: selecting a card pushes #card/<n> (the history entry Back returns through); the token stays out of the hash
if (!P.selectCard) check("AC-3 selectCard exists", false, "no function selectCard in the page");
else {
  call(P.selectCard, "shop/120");
  const pushes = calls.filter((c) => c[0] === "push");
  check("AC-3 selecting card 120 selects it", S.work.key === "shop/120", S.work.key);
  check("AC-3 selecting card 120 pushes one history entry ending in #card/120", pushes.length === 1 && String(pushes[0][1]).endsWith("#card/120"), JSON.stringify(calls));
  check("AC-3 the token never goes into the hash", !calls.some((c) => /#.*secret/.test(String(c[1]))), JSON.stringify(calls));
}
console.log(out.join("\n"));
JS
if command -v node >/dev/null; then
  res="$(node "$(nat "$T/page.js")" "$(nat "$FACTORY_DIR/dashboard.html")" "$(nat "$FACTORY_DIR/lang")" 2>&1)"
  while IFS= read -r line; do
    case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "node: $line" ;; esac
  done <<< "$res"
else
  h="$(cat "$FACTORY_DIR/dashboard.html")"
  assert_contains "$h" "function parseHash("
  assert_contains "$h" "function hashOf("
fi

# AC-8: the operation docs say the push link opens only on the machine that runs the dashboard (it stays on 127.0.0.1)
DOC="$FACTORY_DIR/../docs/operation.md"
grep -iE 'same machine|this machine' "$DOC" | grep -E '127\.0\.0\.1' | grep -iE 'push|link' > /dev/null \
  && pass "AC-8 operation.md: the push link only works on the same machine, the dashboard stays on 127.0.0.1" \
  || fail "AC-8 operation.md has no line saying the push link opens only on the same machine because the dashboard stays on 127.0.0.1"
grep -q 'dashboard\.port' "$DOC" && pass "AC-8 operation.md names dashboard.port, where the link's port comes from" || fail "AC-8 operation.md does not mention dashboard.port"
finish
