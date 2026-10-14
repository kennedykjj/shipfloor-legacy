"""The board suites' harness: shipfloor_core.board.main / setup.main called in this process against a fake gh.

FakeGh answers proc.gh in process, in the shapes GitHub gives (the REST Projects items with Link headers, the GraphQL
board read with pageInfo, the issue and label reads) and evaluates every --jq with the real jq, so the product's
filters are run against real JSON. project.cfg is answered by shipfloor_config in process. Every call is recorded."""
import io
import json
import os
import re
import shutil
import subprocess
import sys

import support
from shipfloor_core import board, proc, project, setup

COLUMNS = ["Inbox", "Ready for Refinement", "Technical Refinement", "Spec Review", "Ready for Dev", "Coding",
           "Validation", "Staged", "Ready for Prod", "Done"]
MARKED = ["👤 Inbox", "👤 Ready for Refinement", "🤖 Technical Refinement", "👤 Spec Review", "👤 Ready for Dev",
          "🤖 Coding", "🤖 Validation", "👤 Staged", "👤 Ready for Prod", "🤖 Done"]
ITEMS = [("25", "👤 Ready for Refinement"), ("26", "👤 Ready for Refinement"), ("33", "👤 Spec Review"),
         ("40", "🤖 Coding"), ("41", "🤖 Validation"), ("47", "👤 Staged")]
PAGE = 100
with open(os.path.join(support.FIXTURE, "factory.yml"), encoding="utf-8") as _f:
    FIX = _f.read()


def strip(s):
    return re.sub(r"^[^A-Za-z]+ ", "", s)


def jq(filt, text):
    r = subprocess.run(["jq", "-r", filt], input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise AssertionError("jq failed on %r: %s" % (filt, r.stderr.decode("utf-8", "replace")))
    return r.stdout.decode("utf-8")


class FakeGh:
    """gh as the board sees it. items: [(number, marked status)] in board order ("draft" is a draft issue); flags:
    rest-fail, gql-fail, patch-fail, fail (every call), fail-delete, fail-labels-<n>, empty-user, no-pageinfo (a
    GraphQL answer without pageInfo, at most first: N items), no-status-field; files: labels-<n>, issue-<n>.json,
    infra, drop-option (a column the board has no option for)."""

    def __init__(self, items=ITEMS, flags=("rest-fail",), files=None):
        self.items = list(items)
        self.flags = set(flags)
        self.files = dict(files or {})
        self.calls, self.edits, self.patches = [], [], []

    def __call__(self, *argv):
        argv = list(argv)
        self.calls.append(argv)
        rc, out, err = self.answer(argv)
        return subprocess.CompletedProcess(argv, rc, out.encode("utf-8"), err.encode("utf-8"))

    def answer(self, argv):
        joined = " ".join(argv)
        jqf = argv[argv.index("--jq") + 1] if "--jq" in argv else None
        emit = lambda text: (0, jq(jqf, text) if jqf else text, "")
        if "fail" in self.flags:
            return 1, "", "gh: network error\n"
        drop = self.files.get("drop-option", "").strip()
        if "projectsV2" in joined:
            return self.rest(argv, joined, jqf, drop)
        if argv[:2] == ["api", "graphql"]:
            if "gql-fail" in self.flags:
                return 1, "", "gh: HTTP 502\n"
            q = next((a[len("query="):] for a in argv if a.startswith("query=")), "")
            if "mutation" in q:
                return 0, '{"data":{}}\n', ""
            cur = re.search(r'after:\s*"c(\d+)"', q)
            page = int(cur.group(1)) if cur else 0
            first = re.search(r"first:\s*(\d+)", q)
            size = min(int(first.group(1)), PAGE) if first else PAGE
            chunk = self.items[page * size:(page + 1) * size]
            nodes = [{"id": "PVTI_" + n, "content": {"number": int(n)} if n != "draft" else {},
                      "status": {"name": s} if s else None} for n, s in chunk]
            items = {"nodes": nodes}
            if "no-pageinfo" not in self.flags:
                items["pageInfo"] = {"hasNextPage": (page + 1) * size < len(self.items), "endCursor": "c%d" % (page + 1)}
            return emit(json.dumps({"data": {"repositoryOwner": {"projectV2": {"items": items}}}}, ensure_ascii=False))
        if argv[:2] == ["project", "view"]:
            return emit('{"id":"PVT_x"}')
        if argv[:2] == ["project", "field-list"]:
            fields = [] if "no-status-field" in self.flags else [
                {"name": "Status", "id": "FLD_x",
                 "options": [{"name": s, "id": "opt%d" % (i + 1)} for i, s in enumerate(MARKED) if strip(s) != drop]}]
            return emit(json.dumps({"fields": fields}, ensure_ascii=False))
        if argv[:2] == ["project", "item-list"]:
            return emit(json.dumps({"items": [{"id": "PVTI_" + n, **({"status": s} if s else {})}
                                              for n, s in self.items]}, ensure_ascii=False))
        if argv[:2] == ["project", "item-edit"]:
            self.edits.append(" ".join(argv))
            return 0, "", ""
        if argv[:2] == ["label", "create"]:
            return 0, "", ""
        if argv[:2] == ["api", "user"]:
            return (0, "", "") if "empty-user" in self.flags else emit('{"login":"factory"}')
        if argv[:3] == ["api", "-X", "DELETE"]:
            return (1, "", "gh: HTTP 404\n") if "fail-delete" in self.flags else (0, "", "")
        if argv[:3] == ["api", "-X", "POST"]:
            return 0, "", ""
        if len(argv) > 1 and argv[0] == "api" and argv[1].startswith("repos/acme/shop/issues?labels=blocked:infra"):
            nums = [l for l in self.files.get("infra", "").split("\n") if l]
            return emit(json.dumps([{"number": int(n)} for n in nums]))
        m = re.fullmatch(r"repos/acme/shop/issues/(\d+)", argv[1]) if len(argv) > 1 and argv[0] == "api" else None
        if m:
            if "fail-labels-" + m.group(1) in self.flags or "fail-labels" in self.flags:
                return 1, "", "gh: HTTP 502\n"
            labels = [l.rstrip("\r") for l in self.files.get("labels-" + m.group(1), "").split("\n") if l]
            return emit(json.dumps({"number": int(m.group(1)), "labels": [{"name": l} for l in labels]}))
        if argv[:2] == ["issue", "view"]:
            return 0, self.files.get("issue-%s.json" % argv[2], ""), ""
        return 9, "", "fake gh: unexpected: %s\n" % joined

    def rest(self, argv, joined, jqf, drop):
        if "rest-fail" in self.flags:
            return 1, "", "gh: HTTP 403: API rate limit exceeded\n"
        if "PATCH" in argv:
            if "patch-fail" in self.flags:
                return 1, "", "gh: HTTP 500\n"
            with open(argv[argv.index("--input") + 1], encoding="utf-8") as f:
                self.patches.append((argv[argv.index("PATCH") + 1], json.load(f)))
            return 0, "{}\n", ""
        if re.search(r"projectsV2/7/fields", joined):  # REST names the Status field by its numeric id, never FLD_x
            opts = [{"id": "ropt-%d" % i, "name": {"raw": "\U0001F916 " + c, "html": c}} for i, c in enumerate(COLUMNS) if c != drop]
            return 0, json.dumps([{"id": 1111, "name": "Title", "data_type": "title"},
                                  {"id": 4242, "name": "Status", "data_type": "single_select", "options": opts}]), ""

        def item(n, s):
            num = n != "draft"
            return {"id": 1000000 + (int(n) if num else 999), "node_id": "PVTI_" + n,
                    "content_type": "Issue" if num else "DraftIssue",
                    "content": {"number": int(n), "title": "t"} if num else {"title": "draft"},
                    "fields": [{"id": "FLD_x", "name": "Status", "type": "single_select",
                                "value": {"id": "o", "name": {"raw": s, "html": s}} if s else None}]}

        m = re.search(r"(?:after=p|[?&]page=)(\d+)", joined)
        start = int(m.group(1)) if m else 1
        pages = [self.items[i:i + PAGE] for i in range(0, max(len(self.items), 1), PAGE)]
        if start > len(pages):
            return 1, "", "gh: HTTP 404\n"
        body = json.dumps([item(n, s) for n, s in pages[start - 1]], ensure_ascii=False) + "\n"
        out = jq(jqf, body) if jqf else body
        if "-i" in argv:
            link = ('Link: <https://api.github.com/users/acme/projectsV2/7/items?fields=4242&per_page=100&after=p%d>; '
                    'rel="next"\r\n' % (start + 1)) if start < len(pages) else ""
            out = "HTTP/2.0 200 OK\r\n" + link + "Content-Type: application/json\r\n\r\n" + out
        return 0, out, ""


def _capture(fn, *args, stdin=b""):
    """fn(*args) with sys.stdout / sys.stderr (and their .buffer) swapped for memory; (rc, out bytes, err bytes)."""
    out, err = io.BytesIO(), io.BytesIO()
    saved = sys.stdout, sys.stderr, sys.stdin
    sys.stdout = io.TextIOWrapper(out, encoding="utf-8", errors="surrogateescape", newline="\n", write_through=True)
    sys.stderr = io.TextIOWrapper(err, encoding="utf-8", errors="surrogateescape", newline="\n", write_through=True)
    sys.stdin = io.TextIOWrapper(io.BytesIO(stdin), encoding="utf-8")
    try:
        try:
            rc = fn(*args)
        except SystemExit as x:
            rc = x.code if isinstance(x.code, int) else 1
    finally:
        for s in (sys.stdout, sys.stderr):
            s.flush()
            s.detach()
        sys.stdout, sys.stderr, sys.stdin = saved
    return rc or 0, out.getvalue(), err.getvalue()


def _cfg(*query, input=None):
    rc, out, err = _capture(project._cfg_in_process, list(query), stdin=input or b"")
    return subprocess.CompletedProcess(list(query), rc, out, err)


class R:
    def __init__(self, rc, out, err):
        self.rc, self.out, self.err = rc, out, err


class BoardCase(support.Case):
    """A test with a FakeGh (self.gh) on proc.gh, the fixture config (self.config(text) for another) and a home."""

    def setUp(self):
        super().setUp()
        self.gh = FakeGh()
        real_gh, real_cfg = proc.gh, project.cfg
        proc.gh, project.cfg = self.gh, _cfg
        self.addCleanup(setattr, proc, "gh", real_gh)
        self.addCleanup(setattr, project, "cfg", real_cfg)
        self.home = os.environ["FACTORY_HOME"]
        os.makedirs(self.home, exist_ok=True)
        here = os.getcwd()
        os.chdir(self.tmp)
        self.addCleanup(os.chdir, here)

    def scene(self, items=ITEMS, flags=("rest-fail",), files=None):
        self.gh = FakeGh(items, flags, files)
        proc.gh = self.gh
        return self.gh

    def config(self, text):
        os.environ["FACTORY_CONFIG"] = self.write("factory.yml", text)

    def run_main(self, mod, *args, snapshot=None, env=None):
        os.environ.pop("FACTORY_BOARD_SNAPSHOT", None)
        if snapshot:
            os.environ["FACTORY_BOARD_SNAPSHOT"] = snapshot
        saved = {k: os.environ.get(k) for k in (env or {})}
        os.environ.update(env or {})
        try:
            rc, out, err = _capture(mod.main, list(args))
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        return R(rc, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"))

    def board(self, *args, **kw):
        return self.run_main(board, *args, **kw)

    def setup_board(self, **kw):
        return self.run_main(setup, **kw)

    def ok(self, r, rc=0):
        self.assertEqual(r.rc, rc, "exit %s, want %s: out=%r err=%r" % (r.rc, rc, r.out[:200], r.err[:300]))

    def gql(self):
        return [c for c in self.gh.calls if c[:2] == ["api", "graphql"]]

    def rest(self):
        return [c for c in self.gh.calls if "projectsV2" in " ".join(c)]


assert shutil.which("jq"), "the board suites need jq (gh evaluates --jq with it)"
