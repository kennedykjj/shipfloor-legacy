"""A project's .shipfloor/factory.yml, through shipfloor-config.sh's queries in process (project.config_main and
shipfloor_config): get, layers, layer, regex, layer-of, describe, language and overrides.yml, and validate's every
refusal with the line it prints."""
import os
import re

from support import SCRIPTS
from config_support import ConfigCase, FIXTURE_YML, BOARD, LAYER

from shipfloor_core import text


class Queries(ConfigCase):
    def matching(self, regex, paths):
        """The paths grep -E matches with the regex, the way the gates read it."""
        return [l for l in text.ere_lines(regex, "\n".join(paths) + "\n").splitlines() if l]

    def assertMatches(self, regex, yes, no):
        self.assertEqual(self.matching(regex, yes + no), yes, "regex %r" % regex)

    def test_get(self):
        "get prints a value, a default, a list one per line; a missing key exits 1, a missing config 2"
        self.assertEqual(self.cfg("validate")[0], 0)
        self.assertEqual(self.out("get", "project.repo"), "acme/shop\n")
        self.assertEqual(self.out("get", "project.main"), "main\n")
        self.assertEqual(self.out("get", "limits.develop.wip"), "4\n")
        self.assertEqual(self.out("get", "paths.specs"), "docs/superpowers/specs/\n")
        self.assertEqual(self.out("get", "context"), "PRODUCT.md\nCLAUDE.md\n")
        self.assertEqual(self.out("get", "deploy"), '{"ci_workflow": "CI", "environment": "production"}\n')
        self.assertEqual(self.cfg("get", "project.nothing")[0], 1)
        rc, _, err = self.cfg("get", "project.repo", config=os.path.join(self.tmp, "nonexistent", "factory.yml"))
        self.assertEqual(rc, 2)
        self.assertIn("config not found: ", err)

    def test_layers(self):
        "layers, --implementers, a layer's field with its default; an unknown layer exits 2"
        self.assertEqual(self.out("layers"), "api\nweb\ne2e\n")
        self.assertEqual(self.out("layers", "--implementers"), "api\nweb\n")
        self.assertEqual(self.out("layer", "api", "agent"), "engineer\n")
        self.assertEqual(self.out("layer", "e2e", "needs_stack"), "true\n")
        self.assertEqual(self.out("layer", "api", "path"), "api/\n")
        self.assertEqual(self.cfg("layer", "api", "nothing")[0], 1)
        rc, _, err = self.cfg("layer", "nope", "path")
        self.assertEqual(rc, 2)
        self.assertIn("unknown layer 'nope'", err)
        self.assertEqual(self.out("fields", "api", "path", "needs_stack", "tests"), "api/\0false\0api/src/test/**\0")
        self.assertEqual(self.out("values", "project.name", "nothing"), "shop\0\0")

    def test_scope_regexes(self):
        "regex scope: qa takes every layer's tests, a layer its path, po the specs, techlead specs and plans"
        self.assertMatches(self.out("regex", "scope", "qa").strip(),
                           ["api/src/test/kotlin/ATest.kt", "web/lib/a.test.ts", "web/e2e/a.spec.ts"],
                           ["web/lib/a.ts", "api/src/main/A.kt"])
        self.assertMatches(self.out("regex", "scope", "web").strip(), ["web/app/page.tsx"], ["api/A.kt"])
        self.assertMatches(self.out("regex", "scope", "po").strip(), ["docs/superpowers/specs/x.md"], ["docs/superpowers/plans/x.md"])
        self.assertMatches(self.out("regex", "scope", "techlead").strip(), ["docs/superpowers/plans/x.md"], ["api/A.kt"])
        rc, _, err = self.cfg("regex", "scope", "e2e")
        self.assertEqual(rc, 2, "a tests-only layer has no implementer")
        self.assertIn("layer 'e2e' is tests_only: it has no implementer", err)
        self.assertEqual(self.cfg("regex", "scope", "nope")[0], 2)

    def test_other_regexes(self):
        "regex test-config, forbidden (built-in and the project's), migrations (one folder deep, empty without)"
        self.assertMatches(self.out("regex", "test-config").strip(), ["web/vitest.config.ts"], ["web/vitest.config/x/y.ts"])
        self.assertMatches(self.out("regex", "forbidden").strip(),
                           [".shipfloor/factory.yml", ".github/w.yml", ".claude/x.md", "CLAUDE.md", "api/.env",
                            "web/.env.local", "docs/engineering/x.md"],
                           ["api/env.kt", "docs/CLAUDE.md.bak"])
        self.assertMatches(self.out("regex", "forbidden").strip(),
                           [".codex/x", ".opencode/x", ".agents/x", "AGENTS.md", "AGENTS.override.md", "opencode.json",
                            "opencode.jsonc"],
                           ["AGENTS.md.bak", "opencode.jsonx", "api/codex/x"])
        guard = open(os.path.join(os.path.dirname(SCRIPTS), "templates", "factory-guard.yml"), encoding="utf-8").read()
        pattern = re.search(r"grep -E '([^']+)'", guard).group(1)
        self.assertMatches(pattern, [".codex/x", ".opencode/x", ".agents/x", "AGENTS.md", "AGENTS.override.md", "opencode.json",
                                     "opencode.jsonc", ".claude/x.md"], ["api/env.kt", "AGENTS.md.bak"])
        self.assertMatches(self.out("regex", "migrations", "api").strip(),
                           ["api/src/main/resources/db/migration/V2__add.sql"],
                           ["api/src/main/resources/db/migration/sub/V2__add.sql"])
        self.assertEqual(self.out("regex", "migrations", "web"), "\n")
        self.assertMatches(self.out("regex", "tests-only").strip(), ["web/e2e/a.spec.ts"], ["web/lib/a.test.ts"])

    def test_layer_of(self):
        "layer-of names the implementer whose path holds the file (preferred over a tests-only layer); none exits 1"
        self.assertEqual(self.out("layer-of", "web/e2e/x.spec.ts"), "web\n")
        self.assertEqual(self.out("layer-of", "./api/A.kt"), "api\n")
        self.assertEqual(self.cfg("layer-of", "README.md")[0], 1)

    def test_describe(self):
        "describe names the repository, the layers and their agents"
        d = self.out("describe")
        for want in ("project: shop  repo: acme/shop  main: main", "  - api: path=api/ agent=engineer stack=Kotlin/Spring Boot",
                     "  - e2e: path=web/ tests only (QA)", "test: ", "(own stack slot)", "migrations: api/src/main/",
                     "deploy: ci_workflow=CI, environment=production", "stack: yes, http://localhost:3000"):
            self.assertIn(want, d)

    def test_literal_globs(self):
        "a glob is literal outside * ? **: spaces, +, ( ) match only themselves; ? is one character, never /"
        cfg = self.yml(BOARD + "layers:\n  - {name: odd, path: 'my dir/', test: 't {selector}', ran: 'ok', "
                       "tests: ['my dir/a+b(1).ts', 'pkg/?.ts']}\n")
        self.assertMatches(self.out("regex", "scope", "qa", config=cfg).strip(), ["my dir/a+b(1).ts", "pkg/a.ts"],
                           ["my dirXa+b(1).ts", "my dir/aab1.ts", "pkg/ab.ts", "pkg/a/b.ts", "pkg//.ts"])

    def test_gate_queries(self):
        "patterns, gate-fast and migration-layers hand the gates their regexes, NUL-terminated"
        self.assertEqual(self.out("patterns").split("\0")[:3], ["Tests run: [1-9]", "Tests +[1-9][0-9]* passed",
                                                               "(^|[[:space:]])[1-9][0-9]* passed"])
        plan = self.out("migration-layers")
        self.assertTrue(plan.startswith("main\napi\t"), plan)
        self.assertEqual(self.out("gate-fast").count("\0"), 3)
        rc, _, err = self.cfg("bogus")
        self.assertEqual(rc, 2)
        self.assertIn("bad usage: bogus", err)


class Validate(ConfigCase):
    def refused(self, yaml_text, *want):
        cfg = self.yml(yaml_text)
        rc, _, err = self.raw("validate", config=cfg)
        self.assertEqual(rc, 1, "validate accepted:\n%s" % yaml_text)
        for w in want:
            self.assertIn("%s: %s" % (cfg, w), err)
        return err

    def test_fixture_valid_through_the_wrapper_code(self):
        "the fixture validates (exit 0); a refused one exits 1 with its reason, through the grep -E pass too"
        self.assertEqual(self.cfg("validate"), (0, "", ""))
        rc, _, err = self.cfg("validate", config=self.yml(BOARD))
        self.assertEqual((rc, err.strip().endswith("layers must be a non-empty list")), (1, True), err)

    def test_refusals(self):
        "every unusable config is refused with a line naming the key"
        L = "layers:\n  - {name: a, path: a/, test: t, ran: ok, tests: [a/**]%s}\n"
        cases = [
            (BOARD, "layers must be a non-empty list"),
            (BOARD + L % ", tests_only: true, agent: z", "layer 'a': a tests_only layer has no agent or build"),
            (BOARD + "layers:\n  - {name: qa, path: a/, test: t, ran: ok, tests: [a/**]}\n", "layer 'qa': name is reserved (po, ux, techlead, qa)"),
            (BOARD + "layers:\n  - {name: a, path: a/, test: t, ran: '(', tests: [a/**]}\n", "layer 'a': ran is not a valid extended regex (grep -E)"),
            (BOARD + LAYER + "  - {name: a, path: b/, test: t, ran: ok, tests: [b/**]}\n", "layer 'a': duplicate name"),
            ("project: {name: X Y, repo: a/x}\nboard: {owner: a, number: 1}\n" + LAYER, "project.name must match [a-z0-9][a-z0-9-]*"),
            ("project: {name: x, repo: nope}\nboard: {owner: '', number: '1'}\n" + LAYER,
             "project.repo must be owner/repo", "board.owner is required", "board.number must be an integer"),
            ("project: {name: x, repo: a/x, main: ''}\nboard: {owner: a, number: 1}\n" + LAYER, "project.main must be a branch name"),
            ("project: 3\nboard: {owner: a, number: 1}\n" + LAYER, "project must be a mapping"),
            (BOARD + "context: x\nforbidden: [1]\n" + LAYER, "context must be a list of strings", "forbidden must be a list of strings"),
            (BOARD + "trusted_commenters: ['-bad']\n" + LAYER, 'trusted_commenters must be a list of GitHub logins, or ["*"] for anyone'),
            (BOARD + "review_criteria: [x]\nlanguage: xx\n" + LAYER, "review_criteria must be a path", "language must be one of en, "),
            (BOARD + "acceptance_assertions: '('\n" + LAYER, "acceptance_assertions must be a valid extended regex (grep -E)"),
            (BOARD + "acceptance_assertions: '\\d+'\n" + LAYER, "acceptance_assertions must be a valid extended regex (grep -E)"),
            (BOARD + "paths: {specs: docs}\n" + LAYER, "paths.specs must be a directory like docs/specs/"),
            (BOARD + "limits: {develop: 3, refine: {runs: 1}, validate: {wip: -1}}\n" + LAYER,
             "limits.develop must be a mapping like {wip: 4}", "limits.refine.runs is not a limit (only wip;",
             "limits.validate.wip must be a non-negative integer"),
            (BOARD + "deploy: {timeout_min: 0, required_checks: x, allow_no_checks: 1, healthcheck: [ftp://x], ci_workflow: 3}\n" + LAYER,
             "deploy.timeout_min must be a positive integer", "deploy.required_checks must be a list of check names",
             "deploy.allow_no_checks must be true or false", "deploy.healthcheck must be a list of http(s) URLs",
             "deploy.ci_workflow must be a string"),
            (BOARD + "stack: {url: 3, timeout: 0, ports: web}\n" + LAYER, "stack.url must be a string",
             "stack.timeout must be an integer >= 1", "stack.ports must be a list of lowercase names"),
            (BOARD + "stack: {url: 'http://localhost:{nope}', ports: [web]}\n" + LAYER, "stack.url uses {nope}, which is not in stack.ports"),
            (BOARD + "layers: [3]\n", "layers[0] must be a mapping"),
            (BOARD + "layers:\n  - {name: 3, path: a, tests: [], test_config: x, build: 1, needs_stack: 1, retry: 2}\n",
             "layers[0]: name must match", "layers[0]: test is required", "layers[0]: ran is required",
             "layers[0]: path must be a directory ending in /", "layers[0]: tests must be a non-empty list of globs",
             "layers[0]: test_config must be a list of globs", "layers[0]: build must be a string",
             "layers[0]: needs_stack must be true or false", "layers[0]: retry must be 0 or 1"),
            (BOARD + L % ", migrations: {}", "layer 'a': migrations needs a glob"),
            (BOARD + L % ", migrations: {glob: x, comment: 3}", "layer 'a': migrations.comment must be a string"),
            (BOARD + L % ", migrations: {glob: x, version: 'V.*'}", "layer 'a': migrations.version must be a regex with one group"),
            (BOARD + L % ", migrations: {glob: x, version: '('}", "layer 'a': migrations.version is not a valid regex"),
            ("- a list\n", "the file is not a YAML mapping"),
        ]
        for case in cases:
            self.refused(*case)

    def test_not_yaml(self):
        "a file that is not YAML is refused by validate (exit 1) and unusable for a query (exit 2)"
        cfg = self.yml("project: [unclosed\n")
        rc, _, err = self.raw("validate", config=cfg)
        self.assertEqual(rc, 1)
        self.assertIn(": not valid YAML: ", err)
        self.assertEqual(self.raw("get", "project.repo", config=cfg)[0], 2)
        self.assertEqual(self.raw("get", "project.repo", config=self.yml(BOARD))[0], 2, "an invalid config is never read")

    def test_stack_block(self):
        "the stack block: commands are strings, ports a list of names that url and health may use"
        base = open(FIXTURE_YML).read().replace('stack: {url: "http://localhost:3000"}\n', "")
        ok = self.yml(base + 'stack: {url: "http://localhost:{web}", health: "http://localhost:{api}/h", up: "x", down: "y", ports: [web, api], timeout: 60}\n')
        self.assertEqual(self.raw("validate", config=ok), (0, "", ""))
        self.refused(base + 'stack: {url: "http://localhost:3000", ports: web}\n', "stack.ports must be a list of lowercase names")
        self.refused(base + 'stack: {url: "http://localhost:{nope}", ports: [web]}\n', "stack.url uses {nope}")

    def test_flags(self):
        "--config/--home/--worktrees need a value; an unknown flag or no command is unusable (exit 2)"
        for argv, want in ((["--config"], "--config needs a value"), (["--bogus", "x"], "unknown flag --bogus"),
                           ([], "usage: shipfloor-config validate|get|")):
            rc, _, err = self.raw(*argv)
            self.assertEqual(rc, 2, argv)
            self.assertIn(want, err)


class Language(ConfigCase):
    """AC-2 (#129): this machine's language for a project lies in overrides.yml beside its factory.yml, which stays as
    it is; every reader follows, and `language` names who decided it."""

    def setUp(self):
        super().setUp()
        self.fixture = open(FIXTURE_YML, encoding="utf-8").read()
        self.c = self.yml(self.fixture)

    def over(self, text):
        return self.write("proj/overrides.yml", text)

    def test_no_language(self):
        "AC-2 no language key anywhere: en, from the repository"
        self.assertEqual(self.out("language", config=self.c), "en\trepository\tEnglish\n")

    def test_override(self):
        "AC-2 an override pt-BR: validate, get, describe, values and language follow it; factory.yml is untouched"
        self.over("language: pt-BR\n")
        self.assertEqual(self.cfg("validate", config=self.c)[0], 0)
        self.assertEqual(self.out("get", "language", config=self.c), "pt-BR\n")
        self.assertIn("language: Brazilian Portuguese (pt-BR)", self.out("describe", config=self.c))
        self.assertEqual(self.out("values", "language", config=self.c), "pt-BR\0")
        self.assertEqual(self.out("language", config=self.c), "pt-BR\tmachine\tBrazilian Portuguese\n")
        self.assertEqual(open(self.c, encoding="utf-8").read(), self.fixture)

    def test_bad_override(self):
        "a language outside LANGS, or not a string, is refused"
        for bad in ("language: xx\n", "language: [en]\n"):
            self.over(bad)
            self.assertEqual(self.raw("validate", config=self.c)[0], 1, bad)

    def test_override_wins(self):
        "AC-2 the override wins over the repository's key, and only it says machine"
        self.c = self.yml("language: pt-BR\n" + self.fixture)
        self.over("language: en\n")
        self.assertEqual(self.out("language", config=self.c), "en\tmachine\tEnglish\n")
        os.unlink(os.path.join(self.tmp, "proj", "overrides.yml"))
        self.assertEqual(self.out("language", config=self.c), "pt-BR\trepository\tBrazilian Portuguese\n")

    def test_run_language(self):
        "FACTORY_LANGUAGE, the language a run started with, wins while it runs"
        os.environ["FACTORY_LANGUAGE"] = "pt-BR"
        self.assertEqual(self.out("get", "language", config=self.c), "pt-BR\n")

    def test_other_overrides(self):
        "overrides.yml may set limits.<stage>.wip and deploy.timeout_min; anything else is refused, as is a non-mapping"
        self.over("limits: {develop: {wip: 9}}\ndeploy: {timeout_min: 7}\n")
        self.assertEqual(self.out("get", "limits.develop.wip", config=self.c), "9\n")
        self.assertEqual(self.out("get", "deploy.timeout_min", config=self.c), "7\n")
        self.assertEqual(self.out("get", "deploy.ci_workflow", config=self.c), "CI\n")
        self.over("project: {repo: b/c}\n")
        rc, _, err = self.raw("validate", config=self.c)
        self.assertEqual(rc, 1)
        self.assertIn("overrides.yml: project cannot be overridden (only limits.<stage>.wip, deploy.timeout_min, "
                      "deploy.conflict_max_files, language)", err)
        self.over("- 1\n")
        self.assertIn("overrides.yml is not a YAML mapping", self.raw("validate", config=self.c)[2])
        self.over("a: [\n")
        self.assertIn("overrides.yml is not a YAML mapping", self.raw("validate", config=self.c)[2])
