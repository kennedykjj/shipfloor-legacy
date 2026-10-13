#!/usr/bin/env bash
# Dashboard names (#113): the owner's two decisions are "Approve" and "Request changes" on every surface (list, decision box,
# drawer), the destination column is secondary text outside the control's name, the list's opener is "Review".
# Read as text, as dashboard-page.test.sh does: no browser, no server. One named check per criterion.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
cat = json.load(open(sys.argv[2], encoding="utf-8"))
exact, rx = cat.get("exact", {}), {a: b for a, b in cat.get("rx", [])}

def func(name):  # the text of a top-level function of the page script
    m = re.search(r"^(?:async )?function " + name + r"\(", h, re.M)
    if not m: return ""
    rest = h[m.start():]
    end = re.search(r"\n(?:async function |function |const |let |document\.)", rest[10:])
    return rest[: end.start() + 10] if end else rest

def rule(sel):  # the body of the CSS rule(s) whose selector list holds exactly `sel`
    bodies = []
    for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", h):
        if sel in [x.strip() for x in s.split(",")]: bodies.append(b)
    return " ".join(bodies)

def opt_lines(oid):  # the lines of optionsFor() that define the option `oid` (spec branch first, staged branch second)
    return [l for l in func("optionsFor").split("\n") if re.search(r'\bid:\s*"' + re.escape(oid) + '"', l)]

def field(line, key):
    m = re.search(r"\b" + key + r':\s*"([^"]*)"', line)
    return m.group(1) if m else None

def btn(src, attr):  # the inner text of the first <button> whose attributes hold `attr`
    m = re.search(r"<button[^>]*" + attr + r"[^>]*>([^<]*)</button>", src)
    return m.group(1) if m else None

def tr(key, want, via=None):
    got = (rx if via == "rx" else exact).get(key)
    return None if got == want else f'catalog {"rx" if via == "rx" else "exact"} "{key}" -> "{want}" (has {got!r})'

def gone(key, via=None):
    return f'catalog {"rx" if via == "rx" else "exact"} "{key}" is still there (no string of the page uses it any more)' if key in (rx if via == "rx" else exact) else None

res = {}
def check(ac, *problems):
    res[ac] = [p for p in problems if p]

optf, passf, decf, syncf = func("optionsFor"), func("passHtml"), func("renderDecide"), func("syncDecide")
appr, reqc = opt_lines("approve"), opt_lines("request-changes")
spec_a, staged_a = (appr + ["", ""])[:2]
spec_r, staged_r = (reqc + ["", ""])[:2]
render_io = next((l for l in h.split("\n") if 'class="iopt"' in l and "data-io" in l), "")
approve_btn = re.search(r"<button[^>]*id=\"approve\"[^>]*>", decf)
approve_btn = approve_btn.group(0) if approve_btn else ""
list_approve = btn(passf, r'data-q="approve"')
drawer_approve, drawer_request = btn(decf, r'id="approve"'), btn(decf, r'id="request"')
list_changes, list_send = btn(passf, r'data-q="changes"'), btn(passf, r'data-q="send"')

# AC-1: Staged approval
check("AC-1",
  None if field(staged_a, "t") == "Approve" else f"AC-1: the Staged option's heading in the decision box is {field(staged_a, 't')!r}, want 'Approve'",
  None if field(staged_a, "verb") == "Approve" else f"AC-1: the Staged option's confirming button is {field(staged_a, 'verb')!r}, want 'Approve'",
  None if list_approve == "Approve" else f"AC-1: the list's approve pill reads {list_approve!r}, want 'Approve'",
  None if drawer_approve == "Approve" else f"AC-1: the drawer's #approve reads {drawer_approve!r}, want exactly 'Approve'",
  None if re.search(r'data-label="Approve"', approve_btn) else f"AC-1: the drawer's #approve data-label is not exactly 'Approve' ({approve_btn.strip()})")

# AC-2: Spec Review approval
check("AC-2",
  None if field(spec_a, "t") == "Approve" else f"AC-2: the Spec Review option's heading in the decision box is {field(spec_a, 't')!r}, want 'Approve'",
  None if field(spec_a, "verb") == "Approve" else f"AC-2: the Spec Review option's confirming button is {field(spec_a, 'verb')!r}, want 'Approve'",
  None if drawer_approve == "Approve" else "AC-2: the drawer's #approve of a Spec Review card is not exactly 'Approve' (it carries the destination)")

# AC-3: request changes everywhere
check("AC-3",
  None if field(spec_r, "t") == "Request changes" else f"AC-3: the Spec Review request option's heading is {field(spec_r, 't')!r}, want 'Request changes'",
  None if field(spec_r, "verb") == "Request changes" else f"AC-3: the Spec Review request option's confirming button is {field(spec_r, 'verb')!r}, want 'Request changes'",
  None if field(staged_r, "t") == "Request changes" else f"AC-3: the Staged request option's heading is {field(staged_r, 't')!r}, want 'Request changes'",
  None if field(staged_r, "verb") == "Request changes" else f"AC-3: the Staged request option's confirming button is {field(staged_r, 'verb')!r}, want 'Request changes'",
  None if list_changes == "Request changes" else f"AC-3: the row's data-q=changes button reads {list_changes!r}, want 'Request changes'",
  None if list_send == "Request changes" else f"AC-3: the list's note-sending button reads {list_send!r}, want exactly 'Request changes'",
  None if drawer_request == "Request changes" else f"AC-3: the drawer's #request reads {drawer_request!r}, want exactly 'Request changes'")

# AC-4: the destination is secondary text outside the name, tied with aria-describedby, the same column everywhere
send_span = re.search(r'data-q="send">[^<]*</button><span([^>]*)>\s*→ \$\{esc\(moves\[1\]\)\}\s*</span><button[^>]*data-q="cancel"', passf)
dec_a = re.search(r"<span([^>]*)>\s*→ \$\{esc\(moves\[0\]\)\}\s*</span>", decf)
dec_r = re.search(r"<span([^>]*)>\s*→ \$\{esc\(moves\[1\]\)\}\s*</span>", decf)
def sid(m):
    i = re.search(r'id="([^"]+)"', m.group(1)) if m else None
    return i.group(1) if i else None
approve_tag = re.search(r'<button[^>]*id="approve"[^>]*>', decf)
send_btn = re.search(r'<button[^>]*data-q="send"[^>]*>', passf)
req_btn = re.search(r'<button[^>]*id="request"[^>]*>', decf)
def desc(tag):
    m = re.search(r'aria-describedby="([^"]*)"', tag.group(0) if tag else "")
    return m.group(1).split() if m else []
wire = re.search(r"aria-labelledby", render_io) and re.search(r"aria-describedby", render_io)
head_span = re.search(r'<span[^>]*\bid="[^"]+"[^>]*>\$\{x\.t\}</span>', render_io) or re.search(r'<span[^>]*\bid=[^>]*>\s*\$\{x\.t\}\s*</span>', render_io)
check("AC-4",
  None if send_span and "hint" in send_span.group(1) else "AC-4: the list's note editor has no '→ <column>' hint span between the Request changes pill and Cancel",
  None if send_span and sid(send_span) and sid(send_span) in desc(send_btn) else "AC-4: the list's send pill is not tied to its destination span by aria-describedby",
  None if dec_a and "hint" in dec_a.group(1) else "AC-4: the drawer has no '→ <Approve column>' hint span beside #approve",
  None if dec_a and sid(dec_a) and sid(dec_a) in desc(approve_tag) and "approve-hint" in desc(approve_tag) else "AC-4: #approve is not described by both its destination span and #approve-hint",
  None if dec_r and "hint" in dec_r.group(1) else "AC-4: the drawer has no '→ <Request-changes column>' hint span under #request",
  None if dec_r and sid(dec_r) and sid(dec_r) in desc(req_btn) else "AC-4: #request is not tied to its destination span by aria-describedby",
  None if not re.search(r'aria-label="[^"]*→', passf + decf) else "AC-4: an aria-label carries the destination",
  None if wire and head_span else "AC-4: the decision box option does not name itself from its heading (heading text in its own span with an id, button aria-labelledby it, aria-describedby the when/then lines)",
  None if "hint" in " ".join(s for s in re.findall(r"([^{}]+)\{", h) if ".decide" in s) and any(".decide .hint" in [x.strip() for x in s.split(",")] for s, _ in re.findall(r"([^{}]+)\{([^{}]*)\}", h)) and any(".edit .hint" in [x.strip() for x in s.split(",")] for s, _ in re.findall(r"([^{}]+)\{([^{}]*)\}", h)) else "AC-4: the hint style is not widened to '.decide .hint, .edit .hint'",
  None if "flex-wrap" in rule(".edit div") else "AC-4: '.edit div' has no flex-wrap: wrap, the destination span would push Cancel out on a small screen")

# AC-5: the opener reads Review for both rows and approves nothing
review_def = re.search(r"const review = \(label, cls\) => `([^`]*)`", passf)
spec_row = re.search(r'c\.column === "Spec Review" \? `([^`]*)`', passf)
check("AC-5",
  None if "Review spec" not in h else 'AC-5: the page still writes "Review spec"',
  None if spec_row and re.search(r'review\("Review"', spec_row.group(1)) else "AC-5: the Spec Review row's opener is not review(\"Review\", ...)",
  None if re.search(r'data-q="approve">Approve</button>\$\{review\("Review"', passf) else 'AC-5: the Staged row does not hold the Approve pill followed by the "Review" opener',
  None if review_def and 'data-go="review"' in review_def.group(1) and "data-open" in review_def.group(1) and "data-q" not in review_def.group(1) else "AC-5: the opener is not data-open + data-go=review without a data-q (it must approve nothing)",
  None if re.search(r'const hit = \{[^}]*r: \'\[data-go="review"\]\'', h) else "AC-5: the key R no longer clicks [data-go=review]")

# AC-6: pt-BR
check("AC-6",
  tr("Approve", "Aprovar"), tr("Request changes", "Pedir mudanças"), tr("Review", "Revisão"),
  gone("Review spec"), gone("Approve and ship"), gone("Approve the spec"), gone("Build it"), gone("Rewrite it"), gone("Not yet"),
  gone("^Approve → ", "rx"), gone("^Request changes → ", "rx"),
  None if "Send back to Coding" in exact else 'catalog "Send back to Coding" was removed, a blocked card still uses it',
  None if not any(re.search(r"^(Aprovar|Pedir mudanças)\b.*→", v) for v in list(exact.values()) + list(rx.values())) else "AC-6: a pt-BR entry still names the decision with its destination (Aprovar → / Pedir mudanças →)",
  None if not any(v in ("Aprovar e publicar", "Aprovar a spec", "Revisar spec") for v in exact.values()) else "AC-6: a second pt-BR name for the decision is still in the catalog")

# AC-7: armed approval
check("AC-7",
  tr("^Approve with (.*)$", "Aprovar com $1", "rx"),
  None if re.search(r"armed \? `Approve with \$\{doubt\}` : a\.dataset\.label", syncf) else "AC-7: syncDecide() no longer writes `Approve with ${doubt}` when armed and data-label otherwise",
  None if re.search(r'data-label="Approve"', approve_btn) else "AC-7: the armed button would return to the destination text: #approve data-label is not 'Approve'")

# AC-8: what must not change, paired with the new names
check("AC-8",
  None if 'const OWNER = { "Spec Review": ["Ready for Dev", "Ready for Refinement"], "Staged": ["Ready for Prod", "Coding"] };' in h else "AC-8: the OWNER column map changed",
  None if 'data-act="approve"' in decf and 'data-act="request-changes"' in decf else "AC-8: #approve / #request lost their data-act",
  None if all(f'data-q="{q}"' in passf for q in ("approve", "changes", "send", "cancel", "unblock")) else "AC-8: the list buttons lost a data-q",
  None if len(appr) == 2 and len(reqc) == 2 and 'id: "send-back"' in optf and 'id: "unblock"' in optf else "AC-8: the option ids changed",
  None if "Goes to ${yes}." in optf and "Goes back to ${no} with your note" in optf else "AC-8: the options' then lines changed",
  None if 'a: \'[data-q="approve"]\'' in h and 'r: \'[data-go="review"]\'' in h else "AC-8: the keys A and R no longer click the approve pill and the review opener",
  None if 'verb: "Send back to Coding"' in optf and "Unblock and retry" in optf else "AC-8: a blocked card's options changed",
  None if "Build this spec?" in h and "Ship it to production?" in h else "AC-8: the questions that head the box changed",
  None if field(staged_a, "t") == "Approve" and field(spec_a, "t") == "Approve" and field(staged_r, "verb") == "Request changes" else "AC-8: the options keep their old names while the ids and the destinations stay (names did not change, moves did not move)")

sys.stdout.reconfigure(encoding="ascii", errors="backslashreplace")  # the red/green output stays plain text
for ac in sorted(res):
    print(ac + ": " + ("ok" if not res[ac] else "FAIL " + "; ".join(res[ac])))
PY
)"
for n in 1 2 3 4 5 6 7 8; do
  line="$(printf '%s\n' "$out" | grep -a "^AC-$n:")"
  case "$line" in
    "AC-$n: ok") pass "AC-$n" ;;
    "") fail "AC-$n: the check did not run: $out" ;;
    *) fail "$line" ;;
  esac
done
finish
