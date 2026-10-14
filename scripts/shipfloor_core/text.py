"""Text helpers: the language catalogs and POSIX ERE matching, both through the same tools the scripts use."""
import os
import subprocess

_LANG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lang")


def say(lang, text):
    """Text written in English, in `lang` (lang/<lang>.sed); unchanged with no catalog or for en."""
    code = lang or "en"
    cat = os.path.join(_LANG, code + ".sed")
    if code == "en" or "/" in code or "\\" in code or not os.path.isfile(cat):
        return text
    r = subprocess.run(["sed", "-E", "-f", cat], input=text.encode("utf-8"),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError("sed failed on %s: %s" % (cat, r.stderr.decode("utf-8", "replace").strip()))
    return r.stdout.decode("utf-8")


def _grep(pattern, text, ignore_case, invert):
    flags = "-E" + ("i" if ignore_case else "") + ("v" if invert else "")
    r = subprocess.run(["grep", flags, "--", pattern], input=text.encode("utf-8", "surrogateescape"),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
