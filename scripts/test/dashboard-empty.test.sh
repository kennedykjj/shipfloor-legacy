#!/usr/bin/env bash
# The dashboard's empty states say what is true for the card (#116). dashboard.html and the pt-BR catalog are read as
# text, as theme.test.sh does: the repo has no browser runner; the timed swap in a real browser is checked by hand.
#   AC-1  Staged card, no review page: the text names the Gates tab and the pull request, never Refine
#   AC-2  Spec Review card, no review page: the text says Refine has not built it yet
#   AC-3  a card waiting for the owner with no page opens on Gates, or Sessions without reports
#   AC-4  a card waiting for the owner with a page still opens on Review
#   AC-5  the maximized reading pane of a Staged card without a page shows PR, CI, size, gates and cost
#   AC-6  nothing known: one line and a link to the log, not a blank area
#   AC-7  Live tab: after 10 s "Reading the session…" gives way to the nothing-to-show message
#   AC-8  the transcript arriving replaces that message with no reload
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0] + "/test"); import page_text  # the page's text is a catalog by key (#122)
h = page_text.english(h)
cat = json.load(open(sys.argv[2], encoding="utf-8"))
ex = page_text.exact("pt-BR")
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
def fn(name):
    m = re.search(r"(?:async )?function %s\(" % re.escape(name), h)
    if not m: return ""
    n = re.search(r"\n(?:async )?function |\nlet |\nconst [A-Za-z_]+ = (?:async )?\(", h[m.end():])
    return h[m.start():m.end() + (n.start() if n else 3000)]

# --- AC-1 / AC-2: the missing-page text by column
nr = fn("noReview")
rp = fn("reviewPane")
check("AC-1 noReview(column) exists and reviewPane uses it", bool(nr) and "noReview(" in rp, "no noReview function used by reviewPane")
st = "No review page for this pull request."
check("AC-1 the Staged text says there is no review page for this pull request", st in nr, f'"{st}" is missing from noReview')
check("AC-1 the Staged text names the Gates tab", "Gates tab" in nr and "validation checked" in nr, 'the Staged text does not point to the Gates tab')
check("AC-1 the Gates tab is a .lnk button with data-tab=gates", bool(re.search(r'<button[^>]*class="lnk"[^>]*data-tab="gates"|<button[^>]*data-tab="gates"[^>]*class="lnk"', nr)), 'no <button class="lnk" data-tab="gates"> in the Staged text')
check("AC-1 the pull request links to GitHub when the card has a PR number", "github.com/" in (nr + rp) and "/pull/" in (nr + rp), "no link to https://github.com/<repo>/pull/<pr>")
sm = re.search(r"Staged.*", nr)
staged_part = nr[nr.find("No review page for this pull request."):] if st in nr else ""
staged_part = staged_part[:staged_part.find("\n\n")] if "\n\n" in staged_part else staged_part[:900]
check("AC-1 the Staged text never names Refine", bool(staged_part) and "Refine" not in staged_part.split("Spec Review")[0], "the Staged text names Refine or is missing")
check("AC-1 the old 'Refine builds it when the spec is ready.' is gone from the page", "Refine builds it when the spec is ready." not in h, "the page still says Refine builds it when the spec is ready")
check("AC-1 the old string is gone from the pt-BR catalog", not any("Refine builds it when the spec is ready." in k for k in ex), "the catalog still has the old string")
check("AC-1 pt-BR Staged text", bool(page_text.msg("pt-BR", "review.none_pr")) and bool(page_text.msg("pt-BR", "review.gates_tab")), "no catalog entry for the Staged text")
check("AC-2 the Spec Review text says Refine has not built the page", "No review page yet. Refine has not built it for this spec." in nr, "the Spec Review text is missing")
check("AC-2 pt-BR Spec Review text", "No review page yet. Refine has not built it for this spec." in ex, "no catalog entry for the Spec Review text")
check("AC-2 other columns say 'No review page for this card.' without Refine", bool(re.search(r"No review page for this card\.(?! Refine)", nr)), "the generic text is missing")
check("AC-2 pt-BR generic text", ex.get("No review page for this card.") not in (None, ""), "no catalog entry for 'No review page for this card.'")
check("AC-2 Refine is named only in the Spec Review text", len(re.findall(r"Refine", nr)) == 1 and "Spec Review" in nr, "Refine appears in more than one missing-page text (or none)")

# --- AC-3 / AC-4: the opening tab
oc = fn("openCard"); ld = fn("landing"); lc = fn("loadCard"); stb = fn("selectTab")
check("AC-3 a landing(ov) function picks the opening tab", bool(ld) and "landing(" in oc, "no landing function used by openCard")
check("AC-3 a card whose overview says review false lands on gates", bool(ld) and "gates" in ld and "review" in ld, "landing does not return gates for a card without a page")
check("AC-3 the automatic choice is marked S.auto", "S.auto" in oc or "S.auto" in ld, "openCard does not mark the tab automatic (S.auto)")
check("AC-3 an explicit review ask for a card without a page is treated as not asked", bool(re.search(r"review", ld)) and bool(re.search(r'"review"\s*&&|===\s*"review"|==\s*"review"', ld)), "landing does not handle an explicit review for review:false")
check("AC-3 loadCard moves an automatic gates to sessions when there are no reports", "S.auto" in lc and "sessions" in lc and "reports" in lc, "loadCard does not fall back to sessions")
check("AC-3 selectTab clears the automatic mark", bool(re.search(r"S\.auto\s*=\s*(false|null|undefined|0|\"\")", stb)), "selectTab does not clear S.auto")
check("AC-4 landing keeps review for a waiting card that has a page", bool(ld) and bool(re.search(r"OWNER\[", ld + oc)) and bool(re.search(r'"review"', ld + oc)) and bool(re.search(r"\.review\b", ld)), "landing does not branch on ov.review to keep review")

# --- AC-5 / AC-6: the reading pane
rh = fn("readHtml")
check("AC-5 readHtml draws a Gates section for a card without a review page", bool(re.search(r'sec\(\s*"?Gates"?,', rh)) and "review" in rh, 'no sec("Gates", …) in readHtml')
check("AC-5 the Gates section draws d.report.gates", "report.gates" in rh or "report?.gates" in rh, "readHtml does not read d.report.gates")
chip = len(re.findall(r'class="gate \$\{', h)) + len(re.findall(r'"gate pass"|"gate fail"|gate \$\{', h))
check("AC-5 the gate chips come from one shared helper, not a copy", bool(re.search(r"gateChips|gateList|gateSpans|gatesHtml|chips\(", rh)) and len(re.findall(r'<span class="gate \$\{', h)) == 1, "the .gate chips are defined more than once or readHtml has no shared helper")
check("AC-5 the cost tag reads 'est. so far'", "est. so far" in rh, 'the cost tag does not say "est. so far"')
check("AC-5 the old '$… so far' cost tag without est. is gone", not re.search(r"\.toFixed\(2\)\} so far", h), "a cost tag still reads '$x so far'")
check("AC-5 pt-BR cost tag", bool(page_text.msg("pt-BR", "cost.so_far")), "no catalog entry for the est. so far tag")
msg = "Nothing is recorded for this card yet."
check("AC-6 readHtml says 'Nothing is recorded for this card yet.'", msg in rh, f'"{msg}" is missing')
check("AC-6 the line is an .empty paragraph", bool(re.search(r'<p class="empty">\s*' + re.escape(msg), rh)), "the line is not a <p class=\"empty\">")
check("AC-6 it offers 'Open the log' as a .lnk button with data-open and data-go=log", bool(re.search(r'<button[^>]*class="lnk"[^>]*data-open[^>]*data-go="log"[^>]*>\s*Open the log|<button[^>]*data-open[^>]*data-go="log"[^>]*class="lnk"[^>]*>\s*Open the log', rh)), "no Open the log button")
check("AC-6 'No validation report for this card yet.' is gone", "No validation report for this card yet." not in h, "the old line is still in the page")
check("AC-6 pt-BR for the nothing-recorded line", ex.get(msg) == "Ainda não há nada registrado para este card." and ex.get("Open the log") == "Abrir o log", "the catalog lacks the nothing-recorded line or Open the log")
check("AC-6 the old pt-BR entry for the removed line is gone", "No validation report for this card yet." not in ex, "the catalog still has the removed line")

# --- AC-7 / AC-8: the Live tab
pl = fn("paintLive"); fl = fn("followLive")
check("AC-7 LIVE_WAIT is 10000 ms", bool(re.search(r"const LIVE_WAIT\s*=\s*10000\b", h)), "no const LIVE_WAIT = 10000")
check("AC-7 paintLive compares the time since S.liveSince with LIVE_WAIT", "S.liveSince" in pl and "LIVE_WAIT" in pl and "Date.now()" in pl, "paintLive does not compare Date.now() - S.liveSince with LIVE_WAIT")
nm = "Nothing to show yet."
check("AC-7 paintLive shows 'Nothing to show yet. The Log tab has what the run wrote.'", nm in pl and "has what the run wrote." in pl, "the nothing-to-show message is missing from paintLive")
check("AC-7 'Log tab' is a .lnk button selecting the Log tab", bool(re.search(r'<button[^>]*data-tab="log"', pl)) and "lnk" in pl, 'no <button class="lnk" data-tab="log"> in paintLive')
check("AC-7 'Reading the session…' stays for the first seconds", "Reading the session…" in pl, "the reading message is gone from paintLive")
check("AC-7 S.liveSince is set in openCard", "S.liveSince" in oc, "openCard does not set S.liveSince")
check("AC-7 S.liveSince is set in selectTab", "S.liveSince" in stb, "selectTab does not set S.liveSince")
check("AC-7 pt-BR for the nothing-to-show message", bool(page_text.msg("pt-BR", "live.nothing")), "no catalog entry for the nothing-to-show message")
check("AC-8 followLive sets the nothing-yet message for a running card with no events", nm in fl or "nothingYet" in fl or "waitingLive" in fl, "followLive does not set the nothing-yet state")
check("AC-8 followLive keeps 'No factory session for this card yet.' only for a card with no run", "No factory session for this card yet." in fl and bool(re.search(r"running|run", fl.split("No factory session")[0][-400:])), "followLive does not tell a running card from one with no run")
tk = re.search(r"function tick\(.*", h)
tick_all = "".join(re.findall(r"[^\n]*tick\([^\n]*", h))
check("AC-8 the 1 s tick repaints the Live pane while it waits", bool(re.search(r"paintLive\(", fn("tick"))) or bool(re.search(r"setInterval\([^\n]*paintLive|paintLive[^\n]*setInterval", h)) or bool(re.search(r'S\.tab\s*===?\s*"live"[^\n]*paintLive', h)), "nothing repaints the Live pane every second")
check("AC-8 events replace the message: the 2 s poll sets S.liveHtml from events", "S.liveHtml" in fl and "events" in fl and "paintLive(" in fl, "followLive does not rebuild S.liveHtml from events")
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
