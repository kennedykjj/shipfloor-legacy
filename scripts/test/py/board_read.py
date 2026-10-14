"""board.py reads, in process against a fake gh: items / status / count / eligible / first / snapshot / infra, the
GraphQL query and --jq, the REST Projects read with its Link pages and its fallback to GraphQL, the owner-mark rule,
FACTORY_BOARD_SNAPSHOT, the fail-closed label lookups and the GraphQL budget (labels by REST, no item-list)."""
import os

from board_support import BoardCase, ITEMS, strip

BOARD_QUERY_HEAD = 'query { repositoryOwner(login: "acme") { ... on ProjectV2Owner { projectV2(number: 7) { items(first: 100,'
BOARD_QUERY_TAIL = ('orderBy: {field: POSITION, direction: ASC}',
                    '  id\n  content { ... on Issue { number } ... on PullRequest { number } }\n'
                    '  status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }')
BOARD_JQ = r'.data.repositoryOwner.projectV2.items.nodes[] | select(.content.number != null) | "\(.content.number)\t\(.status.name // "")\t\(.id)"'
LABELS = lambda n: ["api", "repos/acme/shop/issues/%s" % n, "--jq", ".labels[].name"]
INFRA = ["api", "repos/acme/shop/issues?labels=blocked:infra&state=open&per_page=100", "--jq", ".[].number"]
READS = (("items",), ("status", "25"), ("count", "Coding"), ("eligible", "Coding"), ("first", "Coding"), ("snapshot",))
RITEMS = [("25", "👤 Ready for Refinement"), ("draft", "🤖 Coding"), ("33", ""), ("40", "🤖 Coding")]
BIG = [(str(1000 - i), "🤖 Coding" if i % 2 == 0 else "👤 Inbox") for i in range(250)]


def rows_out(items, ident):
    return "".join("%s\t%s\t%s\n" % (n, strip(st), ident(n)) for n, st in items if n != "draft")


rid = lambda n: "PVTI_%s\t%d" % (n, 1000000 + int(n))  # a REST row: the node id where an item id is read, then the numeric id
gid = lambda n: "PVTI_" + n


class GraphqlRead(BoardCase):
    def test_query_and_jq(self):
        "every read (REST failing) sends today's GraphQL query text and --jq, and never `project item-list`"
        for args in READS:
            self.scene()
            self.ok(self.board(*args))
            g = self.gql()
            self.assertTrue(g, "%s made no GraphQL read" % (args,))
            for c in g:
                q = [a for a in c if a.startswith("query=")]
                self.assertEqual(len(q), 1)
                self.assertTrue(q[0].startswith("query=" + BOARD_QUERY_HEAD), q[0][:200])
                for frag in BOARD_QUERY_TAIL:
                    self.assertIn(frag, q[0])
                self.assertIn(BOARD_JQ, c[c.index("--jq") + 1])
            for c in self.gh.calls:
                self.assertNotEqual(c[:2], ["project", "item-list"], "%s called the expensive item-list" % (args,))

    def test_items_status_count(self):
        "items is n<TAB>status, snapshot adds the item id, the owner mark is stripped; status and count read it"
        self.scene(ITEMS[:1] + ITEMS[2:5])
        r = self.board("snapshot")
        self.assertEqual(r.out, "25\tReady for Refinement\tPVTI_25\n33\tSpec Review\tPVTI_33\n40\tCoding\tPVTI_40\n41\tValidation\tPVTI_41\n")
        self.assertEqual(self.board("items").out, "25\tReady for Refinement\n33\tSpec Review\n40\tCoding\n41\tValidation\n")
        self.assertEqual(self.board("status", "33").out, "Spec Review\n")
        self.assertEqual(self.board("status", "99").out, "")
        self.assertEqual(self.board("count", "Coding", "Validation").out, "2\n")
        self.assertEqual(self.board("count", "Spec Review").out, "1\n")

    def test_failed_read(self):
        "a failed board read: count, items and snapshot exit 1 and print nothing; status prints nothing, exit 0"
        self.scene(flags=("rest-fail", "gql-fail"))
        for args in (("count", "Coding"), ("items",), ("snapshot",)):
            r = self.board(*args)
            self.ok(r, 1)
            self.assertEqual(r.out, "")
        r = self.board("status", "25")
        self.ok(r)
        self.assertEqual(r.out, "")
        self.scene(flags=("fail",))
        self.ok(self.board("count", "Coding"), 1)

    def test_mark_rule(self):
        "the owner mark is stripped by ^[^A-Za-z]+ followed by a space, on ASCII letters"
        sts = ["👤 Spec Review", "🤖  Coding", "2 Validation", "é Done", "👤Inbox", "Staged", "Ready 2 Dev",
               "👤 🤖 Technical Refinement", "- 7 Ready for Prod"]
        self.scene([(str(i + 1), st) for i, st in enumerate(sts)])
        got = [l.split("\t")[1] for l in self.board("snapshot").out.split("\n") if l]
        self.assertEqual(got, [strip(x) for x in sts])
        self.assertEqual(got[4], "👤Inbox", "a mark with no space after it stays")
        self.assertEqual([l.split("\t")[1] for l in self.board("items").out.split("\n") if l], [strip(x) for x in sts])
        self.assertEqual(self.board("status", "2").out, "Coding\n")

    def test_no_pageinfo(self):
        "a GraphQL answer without pageInfo is one page: 100 of 101 cards are read, the 101st is not on the board"
        self.scene([(str(i), "🤖 Coding") for i in range(1, 102)], flags=("rest-fail", "no-pageinfo"))
        self.assertEqual(self.board("count", "Coding").out, "100\n")
        items = self.board("items").out.split("\n")[:-1]
        self.assertEqual((len(items), items[-1].split("\t")[0]), (100, "100"))
        self.assertEqual(self.board("status", "101").out, "")
        r = self.board("move", "101", "Validation")
        self.ok(r, 1)
        self.assertIn("issue #101 is not on the board", r.err)


class Eligible(BoardCase):
    def test_eligible_and_first(self):
        "eligible lists the column's cards not labelled blocked or blocked:infra, in board order; first is the first"
        self.scene([("30", "👤 Inbox"), ("25", "🤖 Coding"), ("26", "🤖 Coding"), ("27", "🤖 Coding"), ("28", "🤖 Coding")],
                   files={"labels-25": "blocked\r\n", "labels-27": "ui\nblocked:infra\n", "labels-28": "ui\n"})
        r = self.board("eligible", "Coding")
        self.ok(r)
        self.assertEqual(r.out, "26\n28\n")
        self.assertEqual(self.board("first", "Coding").out, "26\n")
        self.assertIn(LABELS(25), self.gh.calls, "labels are read by REST, one card at a time")
        self.assertFalse([c for c in self.gh.calls if c[:2] == ["issue", "view"]], "labels read by GraphQL issue view")

    def test_all_blocked(self):
        "every card blocked: first prints nothing, exit 0; a blocked label among 3000 still counts"
        self.scene(files={"labels-25": "blocked\n", "labels-26": "blocked\n"})
        r = self.board("first", "Ready for Refinement")
        self.ok(r)
        self.assertEqual(r.out, "")
        self.scene(files={"labels-25": "blocked\n" + "".join("label-%d\n" % i for i in range(3000))})
        self.assertEqual(self.board("first", "Ready for Refinement").out, "26\n")

    def test_failed_label_lookup(self):
        "one failed label lookup fails closed: eligible and first print nothing and exit 1"
        for flag in ("fail-labels-26", "fail-labels"):
            self.scene(flags=("rest-fail", flag))
            for cmd in ("eligible", "first"):
                r = self.board(cmd, "Ready for Refinement")
                self.ok(r, 1)
                self.assertEqual(r.out, "")

    def test_infra(self):
        "infra lists the open blocked:infra issues through the REST issues search"
        self.scene(files={"infra": "41\n"})
        r = self.board("infra")
        self.ok(r)
        self.assertEqual(r.out, "41\n")
        self.assertIn(INFRA, self.gh.calls)
        self.scene(flags=("fail",))
        self.ok(self.board("infra"), 1)


class Snapshot(BoardCase):
    SNAP = "25\tSpec Review\tIsnap25\n33\tCoding\tIsnap33\n40\tCoding\tIsnap40\n41\tValidation\tIsnap41\n"

    def test_snapshot_file_is_read(self):
        "with a non-empty FACTORY_BOARD_SNAPSHOT every read but snapshot uses it, with gh failing: no board read"
        snap = self.write("snap", self.SNAP)
        self.scene(flags=("fail",))
        expect = {("items",): "25\tSpec Review\n33\tCoding\n40\tCoding\n41\tValidation\n", ("status", "33"): "Coding\n",
                  ("count", "Coding"): "2\n"}
        for args, want in expect.items():
            r = self.board(*args, snapshot=snap)
            self.ok(r)
            self.assertEqual(r.out, want, "%s did not read the snapshot" % (args,))
        self.scene()
        self.assertEqual(self.board("eligible", "Coding", snapshot=snap).out, "33\n40\n")
        self.assertEqual(self.board("first", "Coding", snapshot=snap).out, "33\n")
        self.assertEqual(self.gql() + self.rest(), [], "a board read happened although a snapshot was given")
        r = self.board("snapshot", snapshot=snap)
        self.assertEqual([l.split("\t")[0] for l in r.out.split("\n") if l], [n for n, _ in ITEMS],
                         "snapshot always reads the board")

    def test_empty_snapshot_file(self):
        "an empty FACTORY_BOARD_SNAPSHOT file is not a snapshot: the board is read"
        r = self.board("status", "33", snapshot=self.write("snap", ""))
        self.assertEqual(r.out, "Spec Review\n")
        self.assertTrue(self.gql())


class Rest(BoardCase):
    def test_rest_snapshot(self):
        "snapshot reads GET users/acme/projectsV2/7/items?fields=<numeric Status id>: numeric ids, no GraphQL, no gh project"
        self.scene(RITEMS, flags=())
        r = self.board("snapshot")
        self.ok(r)
        self.assertEqual(r.out, rows_out(RITEMS, rid))
        j = " ".join(next(c for c in self.rest() if "/items" in " ".join(c)))
        self.assertIn("users/acme/projectsV2/7/items", j)
        self.assertIn("fields=4242", j)
        self.assertEqual([c for c in self.gh.calls if c[0] == "project"], [])
        self.assertEqual(self.gql(), [])

    def test_fallback(self):
        "REST failing: snapshot falls back to GraphQL with the same rows and PVTI_ ids; both failing: exit 1, no row"
        self.scene(RITEMS, flags=())
        a = self.board("snapshot").out
        self.scene(RITEMS, flags=("rest-fail",))
        b = self.board("snapshot")
        self.ok(b)
        self.assertEqual(b.out, rows_out(RITEMS, gid))
        self.assertEqual([l.split("\t")[:2] for l in a.split("\n")], [l.split("\t")[:2] for l in b.out.split("\n")])
        self.assertTrue(self.gql())

    def test_pages(self):
        "a board of 250 is read whole, in position order: by REST through the Link headers, by GraphQL through the cursor"
        self.scene(BIG, flags=())
        self.assertEqual(self.board("snapshot").out, rows_out(BIG, rid))
        self.assertGreaterEqual(len([c for c in self.rest() if "/items" in " ".join(c)]), 3)
        self.assertEqual(self.gql(), [])
        self.scene(BIG, flags=("rest-fail",))
        self.assertEqual(self.board("snapshot").out, rows_out(BIG, gid))
        self.assertGreaterEqual(len(self.gql()), 3)
        self.assertEqual(self.board("count", "Coding").out, "125\n")
        self.assertEqual(self.board("status", "751").out, "%s\n" % strip(dict(BIG)["751"]))
