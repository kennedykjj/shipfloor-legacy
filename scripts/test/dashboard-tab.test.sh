#!/usr/bin/env bash
# suite: unit
# The tab says what waits (#183, AC-1, AC-2): the page's pure functions tabState(overview, project) -> {count, stopped},
# tabTitle(state, project) and favicon(state), run in node on their own (skipped without node, like dashboard-brief.test.sh).
# favicon draws on a stub document whose theme tokens are distinct colors, so the test reads which color carries the state.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
T="$(mktemp -d)"
cat > "$T/page.js" <<'JS'
const fs = require("fs");
const [, , htmlPath, langDir] = process.argv;
const h = fs.readFileSync(htmlPath, "utf8");
const cat = (c) => JSON.parse(fs.readFileSync(`${langDir}/dashboard.${c}.json`, "utf8")).messages;
const EN = cat("en");
const out = [];
const check = (name, cond, why) => out.push(cond ? "ok " + name : "no " + name + ": " + String(why).replace(/\s+/g, " "));
const grab = (re) => { let s = ""; for (const m of h.matchAll(re)) { const i = m.index; s += h.slice(i, h.indexOf("\n}", i) + 2) + "\n"; } return s; };
const line = (re) => [...h.matchAll(re)].map((m) => m[0]).join("\n") + "\n";
const core = h.slice(h.indexOf("const LANG = "), h.indexOf("// the static markup"));
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const NAMES = ["tabState", "tabTitle", "favicon"];
// the functions under test and the helpers they may lean on (tab*, fold*, norm*, stale): everything else stays out, as the DOM is not here
const FN = /^function (tabState|tabTitle|favicon|stale|(?:tab[A-Z]|fold|norm)\w*)\(/gm, CONST = /^const (MARK|STALE_S|stale|(?:tab[A-Z]|fold|norm)\w*) =.*$/gm;
const build = (code, doc) => {
  const dollar = () => ({ textContent: JSON.stringify({ language: code, messages: cat(code), en: EN }) });
  const body = core + line(CONST) + grab(FN) + `return {${NAMES.map((n) => `${n}: typeof ${n} === "function" ? ${n} : undefined`)}};`;
  return new Function("$", "esc", "document", "getComputedStyle", "location", body)(dollar, esc, doc, doc.cs, { search: "", hash: "" });
};
const TOKENS = { "--sand": "#c8a24e", "--bad": "#d9483b", "--muted": "#8a8a8a", "--text": "#eeeeee", "--ground": "#101010", "--ok": "#3fa56b" };
const fav = { href: "" };
const doc = { documentElement: {}, title: "", getElementById: () => fav, cs: () => ({ getPropertyValue: (k) => TOKENS[k] || "" }) };
let P = {};
try { P = build("en", doc); } catch (e) { check("the page's tab functions load on their own", false, String(e)); }
const call = (f, ...a) => { try { return f(...a); } catch (e) { return "THROW " + e; } };

const card = (issue, extra) => Object.assign({ issue, column: "Coding" }, extra);
const ov = (silent) => ({ silent, projects: [
  { slug: "shop", board_age_s: 3, cards: [card(1, { awaiting: true }), card(2, { blocked: "owner" }), card(3, { blocked: "infra" }), card(4)] },
  { slug: "other", board_age_s: 3, cards: [card(9, { awaiting: true })] }] });

// AC-1: the count is what waits in the project the page shows
if (!P.tabState) check("AC-1 tabState exists", false, "no function tabState in the page");
else {
  const s = call(P.tabState, ov(null), "shop");
  check("AC-1 tabState counts the cards that wait for the owner in the shown project only", s && s.count === 2 && !s.stopped, JSON.stringify(s));
  const none = call(P.tabState, { silent: null, projects: [{ slug: "shop", board_age_s: 1, cards: [card(4)] }] }, "shop");
  check("AC-1 tabState: nothing waits is count 0", none && none.count === 0 && !none.stopped, JSON.stringify(none));
  const before = call(P.tabState, null, "shop");
  check("AC-1 tabState before the first read does not throw and counts none", before && before.count === 0 && !before.stopped, JSON.stringify(before));
  // AC-2: the dispatcher is silent
  for (const dead of [{ min: 12 }, { min: null }]) {
    const d = call(P.tabState, ov(dead), "shop");
    check("AC-2 tabState: the dispatcher stopped (" + JSON.stringify(dead) + ") is stopped, the count kept", d && d.stopped === true && d.count === 2, JSON.stringify(d));
  }
}
const SEP = " · ";
if (!P.tabTitle) check("AC-1 tabTitle exists", false, "no function tabTitle in the page");
else {
  const T = (state, p) => call(P.tabTitle, state, p);
  check("AC-1 nothing waits: Shipfloor · <project>", T({ count: 0, stopped: false }, "shop") === "Shipfloor" + SEP + "shop", T({ count: 0, stopped: false }, "shop"));
  check("AC-1 N waits: (N) Shipfloor · <project>", T({ count: 3, stopped: false }, "shop") === "(3) Shipfloor" + SEP + "shop", T({ count: 3, stopped: false }, "shop"));
  check("AC-2 stopped: Shipfloor · <project> · stopped", T({ count: 0, stopped: true }, "shop") === "Shipfloor" + SEP + "shop" + SEP + "stopped", T({ count: 0, stopped: true }, "shop"));
  check("AC-2 stopped with decisions waiting keeps the count", T({ count: 2, stopped: true }, "shop") === "(2) Shipfloor" + SEP + "shop" + SEP + "stopped", T({ count: 2, stopped: true }, "shop"));
  let pt = null; try { pt = build("pt-BR", doc); } catch (e) { check("AC-2 the pt-BR tab functions load", false, String(e)); }
  check("AC-2 the stopped word follows the dashboard's language (pt-BR: parado)", pt?.tabTitle && call(pt.tabTitle, { count: 0, stopped: true }, "shop") === "Shipfloor" + SEP + "shop" + SEP + "parado", pt?.tabTitle && call(pt.tabTitle, { count: 0, stopped: true }, "shop"));
}
const WORD = { en: "stopped", "pt-BR": "parado", es: "detenido", fr: "arrêté", de: "gestoppt", it: "fermo", ja: "停止中", ko: "중지됨", ru: "остановлен", tr: "durdu", "zh-CN": "已停止", "zh-TW": "已停止" };
const bad = Object.entries(WORD).filter(([c, w]) => cat(c)["title.stopped"] !== w).map(([c]) => c);
check("AC-2 every catalog has title.stopped", bad.length === 0, "missing or different in: " + bad.join(", "));

// the favicon: the state is carried by color alone
const svgOf = (state) => { fav.href = ""; try { P.favicon(state); } catch (e) { return "THROW " + e; } return decodeURIComponent((fav.href.split(",")[1] || "")); };
if (!P.favicon) check("AC-1 favicon exists", false, "no function favicon in the page");
else {
  const has = (s, k) => s.includes(TOKENS["--" + k]);
  const neutral = svgOf({ count: 0, stopped: false }), wait = svgOf({ count: 2, stopped: false }), dead = svgOf({ count: 0, stopped: true }), both = svgOf({ count: 2, stopped: true });
  check("AC-1 neutral favicon: route in --muted, card in --text, no accent", has(neutral, "muted") && has(neutral, "text") && !has(neutral, "sand") && !has(neutral, "bad"), neutral.slice(0, 300));
  const tile = (s, k) => new RegExp(`<rect[^>]*width="64"[^>]*height="64"[^>]*fill="${TOKENS["--" + k]}"`).test(s);  // the 64x64 square of the brand mark, drawn first
  check("AC-1 waiting favicon: the tile filled with the accent (--sand), the drawing in --ground", tile(wait, "sand") && has(wait, "ground") && !has(wait, "bad") && !has(wait, "muted"), wait.slice(0, 300));
  check("AC-1 neutral favicon: the tile stays --ground", tile(neutral, "ground"), neutral.slice(0, 300));
  check("AC-2 stopped favicon: the tile in --bad, no accent", tile(dead, "bad") && has(dead, "ground") && !has(dead, "sand"), dead.slice(0, 300));
  check("AC-2 stopped outranks waiting in the favicon", has(both, "bad") && !has(both, "sand"), both.slice(0, 300));
  const first = svgOf(undefined);
  check("AC-1 favicon() with no state (before the first read) draws without throwing", first && !first.startsWith("THROW") && first.includes("<svg"), first.slice(0, 200));
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
  assert_contains "$h" "function tabState("
  assert_contains "$h" "function tabTitle("
fi
finish
