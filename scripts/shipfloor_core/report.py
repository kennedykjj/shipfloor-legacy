"""report: commits a factory report to the orphan branch factory-reports (never merged, never deployed)."""
import os
import subprocess
import sys
import time

from . import fs, project, proc
from .defaults import TRAILER

BRANCH = "factory-reports"


def usage(out):
    print("usage: report.sh <issue> <slug> <pipeline> <report.json> <report.md>", file=out)
    print("  pipeline: refine | develop | validate | deploy; the two files are the ones the run wrote in its tmp folder", file=out)
    print("  run it from the project's control checkout, as every other factory script", file=out)


class _Fail(Exception):
    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def _git(*args, quiet=False, must=True):
    """Run git with the caller's streams (stderr silenced when quiet); a failure aborts unless must is False."""
    err = subprocess.DEVNULL if quiet else None
    out = subprocess.DEVNULL if quiet else None
    sys.stdout.flush()
    sys.stderr.flush()
    r = subprocess.run(["git", *args], stdout=out, stderr=err)
    if r.returncode != 0 and must:
        raise _Fail(r.returncode)
    return r.returncode


def _toplevel():
    r = proc.git("rev-parse", "--show-toplevel")
    if r.returncode != 0:
        raise _Fail(r.returncode)
    return r.stdout.decode("utf-8", "replace").rstrip("\r\n")


def _stamp():
    """`date +%Y-%m-%dT%H%M%S` (the clock the Bash script used, so a fixed `date` still fixes the name)."""
    fmt = "%Y-%m-%dT%H%M%S"
    try:
        r = subprocess.run(["date", "+" + fmt], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.decode("utf-8", "replace").strip()
    except OSError:
        pass
    return time.strftime(fmt)


def main(argv):
    if argv and argv[0] in ("-h", "--help", "help"):
        usage(sys.stdout)
        return 0
    if len(argv) != 5:
        usage(sys.stderr)
        return 2
    try:
        project.resolve(".")
    except project.ProjectError as e:
        print(e, file=sys.stderr)
        return 2
    issue, slug, pipeline, json, md = argv
    try:
        return _run(issue, slug, pipeline, json, md)
    except _Fail as e:
        return e.code
    except OSError as e:
        print("report.sh: %s" % e, file=sys.stderr)
        return 1


def _run(issue, slug, pipeline, json, md):
    home = os.environ["FACTORY_HOME"]
    repo = os.environ.get("FACTORY_REPO") or _toplevel()
    wt = os.path.join(home, "reports-wt")
    br = BRANCH

    if not os.path.exists(os.path.join(wt, ".git")):
        _git("-C", repo, "fetch", "-q", "origin", br, quiet=True, must=False)
        if _git("-C", repo, "rev-parse", "-q", "--verify", "origin/" + br, quiet=True, must=False) == 0:
            _git("-C", repo, "worktree", "add", "-q", "-B", br, wt, "origin/" + br)
        else:
            _git("-C", repo, "worktree", "add", "-q", "--detach", wt)
            _git("-C", wt, "checkout", "-q", "--orphan", br)
            _git("-C", wt, "rm", "-rqf", ".", quiet=True, must=False)
            with open(os.path.join(wt, "README.md"), "w", encoding="utf-8", newline="\n") as f:
                f.write("# Factory reports\n")
            _git("-C", wt, "add", "README.md")
            _git("-C", wt, "commit", "-qm", "chore(factory): start reports branch")
    _git("-C", wt, "pull", "-q", "--rebase", "origin", br, quiet=True, must=False)
    stamp = _stamp()
    d = os.path.join(wt, "reports", "%s-%s" % (issue, slug))
    os.makedirs(d, exist_ok=True)
    for src, ext in ((json, "json"), (md, "md")):
        with open(src, "rb") as f:
            fs.write_atomic(os.path.join(d, "%s-%s.%s" % (pipeline, stamp, ext)), f.read())
    _git("-C", wt, "add", "reports")
    _git("-C", wt, "commit", "-qm", "chore(factory): report #%s %s %s" % (issue, pipeline, stamp), "-m", TRAILER)
    _git("-C", wt, "push", "-q", "origin", br)
    return 0
