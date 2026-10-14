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


def ere_match(pattern, text, ignore_case=False):
    """True when `grep -E` (-Ei) finds the pattern in the text; an invalid pattern raises (grep exit 2)."""
    r = subprocess.run(["grep", "-Ei" if ignore_case else "-E", "--", pattern],
                       input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode == 0:
        return True
    if r.returncode == 1:
        return False
    raise ValueError("invalid pattern %r: %s" % (pattern, r.stderr.decode("utf-8", "replace").strip()))
