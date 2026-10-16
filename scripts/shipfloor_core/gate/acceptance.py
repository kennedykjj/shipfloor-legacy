"""The gates around QA's acceptance tests: acceptance-intact, acceptance-own (for shipfloor accept), qa-commit, qa-amend."""
import json
import os
import re
import time
import shutil
import subprocess
import tempfile
from collections import Counter

from .. import proc, text
from . import changes
from .scope import grep, _bad

# QA may correct its own acceptance tests when the implementation shows one was wrong, or when a merge from main
# reshaped a file they share: it commits again under the QA message and that commit becomes what acceptance-intact
# protects. Nobody reviews the amendment before the run goes on, so qa-amend keeps it honest: it is the last commit,
# it touches only tests, it loses no assertion line, it switches no test off, and a card is amended at most twice.
SKIP_MARKS = r"\.(skip|only|fixme|todo)\(|@Disabled|@Ignore|\b(xit|xdescribe|xtest)\(|\bt\.Skip\(|pytest\.mark\.skip"
KEEP_DEFAULT = r"assert|expect\(|verify\(|should"
STUB_MARK = "shipfloor:qa-stub"  # in a file QA wrote only so the red gate compiles: the implementer deletes it
_COMMENT = re.compile(r"^[+-][ \t]*(//|/\*|\*|#|--|<!--)")  # a diff line that is only a comment
_NUMBER = re.compile(r"[0-9]+")
_QA_SUBJECT = re.compile(r"acceptance tests for #([0-9]+)")
_BLANK = re.compile(rb"[ \t\n\r\f\v]*")


def _text(data):
    return data.decode("utf-8", "surrogateescape")


def _lines(data):
    """The lines of some output, as `read` or `$(...)` sees them (no trailing empty line)."""
    parts = data.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return parts


def is_stub(ctx, rev, path):
    """The file at rev carries STUB_MARK: QA's temporary stub for the red gate, not an acceptance test."""
    r = _quiet("show", "%s:%s" % (rev, path))
    return r.returncode == 0 and STUB_MARK.encode() in r.stdout


def _quiet(*args):
    """git with names never C-quoted and its stderr dropped (`2>/dev/null`)."""
    return proc.git("-c", "core.quotePath=false", *args)


def _ok(*args):
    return _quiet(*args).returncode == 0


def _show(rev, path):
    """`git show <rev>:<path>` with its stderr dropped: the bytes, or None when it fails."""
    r = _quiet("show", "%s:%s" % (rev, path))
    return r.stdout if r.returncode == 0 else None


def _rev(rev):
    r = _quiet("rev-parse", "-q", "--verify", rev + "^{commit}")
    return r.returncode == 0


def _merge_base(a, b):
    r = _quiet("merge-base", a, b)
    return _text(r.stdout).rstrip("\n") if r.returncode == 0 else None


def main_bases(ctx, qa):
    """(newest main commit merged into the card, its common ancestor with QA), or None when there is no main.
    The same for every file of a QA commit: found once per gate."""
    cache = ctx.__dict__.setdefault("_main_bases", {})
    if qa not in cache:
        branch = os.environ.get("FACTORY_MAIN") or "main"
        main = next((m for m in ("origin/" + branch, branch) if _rev(m)), "")
        m = b = ""
        if main:
            m = _merge_base("HEAD", main) or ""
        if m:
            b = _merge_base(qa, m)
            if b is None:
                m, b = "", ""
        cache[qa] = (m, b)
    m, b = cache[qa]
    return (m, b) if m else None


def main_sides(ctx, qa, path):
    """(QA's version, main's, their common ancestor's) of a file, or None when main brought nothing to it."""
    bases = main_bases(ctx, qa)
    if bases is None:
        return None
    m, b = bases
    if m == b or not _ok("cat-file", "-e", "%s:%s" % (m, path)):
        return None
    ours = _show(qa, path)
    if ours is None:
        return None
    r = proc.git("-c", "core.quotePath=false", "show", "%s:%s" % (m, path))
    ctx.err_bytes(r.stderr)  # heard, as in the Bash gate
    if r.returncode != 0:
        return None
    base = _show(b, path)
    return ours, r.stdout, base if base is not None else b""


def merged_with_main(ctx, qa, path):
    """The file a clean merge gives (QA's version + main's over their common ancestor), or None when main brought
    nothing or the merge needs a hand. Acceptance tests often live in files main also edits."""
    sides = main_sides(ctx, qa, path)
    if sides is None:
        return None
    tmp = tempfile.mkdtemp()
    try:
        ours, theirs, base = sides
        names = []
        for name, data in (("qa", ours), ("base", base), ("main", theirs)):
            p = os.path.join(tmp, name)
            with open(p, "wb") as f:
                f.write(data)
            names.append(p)
        r = subprocess.run(["git", "merge-file", "-q", *names], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            return None
        with open(names[0], "rb") as f:
            return f.read()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _diff_d(old, new):
    """The lines `diff -d` marks as added from old to new (both lists of byte lines), in order."""
    tmp = tempfile.mkdtemp()
    try:
        paths = []
        for name, lines in (("a", old), ("b", new)):
            p = os.path.join(tmp, name)
            with open(p, "wb") as f:
                f.write(b"".join(l + b"\n" for l in lines))
            paths.append(p)
        r = subprocess.run(["diff", "-d", *paths], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return [l[2:] for l in _lines(r.stdout) if l.startswith(b"> ")]


def _subsequence(part, whole):
    """True when every line of part is in whole, in order (a minimal diff of part against whole deletes nothing)."""
    it = iter(whole)
    return all(any(l == w for w in it) for l in part)


def both_sides_kept(ctx, qa, path):
    """A hand-resolved merge with main where HEAD is QA's version plus main's and nothing of its own.
    QA and main appending tests at the same spot conflict in git though neither loses a line. Passes when, blank lines
    aside: the lines QA added and the lines main added are all in HEAD, each side's in its order; HEAD has no line that
    neither has; and HEAD lacks no line of either, except one copy of a line both added (the same import)."""
    sides = main_sides(ctx, qa, path)
    if sides is None:
        return False
    head = _show("HEAD", path)
    if head is None:
        return False
    ours, theirs, base = ([l for l in _lines(x) if not _BLANK.fullmatch(l)] for x in sides)
    head = [l for l in _lines(head) if not _BLANK.fullmatch(l)]
    qa_add, main_add = _diff_d(base, ours), _diff_d(base, theirs)
    want, got = Counter(ours + theirs), Counter(head + base)
    return (_subsequence(qa_add, head) and _subsequence(main_add, head) and not (got - want)
            and not ((want - got) - (Counter(qa_add) & Counter(main_add))))


def only_main_changed(ctx, qa, path):
    """HEAD's file is the QA version plus what merges from main brought, nothing else. An edit by the card, or a merge
    that needed a hand resolution, differs from the clean merge."""
    merged = merged_with_main(ctx, qa, path)
    return merged is not None and _quiet("show", "HEAD:" + path).stdout == merged


def own_edit(ctx, qa, path):
    """The lines the card itself removed (<) or added (>), without what merges from main brought, as `diff` prints
    them; None when QA's version cannot be read. Against the clean merge when there is one, else against QA's version:
    that diff is larger, so it only blocks more."""
    old = merged_with_main(ctx, qa, path)
    if old is None:
        old = _show(qa, path)
        if old is None:
            return None
    new = _quiet("show", "HEAD:" + path).stdout
    fd, tmp = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(old)
        r = subprocess.run(["diff", tmp, "-"], input=new, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    finally:
        os.unlink(tmp)
    ctx.err_bytes(r.stderr)
    return b"".join(l + b"\n" for l in _lines(r.stdout) if l[:1] in (b"<", b">"))


def own_key(ctx, qa, path):
    """What shipfloor accept records for the card's own edit ("own:<blob hash>"), or None when there is none.
    A merge from main elsewhere in the file keeps it."""
    own = own_edit(ctx, qa, path)
    if own is None:
        return None
    own = own.rstrip(b"\n")
    if not own:
        return None
    r = subprocess.run(["git", "hash-object", "--stdin"], input=own + b"\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    ctx.err_bytes(r.stderr)
    return "own:" + _text(r.stdout).rstrip("\n")


def assertions_kept(ctx, qa, path, keep):
    """The card's own edits add or remove no line matching keep (acceptance_assertions)."""
    if not keep:
        return False
    own = own_edit(ctx, qa, path)
    if own is None:
        return False
    return not grep(ctx, keep, _text(own.rstrip(b"\n")).split("\n"))


def owner_accepted(ctx, path, qa=""):
    """The owner reviewed the card's own edit, this exact content or its deletion, and recorded it (shipfloor accept)."""
    tsv = os.path.join(os.environ.get("FACTORY_HOME", ""), "accepted.tsv")
    if not os.path.isfile(tsv):
        return False
    r = _quiet("rev-parse", "-q", "--verify", "HEAD:" + path)
    blob = _text(r.stdout).rstrip("\n") if r.returncode == 0 else "deleted"
    own = ""
    if blob != "deleted" and qa:
        own = own_key(ctx, qa, path) or ""
    try:
        with open(tsv, "rb") as f:
            rows = _lines(f.read())
    except OSError:
        return False
    for row in rows:
        fields = _text(row).split("\t")
        second = fields[1] if len(fields) > 1 else ""
        if fields[0] == path and (second == blob or (own and second == own)):
            return True
    return False


def qa_commits(ctx, n, rev="HEAD"):
    """Card n's QA commits up to rev, newest first (every "acceptance tests for #<n>")."""
    out = changes.git(ctx, "log", "--format=%H", "-E", "--grep", "acceptance tests for #%s([^0-9]|$)" % n, rev)
    return _text(out).split()


def _names(ctx, *args):
    """`git show --name-only --format= ...`: the names it prints, blank lines gone."""
    return [l for l in _lines(changes.git(ctx, "show", "--name-only", "--format=", *args)) if l]


def check_acceptance_intact(ctx, qa, keep=None):
    """The acceptance-intact gate. `keep` is acceptance_assertions when the caller (fast) has it already."""
    changes.require_rev(ctx, qa)
    if keep is None:
        keep = changes._cfg(("get", "acceptance_assertions")).stdout.decode("utf-8", "surrogateescape").rstrip("\n")
    # The newest QA commit is the baseline, but an amendment that touched one file must not leave the rest of the
    # card's acceptance tests unprotected: the files of every QA commit of the card count, as they are at the baseline.
    subject = _text(changes.git(ctx, "log", "-1", "--format=%s", qa))
    n = "\n".join(_QA_SUBJECT.findall(subject))
    names = _names(ctx, "--diff-filter=d", qa)  # files the QA commit deleted are not acceptance tests
    if n:
        for c in qa_commits(ctx, n, qa):
            names += _names(ctx, "--diff-filter=d", c)
    files = [_text(f) for f in changes._sort_u(names)]
    files = [f for f in files if f and _ok("cat-file", "-e", "%s:%s" % (qa, f)) and not is_stub(ctx, qa, f)]
    if not files:
        ctx.err("acceptance-intact: QA commit %s has no files" % qa)
        return 1
    changed = []
    for f in files:
        here = os.path.exists(f)
        if not here and not _ok("cat-file", "-e", "HEAD:" + f):  # deleted and committed
            if not owner_accepted(ctx, f):
                changed.append(f)
        elif not here or _diff_differs(ctx, "HEAD", "--", f):
            changed.append(f)
        elif (not _diff_differs(ctx, qa, "HEAD", "--", f) or only_main_changed(ctx, qa, f)
              or both_sides_kept(ctx, qa, f) or owner_accepted(ctx, f, qa)):
            pass
        elif assertions_kept(ctx, qa, f, keep):
            ctx.err("acceptance-intact: %s changed, but no assertion line did (acceptance_assertions); passed" % f)
        else:
            changed.append(f)
    bad = _bad(changed)
    if not bad:
        return 0
    ctx.err("acceptance-intact: acceptance tests changed after the QA commit (beyond what merges from main brought):")
    ctx.err(bad)
    ctx.err("acceptance-intact: the owner can review these files and record them as they stand: "
            "shipfloor accept <project> <n> <reason>")
    return 1


def _diff_differs(ctx, *args):
    """`! git diff --quiet ...`: a difference or an error; git's stderr is the gate's."""
    r = proc.git("diff", "--quiet", *args)
    ctx.err_bytes(r.stderr)
    return r.returncode != 0


def acceptance_intact(ctx, args):
    return check_acceptance_intact(ctx, args[0] if args else "")


def acceptance_own(ctx, args):
    """For shipfloor accept: the key of the card's own edit of a file, on stdout."""
    qa = args[0] if args else ""
    changes.require_rev(ctx, qa)
    key = own_key(ctx, qa, args[1] if len(args) > 1 else "")
    if key is None:
        return 1
    ctx.out(key)
    return 0


def _head(ctx):
    return _text(changes.git(ctx, "rev-parse", "HEAD")).rstrip("\n")


def qa_commit(ctx, args):
    """Prints card n's QA commit, the newest "acceptance tests for #<n>" on the branch. Every stage asks here, so a
    rework's QA commit replaces the first one for all of them. --head: it must be the last commit."""
    n = args[0] if args else ""
    flag = args[1] if len(args) > 1 else ""
    if not _NUMBER.fullmatch(n):
        ctx.err("usage: gate.sh qa-commit <n> [--head]")
        ctx.exit(2)
    out = changes.git(ctx, "log", "--format=%H", "-1", "-E", "--grep", "acceptance tests for #%s([^0-9]|$)" % n)
    qa = _text(out).rstrip("\n")
    if not qa or (flag == "--head" and qa != _head(ctx)):
        ctx.err('qa-commit: %sno commit message with "acceptance tests for #%s"%s'
                % ("the last commit is not the QA commit: " if flag else "", n, " at HEAD" if flag else ""))
        return 1
    ctx.out(qa)
    return 0


def _count(ctx, pattern, lines):
    """`grep -Ec -- pattern` of the lines: the count it prints ("" when the pattern is invalid)."""
    data = ("\n".join(lines) + "\n").encode("utf-8", "surrogateescape") if lines else b""
    r = text.grep("-Ec", pattern, data)
    ctx.err_bytes(r.stderr)
    return _text(r.stdout).strip("\n")


def _int(value):
    try:
        return int(value)
    except ValueError:
        return 0


AMEND_LABEL = "qa-amend-ok"


def _amend_tsv():
    return os.path.join(os.environ.get("FACTORY_HOME", ""), "qa-amend-ok.tsv")


def _recorded(n, sha):
    """HEAD's commit was already approved (the label was spent on it): a rerun passes without GitHub."""
    try:
        with open(_amend_tsv(), "rb") as f:
            rows = _lines(f.read())
    except OSError:
        return False
    return any(_text(r).split("\t")[:2] == ["#" + n, sha] for r in rows)


def _gh_json(ctx, *args):
    """gh's JSON answer (pages joined when it prints several arrays); a failure ends the gate with exit 3 (infra)."""
    try:
        r = proc.gh(*args)
    except OSError:
        r = None
    if r is None or r.returncode == 4:
        return None  # no gh, or none signed in: there is no label to read, so no approval
    if r.returncode != 0 and b"HTTP 404" in r.stderr:
        return None  # no such issue: it has no label
    if r.returncode != 0:
        ctx.err("qa-amend: cannot read GitHub (gh %s):%s" % (" ".join(args[:2]), _text(r.stderr).strip()))
        ctx.exit(3)
    dec, s, pos, got = json.JSONDecoder(), _text(r.stdout), 0, []
    try:
        while True:
            while pos < len(s) and s[pos].isspace():
                pos += 1
            if pos >= len(s):
                break
            v, pos = dec.raw_decode(s, pos)
            got.extend(v) if isinstance(v, list) else got.append(v)
    except ValueError:
        ctx.err("qa-amend: cannot read GitHub (gh %s)" % " ".join(args[:2]))
        ctx.exit(3)
    return got


def _approval(ctx, n, sha):
    """None: no approval. "": this commit was approved before. Otherwise the owner's login: the label is pending."""
    if _recorded(n, sha):
        return ""
    repo = changes.config_query(ctx, "get", "project.repo")
    issue = _gh_json(ctx, "api", "repos/%s/issues/%s" % (repo, n))
    if issue is None:
        return None
    names = [(l or {}).get("name") for i in issue if isinstance(i, dict) for l in i.get("labels") or []]
    if AMEND_LABEL not in names:
        return None
    events = _gh_json(ctx, "api", "repos/%s/issues/%s/events?per_page=100" % (repo, n), "--paginate")
    if events is None:
        return None
    last = [e for e in events if isinstance(e, dict) and e.get("event") == "labeled"
            and (e.get("label") or {}).get("name") == AMEND_LABEL]
    if not last:
        return None
    actor = ((last[-1].get("actor") or {}).get("login")) or ""
    from .. import board
    trusted = board.trusted_logins()
    if trusted is None:
        ctx.err("qa-amend: cannot read the GitHub user")
        ctx.exit(3)
    return actor if actor and ("*" in trusted or actor in trusted) else None


def _spend(ctx, n, sha, actor):
    """Use the approval: remove the label, then record the commit. A label that stays would approve a second time."""
    repo = changes.config_query(ctx, "get", "project.repo")
    try:
        r = proc.gh("api", "-X", "DELETE", "repos/%s/issues/%s/labels/%s" % (repo, n, AMEND_LABEL))
    except OSError:
        r = None
    if r is None or r.returncode != 0:
        ctx.err("qa-amend: cannot remove the label %s from #%s" % (AMEND_LABEL, n))
        ctx.exit(3)
    os.makedirs(os.environ.get("FACTORY_HOME", "") or ".", exist_ok=True)
    with open(_amend_tsv(), "a", encoding="utf-8", newline="\n") as f:
        f.write("#%s\t%s\t%s\t%s\n" % (n, sha, actor, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))


def qa_amend(ctx, args):
    n = args[0] if args else ""
    if not _NUMBER.fullmatch(n):
        ctx.err("usage: gate.sh qa-amend <n>")
        ctx.exit(2)
    most = os.environ.get("FACTORY_QA_AMEND_MAX") or "2"
    every = qa_commits(ctx, n)
    new = every[0] if every else ""
    prev = every[1] if len(every) > 1 else ""
    if not new or new != _head(ctx):
        ctx.err('qa-amend: the last commit is not a QA commit ("acceptance tests for #%s")' % n)
        return 1
    if not prev:
        ctx.err("qa-amend: #%s has one QA commit, so nothing was amended" % n)
        return 1
    approval = None
    if len(every) > _int(most) + 1:
        approval = _approval(ctx, n, new)
        if approval is None:
            ctx.err("qa-amend: the acceptance tests of #%s were already amended %s times; the owner decides now. "
                    "To allow one more amendment, add the label qa-amend-ok to the issue, or press "
                    '"Approve this amendment" on the card in the dashboard.' % (n, most))
            return 1
    allowed = changes.config_query(ctx, "regex", "scope", "qa")
    bad = _bad(grep(ctx, allowed, [_text(l) for l in _names(ctx, new)], invert=True))
    if bad:
        ctx.err("qa-amend: the amendment touches files that are not tests:")
        ctx.err(bad)
        return 1
    keep = changes._cfg(("get", "acceptance_assertions")).stdout.decode("utf-8", "surrogateescape").rstrip("\n")
    keep = keep or KEEP_DEFAULT
    names = []
    for c in every:
        names += _names(ctx, c)
    paths = [_text(f) for f in changes._sort_u(names)]
    paths = [f for f in paths if not is_stub(ctx, prev, f) and not is_stub(ctx, new, f)]  # a stub deleted is no test lost
    diff = _lines(changes.git(ctx, "diff", "-U0", prev, new, "--", *paths)) if paths else []
    d = [_text(l) for l in diff if l[:1] in (b"+", b"-") and not (l.startswith(b"+++ ") or l.startswith(b"--- "))]
    added = [l for l in d if l.startswith("+")]
    removed = [l for l in d if l.startswith("-")]
    off = _bad(grep(ctx, SKIP_MARKS, added))
    # a comment is not an assertion, whatever words it uses ("fail by assertion"): count code lines only
    added = [l for l in added if not _COMMENT.match(l)]
    removed = [l for l in removed if not _COMMENT.match(l)]
    if off:
        ctx.err("qa-amend: the amendment switches a test off:")
        ctx.err(off)
        return 1
    lost, gained = _count(ctx, keep, removed), _count(ctx, keep, added)
    if lost.isdigit() and gained.isdigit() and int(gained) < int(lost):
        ctx.err("qa-amend: the amendment removes %s assertion lines and adds %s; an amended test may check differently, "
                "not less" % (lost, gained))
        return 1
    suffix = ""
    if approval is not None:
        if approval:  # pending: spend the label, then record the commit
            _spend(ctx, n, new, approval)
        suffix = "; one amendment over the limit approved by the owner (qa-amend-ok)"
    ctx.err("qa-amend: ok, %s assertion lines replaced by %s%s" % (lost, gained, suffix))
    return 0
