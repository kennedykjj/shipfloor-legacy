#!/usr/bin/env bash
# suite: unit
# The dashboard's API in process (scripts/test/py/dashboard_views.py, scripts/test/py/dashboard_settings.py): one
# dashboard.py server in a thread, a fake gh.
source "$(dirname "$0")/lib.sh"
py_suite dashboard_views
py_suite dashboard_settings
# The belt (#181, AC-1..AC-7): the page's script in node on a fake DOM (BeltRender, BeltMotion) fed this server's overview.
py_suite dashboard_belt
# The day in replay (#184): GET /api/day/<project> (AC-3 server side), and the page's scrubber, replay and Logbook (AC-3..AC-8).
py_suite dashboard_day
py_suite dashboard_replay
# The work area (#182): Area (AC-1, AC-4..AC-7: Decide, Run, Card, Calm), Keys (AC-2: A, R, N, Enter, Esc), Quick (AC-3: the 5 s
# hold with Undo, the send, the next card) and Design (AC-8: DESIGN.md's The Work Area section), in scripts/test/py/dashboard_work.py.
py_suite dashboard_work

# #183 (ux-09): the tab, the address and Ctrl K. The page's pure functions run in node on their own (skipped without node, like
# dashboard-brief.test.sh); each block is a function so the three share this file without sharing variables.
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

# The tab says what waits (AC-1, AC-2): tabState(overview, project) -> {count, stopped}, tabTitle(state, project) and favicon(state).
# favicon draws on a stub document whose theme tokens are distinct colors, so the test reads which color carries the state.
ux09_tab() {
local T h res line
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
}

# The address (AC-3, AC-4) and the docs for the push link (AC-8). parseHash(hash) -> {card}, {at} or null and hashOf(sel) run on
# their own, and selectCard runs with a stub history to see what a selection writes to the address.
ux09_address() {
local T h DOC res line
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
}

# Ctrl K (AC-6, AC-7). palette(query, cards, actions) -> at most nine rows runs on its own; the markup the owner and a screen
# reader meet is checked in the page (header button, dialog, combobox and listbox, the shortcut) and the catalogs carry the keys.
# A row's shape is the page's own: the test reads a row as text and as JSON, never by field name. A card is what the
# overview gives ({issue, title, column, awaiting, since}) with the work area's key ("shop/120"); an action is {id, label}.
ux09_palette() {
local T h res line
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
const dollar = () => ({ textContent: JSON.stringify({ language: "en", messages: EN, en: EN }) });
// the function under test and the helpers it may lean on (pal*, fold*, norm*, hm4, pad): the rest of the page stays out
const FN = /^function (palette|hm4|pad|(?:pal[A-Z]|fold|norm)\w*)\(/gm, CONST = /^const (hm4|pad|(?:pal[A-Z]|fold|norm)\w*) =.*$/gm;
let palette = null;
try { palette = new Function("$", "esc", core + line(CONST) + grab(FN) + `return typeof palette === "function" ? palette : undefined;`)(dollar, esc); } catch (e) { check("the page's palette loads on its own", false, String(e)); }
const txt = (row) => JSON.stringify(row);
const run = (q, cards, actions) => { try { return palette(q, cards, actions); } catch (e) { return "THROW " + e; } };

const card = (issue, title, column, extra) => Object.assign({ issue, key: `shop/${issue}`, title, column }, extra);
const CARDS = [
  card(120, "Fix the login flow", "Spec Review", { awaiting: true, since: "2026-10-14T09:00:00Z" }),
  card(121, "Login page copy", "Staged", { awaiting: true, since: "2026-10-14T08:00:00Z" }),
  card(12, "Refactor Café menu", "Coding"),
  card(30, "Rename the exporter", "Inbox"),
];
const NEXT = { id: "next", label: "Next decision" }, PAUSE = { id: "pause", label: "Pause the factory" }, LIVE = { id: "live", label: "Back to live" };
const ACTIONS = [NEXT, PAUSE];
const at = (rows, needle) => rows.findIndex((r) => txt(r).includes(needle));

if (!palette) check("AC-6 palette exists", false, "no function palette in the page");
else {
  const empty = run("", CARDS, ACTIONS);
  check("AC-6 the empty field lists the actions first, then the waiting cards, oldest first", Array.isArray(empty)
    && at(empty, "Next decision") === 0 && at(empty, "Pause the factory") === 1 && at(empty, "Login page copy") === 2 && at(empty, "Fix the login flow") === 3
    && at(empty, "Refactor") === -1 && at(empty, "Rename") === -1, Array.isArray(empty) ? empty.map(txt).join(" | ") : empty);
  for (const q of ["120", "#120"]) {
    const r = run(q, CARDS, ACTIONS);
    check(`AC-6 '${q}' puts card 120 first`, Array.isArray(r) && r.length > 0 && txt(r[0]).includes("Fix the login flow"), Array.isArray(r) ? r.map(txt).join(" | ") : r);
  }
  const words = run("login", CARDS, ACTIONS), up = run("LOGIN", CARDS, ACTIONS);
  check("AC-6 a word of the title finds the cards, whatever the case", Array.isArray(words) && at(words, "Fix the login flow") >= 0 && at(words, "Login page copy") >= 0 && at(words, "Refactor") === -1 && JSON.stringify(words) === JSON.stringify(up), Array.isArray(words) ? words.map(txt).join(" | ") : words);
  for (const q of ["cafe", "CAFÉ", "café"]) { const r = run(q, CARDS, ACTIONS); check(`AC-6 '${q}' finds "Café" (accents do not matter)`, Array.isArray(r) && at(r, "Refactor Café menu") >= 0, Array.isArray(r) ? r.map(txt).join(" | ") : r); }
  const pause = run("pause", CARDS, ACTIONS);
  check("AC-6 the field also matches an action's label", Array.isArray(pause) && at(pause, "Pause the factory") === 0 && at(pause, "Next decision") === -1, Array.isArray(pause) ? pause.map(txt).join(" | ") : pause);
  const rows = run("", CARDS, ACTIONS);
  check("AC-6 a card row shows its column and its work-area key, an action row keeps its id", Array.isArray(rows) && txt(rows[at(rows, "Fix the login flow")] || "").includes("Spec Review") && txt(rows[at(rows, "Fix the login flow")] || "").includes("shop/120") && txt(rows[0] || "").includes("next"), Array.isArray(rows) ? rows.map(txt).join(" | ") : rows);
  const live = run("", CARDS, [LIVE, NEXT, PAUSE]);
  check("AC-6 the actions offered are the ones given: Back to live shows when the page passes it", Array.isArray(live) && at(live, "Back to live") === 0, Array.isArray(live) ? live.map(txt).join(" | ") : live);
  const many = Array.from({ length: 15 }, (_, i) => card(200 + i, `Task number ${i}`, "Coding", { awaiting: true, since: `2026-10-14T0${i % 10}:00:00Z` }));
  const capped = run("task", many, ACTIONS), cappedAll = run("", many, ACTIONS);
  check("AC-6 at most nine results", Array.isArray(capped) && capped.length === 9 && Array.isArray(cappedAll) && cappedAll.length === 9, `${capped?.length}, ${cappedAll?.length}`);
  const none = run("zzzzqq", CARDS, ACTIONS);
  check("AC-6 no match is one 'Nothing matches' row, no card in it", Array.isArray(none) && none.length === 1 && txt(none[0]).includes("Nothing matches") && at(none, "shop/") === -1, Array.isArray(none) ? none.map(txt).join(" | ") : none);
}

// the markup of the page: the header button, the dialog, the combobox and the shortcut (static: the factory has no browser)
const head = h.slice(h.indexOf("<header>"), h.indexOf("</header>"));
const btn = head.match(/<button\b[^>]*aria-keyshortcuts="Control\+K Meta\+K"[^>]*>[\s\S]*?<\/button>/);
check("AC-6 the header has a Commands button with aria-keyshortcuts Control+K Meta+K", !!btn, "no such button in <header>");
check("AC-6 the header button is a ghost button with a kbd hint and the pal.open label", !!btn && /\bbtn\b/.test(btn[0]) && /\bghost\b/.test(btn[0]) && /<kbd\b/.test(btn[0]) && /pal\.open/.test(btn[0]), btn?.[0]);
for (const [name, re] of [["a dialog that is modal", /role="dialog"[^>]*aria-modal="true"|aria-modal="true"[^>]*role="dialog"/], ["a combobox field", /role="combobox"/], ["a listbox with options", /role="listbox"[\s\S]*role="option"|role="option"[\s\S]*role="listbox"/], ["aria-activedescendant on the field", /aria-activedescendant/], ["the Ctrl K / Cmd K shortcut", /(ctrlKey\s*\|\|\s*e\.metaKey|metaKey\s*\|\|\s*e\.ctrlKey)[\s\S]{0,80}["']k["']|["']k["'][\s\S]{0,80}(ctrlKey|metaKey)/i]]) {
  check(`AC-6/7 the page has ${name}`, re.test(h), "not found in dashboard.html");
}
const keys = ["title.stopped", "pal.open", "pal.field", "pal.next", "pal.live", "pal.at", "pal.pause", "pal.none", "pal.count"];
const langs = ["en", "pt-BR", "es", "fr", "de", "it", "ja", "ko", "ru", "tr", "zh-CN", "zh-TW"];
const miss = langs.flatMap((c) => keys.filter((k) => !cat(c)[k]).map((k) => `${c}:${k}`));
check("AC-6 every catalog has the palette's keys", miss.length === 0, "missing " + miss.slice(0, 8).join(", "));
check("AC-6 the English labels are the spec's", EN["pal.next"] === "Next decision" && EN["pal.pause"] === "Pause the factory" && EN["pal.live"] === "Back to live" && EN["pal.at"] === "See the line at {time}" && EN["pal.none"] === "Nothing matches" && cat("pt-BR")["pal.next"] === "Próxima decisão", [EN["pal.next"], EN["pal.pause"], EN["pal.at"]].join(" | "));
console.log(out.join("\n"));
JS
if command -v node >/dev/null; then
  res="$(node "$(nat "$T/page.js")" "$(nat "$FACTORY_DIR/dashboard.html")" "$(nat "$FACTORY_DIR/lang")" 2>&1)"
  while IFS= read -r line; do
    case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "node: $line" ;; esac
  done <<< "$res"
else
  h="$(cat "$FACTORY_DIR/dashboard.html")"
  assert_contains "$h" "function palette("
  assert_contains "$h" 'aria-keyshortcuts="Control+K Meta+K"'
fi
}

ux09_tab
ux09_address
ux09_palette
finish
