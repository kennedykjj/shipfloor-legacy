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
               "validar": {"parallel": 2, "wip": 0}, "deployar": {"parallel": 1, "wip": 0}},
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


PCRE_ONLY = re.compile(r"\\[dDhHpPAzZ]|\(\?")  # not ERE: grep -E would read these literally


def compiles(pattern):
    """A usable ERE: Python can compile it and it uses no PCRE-only syntax (grep -E has none)."""
    if PCRE_ONLY.search(pattern):
        return False
    try:
        re.compile(pattern); return True
    except re.error:
        return False


def is_str_list(value):
    return isinstance(value, list) and all(isinstance(v, str) and v for v in value)


def mapping(cfg, key):
    return cfg.get(key) if isinstance(cfg.get(key), dict) else {}


def problems(cfg):
    """Every reason the config is unusable, as human-readable lines."""
    if not isinstance(cfg, dict):
        return ["the file is not a YAML mapping"]
    errs = []
    for key in ("project", "board", "paths", "limits", "stack", "deploy"):
        if key in cfg and not isinstance(cfg[key], dict):
            errs.append(f"{key} must be a mapping")
    project, board = mapping(cfg, "project"), mapping(cfg, "board")
    if not isinstance(project.get("name"), str) or not SLUG.match(project["name"]):
        errs.append("project.name must match [a-z0-9][a-z0-9-]*")
    if not isinstance(project.get("repo"), str) or not REPO.match(project["repo"]):
        errs.append("project.repo must be owner/repo")
    if "main" in project and (not isinstance(project["main"], str) or not project["main"]):
        errs.append("project.main must be a branch name")
    if not isinstance(board.get("owner"), str) or not board["owner"]:
        errs.append("board.owner is required")
    if not isinstance(board.get("number"), int) or isinstance(board.get("number"), bool):
        errs.append("board.number must be an integer")
    for key in ("context", "forbidden"):
        if key in cfg and not is_str_list(cfg[key]):
            errs.append(f"{key} must be a list of strings")
    if not isinstance(cfg.get("review_criteria", ""), str):
        errs.append("review_criteria must be a path")
    for k, v in mapping(cfg, "paths").items():
        if not isinstance(v, str) or not v.endswith("/") or v.strip("/.") == "":
            errs.append(f"paths.{k} must be a directory like docs/specs/")
    for p, lim in mapping(cfg, "limits").items():
        if not isinstance(lim, dict):
            errs.append(f"limits.{p} must be a mapping like {{parallel: 2, wip: 4}}"); continue
        for k, v in lim.items():
            if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                errs.append(f"limits.{p}.{k} must be a non-negative integer")
    for k, v in mapping(cfg, "deploy").items():
        if k == "timeout_min":
            if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
                errs.append("deploy.timeout_min must be a positive integer")
        elif not isinstance(v, str):
            errs.append(f"deploy.{k} must be a string")
    if "url" in mapping(cfg, "stack") and not isinstance(cfg["stack"]["url"], str):
        errs.append("stack.url must be a string")
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
        for key in ("test", "ran"):
            if not isinstance(layer.get(key), str) or not layer[key]:
                errs.append(f"{where}: {key} is required")
        path = layer.get("path")
        if not isinstance(path, str) or not (path in ("", ".", "./") or path.endswith("/")):
            errs.append(f"{where}: path must be a directory ending in / (or ./ for the whole repo)")
        if not is_str_list(layer.get("tests")) or not layer["tests"]:
            errs.append(f"{where}: tests must be a non-empty list of globs")
        if not is_str_list(layer.get("test_config", [])):
            errs.append(f"{where}: test_config must be a list of globs")
        for key in ("stack", "build", "assertions", "setup_errors", "agent"):
            if key in layer and not isinstance(layer[key], str):
                errs.append(f"{where}: {key} must be a string")
        for key in ("needs_stack", "tests_only"):
            if key in layer and not isinstance(layer[key], bool):
                errs.append(f"{where}: {key} must be true or false")
        for key in ("ran", "assertions", "setup_errors"):
            if isinstance(layer.get(key), str) and layer[key] and not compiles(layer[key]):
                errs.append(f"{where}: {key} is not a valid extended regex (grep -E)")
        if layer.get("tests_only") and ("agent" in layer or "build" in layer):
            errs.append(f"{where}: a tests_only layer has no agent or build")
        mig = layer.get("migrations")
        if mig is not None and (not isinstance(mig, dict) or not isinstance(mig.get("glob"), str) or not mig["glob"]):
            errs.append(f"{where}: migrations needs a glob")
        elif isinstance(mig, dict) and not isinstance(mig.get("comment", "--"), str):
            errs.append(f"{where}: migrations.comment must be a string")
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
            full["_path_re"] = any_of([full["path"]])
            full["_migrations_re"] = any_of([full["migrations"]["glob"]]) if full["migrations"] else ""
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
        while path.startswith("./"):
            path = path[2:]
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


def nul_values(data, keys):
    out = []
    for key in keys:
        v = dotted(data, key)
        if isinstance(v, list):
            v = "\n".join(map(str, v))
        elif isinstance(v, bool):
            v = "true" if v else "false"
        elif isinstance(v, dict):
            v = json.dumps(v, ensure_ascii=False) if v else ""
        elif v is None:
            v = ""
        out.append(f"{v}\0")
    return "".join(out)


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


STAGES = ("refinar", "desenvolver", "validar", "deployar")
MACHINE_DEFAULTS = {"pool": 4, "stages": {"refinar": 2, "desenvolver": 2, "validar": 2, "deployar": 1}}


def machine_problems(raw):
    if not isinstance(raw, dict):
        return ["the file is not a YAML mapping"]
    errs = []
    pool = raw.get("pool", MACHINE_DEFAULTS["pool"])
    if not isinstance(pool, int) or isinstance(pool, bool) or pool < 1:
        errs.append("pool must be an integer >= 1")
        pool = None
    stages = raw.get("stages", {})
    if not isinstance(stages, dict):
        return errs + ["stages must be a mapping of stage: runs"]
    for k, v in stages.items():
        if k not in STAGES:
            errs.append(f"stages.{k}: unknown stage (use {', '.join(STAGES)})")
        elif not isinstance(v, int) or isinstance(v, bool) or v < 0:
            errs.append(f"stages.{k} must be an integer >= 0")
        elif pool is not None and v > pool:
            errs.append(f"stages.{k} ({v}) is above the pool ({pool})")
    for k in STAGES:  # defaults must fit a smaller pool too
        if k not in stages and pool is not None and MACHINE_DEFAULTS["stages"][k] > pool:
            stages_default = MACHINE_DEFAULTS["stages"][k]
            errs.append(f"stages.{k} defaults to {stages_default}, above the pool ({pool}): set it")
    return errs


def machine(rest):
    """machine <validate | values <key>... | show | set <key> <int>> on $MYLOS_MACHINE_CONFIG."""
    path = os.environ.get("MYLOS_MACHINE_CONFIG", "")
    raw = {}
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            try:
                raw = yaml.safe_load(f)
            except yaml.YAMLError as e:
                raw = e
        if raw is None:
            raw = {}
    errs = [f"not valid YAML: {raw}"] if isinstance(raw, yaml.YAMLError) else machine_problems(raw)
    cmd, args = (rest[0], rest[1:]) if rest else ("", [])
    if cmd == "validate" and not args:
        for e in errs:
            print(f"mylos-config: {path}: {e}", file=sys.stderr)
        return 1 if errs else 0
    if cmd == "set" and len(args) == 2:
        if isinstance(raw, yaml.YAMLError):
            print(f"mylos-config: {path} is not valid YAML; fix it by hand", file=sys.stderr); return 1
        try:
            value = int(args[1])
        except ValueError:
            print(f"mylos-config: {args[1]} is not an integer", file=sys.stderr); return 1
        new = json.loads(json.dumps(raw))
        if args[0] == "pool":
            new["pool"] = value
        elif args[0].startswith("stages.") and args[0].count(".") == 1:
            if not isinstance(new.get("stages", {}), dict):
                new["stages"] = {}
            new.setdefault("stages", {})[args[0].split(".")[1]] = value
        else:
            print(f"mylos-config: cannot set {args[0]} (pool or stages.<stage>)", file=sys.stderr); return 1
        new_errs = machine_problems(new)
        if new_errs:
            for e in new_errs:
                print(f"mylos-config: {e}", file=sys.stderr)
            return 1
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("# mylos machine config: runs at once on this machine (pool) and per stage\n")
            yaml.safe_dump(new, f, sort_keys=False)
        return 0
    if errs:
        raise Unusable(f"{path} is invalid: " + "; ".join(errs))
    data = merged(raw, MACHINE_DEFAULTS)
    if cmd == "values" and args:
        sys.stdout.write(nul_values(data, args)); return 0
    if cmd == "show" and not args:
        print(f"pool: {data['pool']}")
        for k in STAGES:
            print(f"  {k}: {data['stages'][k]}")
        return 0
    raise Unusable("usage: machine validate | values <key>... | show | set <key> <int>")


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
    if cmd == "machine":
        return machine(rest)

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
    if cmd == "fields" and len(rest) >= 2:  # NUL-terminated values, for one bash read of many fields
        sys.stdout.write(nul_values(cfg.layer(rest[0]), rest[1:])); return 0
    if cmd == "values" and rest:  # same, for project-level keys
        sys.stdout.write(nul_values(cfg.data, rest)); return 0
    if cmd == "regex" and rest[:1] == ["scope"] and len(rest) == 2:
        print(cfg.scope(rest[1])); return 0
    if cmd == "patterns" and not rest:  # every regex the gates hand to grep -E, NUL-terminated
        sys.stdout.write("".join(f"{l[k]}\0" for l in cfg.layers for k in ("ran", "assertions", "setup_errors") if l[k]))
        return 0
    if cmd == "regex" and rest == ["tests-only"]:  # areas only QA writes, even inside an implementer's path
        print(any_of([t for l in cfg.layers if l["tests_only"] for t in l["tests"]])); return 0
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
    except Exception as e:  # a crash is never a negative answer (exit 1): it is unusable
        print(f"mylos-config: internal error: {e!r}", file=sys.stderr)
        sys.exit(2)
