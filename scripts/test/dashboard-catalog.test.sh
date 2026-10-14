#!/usr/bin/env bash
# The dashboard's catalogs (#122): every string the page shows is a message asked for by its key, and English is a
# catalog like the others (scripts/lang/dashboard.<code>.json). This fails when a catalog lacks a key the English one
# has or carries one it does not, when the English catalog lacks a key the page or the server asks for or keeps one
# nothing asks for, and when a translation drops a value, a plural form its language needs, or the page's markup.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" -I - "$FACTORY_DIR" <<'PY'
import json, re, sys
from pathlib import Path
here = Path(sys.argv[1])
res = []
def check(name, cond, why=""):
    if isinstance(why, list): why = ", ".join(why[:15]) + (f" (and {len(why) - 15} more)" if len(why) > 15 else "")
    res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))

sys.path.insert(0, str(here))
import shipfloor_config
page = (here / "dashboard.html").read_text(encoding="utf-8")
cats = {p.name[len("dashboard."):-len(".json")]: p for p in sorted((here / "lang").glob("dashboard.*.json"))}
load = lambda code: json.loads(cats[code].read_text(encoding="utf-8"))
en = load("en")["messages"]

# the keys asked for: every string of the page under a namespace of the catalog, data-i*, and the server's Msg keys;
# a key built in a template literal (`stage.${st}`) is a pattern that must match at least one key
spaces = {k.split(".")[0] for k in en}
script = page[page.index("<script>\n\"use strict\""):]
literal = set(re.findall(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"', script))
used = {k for k in literal if k.split(".")[0] in spaces}
used |= set(re.findall(r'data-i(?:-title|-aria|-ph)?="([^"]+)"', page))
server = set()
for f in ("shipfloor_config.py", "dashboard.py"):
    server |= set(re.findall(r'Msg\("([a-z0-9_.]+)"', (here / f).read_text(encoding="utf-8")))
patterns = set()
for tpl in re.findall(r"\b(?:t|ta)\(`([^`]*)`", script):
    patterns.add(re.compile("^" + ".+".join(re.escape(x) for x in re.split(r"\$\{[^}]*\}", tpl)) + "$"))
missing = sorted((used | server) - set(en))
check("the English catalog has every key the page and the server ask for", not missing, missing)
unused = sorted(k for k in en if k not in used and k not in server and not any(p.match(k) for p in patterns))
check("the English catalog carries no key nothing asks for", not unused, unused)
idle = sorted(p.pattern for p in patterns if not any(p.match(k) for k in en))
check("every key built in the page matches a key of the catalog", not idle, idle)
check("the page asks for its strings by key: no catalog of English text, no regular expressions", "LANG.exact" not in page and "LANG.rx" not in page and "MutationObserver" not in page, "the old text-matching catalog is still in the page")

# a message: {name}, {n, plural, one {...} other {...}}; '#' in a form is n
def parse(m, at=""):
    """the values a message takes and, per plural value, the forms it gives; raises on unbalanced braces"""
    names, forms, i = set(), {}, 0
    while i < len(m):
        if m[i] == "}": raise ValueError(f"a lone }} at {at}{i}")
        if m[i] != "{": i += 1; continue
        d, j = 1, i + 1
        while j < len(m) and d:
            d += {"{": 1, "}": -1}.get(m[j], 0); j += 1
        if d: raise ValueError(f"an open {{ at {at}{i}")
        body = m[i + 1:j - 1]
        pl = re.match(r"\s*(\w+)\s*,\s*plural\s*,(.*)$", body, re.S)
        if not pl:
            if not re.fullmatch(r"\w+", body.strip()): raise ValueError(f"{{{body}}} is not a value")
            names.add(body.strip())
        else:
            names.add(pl[1]); fs = forms.setdefault(pl[1], set()); rest = pl[2]
            while rest.strip():
                sel = re.match(r"\s*(=\d+|\w+)\s*\{", rest)
                if not sel: raise ValueError(f"a plural form without a selector in {{{body}}}")
                k, d = sel.end(), 1
                while k < len(rest) and d:
                    d += {"{": 1, "}": -1}.get(rest[k], 0); k += 1
                if d: raise ValueError(f"an open plural form in {{{body}}}")
                fs.add(sel[1]); n2, f2 = parse(rest[sel.end():k - 1], at); names |= n2
                for a, b in f2.items(): forms.setdefault(a, set()).update(b)
                rest = rest[k:]
        i = j
    return names, forms
tags = lambda m: sorted(re.findall(r"</?[a-z]+[^>]*>", m))
# the plural forms a language needs (CLDR cardinals, whole numbers): a form it lacks falls back to "other"
NEEDS = {"en": {"one", "other"}, "de": {"one", "other"}, "es": {"one", "other"}, "fr": {"one", "other"}, "it": {"one", "other"}, "pt-BR": {"one", "other"},
         "tr": {"one", "other"}, "ru": {"one", "few", "many", "other"}, "ja": {"other"}, "ko": {"other"}, "zh-CN": {"other"}, "zh-TW": {"other"}}

check("Settings > Language offers every language with a catalog, and only those", list(cats) and set(cats) == set(shipfloor_config.LANGS), f"catalogs {sorted(cats)}, LANGS {sorted(shipfloor_config.LANGS)}")
shape = {}
for code in cats:
    try:
        c = load(code)
    except ValueError as e:
        check(f"{code}: the catalog is JSON", False, str(e)); continue
    msgs = c.get("messages") if isinstance(c.get("messages"), dict) else {}
    check(f"{code}: the catalog names its language in itself", isinstance(c.get("name"), str) and c["name"].strip(), repr(c.get("name")))
    lacks, extra = sorted(set(en) - set(msgs)), sorted(set(msgs) - set(en))
    check(f"{code}: no key of the English catalog is missing", not lacks, lacks)
    check(f"{code}: no key the English catalog does not have", not extra, extra)
    bad = []
    for k, m in msgs.items():
        if k not in en: continue
        if not isinstance(m, str) or not m.strip():
            bad.append(f"{k}: empty"); continue
        try:
            names, forms = parse(m); want, wforms = parse(en[k])
        except ValueError as e:
            bad.append(f"{k}: {e}"); continue
        if names != want: bad.append(f"{k}: takes {sorted(names)}, English takes {sorted(want)}")
        for v in wforms:
            if v in forms and not NEEDS.get(code, {"other"}) <= forms[v]: bad.append(f"{k}: {v} has the forms {sorted(forms[v])}, {code} needs {sorted(NEEDS[code])}")
        if tags(m) != tags(en[k]): bad.append(f"{k}: markup {tags(m)}, English has {tags(en[k])}")
    check(f"{code}: every message keeps the English one's values, plural forms and markup", not bad, bad)
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"

# t() in node: a value, a plural form by Intl.PluralRules, a missing key in English, a value that is a message itself
if command -v node >/dev/null; then
  core="$(sed -n '/^const LANG = /,/^const told = /p' "$FACTORY_DIR/dashboard.html")"
  got="$(node -e '
const esc = (s) => String(s);
const $ = () => ({ textContent: JSON.stringify({ language: "ru", messages: { "a.b": "{n, plural, one {# карточка} few {# карточки} many {# карточек} other {# карточки}}", "a.v": "в {x}" },
  en: { "a.b": "{n, plural, one {# card} other {# cards}}", "a.v": "in {x}", "a.only": "only {y}", "a.in": "({m})" } }) });
'"$core"'
console.log([t("a.b", { n: 1 }), t("a.b", { n: 3 }), t("a.b", { n: 5 }), t("a.b", { n: 21 }), t("a.v", { x: "<b>" }), t("a.only", { y: 2 }), t("a.in", { m: { key: "a.v", params: { x: 1 } } }), t("a.none")].join("|"))')"
  [ "$got" = "1 карточка|3 карточки|5 карточек|21 карточка|в <b>|only 2|(в 1)|a.none" ] && pass "t(): values, Russian plural forms, English for a missing key, a message as a value" || fail "t() gave: $got"
else
  pass "t(): node is not installed here; the catalog checks above still ran"
fi
# dur() in node (#119): long durations in days, its words the English catalog's
if command -v node >/dev/null; then
  durjs="$(grep -e '^function dur(' -e '^const pad = ' "$FACTORY_DIR/dashboard.html")"
  got="$(node -e "const EN = require('$(cd "$FACTORY_DIR" && pwd)/lang/dashboard.en.json').messages, t = (k, v) => EN[k].replace(/\{(\w+)\}/g, (_, x) => v[x]);
$durjs
const at = (s) => dur(new Date(0).toISOString(), new Date(s * 1000).toISOString());
console.log([42 * 60, 47 * 3600 + 59 * 60, 48 * 3600, 48 * 3600 + 60, 96 * 3600 + 8 * 60, 49 * 3600, 12 * 86400 + 23 * 3600 + 59 * 60].map(at).join('|'))")"
  [ "$got" = "42m|47h59|48h00|2d 0h|4d 0h|2d 1h|12d 23h" ] && pass "dur(): 42m, 47h59, 48h00, then days and hours" || fail "dur() gave $got"
else
  pass "dur(): node is not installed here"
fi
finish
