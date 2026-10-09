"""Reads and validates a project's .mylos/factory.yml and answers the factory scripts' queries.

Exit codes: 0 ok, 1 negative answer (invalid config on validate, missing key, no owner layer),
2 unusable (missing or invalid config, unknown layer or role, bad usage). Read-only.
"""
import json, os, re, sys, warnings

warnings.simplefilter("ignore")  # ERE classes like [[:space:]] make Python's re warn
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

try:
    import yaml
except ImportError:
    print("mylos-config: PyYAML is missing (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

RESERVED = {"po", "ux", "techlead", "qa"}
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
DEFAULTS = {
    "project": {"main": "main"},
    "paths": {"specs": "docs/superpowers/specs/", "plans": "docs/superpowers/plans/"},
    "limits": {"refinar": {"parallel": 2, "wip": 2}, "desenvolver": {"parallel": 2, "wip": 4},
               "deployar": {"parallel": 1, "wip": 0}},
    "context": [], "forbidden": [], "review_criteria": "",
}
LAYER_DEFAULTS = {"stack": "", "build": "", "assertions": "", "setup_errors": "", "test_config": [],
                  "needs_stack": False, "tests_only": False, "migrations": {}}
BUILTIN_FORBIDDEN = r"^(\.github/|\.githooks/|\.claude/|\.mylos/)|^(CLAUDE\.md|\.gitattributes|\.mcp\.json)$|(^|/)\.env"
ERE_SPECIAL = set(".^$+(){}[]|\\")


class Unusable(Exception):
    """The config cannot answer: exit 2."""


def glob_to_ere(glob):
    """One glob as an unanchored ERE: ** crosses /, * and ? do not, a trailing / is a prefix."""
    if glob in ("", ".", "./"):
        return ".*"
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(.*/)?"); i += 3; continue
        if glob.startswith("**", i):
            out.append(".*"); i += 2; continue
        ch = glob[i]
        out.append("[^/]*" if ch == "*" else "[^/]" if ch == "?" else "\\" + ch if ch in ERE_SPECIAL else ch)
        i += 1
    if glob.endswith("/"):
        out.append(".*")
    return "".join(out)


def any_of(globs):
    """Anchored ERE matching any of the globs; empty string when there are none."""
    globs = [g for g in globs if isinstance(g, str)]
    return "^(" + "|".join(glob_to_ere(g) for g in globs) + ")$" if globs else ""


def merged(raw, defaults):
    out = dict(defaults)
    for k, v in (raw or {}).items():
        out[k] = merged(v, defaults[k]) if isinstance(v, dict) and isinstance(defaults.get(k), dict) else v
    return out


def compiles(pattern):
    try:
        re.compile(pattern); return True
    except re.error:
        return False


def problems(cfg):
    """Every reason the config is unusable, as human-readable lines."""
    if not isinstance(cfg, dict):
        return ["the file is not a YAML mapping"]
    errs = []
    project, board = cfg.get("project") or {}, cfg.get("board") or {}
    if not isinstance(project.get("name"), str) or not SLUG.match(project["name"]):
        errs.append("project.name must match [a-z0-9][a-z0-9-]*")
    if not isinstance(project.get("repo"), str) or not REPO.match(project["repo"]):
        errs.append("project.repo must be owner/repo")
    if not isinstance(board.get("owner"), str) or not board["owner"]:
        errs.append("board.owner is required")
    if not isinstance(board.get("number"), int) or isinstance(board.get("number"), bool):
        errs.append("board.number must be an integer")
    for key in ("context", "forbidden"):
        if not isinstance(cfg.get(key, []), list):
            errs.append(f"{key} must be a list")
    for p, lim in (cfg.get("limits") or {}).items():
        for k, v in (lim or {}).items():
            if not isinstance(v, int) or v < 0:
                errs.append(f"limits.{p}.{k} must be a non-negative integer")
    layers = cfg.get("layers")
    if not isinstance(layers, list) or not layers:
        return errs + ["layers must be a non-empty list"]
    seen = set()
    for i, layer in enumerate(layers):
        if not isinstance(layer, dict):
            errs.append(f"layers[{i}] must be a mapping"); continue
        name = layer.get("name")
        where = f"layer '{name}'" if isinstance(name, str) else f"layers[{i}]"
        if not isinstance(name, str) or not SLUG.match(name):
            errs.append(f"{where}: name must match [a-z0-9][a-z0-9-]*")
        elif name in RESERVED:
            errs.append(f"{where}: name is reserved (po, ux, techlead, qa)")
        elif name in seen:
            errs.append(f"{where}: duplicate name")
        seen.add(name)
        for key in ("path", "test", "ran"):
            if not isinstance(layer.get(key), str):
                errs.append(f"{where}: {key} is required")
        tests = layer.get("tests")
        if not isinstance(tests, list) or not tests or not all(isinstance(t, str) and t for t in tests):
            errs.append(f"{where}: tests must be a non-empty list of globs")
        if not isinstance(layer.get("test_config", []), list):
            errs.append(f"{where}: test_config must be a list")
        for key in ("ran", "assertions", "setup_errors"):
            if isinstance(layer.get(key), str) and not compiles(layer[key]):
                errs.append(f"{where}: {key} is not a valid regex")
        if layer.get("tests_only") and ("agent" in layer or "build" in layer):
            errs.append(f"{where}: a tests_only layer has no agent or build")
        mig = layer.get("migrations")
        if mig is not None and (not isinstance(mig, dict) or not isinstance(mig.get("glob"), str)):
            errs.append(f"{where}: migrations needs a glob")
    return errs


def load(path):
    if not path or not os.path.isfile(path):
        raise Unusable(f"config not found: {path or '(FACTORY_CONFIG unset)'}")
    with open(path, encoding="utf-8") as f:
        try:
            return yaml.safe_load(f)
        except yaml.YAMLError as e:
            raise Unusable(f"{path}: not valid YAML: {e}")


class Config:
    def __init__(self, raw):
        self.raw = raw
        self.data = merged(raw, DEFAULTS)
        self.layers = []
        for layer in raw["layers"]:
            full = merged(layer, LAYER_DEFAULTS)
            if not full["tests_only"]:
                full.setdefault("agent", "engineer")
            if full["migrations"]:
                full["migrations"] = merged(full["migrations"], {"comment": "--"})
            self.layers.append(full)

    def layer(self, name):
        for layer in self.layers:
            if layer["name"] == name:
                return layer
        raise Unusable(f"unknown layer '{name}'")

    def implementers(self):
        return [l for l in self.layers if not l["tests_only"]]

    def scope(self, role):
        specs, plans = self.data["paths"]["specs"], self.data["paths"]["plans"]
        if role == "qa":
            return any_of([t for l in self.layers for t in l["tests"]])
        if role in ("po", "ux"):
            return any_of([specs])
        if role == "techlead":
            return any_of([specs, plans])
        layer = self.layer(role)
        if layer["tests_only"]:
            raise Unusable(f"layer '{role}' is tests_only: it has no implementer")
        return any_of([layer["path"]])

    def forbidden(self):
        extra = any_of(self.data["forbidden"])
        return BUILTIN_FORBIDDEN + ("|" + extra if extra else "")

    def layer_of(self, path):
        for layer in self.implementers():
            if re.search(any_of([layer["path"]]), path):
                return layer["name"]
        return None


def dotted(data, key):
    for part in key.split("."):
        if not isinstance(data, dict) or part not in data:
            return None
        data = data[part]
    return data


def emit(value):
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, list):
        for item in value:
            emit(item)
    elif isinstance(value, dict):
        print(json.dumps(value, ensure_ascii=False))
    elif value is not None:
        print(value)


def describe(cfg, home, worktrees):
    d, p = cfg.data, cfg.data["project"]
    lines = [f"project: {p['name']}  repo: {p['repo']}  main: {p['main']}",
             f"board: {d['board']['owner']} #{d['board']['number']}",
             f"home: {home}", f"worktrees: {worktrees}", f"tmp: {home}/tmp/<n>", f"reviews: {home}/reviews",
             f"specs: {d['paths']['specs']}  plans: {d['paths']['plans']}",
             f"context: {', '.join(d['context']) or '(none)'}",
             f"review criteria: {d['review_criteria'] or '~/.mylos/factory/templates/review-criteria.md'}",
             f"stack: {('yes, ' + str(d['stack'].get('url', ''))) if d.get('stack') else 'none'}"]
    dep = d.get("deploy") or {}
    lines.append("deploy: " + (", ".join(f"{k}={v}" for k, v in dep.items()) if dep else "none (Done after merge)"))
    lines.append("layers:")
    for l in cfg.layers:
        who = "tests only (QA)" if l["tests_only"] else f"agent={l['agent']}"
        lines.append(f"  - {l['name']}: path={l['path']} {who}" + (f" stack={l['stack']}" if l["stack"] else ""))
        if l["build"]:
            lines.append(f"      build: {l['build']}")
        lines.append(f"      test: {l['test']}" + ("  (takes the stack lock)" if l["needs_stack"] else ""))
        lines.append(f"      tests: {', '.join(l['tests'])}")
        if l["migrations"]:
            lines.append(f"      migrations: {l['migrations']['glob']}")
    return "\n".join(lines)


def main(argv):
    args = list(argv)
    path = os.environ.get("FACTORY_CONFIG", "")
    home = worktrees = ""
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if not args:
            raise Unusable(f"{flag} needs a value")
        if flag == "--config":
            path = args.pop(0)
        elif flag == "--home":
            home = args.pop(0)
        elif flag == "--worktrees":
            worktrees = args.pop(0)
        else:
            raise Unusable(f"unknown flag {flag}")
    if not args:
        raise Unusable("usage: mylos-config validate|get|layers|layer|regex|layer-of|describe ...")
    cmd, rest = args[0], args[1:]

    if not path or not os.path.isfile(path):
        raise Unusable(f"config not found: {path or '(FACTORY_CONFIG unset)'}")
    try:
        raw = load(path)
    except Unusable as e:
        if cmd == "validate":
            print(f"mylos-config: {e}", file=sys.stderr); return 1
        raise
    errs = problems(raw)
    if cmd == "validate":
        for e in errs:
            print(f"mylos-config: {path}: {e}", file=sys.stderr)
        return 1 if errs else 0
    if errs:
        raise Unusable(f"{path} is invalid: " + "; ".join(errs))
    cfg = Config(raw)

    if cmd == "get" and len(rest) == 1:
        value = dotted(cfg.data, rest[0])
        if value is None:
            return 1
        emit(value); return 0
    if cmd == "layers" and rest in ([], ["--implementers"]):
        emit([l["name"] for l in (cfg.implementers() if rest else cfg.layers)]); return 0
    if cmd == "layer" and len(rest) == 2:
        value = dotted(cfg.layer(rest[0]), rest[1])
        if value is None:
            return 1
        emit(value); return 0
    if cmd == "regex" and rest[:1] == ["scope"] and len(rest) == 2:
        print(cfg.scope(rest[1])); return 0
    if cmd == "regex" and rest == ["test-config"]:
        print(any_of([g for l in cfg.layers for g in l["test_config"]])); return 0
    if cmd == "regex" and rest == ["forbidden"]:
        print(cfg.forbidden()); return 0
    if cmd == "regex" and rest[:1] == ["migrations"] and len(rest) == 2:
        mig = cfg.layer(rest[1])["migrations"]
        print(any_of([mig["glob"]]) if mig else ""); return 0
    if cmd == "layer-of" and len(rest) == 1:
        name = cfg.layer_of(rest[0])
        if name is None:
            return 1
        print(name); return 0
    if cmd == "describe" and not rest:
        print(describe(cfg, home, worktrees)); return 0
    raise Unusable(f"bad usage: {' '.join(args)}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Unusable as e:
        print(f"mylos-config: {e}", file=sys.stderr)
        sys.exit(2)
