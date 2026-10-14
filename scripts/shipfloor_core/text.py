"""Text helpers: the language catalogs and POSIX ERE matching, both through the same tools the scripts use."""
import os
import subprocess

_LANG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lang")


def _catalog(lang):
    """lang/<lang>.sed, or None for en, a name that is not a plain code, or a language with no catalog."""
    code = lang or "en"
    cat = os.path.join(_LANG, code + ".sed")
    if code == "en" or "/" in code or "\\" in code or not os.path.isfile(cat):
        return None
    return cat


def say_bytes(lang, data):
    """`sed -E -f lang/<lang>.sed` on bytes: (exit code, stdout, stderr); the bytes unchanged with no catalog or for en."""
    cat = _catalog(lang)
    if cat is None:
        return 0, data, b""
    r = subprocess.run(["sed", "-E", "-f", cat], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout, r.stderr


def say(lang, text):
    """Text written in English, in `lang` (lang/<lang>.sed); unchanged with no catalog or for en."""
    cat = _catalog(lang)
    if cat is None:
        return text
    rc, out, err = say_bytes(lang, text.encode("utf-8"))
    if rc != 0:
        raise RuntimeError("sed failed on %s: %s" % (cat, err.decode("utf-8", "replace").strip()))
    return out.decode("utf-8")


def grep(flags, pattern, data, stdout=subprocess.PIPE, stderr=subprocess.PIPE):
    """`grep <flags> -- <pattern>` on data (bytes): the CompletedProcess. The one place the package starts grep, so
    every pattern from a project's config is matched with the same engine and its POSIX ERE semantics."""
    return subprocess.run(["grep", flags, "--", pattern], input=data, stdout=stdout, stderr=stderr)


def grep_lines(pattern, lines, invert=False):
    """`printf '%s\\n' lines | grep -E[v] -- pattern`: (the lines kept, grep's stderr bytes). Exit 1 keeps none; an
    invalid pattern (exit 2) keeps none and its message is in the stderr, as the Bash callers' `|| true` left it."""
    data = ("\n".join(lines) + "\n").encode("utf-8", "surrogateescape") if lines else b""
    r = grep("-Ev" if invert else "-E", pattern, data)
    if r.returncode not in (0, 1):
        return [], r.stderr
    kept = r.stdout.decode("utf-8", "surrogateescape").split("\n")
    if kept and kept[-1] == "":
        kept.pop()
    return kept, r.stderr


def grep_lines(pattern, lines, invert=False):
    """`printf '%s\\n' lines | grep -E[v] -- pattern`: (the lines kept, grep's stderr bytes). Exit 1 keeps none; an
    invalid pattern (exit 2) keeps none and its message is in the stderr, as the Bash callers' `|| true` left it."""
    data = ("\n".join(lines) + "\n").encode("utf-8", "surrogateescape") if lines else b""
    r = subprocess.run(["grep", "-Ev" if invert else "-E", "--", pattern], input=data,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode not in (0, 1):
        return [], r.stderr
    kept = r.stdout.decode("utf-8", "surrogateescape").split("\n")
    if kept and kept[-1] == "":
        kept.pop()
    return kept, r.stderr


def _grep(pattern, text, ignore_case, invert):
    flags = "-E" + ("i" if ignore_case else "") + ("v" if invert else "")
    r = grep(flags, pattern, text.encode("utf-8", "surrogateescape"))
    if r.returncode in (0, 1):
        return r
    raise ValueError("invalid pattern %r: %s" % (pattern, r.stderr.decode("utf-8", "replace").strip()))


def ere_match(pattern, text, ignore_case=False, invert=False):
    """True when `grep -E` (-Ei; -Ev with invert: a line that does not match) finds the pattern in the text; an
    invalid pattern raises (grep exit 2)."""
    return _grep(pattern, text, ignore_case, invert).returncode == 0


def ere_lines(pattern, text, ignore_case=False):
    """What `grep -E` prints: the lines of the text where the pattern matches, each with its newline ("" for none);
    an invalid pattern raises (grep exit 2)."""
    return _grep(pattern, text, ignore_case, False).stdout.decode("utf-8", "surrogateescape")


def read_tab(line, n):
    """IFS=$'\\t' read -r v1 .. vn: tabs around the line dropped, runs of tabs split, the last name takes the rest."""
    s = line.strip("\t")
    out = []
    for _ in range(n - 1):
        i = s.find("\t")
        if i < 0:
            out.append(s)
            s = ""
        else:
            out.append(s[:i])
            s = s[i:].lstrip("\t")
    out.append(s)
    return out
