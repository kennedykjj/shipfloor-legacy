#!/usr/bin/env bash
# suite: unit
# Ctrl K (#183, AC-6, AC-7). The page's pure function palette(query, cards, actions) -> at most nine rows runs in node on its
# own (skipped without node, like dashboard-brief.test.sh); the markup the owner and a screen reader meet is checked in the page
# (header button, dialog, combobox and listbox, the shortcut) and the catalogs carry the palette's keys.
# A row's shape is the page's own: the test reads a row as text and as JSON, never by field name. A card is what the
# overview gives ({issue, title, column, awaiting, since}) with the work area's key ("shop/120"); an action is {id, label}.
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
finish
