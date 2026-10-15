"""board: reads and moves cards on the project's board (a GitHub Project v2, from .shipfloor/factory.yml).

The port of scripts/board.sh. `snapshot` and `move` read the board by the REST Projects API first (the core quota) and
fall back to GraphQL (today's query, plus cursor paging); the other reads use GraphQL. The whole board is read.
"""
import json
import os
import re
import sys
import tempfile

from . import project, proc

OWNER_ONLY_TARGETS = ("Ready for Refinement", "Ready for Dev", "Ready for Prod")
OWNER_ONLY_SOURCES = ("Spec Review", "Staged")
COLUMNS = ("Inbox", "Ready for Refinement", "Technical Refinement", "Spec Review", "Ready for Dev", "Coding",
           "Validation", "Staged", "Ready for Prod", "Done")

USAGE = ("usage: board.sh items|status <n>|count <status>...|first <status>|closed <status>|move <n> <status>|infra|"
         "label <n> add|remove <label>|issue <n>")

# Column names carry an owner mark ("👤 Spec Review", "🤖 Coding"); scripts use the plain name (the C-locale rule of awk).
_MARK = re.compile(r"^[^A-Za-z]+ ")

# Asks only for each card's issue number and Status: a few points per read, where `gh project item-list` fetches up to 100
# fields per card. repositoryOwner serves both user and organization boards. The items come in the project's own order.
_QUERY = ('query { repositoryOwner(login: "%(owner)s") { ... on ProjectV2Owner { projectV2(number: %(num)s) { '
          'items(first: 100,%(after)s orderBy: {field: POSITION, direction: ASC}) { nodes {\n'
          '  id\n'
          '  content { ... on Issue { number } ... on PullRequest { number } }\n'
          '  status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }\n'
          '} } } } } }')
_ROWS_JQ = r'.data.repositoryOwner.projectV2.items.nodes[] | select(.content.number != null) | "\(.content.number)\t\(.status.name // "")\t\(.id)"'
_PAGE_MARK = "@@page"
_PAGE_JQ = r'.data.repositoryOwner.projectV2.items.pageInfo | "@@page\t\(.hasNextPage)\t\(.endCursor // "")"'
_MAX_PAGES = 1000


def _out(text):
    sys.stdout.flush()
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


def _err(text):
    sys.stderr.flush()
    sys.stderr.buffer.write(text.encode("utf-8"))
    sys.stderr.buffer.flush()


def _msg(text):
    _err(text + "\n")


def _text(b):
    return b.decode("utf-8", "replace")


def _gh(*args):
    """Run gh; (rc, stdout, stderr) as text. A gh that cannot start is rc 127."""
    try:
        r = proc.gh(*args)
    except OSError as e:
        return 127, "", "%s\n" % e
    return r.returncode, _text(r.stdout), _text(r.stderr)


def trusted_logins():
    """The people the factory listens to: the GitHub user plus trusted_commenters ("*" trusts everyone).
    None when the GitHub user cannot be read."""
    rc, out, _ = _gh("api", "user", "--jq", ".login")
    me = out.strip()
    if rc != 0:  # a gh that refuses --jq (the dashboard's calls): the JSON answer
        rc, out, _ = _gh("api", "user")
        try:
            data = json.loads(out)
            me = data.get("login") if isinstance(data, dict) else data
        except ValueError:
            me = out.strip()
    if rc != 0 or not me or not isinstance(me, str):
        return None
    c = project.cfg("get", "trusted_commenters")
    who = _text(c.stdout).rstrip("\n") if c.returncode == 0 else ""
    return set(who.split()) | {me}


def strip_mark(s):
    return _MARK.sub("", s, count=1)


class Board:
    def __init__(self, owner, num, repo):
        self.owner, self.num, self.repo = owner, num, repo
        self._ids = None
        self._rest_field, self._rest_kind = None, "users"

    # ------------------------------------------------------------------------------------------------ ids
    def board_ids(self, quiet=False):
        """(PROJECT_ID, FIELD_ID of Status), looked up once per project and cached; None on failure."""
        if self._ids:
            return self._ids
        cache = os.path.join(os.environ.get("FACTORY_HOME") or project.shipfloor_home(), "board-ids")
        try:
            if os.path.getsize(cache) > 0:
                with open(cache, encoding="utf-8", errors="replace") as f:
                    parts = f.readline().strip().split(None, 1)
                if len(parts) == 2 and parts[1]:
                    self._ids = (parts[0], parts[1])
                    return self._ids
        except OSError:
            pass
        rc, pid, err = _gh("project", "view", self.num, "--owner", self.owner, "--format", "json", "--jq", ".id")
        if rc != 0:
            if not quiet:
                _err(err)
            return None
        rc, fid, err = _gh("project", "field-list", self.num, "--owner", self.owner, "--format", "json",
                           "--jq", '.fields[] | select(.name=="Status") | .id')
        if rc != 0:
            if not quiet:
                _err(err)
            return None
        pid, fid = pid.rstrip("\n"), fid.rstrip("\n")
        if not pid or not fid:
            if not quiet:
                _msg("board: project %s/%s has no Status field" % (self.owner, self.num))
            return None
        if re.search(r"\s", pid + fid):  # not ids (a stand-in gh that ignores --jq): never leave them for the dashboard to read
            self._ids = (pid, fid)
            return self._ids
        try:
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            with open(cache, "w", encoding="utf-8", newline="\n") as f:
                f.write("%s %s\n" % (pid, fid))
        except OSError:
            pass
        self._ids = (pid, fid)
        return self._ids

    def option_id(self, target):
        rc, out, _ = _gh("project", "field-list", self.num, "--owner", self.owner, "--format", "json",
                         "--jq", r'.fields[] | select(.name=="Status") | .options[] | "\(.name)\t\(.id)"')
        for line in out.split("\n"):
            name, _, oid = line.partition("\t")
            if "\t" in line and strip_mark(name) == target:
                return oid
        return ""

    # ------------------------------------------------------------------------------------------------ reads
    def graphql_rows(self):
        """Every card, by GraphQL with the cursor: [[number, status, PVTI_ id]] in board order; None when a read fails."""
        rows, seen, cursor = [], set(), None
        for _ in range(_MAX_PAGES):
            after = ' after: "%s",' % cursor if cursor else ""
            query = _QUERY % dict(owner=self.owner, num=self.num, after=after)
            jq = "(%s), (%s)" % (_ROWS_JQ, _PAGE_JQ)
            rc, out, err = _gh("api", "graphql", "-f", "query=" + query, "--jq", jq)
            if rc != 0:
                _err(err)
                return None
            new, more, cursor = 0, False, None
            for line in out.split("\n"):
                if not line:
                    continue
                if line.startswith(_PAGE_MARK + "\t"):
                    parts = line.split("\t")
                    more = len(parts) > 1 and parts[1] == "true"
                    cursor = parts[2] if len(parts) > 2 and parts[2] else None
                    continue
                parts = (line.split("\t") + ["", ""])[:3]
                if parts[2] in seen:
                    continue
                seen.add(parts[2])
                new += 1
                rows.append([parts[0], strip_mark(parts[1]), parts[2]])
            if not more or not cursor or new == 0:
                break
        return rows

    def rest_field(self):
        """(numeric id of the Status field, {plain column name: option id}) by the REST Projects API; None on failure.

        REST names a field by its numeric id, not the PVTSSF_ node id that `project field-list` (and board-ids) carry.
        The owner may be a user or an organization: the first prefix that answers is kept for the other calls."""
        if self._rest_field is not None:
            return self._rest_field or None
        self._rest_field = False
        for kind in ("users", "orgs"):
            rc, out, _ = _gh("api", "%s/%s/projectsV2/%s/fields?per_page=100" % (kind, self.owner, self.num))
            if rc != 0:
                continue
            try:
                fields = json.loads(out)
            except ValueError:
                return None
            status = next((f for f in fields if isinstance(f, dict) and f.get("name") == "Status"), None) \
                if isinstance(fields, list) else None
            if not status or status.get("id") is None:
                return None
            options = {}
            for o in status.get("options") or []:
                name = o.get("name") if isinstance(o, dict) else None
                if isinstance(name, dict):
                    name = name.get("raw")
                if isinstance(name, str) and o.get("id"):
                    options[strip_mark(name)] = str(o["id"])
            self._rest_kind, self._rest_field = kind, (str(status["id"]), options)
            return self._rest_field
        return None

    def rest_rows(self):
        """Every card, by the REST Projects API with the Link headers: [[number, status, node id, numeric id]];
        None on failure. The node id stays third, where the dashboard and GraphQL item-edit read an item id."""
        field = self.rest_field()
        if not field:
            return None
        url = "%s/%s/projectsV2/%s/items?fields=%s&per_page=100" % (self._rest_kind, self.owner, self.num, field[0])
        rows, seen = [], set()
        for _ in range(_MAX_PAGES):
            rc, out, _ = _gh("api", "-i", url)
            if rc != 0:
                return None
            m = re.search(r"\r?\n\r?\n", out)
            if not m or not out.startswith("HTTP/"):
                return None
            head, body = out[:m.start()], out[m.end():]
            try:
                items = json.loads(body)
            except ValueError:
                return None
            if not isinstance(items, list):
                return None
            new = 0
            for it in items:
                if not isinstance(it, dict) or it.get("id") is None:
                    return None
                key = str(it["id"])
                if key in seen:
                    continue
                seen.add(key)
                new += 1
                content = it.get("content") if isinstance(it.get("content"), dict) else {}
                number = content.get("number")
                if number is None:
                    continue
                if not it.get("node_id"):
                    return None
                rows.append([str(number), strip_mark(_rest_status(it)), str(it["node_id"]), key])
            nxt = None
            for line in head.split("\n"):
                if line.lower().startswith("link:"):
                    m2 = re.search(r'<([^>]+)>\s*;\s*rel="next"', line)
                    if m2:
                        nxt = m2.group(1)
            if not nxt or new == 0:
                break
            url = re.sub(r"^https?://[^/]+/", "", nxt)
        return rows

    def fetch_rows(self, rest):
        if rest:
            rows = self.rest_rows()
            if rows is not None:
                return rows
        return self.graphql_rows()

    def snapshot_rows(self):
        """The rows of FACTORY_BOARD_SNAPSHOT when it names a non-empty file, else None."""
        path = os.environ.get("FACTORY_BOARD_SNAPSHOT", "")
        try:
            if not path or os.path.getsize(path) == 0:
                return None
            with open(path, encoding="utf-8", errors="replace", newline="") as f:
                text = f.read()
        except OSError:
            return None
        return [l.split("\t") for l in text.split("\n") if l != ""]

    def raw_items(self):
        rows = self.snapshot_rows()
        return rows if rows is not None else self.graphql_rows()

    # ------------------------------------------------------------------------------------------------ commands
    def items(self):
        rows = self.raw_items()
        if rows is None:
            return 1
        _out("".join("\t".join(r[:2]) + "\n" for r in rows))
        return 0

    def status(self, n):
        rows = self.raw_items()
        if rows is None:
            return 0  # the bash pipeline ends in awk: a failed read prints nothing and the exit is awk's
        _out("".join("%s\n" % (r[1] if len(r) > 1 else "") for r in rows if r[0] == n))
        return 0

    def count(self, statuses):
        rows = self.raw_items()
        if rows is None:
            return 1
        total = sum(1 for s in statuses for r in rows if len(r) > 1 and r[1] == s)
        _out("%d\n" % total)
        return 0

    def snapshot(self):
        rows = self.fetch_rows(rest=True)
        if rows is None:
            return 1
        _out("".join("\t".join(r) + "\n" for r in rows))
        return 0

    def eligible_list(self, status):
        rows = self.raw_items()
        if rows is None:
            return None
        out = []
        for r in rows:
            if len(r) < 2 or r[1] != status:
                continue
            rc, labels, err = _gh("api", "repos/%s/issues/%s" % (self.repo, r[0]), "--jq", ".labels[].name")
            if rc != 0:  # REST: separate quota; fails closed
                _err(err)
                return None
            if not any(l.rstrip("\r") in ("blocked", "blocked:infra") for l in labels.split("\n")):
                out.append(r[0])
        return out

    def closed(self, status):
        """The column's cards whose issue is closed: a PR merged outside the deploy closes its issue and leaves the card
        in the column. The state is read by REST, one card at a time; a read that fails fails the command."""
        rows = self.raw_items()
        if rows is None:
            return 1
        out = []
        for r in rows:
            if len(r) < 2 or r[1] != status:
                continue
            rc, state, err = _gh("api", "repos/%s/issues/%s" % (self.repo, r[0]), "--jq", ".state")
            if rc != 0:
                _err(err)
                return 1
            if state.strip() == "closed":
                out.append(r[0])
        _out("".join(n + "\n" for n in out))
        return 0

    def eligible(self, status):
        out = self.eligible_list(status)
        if out is None:
            return 1
        _out("".join(n + "\n" for n in out))
        return 0

    def first(self, status):
        out = self.eligible_list(status)
        if out is None:
            return 1
        if out:
            _out(out[0] + "\n")
        return 0

    def infra(self):
        rc, out, err = _gh("api", "repos/%s/issues?labels=blocked:infra&state=open&per_page=100" % self.repo,
                           "--jq", ".[].number")
        _out(out)
        if rc != 0:
            _err(err)
        return rc

    def label(self, args):
        action = args[1] if len(args) > 1 else ""
        if action == "add" and len(args) > 2:
            rc, _, err = _gh("api", "-X", "POST", "repos/%s/issues/%s/labels" % (self.repo, args[0]),
                             "-f", "labels[]=%s" % args[2])
            if rc != 0:
                _err(err)
            return rc
        if action == "remove" and len(args) > 2:
            _gh("api", "-X", "DELETE", "repos/%s/issues/%s/labels/%s" % (self.repo, args[0], args[2]))
            return 0
        _msg("label: <n> add|remove <name>")
        return 2

    def _patch(self, item_id, field_id, option):
        body = {"fields": [{"id": int(field_id), "value": option}]}
        fd, path = tempfile.mkstemp(suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(body, f)
            rc, _, _ = _gh("api", "-X", "PATCH", "%s/%s/projectsV2/%s/items/%s" % (self._rest_kind, self.owner, self.num, item_id),
                           "--input", path)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        return rc == 0

    def move(self, n, target):
        if target not in COLUMNS:
            _msg("move: '%s' is not a board column" % target)
            return 2
        if target in OWNER_ONLY_TARGETS:
            _msg("move: only the owner moves cards to '%s'" % target)
            return 3
        rows = self.snapshot_rows()
        if rows is None:
            rows = self.fetch_rows(rest=True)
        if rows is None:
            return 1
        hit = next((r for r in rows if r[0] == n), None)
        current = hit[1] if hit and len(hit) > 1 else ""
        if current in OWNER_ONLY_SOURCES:
            _msg("move: only the owner moves cards out of '%s'" % current)
            return 3
        node = hit[2] if hit and len(hit) > 2 else ""
        item = hit[3] if hit and len(hit) > 3 else ""
        if not node:
            _msg("move: issue #%s is not on the board" % n)
            return 1
        if item.isdigit():  # the REST path wrote this row: PATCH the numeric id, GraphQL item-edit when that fails
            field = self.rest_field()
            opt = field[1].get(target) if field else None
            if opt and self._patch(item, field[0], opt):
                return 0
        opt = self.option_id(target)
        if not opt:
            _msg("move: unknown status '%s'" % target)
            return 1
        ids = self.board_ids()
        if not ids:
            return 1
        rc, _, err = _gh("project", "item-edit", "--project-id", ids[0], "--id", node, "--field-id", ids[1],
                         "--single-select-option-id", opt)
        if rc != 0:
            _err(err)
        return rc

    def issue(self, n):
        """The issue as an agent may read it: title, body and the comments of the people it listens to."""
        if not re.fullmatch(r"[0-9]+", n):
            _msg("issue: <n> must be a number")
            return 2
        trusted = trusted_logins()
        if trusted is None:
            _msg("issue: cannot read the GitHub user")
            return 1
        rc, out, err = _gh("issue", "view", n, "--repo", self.repo, "--json", "number,title,body,comments")
        if rc != 0:
            _err(err)
            return 1
        try:
            d = json.loads(out)
        except ValueError:
            _msg("issue: cannot read the issue")
            return 1
        comments = d.get("comments") or []
        mine = [c for c in comments if "*" in trusted or (c.get("author") or {}).get("login") in trusted]
        text = "#%s %s\n\n%s\n" % (d["number"], d["title"], d.get("body") or "")
        for c in mine:
            text += "\n--- comment by %s, %s\n%s\n" % ((c.get("author") or {}).get("login", "?"),
                                                       c.get("createdAt", ""), c.get("body") or "")
        left = len(comments) - len(mine)
        if left:
            text += "\n(%d comment%s by other people not shown)\n" % (left, "" if left == 1 else "s")
        _out(text)
        return 0


def _rest_status(item):
    for f in item.get("fields") or []:
        if isinstance(f, dict) and f.get("name") == "Status":
            v = f.get("value")
            name = v.get("name") if isinstance(v, dict) else None
            if isinstance(name, dict):
                name = name.get("raw")
            return name if isinstance(name, str) else ""
    return ""


def main(argv):
    try:
        project.resolve(".")
    except project.ProjectError as e:
        _msg(str(e))
        return 2
    c = project.cfg("values", "board.owner", "board.number", "project.repo")
    data = _text(c.stdout)
    values = data.split("\0")[:-1] if data.endswith("\0") else (data.split("\0") if data else [])
    if len(values) != 3:
        _msg("board: cannot read the board from the project config")
        return 2
    owner, num, repo = values
    if not re.fullmatch(r"[A-Za-z0-9-]+", owner) or not re.fullmatch(r"[0-9]+", num):
        _msg("board: bad board owner/number")
        return 2
    b = Board(owner, num, repo)
    cmd, args = (argv[0], list(argv[1:])) if argv else ("", [])
    arg = lambda i: args[i] if len(args) > i else ""
    if cmd == "items":
        return b.items()
    if cmd == "status":
        return b.status(arg(0))
    if cmd == "count":
        return b.count(args)
    if cmd == "first":
        return b.first(arg(0))
    if cmd == "eligible":
        return b.eligible(arg(0))
    if cmd == "closed":
        return b.closed(arg(0))
    if cmd == "move":
        if len(args) < 2:
            _msg(USAGE)
            return 2
        return b.move(args[0], args[1])
    if cmd == "snapshot":
        return b.snapshot()
    if cmd == "infra":
        return b.infra()
    if cmd == "label":
        return b.label(args)
    if cmd == "issue":
        return b.issue(arg(0))
    _msg(USAGE)
    return 2
