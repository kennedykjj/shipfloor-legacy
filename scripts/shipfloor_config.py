"""Reads and validates a project's .shipfloor/factory.yml and answers the factory scripts' queries.

Exit codes: 0 ok, 1 negative answer (invalid config on validate, missing key, no owner layer),
2 unusable (missing or invalid config, unknown layer or role, bad usage). Read-only.
"""
import json, math, os, re, sys, time, warnings

warnings.simplefilter("ignore")  # ERE classes like [[:space:]] make Python's re warn
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

try:
    import yaml
except ImportError:
    print("shipfloor-config: PyYAML is missing (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

RESERVED = {"po", "ux", "techlead", "qa"}
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# what people read: the agents' specs, comments and reports, and what the scripts say (lang/<code>.sed, dashboard.<code>.json)
LANGS = {"en": "English", "pt-BR": "Brazilian Portuguese"}
DEFAULTS = {
    "language": "en",
    "project": {"main": "main"},
    "paths": {"specs": "docs/superpowers/specs/", "plans": "docs/superpowers/plans/"},
    # cards in the WIP columns; runs at once are the machine's (pool and stage slots), and deploy is serial per project
    "limits": {"refine": {"wip": 2}, "develop": {"wip": 4}, "validate": {"wip": 0}, "deploy": {"wip": 0}},
    "context": [], "forbidden": [], "review_criteria": "",
    # whose issue comments the agents read besides the factory's own GitHub user: logins, or "*" for anyone
    "trusted_commenters": [],
    # acceptance-intact lets through an edit to an acceptance test that adds or removes no line matching this. "" = every edit blocks.
    "acceptance_assertions": "",
}
LAYER_DEFAULTS = {"stack": "", "build": "", "install": "", "assertions": "", "setup_errors": "", "test_config": [],
                  "needs_stack": False, "tests_only": False, "migrations": {}, "retry": 0}
BUILTIN_FORBIDDEN = r"^(\.github/|\.githooks/|\.claude/|\.shipfloor/)|^(CLAUDE\.md|\.gitattributes|\.mcp\.json)$|(^|/)\.env"
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
    who = cfg.get("trusted_commenters", [])
    if not is_str_list(who) or any(w != "*" and not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\[bot\])?", w) for w in who):
        errs.append('trusted_commenters must be a list of GitHub logins, or ["*"] for anyone')
    if not isinstance(cfg.get("review_criteria", ""), str):
        errs.append("review_criteria must be a path")
    if cfg.get("language", "en") not in LANGS:
        errs.append(f"language must be one of {', '.join(LANGS)}")
    keep = cfg.get("acceptance_assertions", "")
    if not isinstance(keep, str) or (keep and not compiles(keep)):
        errs.append("acceptance_assertions must be a valid extended regex (grep -E)")
    for k, v in mapping(cfg, "paths").items():
        if not isinstance(v, str) or not v.endswith("/") or v.strip("/.") == "":
            errs.append(f"paths.{k} must be a directory like docs/specs/")
    for p, lim in mapping(cfg, "limits").items():
        if not isinstance(lim, dict):
            errs.append(f"limits.{p} must be a mapping like {{wip: 4}}"); continue
        for k, v in lim.items():
            if k != "wip":
                errs.append(f"limits.{p}.{k} is not a limit (only wip; runs at once are set by `shipfloor pool`)")
            elif not isinstance(v, int) or isinstance(v, bool) or v < 0:
                errs.append(f"limits.{p}.{k} must be a non-negative integer")
    for k, v in mapping(cfg, "deploy").items():
        if k in ("timeout_min", "conflict_max_files", "conflict_max_hunks", "fix_max_files", "fix_max_lines"):
            if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
                errs.append(f"deploy.{k} must be a positive integer")
        elif k == "required_checks":
            if not is_str_list(v):
                errs.append("deploy.required_checks must be a list of check names")
        elif k in ("allow_no_checks", "refresh_staged"):
            if not isinstance(v, bool):
                errs.append(f"deploy.{k} must be true or false")
        elif k == "healthcheck":
            if not is_str_list(v) or not all(u.startswith(("http://", "https://")) for u in v):
                errs.append("deploy.healthcheck must be a list of http(s) URLs")
        elif not isinstance(v, str):
            errs.append(f"deploy.{k} must be a string")
    st = mapping(cfg, "stack")
    for key in ("url", "up", "down", "health", "reject"):
        if key in st and not isinstance(st[key], str):
            errs.append(f"stack.{key} must be a string")
    if "timeout" in st and (not isinstance(st["timeout"], int) or isinstance(st["timeout"], bool) or st["timeout"] < 1):
        errs.append("stack.timeout must be an integer >= 1")
    ports = st.get("ports", [])
    if not (isinstance(ports, list) and all(isinstance(n, str) and re.fullmatch(r"[a-z][a-z0-9]*", n) for n in ports)):
        errs.append("stack.ports must be a list of lowercase names")
        ports = []
    for key in ("url", "health"):
        for name in re.findall(r"\{([a-z0-9]+)\}", st[key]) if isinstance(st.get(key), str) else []:
            if name not in ports:
                errs.append(f"stack.{key} uses {{{name}}}, which is not in stack.ports")
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
        for key in ("stack", "build", "install", "assertions", "setup_errors", "agent"):
            if key in layer and not isinstance(layer[key], str):
                errs.append(f"{where}: {key} must be a string")
        for key in ("needs_stack", "tests_only"):
            if key in layer and not isinstance(layer[key], bool):
                errs.append(f"{where}: {key} must be true or false")
        if "retry" in layer and (type(layer["retry"]) is not int or layer["retry"] not in (0, 1)):
            errs.append(f"{where}: retry must be 0 or 1")
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
        elif isinstance(mig, dict) and "version" in mig:
            try:
                if not isinstance(mig["version"], str) or re.compile(mig["version"]).groups < 1:
                    errs.append(f"{where}: migrations.version must be a regex with one group (the version)")
            except re.error:
                errs.append(f"{where}: migrations.version is not a valid regex")
    return errs


def load(path):
    if not path or not os.path.isfile(path):
        raise Unusable(f"config not found: {path or '(FACTORY_CONFIG unset)'}")
    with open(path, encoding="utf-8") as f:
        try:
            return yaml.safe_load(f)
        except yaml.YAMLError as e:
            raise Unusable(f"{path}: not valid YAML: {e}")


OVERRIDABLE_DEPLOY = ("timeout_min", "conflict_max_files")


def with_overrides(raw, over):
    """(the project's config with this machine's overrides on top, what the overrides hold that they may not).
    A project's factory.yml comes from its repository on every cycle. overrides.yml beside it is the machine
    owner's, written by the dashboard's Settings, and changes only how the factory operates on the project:
    limits.<stage>.wip, deploy.timeout_min, deploy.conflict_max_files and the language it writes in."""
    if not isinstance(raw, dict) or not over:
        return raw, []
    if not isinstance(over, dict):
        return raw, ["overrides.yml is not a YAML mapping"]
    new, errs = json.loads(json.dumps(raw)), []
    for top, val in over.items():
        if top == "language" and isinstance(val, str):  # problems() on the merged config refuses a code outside LANGS
            new["language"] = val
            continue
        for k, v in (val.items() if top in ("limits", "deploy") and isinstance(val, dict) else [(None, None)]):
            if top == "limits" and isinstance(v, dict) and set(v) == {"wip"}:
                limits = new["limits"] = new["limits"] if isinstance(new.get("limits"), dict) else {}
                limits[k] = dict(limits[k] if isinstance(limits.get(k), dict) else {}, wip=v["wip"])
            elif top == "deploy" and k in OVERRIDABLE_DEPLOY:
                new["deploy"] = dict(new["deploy"] if isinstance(new.get("deploy"), dict) else {}, **{k: v})
            else:
                errs.append(f"overrides.yml: {top}{'.' + str(k) if k else ''} cannot be overridden "
                            f"(only limits.<stage>.wip, {', '.join('deploy.' + d for d in OVERRIDABLE_DEPLOY)}, language)")
    return new, errs


def overrides_of(path):
    """What overrides.yml beside the project's config holds, {} when there is none."""
    f = os.path.join(os.path.dirname(path), "overrides.yml")
    if not os.path.isfile(f):
        return {}
    with open(f, encoding="utf-8") as fh:
        try:
            return yaml.safe_load(fh) or {}
        except yaml.YAMLError:
            return "not YAML"  # with_overrides reports it


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
                full["migrations"] = merged(full["migrations"], {"comment": "--", "version": DEFAULT_VERSION})
            full["_path_re"] = any_of([full["path"]])
            full["_tests_re"] = any_of(full["tests"])
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
             f"review criteria: {d['review_criteria'] or '~/.shipfloor/factory/templates/review-criteria.md'}",
             f"language: {LANGS[d['language']]} ({d['language']})",
             f"stack: {('yes, ' + str(d['stack'].get('url', ''))) if d.get('stack') else 'none'}"]
    machine_cfg = os.path.join(os.path.dirname(os.path.dirname(os.path.normpath(home))), "config.yml") if home else ""
    try:
        with open(machine_cfg, encoding="utf-8") as f:
            agents = models_of(yaml.safe_load(f), [l["agent"] for l in cfg.layers if "agent" in l])["agents"]
    except (OSError, yaml.YAMLError):
        agents = {}
    if agents:
        lines.insert(10, "agent models: " + ", ".join(f"{k}={v}" for k, v in agents.items()))
    dep = d.get("deploy") or {}
    lines.append("deploy: " + (", ".join(f"{k}={v}" for k, v in dep.items()) if dep else "none (Done after merge)"))
    lines.append("layers:")
    for l in cfg.layers:
        who = "tests only (QA)" if l["tests_only"] else f"agent={l['agent']}"
        lines.append(f"  - {l['name']}: path={l['path']} {who}" + (f" stack={l['stack']}" if l["stack"] else ""))
        if l["build"]:
            lines.append(f"      build: {l['build']}")
        lines.append(f"      test: {l['test']}" + ("  (own stack slot)" if l["needs_stack"] else "")
                     + ("  (retries once)" if l["retry"] else ""))
        lines.append(f"      tests: {', '.join(l['tests'])}")
        if l["migrations"]:
            lines.append(f"      migrations: {l['migrations']['glob']}")
    return "\n".join(lines)


def migration_renumber(pattern, lines):
    """lines as in migration_check. The renames (old path, new path) that put the card's migrations (N)
    above the newest existing one (E) when their version is taken or older. Plain integer versions only:
    any other scheme is left to the migration gate."""
    version_re = re.compile(pattern)
    top, mine = -1, {}
    for line in lines:
        kind, _, path = line.partition("\t")
        m = version_re.search(path.rsplit("/", 1)[-1])
        if not m or not m.group(1).isdigit():
            continue
        if kind == "E":
            top = max(top, int(m.group(1)))
        else:
            mine.setdefault(m.group(1), []).append((path, m))
    out = []
    for old in sorted(mine, key=int):  # a migration's files (up, down, undo) share a version and move together
        if int(old) > top:
            top = int(old)
            continue
        top += 1
        for path, m in mine[old]:
            head, _, name = path.rpartition("/")
            new = name[:m.start(1)] + str(top).zfill(len(old)) + name[m.end(1):]
            out.append((path, f"{head}/{new}" if head else new))
    return out


def migration_check(pattern, lines):
    """lines: 'E<TAB>path' (on the base or main) or 'N<TAB>path' (the card's own).
    Blocks (1) only on problems that involve the card's migrations; problems already on main are
    reported as warnings so one bad file there does not stall every card."""
    version_re = re.compile(pattern)
    found, errs, warns = [], [], []
    for line in lines:
        kind, _, path = line.partition("\t")
        if not path:
            continue
        name = path.rsplit("/", 1)[-1]
        m = version_re.search(name)
        if not m:
            (errs if kind == "N" else warns).append(f"{path}: no version in the name (pattern {pattern})"); continue
        try:
            version = tuple(int(x) for x in re.split(r"[._]", m.group(1)) if x != "")
        except (TypeError, ValueError):
            (errs if kind == "N" else warns).append(f"{path}: '{m.group(1)}' is not a numeric version"); continue
        # one migration may have several files: up/down pairs (000027_a.up.sql, .down.sql), undo (U27__a)
        ident = re.sub(r"\.(up|down|undo)$", "", name[m.end():].rsplit(".", 1)[0] if "." in name[m.end():] else name[m.end():])
        found.append((kind, version, ident, path))
    by_version = {}
    for kind, version, ident, path in found:
        by_version.setdefault(version, []).append((kind, ident, path))
    for version, items in by_version.items():
        if len({ident for _, ident, _ in items}) > 1:
            paths = ", ".join(p for _, _, p in items)
            (errs if any(k == "N" for k, _, _ in items) else warns).append(f"version {'.'.join(map(str, version))} is used by {paths}")
    existing = [(v, p) for k, v, _, p in found if k == "E"]
    if existing:
        newest = max(existing)
        for kind, version, _, path in found:
            if kind == "N" and version <= newest[0]:
                errs.append(f"{path}: not newer than {newest[1]} (on the base or main); use a higher version")
    for w in warns:
        print(f"migration: warning (already on the base or main): {w}", file=sys.stderr)
    for e in errs:
        print(f"migration: {e}", file=sys.stderr)
    return 1 if errs else 0


DEFAULT_VERSION = r"^[A-Za-z]*([0-9]+(?:[._][0-9]+)*)"  # V27__x.sql, 000027_x.up.sql
STAGES = ("refine", "develop", "validate", "deploy")
MACHINE_DEFAULTS = {"language": "en", "pool": 4, "stages": {"refine": 2, "develop": 2, "validate": 2, "deploy": 1},
                    "stacks": 3, "ports": {"base": 20000, "span": 20},
                    "stack_wait": 1800, "stack_stale": 90, "stack_hold_max": 2700, "dispatcher": {"every_min": 3},
                    "notify": {"events": {"waiting": True, "blocked": True, "reminder": True, "stuck": True, "done": False},
                               "channels": {"toast": True, "ntfy": False}, "ntfy_topic": "", "reminder_min": 60, "quiet": ""}}
DISPATCHER_EVERY = (1, 3, 5, 10)  # minutes between dispatcher cycles; the installer's trigger reads it


def dispatcher_every(raw):
    """The pace a raw machine config sets (minutes between cycles), or the default when it sets none or a bad one."""
    disp = raw.get("dispatcher") if isinstance(raw, dict) else None
    every = disp.get("every_min") if isinstance(disp, dict) else None
    return every if type(every) is int and every in DISPATCHER_EVERY else MACHINE_DEFAULTS["dispatcher"]["every_min"]


MACHINE_INTS = ("pool", "stacks", "stack_wait", "stack_stale", "stack_hold_max")
QUIET = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]-(?:[01][0-9]|2[0-3]):[0-5][0-9]")
NTFY_TOPIC = re.compile(r"[A-Za-z0-9_-]{1,64}")


def notify_problems(raw):
    """Sentences for the dashboard's Settings where the page shows one; the rest are for the file's owner."""
    if not isinstance(raw, dict):
        return ["notify must be a mapping"]
    defaults, errs = MACHINE_DEFAULTS["notify"], []
    for k, v in raw.items():
        if k not in defaults:
            errs.append(f"notify.{k}: unknown setting")
        elif k in ("events", "channels") and not isinstance(v, dict):
            errs.append(f"notify.{k} must be a mapping")
        elif k in ("events", "channels"):
            for name, on in v.items():
                if name not in defaults[k]:
                    errs.append(f"notify.{k}.{name}: unknown setting")
                elif not isinstance(on, bool):
                    errs.append(f"notify.{k}.{name} must be true or false")
    minutes, quiet, topic = raw.get("reminder_min", 60), raw.get("quiet", ""), raw.get("ntfy_topic", "")
    if not isinstance(minutes, int) or isinstance(minutes, bool) or not 15 <= minutes <= 720:
        errs.append("The reminder takes 15 to 720 minutes.")
    if not isinstance(quiet, str) or (quiet and not (QUIET.fullmatch(quiet) and quiet[:5] != quiet[6:])):
        errs.append("Quiet hours need both times, and they cannot be the same.")
    if not isinstance(topic, str) or (topic and not NTFY_TOPIC.fullmatch(topic)):
        errs.append("The topic takes letters, digits, - and _, up to 64.")
    elif not topic and (raw.get("channels") or {}).get("ntfy") is True:
        errs.append("The phone push needs a topic.")
    return errs


MODELS = ("opus", "sonnet", "haiku", "fable")  # what `claude --model` and the Agent tool's model take
STAGE_MODELS = {"refine": None, "develop": None, "validate": "sonnet", "deploy": "sonnet"}  # None = no --model flag
PLUGIN_AGENTS = {"product-owner": "opus", "ux-designer": "opus", "qa-engineer": "sonnet", "engineer": "sonnet", "cybersec": "opus"}


def model_problems(raw, project_agents=()):
    """The `models` entries of the machine config that the factory cannot use, as {key, value, why}
    (why: model, name or shape). Not part of machine_problems: a bad model must not make config.yml invalid."""
    models = raw.get("models") if isinstance(raw, dict) else None
    if models is None:
        return []
    if not isinstance(models, dict):
        return [{"key": "models", "value": models, "why": "shape"}]
    out = []
    known = {"stages": STAGES, "agents": (*PLUGIN_AGENTS, *project_agents)}
    for group, entries in models.items():  # in the file's order
        names = known.get(group)
        if names is None or entries is None:
            continue
        if not isinstance(entries, dict):
            out.append({"key": f"models.{group}", "value": entries, "why": "shape"}); continue
        for name, model in entries.items():
            if name not in names:
                out.append({"key": f"models.{group}.{name}", "value": model, "why": "name"})
            elif model not in MODELS:
                out.append({"key": f"models.{group}.{name}", "value": model, "why": "model"})
    return out


def models_of(raw, project_agents=()):
    """The models the factory runs with: STAGE_MODELS with the valid `models.stages` on top, and the valid
    `models.agents`. A problem entry is dropped, so its key keeps today's model."""
    bad = {p["key"] for p in model_problems(raw, project_agents)}
    out = {"stages": dict(STAGE_MODELS), "agents": {}}
    models = raw.get("models") if isinstance(raw, dict) and isinstance(raw.get("models"), dict) else {}
    for group in out:
        entries = models.get(group) if isinstance(models.get(group), dict) else {}
        out[group].update({n: m for n, m in entries.items() if f"models.{group}.{n}" not in bad})
    return out


def model_problem_line(p):
    if p["why"] == "name":
        return f"{p['key']}: not a stage or an agent here"
    if p["why"] == "shape":
        return f"{p['key']}: must be a mapping"
    return f"{p['key']}: \"{p['value']}\" is not a model the factory knows ({', '.join(MODELS)})"


COST_KEYS = ("card_warn", "card_block", "day_stop")


def cost_problems(costs):
    """The machine's costs: optional limits in US$, each a number > 0, card_warn <= card_block, no other key."""
    if costs is None:
        return []
    if not isinstance(costs, dict):
        return ["costs must be a mapping of limit: US$"]
    errs = [f"costs.{k}: unknown limit (use {', '.join(COST_KEYS)})" for k in costs if k not in COST_KEYS]
    for k in COST_KEYS:
        v = costs.get(k)
        if k in costs and (isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0):
            errs.append(f"costs.{k} must be a number above 0")
    if not errs and "card_warn" in costs and "card_block" in costs and costs["card_warn"] > costs["card_block"]:
        errs.append(f"costs.card_warn ({costs['card_warn']}) is above costs.card_block ({costs['card_block']})")
    return errs


def machine_problems(raw):
    if not isinstance(raw, dict):
        return ["the file is not a YAML mapping"]
    errs = []
    if raw.get("language", "en") not in LANGS:
        errs.append(f"language must be one of {', '.join(LANGS)}")
    errs += cost_problems(raw.get("costs"))
    errs += notify_problems(raw["notify"]) if "notify" in raw else []
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
    for key in MACHINE_INTS[1:]:
        v = raw.get(key, MACHINE_DEFAULTS[key])
        if not isinstance(v, int) or isinstance(v, bool) or v < 1:
            errs.append(f"{key} must be an integer >= 1")
    ports = raw.get("ports", {})
    if not isinstance(ports, dict):
        return errs + ["ports must be a mapping {base, span}"]
    base, span = ports.get("base", 20000), ports.get("span", 20)
    stacks = raw.get("stacks", MACHINE_DEFAULTS["stacks"])
    if not all(isinstance(v, int) and not isinstance(v, bool) and v >= 1 for v in (base, span)):
        errs.append("ports.base and ports.span must be integers >= 1")
    elif isinstance(stacks, int) and not 1024 <= base <= base + span * stacks <= 65535:
        errs.append("ports: base .. base + span * stacks must fit in 1024..65535")
    disp = raw.get("dispatcher", {})
    if not isinstance(disp, dict):
        errs.append("dispatcher must be a mapping {every_min}")
    else:
        every = disp.get("every_min", MACHINE_DEFAULTS["dispatcher"]["every_min"])
        if type(every) is not int or every not in DISPATCHER_EVERY:  # True == 1: the type is checked too
            errs.append("dispatcher.every_min must be 1, 3, 5 or 10")
    return errs


WINDOW = re.compile(r"([01][0-9]|2[0-3]):([0-5][0-9])-([01][0-9]|2[0-3]):([0-5][0-9])")


def now():
    """The clock for working hours: local HH:MM, or SHIPFLOOR_NOW when set."""
    return os.environ.get("SHIPFLOOR_NOW") or time.strftime("%H:%M")


def hours_problems(raw):
    """Why `hours` is unusable, as lines that start with 'hours'. Missing or [] is fine."""
    value = raw.get("hours") if isinstance(raw, dict) else None
    if value is None or value == []:
        return []
    if not isinstance(value, list):
        return ["hours must be a list of HH:MM-HH:MM windows"]
    errs = []
    for w in value:
        m = WINDOW.fullmatch(w) if isinstance(w, str) else None
        if not m:
            errs.append(f"hours: {w!r} is not a window HH:MM-HH:MM (24-hour, 00:00 to 23:59)")
        elif m.group(1, 2) == m.group(3, 4):
            errs.append(f"hours: {w!r} starts and ends at the same time")
    return errs


def minutes(hhmm):
    return int(hhmm[:2]) * 60 + int(hhmm[3:5])


def hours_state(raw, now):
    """{windows, open, next, error}: a window includes its start and excludes its end; an end before its
    start crosses midnight. Unset or malformed is open; closed, next is the nearest coming start."""
    value = raw.get("hours") if isinstance(raw, dict) else None
    errs = hours_problems(raw)
    if errs:
        return {"windows": json.dumps(value, ensure_ascii=False), "open": True, "next": None, "error": errs[0]}
    windows = value or []
    at, starts = minutes(now), []
    for w in windows:
        start, end = minutes(w[:5]), minutes(w[6:])
        if start <= at < end or (end < start and (at >= start or at < end)):
            return {"windows": windows, "open": True, "next": None, "error": None}
        starts.append(w[:5])
    return {"windows": windows, "open": not windows,
            "next": min(starts, key=lambda s: (minutes(s) - at) % 1440) if starts else None, "error": None}


def machine(rest):
    """machine <validate | values <key>... | show | hours | set <key> <int> | stage-models | models-check [<agent>...]> on $SHIPFLOOR_MACHINE_CONFIG."""
    path = os.environ.get("SHIPFLOOR_MACHINE_CONFIG", "")
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
    if cmd == "hours" and not args:
        state = hours_state(raw, now())
        print("open" if state["open"] else f"closed {state['next']}"); return 0
    if cmd == "validate" and not args:
        for e in errs:
            print(f"shipfloor-config: {path}: {e}", file=sys.stderr)
        for e in hours_problems(raw):
            print(f"shipfloor-config: {path}: {e}; ignored, runs start at all hours", file=sys.stderr)
        return 1 if errs else 0
    if cmd == "set" and len(args) == 2:
        if isinstance(raw, yaml.YAMLError):
            print(f"shipfloor-config: {path} is not valid YAML; fix it by hand", file=sys.stderr); return 1
        try:
            value = int(args[1])
        except ValueError:
            print(f"shipfloor-config: {args[1]} is not an integer", file=sys.stderr); return 1
        new = json.loads(json.dumps(raw))
        if args[0] in MACHINE_INTS:
            new[args[0]] = value
        elif args[0].startswith("stages.") and args[0].count(".") == 1:
            if not isinstance(new.get("stages", {}), dict):
                new["stages"] = {}
            new.setdefault("stages", {})[args[0].split(".")[1]] = value
        else:
            print(f"shipfloor-config: cannot set {args[0]} ({', '.join(MACHINE_INTS)} or stages.<stage>)", file=sys.stderr); return 1
        new_errs = machine_problems(new)
        if new_errs:
            for e in new_errs:
                print(f"shipfloor-config: {e}", file=sys.stderr)
            return 1
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("# shipfloor machine config: runs at once on this machine (pool) and per stage\n")
            yaml.safe_dump(new, f, sort_keys=False)
        return 0
    if errs:
        raise Unusable(f"{path} is invalid: " + "; ".join(errs))
    if cmd == "stage-models" and not args:
        sys.stdout.write("".join(f"{models_of(raw)['stages'][s] or ''}\0" for s in STAGES)); return 0
    if cmd == "models-check":
        found = model_problems(raw, args)
        for p in found:
            print(model_problem_line(p), file=sys.stderr)
        return 1 if found else 0
    data = merged(raw, MACHINE_DEFAULTS)
    if cmd == "values" and args:
        sys.stdout.write(nul_values(data, args)); return 0
    if cmd == "show" and not args:
        print(f"pool: {data['pool']}")
        for k in STAGES:
            print(f"  {k}: {data['stages'][k]}")
        print(f"stacks: {data['stacks']}")
        return 0
    raise Unusable("usage: machine validate | values <key>... | show | hours | set <key> <int> | stage-models | models-check [<agent>...]")


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
        raise Unusable("usage: shipfloor-config validate|get|layers|layer|regex|layer-of|language|describe ...")
    cmd, rest = args[0], args[1:]
    if cmd == "machine":
        return machine(rest)

    if not path or not os.path.isfile(path):
        raise Unusable(f"config not found: {path or '(FACTORY_CONFIG unset)'}")
    try:
        raw = load(path)
    except Unusable as e:
        if cmd == "validate":
            print(f"shipfloor-config: {e}", file=sys.stderr); return 1
        raise
    over = overrides_of(path)
    raw, over_errs = with_overrides(raw, over)
    # the language a run started with (dispatch.sh sets it at launch): a change made while it runs waits for the next one
    if isinstance(raw, dict) and os.environ.get("FACTORY_LANGUAGE", "") in LANGS:
        raw["language"] = os.environ["FACTORY_LANGUAGE"]
    errs = problems(raw) + over_errs
    if cmd == "validate":
        for e in errs:
            print(f"shipfloor-config: {path}: {e}", file=sys.stderr)
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
        sys.stdout.write(f"{cfg.data['acceptance_assertions']}\0" if cfg.data["acceptance_assertions"] else "")
        return 0
    if cmd == "migration-check" and len(rest) == 1:
        mig = cfg.layer(rest[0])["migrations"]
        if not mig:
            return 0
        return migration_check(mig["version"], sys.stdin.read().splitlines())
    if cmd == "migration-renumber" and len(rest) == 1:
        mig = cfg.layer(rest[0])["migrations"]
        for old, new in migration_renumber(mig["version"], sys.stdin.read().splitlines()) if mig else []:
            print(f"{old}\t{new}")
        return 0
    # main branch, then <layer>	<ERE>	<comment> per layer with migrations
    plan = "\n".join([cfg.data["project"]["main"]] + [f"{l['name']}	{l['_migrations_re']}	{l['migrations']['comment']}"
                                                      for l in cfg.layers if l["migrations"]])
    if cmd == "migration-layers" and not rest:
        print(plan); return 0
    if cmd == "gate-fast" and not rest:  # what `gate.sh fast` asks its three gates, NUL-terminated, in one start
        sys.stdout.write(f"{cfg.forbidden()}\0{plan}\0{cfg.data['acceptance_assertions']}\0"); return 0
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
    if cmd == "language" and not rest:  # <code>	<machine|repository>	<name>: the language the project writes in, who decided it
        code = cfg.data["language"]
        print(f"{code}\t{'machine' if isinstance(over, dict) and 'language' in over else 'repository'}\t{LANGS[code]}"); return 0
    if cmd == "describe" and not rest:
        print(describe(cfg, home, worktrees)); return 0
    raise Unusable(f"bad usage: {' '.join(args)}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Unusable as e:
        print(f"shipfloor-config: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:  # a crash is never a negative answer (exit 1): it is unusable
        print(f"shipfloor-config: internal error: {e!r}", file=sys.stderr)
        sys.exit(2)
