"""The gates that read the changed set (scope.py, changes.py, migration.py): scope, forbidden, migration and fast, on
temp repos; and text.ere_match, the POSIX ERE matcher the migration gate uses."""
import os
import subprocess
import unittest

import gate_support as gs
from gate_support import M
from shipfloor_core import text

OUTSIDE = "scope: api touched files outside its area:"
CONTROL = "forbidden: a changed file name has a control character"


class Scope(gs.GateCase):
    def fresh(self):
        """A repo with api/src/main/Keep.kt committed and ignored.log in .gitignore; the base is that commit."""
        self.repo()
        self.put(".gitignore", "ignored.log\n")
        self.put("api/src/main/Keep.kt")
        self.base = self.commit()
        return self.base

    def test_roles(self):
        "scope: each role passes in its own area and blocks outside it (implementers, qa, po)"
        self.repo()
        base = self.head()
        self.put("api/src/main/A.kt")
        self.table([("api in api/", 0, ("scope", "api", base)), ("web on an api file", 1, ("scope", "web", base)),
                    ("qa on an api file", 1, ("scope", "qa", base))])
        self.repo("qa")
        base = self.head()
        for f in ("api/src/test/ATest.kt", "web/e2e/a.spec.ts", "web/lib/a.test.ts"):
            self.put(f)
        self.expect(0, "scope", "qa", base)
        self.put("web/lib/a.ts")
        self.expect(1, "scope", "qa", base)
        self.repo("po")
        base = self.head()
        self.put("docs/superpowers/specs/my spec.md")
        self.expect(0, "scope", "po", base)

    def test_implementers_off_limits(self):
        "scope: an implementer may not touch a tests-only layer inside its path, nor test-runner config; its unit tests are fine"
        self.repo()
        base = self.head()
        self.put("web/e2e/fixtures/expect.ts")
        r = self.expect(1, "scope", "web", base)
        self.assertIn("scope: only QA writes in tests-only layers:\nweb/e2e/fixtures/expect.ts\n", r.err)
        self.git("clean", "-qfd", "web")
        self.put("web/lib/a.test.ts")
        self.put("web/lib/a.ts")
        self.expect(0, "scope", "web", base)
        bad = []
        for f, role in [("web/vitest.config.ts", "web"), ("web/playwright.config.ts", "web"),
                        ("api/src/test/resources/junit-platform.properties", "api")]:
            self.repo(role + os.path.basename(f))
            base = self.head()
            self.put(f)
            r = self.gate("scope", role, base)
            if r.code != 1 or "scope: test runner config is off-limits to implementers:\n%s\n" % f not in r.err:
                bad.append("%s: %r" % (f, r))
        self.assertFalse(bad, "\n".join(bad))

    def test_usage_and_revisions(self):
        "scope: no role, an unknown role (a tests-only layer too) and a bad or empty base are exit 2, each said"
        self.repo()
        base = self.head()
        self.table([
            ("no role", 2, ("scope",), "scope: role required"),
            ("an unknown role", 2, ("scope", "nobody", base), "scope: unknown role 'nobody'"),
            ("a tests-only layer as the role", 2, ("scope", "e2e", base), "scope: unknown role 'e2e'"),
            ("a bad revision", 2, ("scope", "api", "deadbeef"), "gate: bad revision 'deadbeef'"),
            ("another bad revision", 2, ("scope", "api", "nonexistent123")),
            ("an empty base", 2, ("scope", "api", ""), "gate: bad revision ''"),
        ])

    def test_changed_set(self):
        "the changed set: uncommitted edits and untracked files count, ignored ones do not; a change restored on disk still counts"
        base = self.fresh()
        self.put("api/src/main/Keep.kt", "x\nchanged\n")
        self.expect(0, "scope", "api", base)
        self.assertIn("api/src/main/Keep.kt", self.expect(1, "scope", "web", base).err)
        self.git("checkout", "-q", "--", ".")
        self.put("api/src/main/New.kt")
        self.assertIn("api/src/main/New.kt", self.expect(1, "scope", "web", base).err)
        os.unlink("api/src/main/New.kt")
        self.put("ignored.log")
        self.expect(0, "scope", "po", base)
        self.expect(0, "forbidden", base)
        os.unlink("ignored.log")
        self.put("web/B.ts")
        self.put("api/A.kt", "y\n")
        self.commit("sneaky")
        os.unlink("web/B.ts")
        self.expect(1, "scope", "api", base)

    def test_renames(self):
        "a rename counts both paths, committed or not"
        base = self.fresh()
        os.makedirs("web")
        self.git("mv", "api/src/main/Keep.kt", "web/Keep.kt")
        for state in ("uncommitted", "committed"):
            self.assertIn("web/Keep.kt", self.expect(1, "scope", "api", base).err, state)
            self.assertIn("api/src/main/Keep.kt", self.expect(1, "scope", "web", base).err, state)
            if state == "uncommitted":
                self.commit("rename")
        self.fresh()
        self.put(".github/ci.yml")
        base2 = self.commit("ci")
        os.makedirs("api", exist_ok=True)
        self.git("mv", ".github/ci.yml", "api/ci.yml")
        self.assertIn(".github/ci.yml", self.expect(1, "forbidden", base2).err)
        self.assertIn(".github/ci.yml", self.expect(1, "scope", "api", base2).err)
        self.commit("move ci")
        self.expect(1, "forbidden", base2)
        self.expect(1, "scope", "api", base2)

    def test_names_as_they_are(self):
        "names are never C-quoted: non-ASCII names, regex metacharacters and spaces are plain characters"
        base = self.fresh()
        self.put("web/lib/ação.ts")
        r = self.expect(1, "scope", "api", base)
        self.assertIn("web/lib/ação.ts", r.err)
        self.assertNotIn("\\303", r.err)
        os.unlink("web/lib/ação.ts")
        self.put("api/src/main/ação.kt")
        self.expect(0, "scope", "api", base)
        self.expect(0, "forbidden", base)
        self.put("api/src/main/a+b (1) [x].kt")
        self.put("api/src/main/my file.kt")
        self.expect(0, "scope", "api", base)

    def test_anchored_areas(self):
        "areas are anchored at the start of the path: xapi/ is not api/, web/e2e.txt is not under web/e2e/"
        base = self.fresh()
        self.put("xapi/A.kt")
        self.assertIn("xapi/A.kt", self.expect(1, "scope", "api", base).err)
        os.unlink("xapi/A.kt")
        self.put("web/e2e.txt")
        self.assertIn("web/e2e.txt", self.expect(1, "scope", "api", base).err)

    def test_control_characters(self):
        "a control character in a name blocks; scope's own area check runs before forbidden's control-character check"
        base = self.fresh()
        bad = []
        for name, role_api in [("api/src/main/odd\nname.kt", OUTSIDE), ("api/src/main/tab\tname.kt", CONTROL),
                               ("api/src/main/del\x7fname.kt", CONTROL), ("web/odd\nname.ts", OUTSIDE)]:
            self.put(name)
            f = self.gate("forbidden", base)
            s = self.gate("scope", "api", base)
            if f.code != 1 or CONTROL not in f.err:
                bad.append("forbidden %r: %r" % (name, f))
            if s.code != 1 or role_api not in s.err or (role_api == OUTSIDE and CONTROL in s.err):
                bad.append("scope api %r: %r" % (name, s))
            if "\n" in name and self.gate("scope", "po", base).code != 1:
                bad.append("scope po %r passed" % name)
            os.unlink(name)
        self.assertFalse(bad, "\n".join(bad))
        self.put("api/src/main/odd\nname.kt")
        self.commit("odd")
        self.assertIn(CONTROL, self.expect(1, "forbidden", base).err)
        self.expect(0, "forbidden", "HEAD")

    def test_quoted_and_newline_names_in_the_index(self):
        "a quoted or newline name committed straight to the index never slips past forbidden or scope"
        self.repo()
        base = self.head()
        blob = subprocess.run(["git", "hash-object", "-w", "--stdin"], input=b"x\n", stdout=subprocess.PIPE).stdout.decode().strip()
        self.git("-c", "core.protectNTFS=false", "update-index", "--add", "--cacheinfo", "100644", blob, '.github/workflows/a"b.yml')
        self.git("-c", "core.protectNTFS=false", "commit", "-qm", "sneaky")
        self.expect(1, "forbidden", base)
        self.repo("nl")
        base = self.head()
        blob = subprocess.run(["git", "hash-object", "-w", "--stdin"], input=b"x\n", stdout=subprocess.PIPE).stdout.decode().strip()
        self.git("-c", "core.protectNTFS=false", "update-index", "--add", "--cacheinfo", "100644", blob, "app/a\nb.go")
        self.git("-c", "core.protectNTFS=false", "commit", "-qm", "newline")
        self.own_config('project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n'
                        '  - {name: app, path: ./, test: "echo ok", ran: ok, tests: ["app/**/*_test.go"]}\n')
        self.expect(1, "scope", "app", base)

    def test_any_layers(self):
        "scope follows the project's own layers, names and paths; a role the config lacks is exit 2"
        self.own_config(LAYERS)
        self.repo()
        base = self.head()
        self.put("services/a/x.go")
        self.table([("svc-a", 0, ("scope", "svc-a", base)), ("svc-b", 1, ("scope", "svc-b", base)),
                    ("qa", 1, ("scope", "qa", base))])
        self.put("services/b/y.go")
        self.table([("svc-a with svc-b's file", 1, ("scope", "svc-a", base)), ("nope", 2, ("scope", "nope", base))])
        self.repo("qa")
        self.put("services/a/pkg/x_test.go")
        self.expect(0, "scope", "qa", base)
        self.put(".shipfloor/factory.yml")
        self.expect(1, "scope", "qa", base)


LAYERS = """project: {name: mono, repo: acme/mono}
board: {owner: acme, number: 1}
layers:
  - name: svc-a
    path: services/a/
    build: 'echo "svc-a $PWD" >> "$CALLS"'
    test: 'printf "%s\\n" {selector} > "$CALLS.sel"; echo "--- FAIL: TestX"; exit 1'
    ran: '^ok '
    assertions: '--- FAIL'
    tests: ['services/a/**/*_test.go']
  - name: svc-b
    path: services/b/
    build: 'echo "svc-b $PWD" >> "$CALLS"'
    test: 'echo "ok  pkg 0.1s"'
    ran: '^ok '
    tests: ['services/b/**/*_test.go']
    migrations: {glob: 'services/b/migrations/*.sql', comment: '#'}
  - name: lib
    path: packages/lib/
    test: 'echo "no tests"'
    ran: '^ok '
    tests: ['packages/lib/test/**']
"""


class Forbidden(gs.GateCase):
    def test_off_limits(self):
        "forbidden: CI, hooks, agent instructions, repo config, the factory's config and env files block; api/env.kt does not"
        bad = []
        for f in (".github/w.yml", ".githooks/pre-push", ".claude/x.md", ".shipfloor/factory.yml", "api/.env",
                  "web/.env.local", "CLAUDE.md", ".gitattributes", ".mcp.json", "docs/engineering/review-criteria.md"):
            self.repo(f.replace("/", "_"))
            base = self.head()
            self.put(f)
            r = self.gate("forbidden", base)
            if r.code != 1 or "forbidden: these paths are off-limits to agents:\n%s\n" % f not in r.err:
                bad.append("%s: %r" % (f, r))
        self.repo("ok")
        base = self.head()
        self.put("api/env.kt")
        self.put("docs/engineeringX/a.md")
        r = self.gate("forbidden", base)
        if r.code != 0:
            bad.append("api/env.kt, docs/engineeringX/: %r" % r)
        self.assertFalse(bad, "\n".join(bad))

    def test_every_kind_of_change(self):
        "forbidden: untracked, staged, committed, both ways (listed once); added then deleted is no change"
        self.repo()
        self.put("api/src/main/Keep.kt")
        base = self.commit()
        self.put(".github/w.yml")
        self.assertIn(".github/w.yml", self.expect(1, "forbidden", base).err)
        self.git("add", "-A")
        self.expect(1, "forbidden", base)
        self.commit("gh", add=False)
        self.expect(1, "forbidden", base)
        self.put(".github/w.yml", "x\ny\n")
        r = self.expect(1, "forbidden", base)
        self.assertEqual(r.err.split("\n").count(".github/w.yml"), 1, r)
        self.git("checkout", "-q", "--", ".")
        self.git("rm", "-q", "-r", ".github")
        self.commit("gh gone", add=False)
        self.expect(0, "forbidden", base)
        self.expect(0, "scope", "po", base)

    def test_bad_base(self):
        "forbidden with no base or a bad one is exit 2, never a pass"
        self.repo()
        self.put(".github/w.yml")
        self.commit()
        self.table([("no base", 2, ("forbidden",), "gate: bad revision ''"), ("an empty base", 2, ("forbidden", "")),
                    ("a bad base", 2, ("forbidden", "deadbeef"))])


def spec_with(body):
    with open("spec.md", "w", encoding="utf-8") as f:
        f.write("# Spec\n\n## Rollback\n\n%s\n\n## Dúvidas\n\nnenhuma\n" % body)


def no_rollback_spec(body="não se aplica"):
    with open("spec.md", "w", encoding="utf-8") as f:
        f.write("# S\n\n## Rollback\n\n%s\n" % body)


class Migration(gs.GateCase):
    def mig_repo(self, sql, name="V2__x.sql"):
        """A repo whose card adds <M>/<name> with that content; self.base is the first commit."""
        self.repo("m%d" % len(os.listdir(self.path("repos"))))
        self.base = self.head()
        self.put("%s/%s" % (M, name), sql + "\n")
        return self.base

    def mig(self, *extra, **env):
        return self.gate("migration", self.base, "spec.md", *extra, **env)

    def test_rollback_section(self):
        "migration: a destructive migration needs a filled '## Rollback' (comments, blanks and n/a-style bodies are none)"
        self.mig_repo("alter table a drop column b;")
        bad = []
        cases = [("<!-- how to roll back -->", 1), ("<!--\nexplain the way back\n-->\nRevert with V3, which recreates column b.", 0),
                 ("Revert with V3.\n<!-- note\nfor the reviewer -->", 0), ("<!-- one\nline -->\nnot applicable", 1),
                 ("<!-- descreva -->", 1), ("Revert with V3 (not applicable to old rows).", 0),
                 ("n/a for the data; revert by recreating the column.", 0),
                 ("Reverter com V4 que recria a coluna b a partir do backup em a_b_backup.", 0)]
        cases += [(body, 1) for body in ("", "n/a", "N/A", "None.", "none", "- not applicable", "* Not Applicable.",
                                          "não se aplica", "  n/a  ")]
        for body, want in cases:
            spec_with(body)
            r = self.mig()
            if r.code != want:
                bad.append("Rollback %r: want %s, %r" % (body, want, r))
        spec_with("")
        r = self.mig()
        self.assertEqual(r.err, "migration: destructive migration(s) %s/V2__x.sql need a filled '## Rollback' section in spec.md\n"
                                "gate migration: FAIL (exit 1)\n" % M)
        os.unlink("spec.md")
        if self.mig().code != 1:
            bad.append("no spec file passed")
        with open("spec.md", "w") as f:
            f.write("# Spec\n\n## Product\n\nx\n")
        if self.mig().code != 1:
            bad.append("no Rollback section passed")
        with open("spec.md", "w") as f:
            f.write("# Spec\n\n## Rollback extra\n\nRevert with V3.\n\n## Other\n\nx\n")
        if self.mig().code != 0:
            bad.append("a heading starting with '## Rollback' did not count")
        self.assertFalse(bad, "\n".join(bad))

    def test_destructive_keywords(self):
        "migration: drop, rename, truncate and delete are destructive as words in code, in any case; not in names or comments"
        bad = []
        for sql, want in [("alter table a drop column b;", 1), ("ALTER TABLE a RENAME COLUMN b TO c;", 1), ("TRUNCATE a;", 1),
                          ("delete from a;", 1), ("DELETE FROM users;", 1), ("Drop Table a;", 1),
                          ("INSERT INTO t VALUES ('please drop by');", 1), ("select 1; -- drop", 1),
                          ("ALTER TABLE a ADD COLUMN deleted_at timestamp;", 0), ("ALTER TABLE a ADD COLUMN dropped int;", 0),
                          ("ALTER TABLE a ADD COLUMN soft_delete int;", 0), ("-- we drop nothing here", 0),
                          ("   -- drop it", 0), ("-- we do not drop anything here\nCREATE TABLE x (id int);", 0),
                          ("ALTER TABLE a ADD COLUMN b text;", 0)]:
            self.mig_repo(sql)
            spec_with("n/a")
            r = self.mig()
            if r.code != want:
                bad.append("%r: want %s, %r" % (sql, want, r))
        self.mig_repo("ALTER TABLE a DROP COLUMN b;", "V3__remoção.sql")
        spec_with("n/a")
        if self.mig().code != 1:
            bad.append("a non-ASCII migration name with drop passed")
        self.assertFalse(bad, "\n".join(bad))

    def test_committed_and_several(self):
        "migration: a committed destructive migration blocks too; among several, only the destructive one is listed"
        self.mig_repo("drop table a;")
        spec_with("n/a")
        self.expect(1, "migration", self.base, "spec.md")
        self.commit("card migration")
        self.expect(1, "migration", self.base, "spec.md")
        spec_with("Revert with V3.")
        self.expect(0, "migration", self.base, "spec.md")
        self.mig_repo("create table b (id int);")
        self.put("%s/V3__y.sql" % M, "drop table b;\n")
        spec_with("n/a")
        r = self.expect(1, "migration", self.base, "spec.md")
        self.assertIn("%s/V3__y.sql" % M, r.err)
        self.assertNotIn("%s/V2__x.sql" % M, r.err)

    def test_applied_are_immutable(self):
        "migration: deleting (committed or not) or editing a migration on the base blocks"
        self.repo()
        self.put("%s/V1__a.sql" % M, "create table a (id int);\n")
        base = self.commit("v1")
        no_rollback_spec("Revert.")
        os.unlink("%s/V1__a.sql" % M)
        r = self.expect(1, "migration", base, "spec.md")
        self.assertIn("migration: %s/V1__a.sql already exists on the base; applied migrations are immutable (add a new file)" % M, r.err)
        self.commit("delete V1")
        self.expect(1, "migration", base, "spec.md")
        self.git("reset", "-q", "--hard", base)
        self.put("%s/V1__a.sql" % M, "create table a (id bigint);\n")
        self.expect(1, "migration", base, "spec.md")
        self.git("checkout", "-q", "--", M)
        self.expect(0, "migration", base, "spec.md")

    def test_versions(self):
        "migration: versions must be unique and newer than every one on the base; a base off HEAD's history is exit 2"
        self.repo()
        self.put("%s/V1__a.sql" % M, "create table a (id int);\n")
        base = self.commit("v1")
        no_rollback_spec("Revert.")
        self.put("%s/V1__b.sql" % M)
        r = self.expect(1, "migration", base, "spec.md")
        self.assertIn("%s/V1__b.sql: not newer than %s/V1__a.sql (on the base or main); use a higher version" % (M, M), r.err)
        os.unlink("%s/V1__b.sql" % M)
        self.put("%s/V2__b.sql" % M)
        self.put("%s/V2__c.sql" % M)
        r = self.expect(1, "migration", base, "spec.md")
        self.assertIn("migration: version 2 is used by", r.err)
        self.assertIn("migration: versions of layer 'api' must be unique and newer than the base's", r.err)
        os.unlink("%s/V2__c.sql" % M)
        self.put("%s/V3__d.sql" % M)
        self.expect(0, "migration", base, "spec.md")
        self.git("checkout", "-q", "-b", "side")
        self.git("commit", "-q", "--allow-empty", "-m", "s")
        self.git("checkout", "-q", "main")
        self.git("commit", "-q", "--allow-empty", "-m", "m2")
        side = self.head("side")
        r = self.expect(2, "migration", side, "spec.md")
        self.assertIn("migration: base %s is not an ancestor of HEAD" % side, r.err)
        self.assertEqual(r.last, "gate migration: FAIL (exit 2)")
        self.git("checkout", "-q", "--orphan", "lone")
        self.git("commit", "-qm", "lone", "--allow-empty")
        lone = self.head()
        self.git("checkout", "-q", "-f", "main")
        self.expect(2, "migration", lone, "spec.md")
        self.expect(2, "migration", "", "spec.md")
        self.assertIn("gate: bad revision 'deadbeef'", self.expect(2, "migration", "deadbeef", "spec.md").err)

    def test_parallel_cards(self):
        "migration: a version main already took (base or origin/main) collides; after merging main, main's are not the card's"
        self.repo()
        self.put("%s/V26__a.sql" % M)
        self.commit("v26")
        no_rollback_spec()
        self.put("%s/V27__access_log.sql" % M)
        self.commit("main: V27")
        self.put("%s/V27__retention.sql" % M)
        self.assertIn("V27", self.expect(1, "migration", self.head(), "spec.md").err)
        self.repo("older")
        self.put("%s/V26__a.sql" % M)
        self.put("%s/V28__b.sql" % M)
        base = self.commit("base")
        no_rollback_spec()
        self.put("%s/V27__late.sql" % M, "create table c (id int);\n")
        self.expect(1, "migration", base, "spec.md")
        os.unlink("%s/V27__late.sql" % M)
        self.put("%s/V29__next.sql" % M)
        self.expect(0, "migration", base, "spec.md")
        self.repo("merged")
        self.put("%s/V26__a.sql" % M)
        self.commit("v26")
        self.git("checkout", "-qb", "card")
        self.put("%s/V28__retention.sql" % M)
        self.commit("card")
        self.git("checkout", "-q", "main")
        self.put("%s/V27__log.sql" % M)
        self.commit("main")
        self.git("checkout", "-q", "card")
        self.git("merge", "-q", "--no-edit", "main")
        no_rollback_spec()
        self.expect(0, "migration", self.git("merge-base", "HEAD", "main"), "spec.md")

    def test_names(self):
        "migration: a card migration with no version in its name is refused; bad names already on main only warn"
        self.repo()
        base = self.head()
        no_rollback_spec("n/a")
        self.put("%s/Vlatest__oops.sql" % M)
        self.assertIn("%s/Vlatest__oops.sql: no version in the name" % M, self.expect(1, "migration", base, "spec.md").err)
        self.repo("main-names")
        for n in ("V26__a.sql", "Vlatest__x.sql", "V26__dup.sql"):
            self.put("%s/%s" % (M, n))
        base = self.commit("m")
        no_rollback_spec("n/a")
        self.put("web/a.ts")
        r = self.expect(0, "migration", base, "spec.md")
        self.assertIn("migration: warning (already on the base or main): %s/Vlatest__x.sql: no version in the name" % M, r.err)
        self.assertIn("migration: warning (already on the base or main): version 26 is used by", r.err)
        self.put("%s/V27__new.sql" % M)
        self.assertIn("migration: warning (already on the base or main)", self.expect(0, "migration", base, "spec.md").err)
        self.put("%s/U27__new.sql" % M)
        self.expect(0, "migration", base, "spec.md")

    def test_project_main(self):
        "migration reads origin/<project.main> (the config), never FACTORY_MAIN"
        self.repo()
        self.put("%s/V26__a.sql" % M)
        base = self.commit("v26")
        self.git("checkout", "-q", "-b", "side")
        self.put("%s/V27__main.sql" % M)
        self.commit("main took V27")
        self.git("update-ref", "refs/remotes/origin/trunk", "HEAD")
        self.git("checkout", "-q", "main")
        self.git("branch", "-q", "-D", "side")
        self.put("%s/V27__card.sql" % M)
        no_rollback_spec("n/a")
        trunk = self.config(replace=[("  repo: acme/shop\n", "  repo: acme/shop\n  main: trunk\n")], use=False)
        fix = os.environ["FACTORY_CONFIG"]
        cases = [(trunk, "other", 1), (trunk, "main", 1), (fix, "trunk", 0)]
        got = [self.gate("migration", base, "spec.md", FACTORY_CONFIG=c, FACTORY_MAIN=m).code for c, m, _ in cases]
        self.assertEqual(got, [w for _, _, w in cases])
        self.git("update-ref", "refs/remotes/origin/main", "refs/remotes/origin/trunk")
        self.expect(1, "migration", base, "spec.md")
        os.rename("%s/V27__card.sql" % M, "%s/V28__card.sql" % M)
        self.expect(0, "migration", base, "spec.md")

    def test_configurable_versions(self):
        "migration: the version pattern comes from the layer (golang-migrate); up/down pairs are one migration"
        self.own_config("project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n"
                        "  - {name: db, path: db/, test: t, ran: ok, tests: ['db/**/*_test.go'], "
                        "migrations: {glob: 'db/migrations/*.sql', version: '^([0-9]+)_'}}\n")
        self.repo()
        self.put("db/migrations/000027_a.up.sql")
        self.put("db/migrations/000027_a.down.sql")
        base = self.commit("m")
        no_rollback_spec("n/a")
        self.put("db/migrations/000028_b.up.sql")
        self.put("db/migrations/000028_b.down.sql")
        self.expect(0, "migration", base, "spec.md")
        self.put("db/migrations/000027_c.up.sql", "create table z (id int);\n")
        self.expect(1, "migration", base, "spec.md")

    def test_any_layer(self):
        "migration: any layer's migrations, with the layer's comment prefix"
        self.own_config(LAYERS)
        self.repo()
        self.put("services/b/migrations/1.sql", "create table a (id int);\n")
        base = self.commit("m")
        no_rollback_spec()
        self.put("services/b/migrations/2.sql", "# we never drop here\ncreate table b (id int);\n")
        self.expect(0, "migration", base, "spec.md")
        self.put("services/b/migrations/3.sql", "drop table a;\n")
        self.expect(1, "migration", base, "spec.md")
        os.unlink("services/b/migrations/3.sql")
        self.put("services/b/migrations/1.sql", "create table a (id bigint);\n")
        self.expect(1, "migration", base, "spec.md")


class Fast(gs.GateCase):
    """fast <base> <spec> [qa]: forbidden + migration + acceptance-intact on one config answer (deploy's gate)."""

    def setUp(self):
        super().setUp()
        self.repo()
        self.put("%s/V1__a.sql" % M, "create table a (id int);\n")
        self.base = self.commit("v1")
        no_rollback_spec("n/a")
        self.put("api/src/test/ATest.kt", "test\n")
        self.qa = self.commit("test(x): acceptance tests for #9")
        self.put("api/Impl.kt", "impl\n")
        self.commit("impl")

    def test_three_checks(self):
        "fast: passes when all three hold; blocks an edited acceptance test only with the qa argument, a forbidden file, a destructive migration"
        self.expect(0, "fast", self.base, "spec.md", self.qa)
        self.put("api/src/test/ATest.kt", "weakened\n")
        self.assertIn("api/src/test/ATest.kt", self.expect(1, "fast", self.base, "spec.md", self.qa).err)
        self.expect(0, "fast", self.base, "spec.md")
        self.git("checkout", "-q", "--", "api/src/test/ATest.kt")
        self.put(".github/w.yml")
        self.expect(1, "fast", self.base, "spec.md", self.qa)
        os.unlink(".github/w.yml")
        self.put("%s/V2__x.sql" % M, "drop table a;\n")
        self.expect(1, "fast", self.base, "spec.md")

    def test_bad_revisions_end_the_gate(self):
        "fast: a qa or base that is no commit is exit 2; an exit inside a check ends the whole gate"
        self.expect(2, "fast", self.base, "spec.md", "deadbeef")
        self.expect(2, "fast", "deadbeef", "spec.md")
        self.git("checkout", "-q", "-b", "side")
        self.git("rm", "-q", "-r", M)
        self.commit("x", add=False)
        self.git("checkout", "-q", "main")
        r = self.expect(2, "fast", self.head("side"), "spec.md", "deadbeef")
        self.assertIn("is not an ancestor", r.err)
        self.assertNotIn("bad revision 'deadbeef'", r.err)

    def test_config_answer_count(self):
        "fast: a gate-fast answer with the wrong number of values is a failed config query, exit 2"
        py = self.sh("fakepy", 'for a in "$@"; do\n  if [ "$a" = gate-fast ]; then n="$FAST_COUNT"; '
                               "while [ \"$n\" -gt 0 ]; do printf 'x\\0'; n=$(( n - 1 )); done; exit 0; fi\ndone\n"
                               'exec "%s" "$@"' % gs.sys.executable)
        bad = []
        for n in ("0", "2", "4"):
            r = self.gate("fast", self.base, "spec.md", self.qa, SHIPFLOOR_PY=py, FAST_COUNT=n)
            if r.code != 2 or "gate: config query failed: gate-fast" not in r.err or r.last != "gate fast: FAIL (exit 2)":
                bad.append("%s values: %r" % (n, r))
        self.assertFalse(bad, "\n".join(bad))


def grep_e(pattern, line, ignore_case=False):
    r = subprocess.run(["grep", "-Ei" if ignore_case else "-E", "--", pattern], input=line.encode("utf-8"),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode


class Ere(unittest.TestCase):
    VALID = [(r"\bfoo\b", "a foo b", False), (r"\bfoo\b", "foobar", False), (r"\bfoo\b", "barfoo", False),
             ("a[[:space:]]b", "a b", False), ("a[[:space:]]b", "a\tb", False), ("a[[:space:]]b", "ab", False),
             ("a[[:space:]]+b", "a   b", False), ("^(light|standard|heavy)$", "heavy", False),
             ("^(light|standard|heavy)$", "heavier", False), ("^[0-9]+$", "123", False), ("^[0-9]+$", "12a", False),
             ("ABC", "xabcx", True), ("ABC", "xabcx", False), ("tests? [0-9]{2}", "test 42", False),
             ("tests? [0-9]{2}", "tests 4", False), (r"a\.b", "a.b", False), (r"a\.b", "axb", False)]

    def test_ere_match_agrees_with_grep_e(self):
        "text.ere_match agrees with grep -E on \\b, [[:space:]] and the other valid patterns"
        for pattern, line, ic in self.VALID:
            want = grep_e(pattern, line, ic)
            self.assertIn(want, (0, 1), "grep -E rejects %r" % pattern)
            self.assertEqual(bool(text.ere_match(pattern, line, ignore_case=ic)), want == 0, (pattern, line, ic))

    def test_ere_match_raises_on_an_invalid_pattern(self):
        "text.ere_match raises on an invalid pattern, never 'no match'"
        for pattern in ["(", "a(b", "[a-", "[[:space:]", "a\\"]:
            self.assertEqual(grep_e(pattern, "anything"), 2, "grep -E accepts %r" % pattern)
            self.assertRaises(ValueError, text.ere_match, pattern, "anything")
