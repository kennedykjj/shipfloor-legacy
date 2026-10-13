"""The page's text for the tests that read dashboard.html as text (#122). The page asks for its strings by key
(t("key", {values}), ta(...) for an attribute); english(h) writes each call whose arguments it can read out as the
English message (a string literal in code, the bare text inside ${} of a template literal), a value as ${name} and a plural as its "other" form with ${n} for '#', so a test can still look for
what the page says. exact(code) maps each English message with no value to that language's one, as the old
text-matching catalog did; msg(code, key) is one message. Standard library only."""
import json, re
from pathlib import Path

LANG = Path(__file__).resolve().parent.parent / "lang"


def catalog(code):
    try:
        return json.loads((LANG / f"dashboard.{code}.json").read_text(encoding="utf-8")).get("messages", {})
    except (OSError, ValueError):
        return {}


EN = catalog("en")


def msg(code, key):
    return catalog(code).get(key)


def plain(m, vals=None):
    """a message as one English string: the "other" form of a plural, ${name} for a value (or the source the call
    gives it, from vals: a template literal's own text)"""
    vals = vals or {}
    out, i = "", 0
    while i < len(m):
        if m[i] != "{":
            out += m[i]; i += 1; continue
        d, j = 1, i + 1
        while j < len(m) and d:
            d += {"{": 1, "}": -1}.get(m[j], 0); j += 1
        body = m[i + 1:j - 1]
        pl = re.match(r"\s*(\w+)\s*,\s*plural\s*,(.*)$", body, re.S)
        if pl:
            other = re.search(r"other\s*\{", pl[2])
            k, d = other.end(), 1
            while d:
                d += {"{": 1, "}": -1}.get(pl[2][k], 0); k += 1
            out += plain(pl[2][other.end():k - 1], vals).replace("#", "${" + (vals.get(pl[1]) or pl[1]).strip("`") + "}")
        else:
            v = vals.get(body.strip())
            out += v[1:-1] if v and v[0] == "`" and v[-1] == "`" else "${" + (v or body.strip()) + "}"
        i = j
    return out


def english(h):
    """h with t("key"...) and ta("key"...) written out as their English message, when the key is a literal"""
    out, i = [], 0
    for m in re.finditer(r'\b(?:ta|t)\("([a-z0-9_.]+)"', h):
        if m.start() < i or (m.start() and h[m.start() - 1] in "._"):
            continue
        j, d, q = m.end(), 1, None  # to the closing parenthesis, past strings and template literals
        while j < len(h) and d:
            c = h[j]
            if q:
                if c == "\\": j += 1
                elif c == q: q = None
            elif c in "\"'`": q = c
            elif c == "(": d += 1
            elif c == ")": d -= 1
            j += 1
        if m.group(1) not in EN:
            continue
        start = m.start()
        if h[start - 2:start] == "${" and h[j:j + 1] == "}":  # ${t("key")} in a template literal: the text alone
            start, j = start - 2, j + 1
        text = plain(EN[m.group(1)], args(h[m.end():j - (2 if start < m.start() else 1)]))
        if start == m.start():  # a call in code: a string literal, as the page had it
            text = "`" + text + "`" if "${" in text else json.dumps(text, ensure_ascii=False)
        out.append(h[i:start]); out.append(text); i = j
    out.append(h[i:])
    out = "".join(out)
    return out if out == h else english(out)  # a value's source may ask for a message of its own


def args(src):
    """{name: source} of a call's values object: `, { a: x, b: `...` }`"""
    src = src.strip().lstrip(",").strip()
    if not (src.startswith("{") and src.endswith("}")):
        return {}
    body, out, part, d, q = src[1:-1], {}, "", 0, None
    for c in body + ",":
        if q:
            part += c
            if c == q: q = None
            continue
        if c in "\"'`": q = c
        elif c in "([{": d += 1
        elif c in ")]}": d -= 1
        if c == "," and d == 0:
            k, _, v = part.partition(":")
            k = k.strip()
            if k: out[k] = (v.strip() or k)
            part = ""
        else:
            part += c
    return out


def exact(code):
    """{English message: that language's message} for every message with no value"""
    other = catalog(code)
    return {v: other[k] for k, v in EN.items() if "{" not in v and k in other}


def one(code, n):
    """the plural form of a whole number n (CLDR cardinals), for the languages of the catalogs"""
    if code == "ru":
        return "one" if n % 10 == 1 and n % 100 != 11 else "few" if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14 else "many"
    if code in ("ja", "ko", "zh-CN", "zh-TW"):
        return "other"
    return "one" if n == 1 or (code in ("fr", "pt-BR") and n == 0) else "other"


def render(code, key, **values):
    """a message as the page shows it in <code> (English for a key the catalog lacks); a value can be {"key", "params"}"""
    m = catalog(code).get(key, EN.get(key, key))
    return fmt(code, m, values)


def fmt(code, m, values, n=None):
    out, i = "", 0
    while i < len(m):
        if m[i] == "#" and n is not None:
            out += str(n); i += 1; continue
        if m[i] != "{":
            out += m[i]; i += 1; continue
        d, j = 1, i + 1
        while j < len(m) and d:
            d += {"{": 1, "}": -1}.get(m[j], 0); j += 1
        body = m[i + 1:j - 1]
        pl = re.match(r"\s*(\w+)\s*,\s*plural\s*,(.*)$", body, re.S)
        if pl:
            v, forms, rest = int(values[pl[1]]), {}, pl[2]
            while rest.strip():
                sel = re.match(r"\s*(=\d+|\w+)\s*\{", rest); k, dd = sel.end(), 1
                while dd:
                    dd += {"{": 1, "}": -1}.get(rest[k], 0); k += 1
                forms[sel[1]] = rest[sel.end():k - 1]; rest = rest[k:]
            out += fmt(code, forms.get(f"={v}", forms.get(one(code, v), forms.get("other", ""))), values, v)
        else:
            v = values.get(body.strip(), "")
            out += render(code, v["key"], **v.get("params", {})) if isinstance(v, dict) else str(v)
        i = j
    return out
