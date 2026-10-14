"""setup-board: one-off per project, sets the board's Status columns and the factory labels.

The port of scripts/setup-board.sh. Rewriting the options resets every card's Status, so it snapshots item -> status
first and restores by name, ignoring the owner mark. Cards whose status has no column keep an empty Status (listed).
"""
import os
import re
import tempfile

from . import project, proc
from .board import _err, _gh, _msg, _out, _text, strip_mark

_OPTIONS = (
    ("👤 Inbox", "GRAY", "Idea captured"),
    ("👤 Ready for Refinement", "BLUE", "Owner picked it; refine queue"),
    ("🤖 Technical Refinement", "PINK", "Spec being written"),
    ("👤 Spec Review", "PINK", "Spec ready; waits for the owner"),
    ("👤 Ready for Dev", "BLUE", "Spec approved; develop queue"),
    ("🤖 Coding", "YELLOW", "Acceptance tests and implementation"),
    ("🤖 Validation", "ORANGE", "Validate queue: review, PR and CI"),
    ("👤 Staged", "PURPLE", "PR open and CI green; waits for the owner"),
    ("👤 Ready for Prod", "BLUE", "Released; deploy queue"),
    ("🤖 Done", "GREEN", "In production"),
)

_LABELS = (
    ("ui", "1d76db", "Issue touches UI; UX/UI joins the refinement"),
    ("cybersec", "b60205", "Owner asked for a security review in the pipelines"),
    ("blocked", "000000", "The factory stopped on this card; the owner decides"),
)


def _read_split(line):
    """`IFS=<tab> read -r item st`: tab is IFS whitespace, so runs collapse and the ends are trimmed."""
    line = line.lstrip("\t")
    item, _, rest = line.partition("\t")
    return item, rest.lstrip("\t").rstrip("\t")


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
        _msg("setup-board: cannot read the board from the project config")
        return 2
    owner, num, repo = values

    rc, pid, err = _gh("project", "view", num, "--owner", owner, "--format", "json", "--jq", ".id")
    if rc != 0:
        _err(err)
        return rc
    pid = pid.rstrip("\n")
    rc, fid, err = _gh("project", "field-list", num, "--owner", owner, "--format", "json",
                       "--jq", '.fields[] | select(.name=="Status") | .id')
    if rc != 0:
        _err(err)
        return rc
    fid = fid.rstrip("\n")
    if not fid:
        _msg("setup-board: project %s/%s has no Status field" % (owner, num))
        return 1

    snap = os.environ.get("SNAPSHOT")
    if not snap:
        fd, snap = tempfile.mkstemp()
        os.close(fd)
    try:
        r = proc.gh("project", "item-list", num, "--owner", owner, "--limit", "500", "--format", "json",
                    "--jq", r'.items[] | "\(.id)\t\(.status // "")"')
    except OSError as e:
        _err("%s\n" % e)
        return 127
    try:
        with open(snap, "wb") as f:
            f.write(r.stdout)
    except OSError as e:
        _msg("setup-board: %s" % e)
        return 1
    if r.returncode != 0:
        _err(_text(r.stderr))
        return r.returncode
    _out("snapshot (%s): %d items\n" % (snap, r.stdout.count(b"\n")))

    opts = ",".join('{name:"%s",color:%s,description:"%s"}' % o for o in _OPTIONS)
    query = ('mutation { updateProjectV2Field(input:{fieldId:"%s", singleSelectOptions:[%s]}) '
             '{ projectV2Field { ... on ProjectV2SingleSelectField { id } } } }' % (fid, opts))
    rc, _, err = _gh("api", "graphql", "-f", "query=" + query)
    if rc != 0:
        _err(err)
        return rc

    rc, out, err = _gh("project", "field-list", num, "--owner", owner, "--format", "json", "--jq",
                       r'.fields[] | select(.name=="Status") | .options[] | "\(.name)\t\(.id)"')
    if rc != 0:
        _err(err)
        return rc
    ids = []
    for line in out.rstrip("\n").split("\n") if out.rstrip("\n") else []:
        name, _, oid = line.partition("\t")
        ids.append((strip_mark(name), oid.split("\t")[0]))

    text = _text(r.stdout)
    for line in text.split("\n"):
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            parts[1] = strip_mark(parts[1])
        item, st = _read_split("\t".join(parts))
        if not st:
            continue
        o = "\n".join(oid for name, oid in ids if name == st).rstrip("\n")
        if not o:
            _msg("no column for '%s' (item %s): left without Status" % (st, item))
            continue
        rc, _, err = _gh("project", "item-edit", "--project-id", pid, "--id", item, "--field-id", fid,
                         "--single-select-option-id", o)
        if rc != 0:
            _err(err)
            return rc

    for name, color, desc in _LABELS:
        rc, out, err = _gh("label", "create", name, "--repo", repo, "--color", color, "--description", desc, "--force")
        _out(out)
        _err(err)
        if rc != 0:
            return rc

    try:
        os.remove(os.path.join(os.environ.get("FACTORY_HOME") or project.shipfloor_home(), "board-ids"))
    except OSError:
        pass
    rc, out, err = _gh("project", "item-list", num, "--owner", owner, "--limit", "500", "--format", "json", "--jq",
                       r'[.items[] | .status] | group_by(.) | map("\(.[0]): \(length)") | .[]')
    _out(out)
    _err(err)
    return rc
