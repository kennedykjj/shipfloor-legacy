"""deps: the issues a card is "Blocked by" (GitHub's issue dependencies), for the dispatcher (#202).

blocked_by(repo, n) makes one REST call; the dispatcher records what it read in <home>/deps.json:
    {"<n>": {"read": bool, "deps": [{"n": 162, "title": "...", "state": "open" | "closed"}]}}
"""
import json
import os
import subprocess
import tempfile

from . import proc


def blocked_by(repo, n):
    """The issues #n is blocked by: [{"n", "title", "state"}]; None when GitHub did not answer with a JSON array.
    A closed issue is closed whatever the reason (completed or not planned)."""
    argv = proc.gh_argv("api", "repos/%s/issues/%s/dependencies/blocked_by?per_page=100" % (repo, n))
    try:
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    try:
        body = json.loads(r.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None
    if not isinstance(body, list):
        return None
    out = []
    for d in body:
        if not isinstance(d, dict):
            return None
        try:
            num = int(d.get("number"))
        except (TypeError, ValueError):
            return None
        state = "closed" if str(d.get("state", "")).lower() == "closed" else "open"
        out.append({"n": num, "title": str(d.get("title") or ""), "state": state})
    return out


def open_numbers(deps):
    """The numbers of the dependencies still open."""
    return [d["n"] for d in deps or [] if d.get("state") != "closed"]


def load(home):
    """<home>/deps.json as a dict; empty when missing or unreadable."""
    try:
        with open(os.path.join(home, "deps.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save(home, record):
    """Write <home>/deps.json atomically (a temp file in the same directory, then os.replace)."""
    path = os.path.join(home, "deps.json")
    fd, tmp = tempfile.mkstemp(prefix="deps.json.", suffix=".tmp", dir=home)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            json.dump(record, f, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
