"""Reads and validates a project's .shipfloor/factory.yml and answers the factory scripts' queries.

Exit codes: 0 ok, 1 negative answer (invalid config on validate, missing key, no owner layer),
2 unusable (missing or invalid config, unknown layer or role, bad usage). Read-only.
"""
import json, math, os, re, sys, time, warnings

sys.dont_write_bytecode = True  # the installed factory carries no __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # `python -I` leaves the script's folder out of the path
import runtimes
from runtimes import claude_code

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
# what people read: the agents' specs, comments and reports, and what the scripts say (lang/<code>.sed, dashboard.<code>.json).
# Every code here has a dashboard catalog, which names the language in itself (#122); a code with no lang/<code>.sed or
# notify.<code>.json has the scripts speak English. The name here is the one the agents and the CLI read.
LANGS = {"en": "English", "zh-CN": "Simplified Chinese", "zh-TW": "Traditional Chinese", "es": "Spanish", "ja": "Japanese", "de": "German",
         "fr": "French", "pt-BR": "Brazilian Portuguese", "ru": "Russian", "ko": "Korean", "it": "Italian", "tr": "Turkish"}


class Msg(str):
    """A sentence a person reads, in English as every caller has it, that also carries the key and values the dashboard's
    catalogs translate it by (lang/dashboard.<code>.json): the page shows a refusal in its own language. A value can be
    a Msg too."""
    def __new__(cls, msg_key, text, /, **params):
        s = super().__new__(cls, text)
        s.key, s.params = msg_key, params
        return s

    def as_json(self):
        return {"key": self.key, "params": {k: v.as_json() if isinstance(v, Msg) else v for k, v in self.params.items()}}


def lang_problem():
    return Msg("err.language", f"language must be one of {', '.join(LANGS)}", codes=", ".join(LANGS))
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
BUILTIN_FORBIDDEN = (r"^(\.github/|\.githooks/|\.claude/|\.shipfloor/)|^(CLAUDE\.md|\.gitattributes|\.mcp\.json)$|(^|/)\.env"
                     r"|^(\.codex/|\.opencode/|\.agents/)|^(AGENTS\.md|AGENTS\.override\.md|opencode\.jsonc?)$")
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


def runtime_problems(raw, where="runtime"):
    """Why the `runtime` of a machine or project config is unusable: a runtime name, or a mapping with only `default`
    (a name) and `stages` ({refine|develop|validate|deploy: name}). The known runtimes are in every line."""
    if raw is None:
        return []
    known = ", ".join(runtimes.NAMES)
    errs = []

    def check(name, at):
        if not isinstance(name, str) or name not in runtimes.NAMES:
            errs.append(f"{at}: {name!r} is not a runtime the factory knows (known runtimes: {known})")

    if isinstance(raw, str):
        check(raw, where)
    elif not isinstance(raw, dict):
        errs.append(f"{where} must be a runtime name or a mapping of default and stages (known runtimes: {known})")
    else:
        for k, v in raw.items():
            if k == "default":
                check(v, f"{where}.default")
            elif k == "stages" and isinstance(v, dict):
                for stage, name in v.items():
                    if stage not in STAGES:
                        errs.append(f"{where}.stages.{stage}: unknown stage (use {', '.join(STAGES)}; known runtimes: {known})")
                    else:
                        check(name, f"{where}.stages.{stage}")
            elif k == "stages":
                errs.append(f"{where}.stages must be a mapping of stage: runtime (known runtimes: {known})")
            elif k == "models":
                errs += [f"{e} (known runtimes: {known})" for e in runtime_models_problems(v, f"{where}.models")]
            elif k == "ladder":
                if not is_str_list(v):
                    errs.append(f"{where}.ladder must be a list of model names, lowest first (known runtimes: {known})")
            elif k == "provider":
                errs += [f"{e} (known runtimes: {known})" for e in provider_problems(v, f"{where}.provider")]
            else:
                errs.append(f"{where}.{k}: unknown setting (use default, stages, models, ladder, provider; known runtimes: {known})")
    return errs


BASE_URL = re.compile(r"^https?://[^\s\"'\\]+$")  # it goes inside an inline TOML table in a -c: no quote, no space
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
MODEL_NAME = re.compile(r"^[A-Za-z0-9._:/@-]+$")


def provider_problems(raw, where):
    """`runtime.provider`: {base_url, api_key_env?, models?, ladder?}, the OpenAI-compatible endpoint a codex run talks to."""
    if not isinstance(raw, dict):
        return [f"{where} must be a mapping of base_url, api_key_env, models and ladder"]
    errs = []
    for k, v in raw.items():
        if k == "base_url":
            if not isinstance(v, str) or not BASE_URL.match(v):
                errs.append(f"{where}.base_url must be an http:// or https:// URL without spaces or quotes")
        elif k == "api_key_env":
            if not isinstance(v, str) or not ENV_NAME.match(v):
                errs.append(f"{where}.api_key_env must be the NAME of an environment variable ([A-Za-z_][A-Za-z0-9_]*)")
        elif k == "models":
            errs += runtime_models_problems(v, f"{where}.models", MODEL_NAME)
        elif k == "ladder":
            if not is_str_list(v) or not all(MODEL_NAME.match(m) for m in v):
                errs.append(f"{where}.ladder must be a list of model names ([A-Za-z0-9._:/@-]), lowest first")
        else:
            errs.append(f"{where}.{k}: unknown setting (use base_url, api_key_env, models, ladder)")
    return errs


def runtime_models_problems(raw, where, pattern=None):
    """`runtime.models`: {stages: {<stage>: model | {light|standard|heavy: model}}, agents: {<name>: model}}. A model is
    any non-empty name (the runtime's own CLI takes it); refine runs before the card has a weight, so it has one."""
    if not isinstance(raw, dict):
        return [f"{where} must be a mapping of stages and agents"]

    def model(v, at):
        if not (isinstance(v, str) and v.strip()):
            return [f"{at} must be a model name (not empty)"]
        if pattern and not pattern.match(v):
            return [f"{at} must be a model name ({pattern.pattern[1:-2]} only)"]
        return []

    errs = []
    for group, entries in raw.items():
        if group not in ("stages", "agents"):
            errs.append(f"{where}.{group}: unknown setting (use stages, agents)")
        elif not isinstance(entries, dict):
            errs.append(f"{where}.{group} must be a mapping")
        elif group == "agents":
            for name, v in entries.items():
                errs += model(v, f"{where}.agents.{name}")
        else:
            for stage, v in entries.items():
                at = f"{where}.stages.{stage}"
                if stage not in STAGES:
                    errs.append(f"{at}: unknown stage (use {', '.join(STAGES)})")
                elif isinstance(v, dict) and stage != "refine":
                    for weight, m in v.items():
                        if weight not in WEIGHTS:
                            errs.append(f"{at}.{weight}: not a weight ({', '.join(WEIGHTS)})")
                        else:
                            errs += model(m, f"{at}.{weight}")
                else:
                    errs += model(v, at)
    return errs


def runtime_setting(machine_raw, project_raw, key):
    """What `runtime.<key>` (models, ladder) says: the project's over the machine's. models merge group by group and
    name by name; a ladder is replaced as a whole. `provider` merges key by key (its models as `models` do). With an
    effective provider (one with a base_url) its models and ladder are the ones that count and runtime's are ignored."""
    if key in ("models", "ladder"):
        provider = runtime_setting(machine_raw, project_raw, "provider")
        if provider and provider.get("base_url"):
            return provider.get(key)
    out = None
    for raw in (machine_raw, project_raw):
        value = raw.get("runtime").get(key) if isinstance(raw, dict) and isinstance(raw.get("runtime"), dict) else None
        if value is None:
            continue
        if key == "provider" and isinstance(value, dict):
            out = dict(out or {})
            for k, v in value.items():
                out[k] = (_merge_models(out.get(k), v) if k == "models" and isinstance(out.get(k), dict) and isinstance(v, dict) else v)
        elif key == "models" and isinstance(out, dict):
            out = _merge_models(out, value)
        else:
            out = value
    return out


def _merge_models(base, over):
    return {g: {**(base.get(g) or {}), **(over.get(g) or {})} for g in {*base, *over}}


def runtime_stage_models(machine_raw, project_raw=None):
    """Stage -> weight -> model of the stages that do not run on claude-code, from `runtime.models.stages`; '' = the
    runtime's own default (no model flag). Call it on valid values."""
    configured = (runtime_setting(machine_raw, project_raw, "models") or {}).get("stages") or {}
    out = {}
    for stage, rt in zip(STAGES, runtime_of(machine_raw, project_raw)):
        if rt == "claude-code":
            continue
        m = configured.get(stage)
        out[stage] = {w: (m.get(w, "") if isinstance(m, dict) else m or "") for w in WEIGHTS}
    return out


def runtime_of(machine_raw, project_raw=None):
    """The runtime of refine, develop, validate, deploy: the project's `runtime` over the machine's, key by key (a
    name is the default), a stage's own name over the default over the first runtime. Call it on valid values."""
    default, stages = None, {}
    for raw in (machine_raw, project_raw):
        value = raw.get("runtime") if isinstance(raw, dict) else None
        if isinstance(value, str):
            default = value
        elif isinstance(value, dict):
            default = value.get("default") or default
            stages.update(value.get("stages") or {})
    return [stages.get(s) or default or runtimes.NAMES[0] for s in STAGES]


def problems(cfg):
    """Every reason the config is unusable, as human-readable lines."""
    if not isinstance(cfg, dict):
        return ["the file is not a YAML mapping"]
    errs = runtime_problems(cfg["runtime"]) if "runtime" in cfg else []
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
        errs.append(lang_problem())
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
        errs.append(Msg("err.reminder", "The reminder takes 15 to 720 minutes."))
    if not isinstance(quiet, str) or (quiet and not (QUIET.fullmatch(quiet) and quiet[:5] != quiet[6:])):
        errs.append(Msg("err.quiet", "Quiet hours need both times, and they cannot be the same."))
    if not isinstance(topic, str) or (topic and not NTFY_TOPIC.fullmatch(topic)):
        errs.append(Msg("err.topic", "The topic takes letters, digits, - and _, up to 64."))
    elif not topic and isinstance(raw.get("channels"), dict) and raw["channels"].get("ntfy") is True:
        errs.append(Msg("err.ntfy_topic", "The phone push needs a topic."))
    return errs


MODELS = claude_code.MODELS  # what `claude --model` and the Agent tool's model take
MODEL_LADDER = claude_code.LADDER  # a run that fails a gate steps one up; fable is not on it: the factory cannot rank it
WEIGHTS = ("light", "standard", "heavy")  # the card's weight, written by Refine in the spec header; none = standard
# A stage's model per weight. Refine runs before the card has a weight, so it has one model.
STAGE_MODELS = {"refine": "sonnet", "develop": {"light": "sonnet", "standard": "sonnet", "heavy": "opus"},
                "validate": dict.fromkeys(WEIGHTS, "sonnet"), "deploy": dict.fromkeys(WEIGHTS, "sonnet")}
PLUGIN_AGENTS = {"product-owner": "opus", "ux-designer": "opus", "qa-engineer": "sonnet", "engineer": "sonnet", "cybersec": "opus"}


def model_up(model, ladder=MODEL_LADDER):
    """The next model up the ladder (claude-code's by default); None for the top one or a model outside it."""
    i = ladder.index(model) if model in ladder else len(ladder)
    return ladder[i + 1] if i + 1 < len(ladder) else None


def model_problems(raw, project_agents=()):
    """The `models` entries of the machine config that the factory cannot use, as {key, value, why}
    (why: model, name or shape). Not part of machine_problems: a bad model must not make config.yml invalid.
    A stage but refine takes a model (every weight) or a mapping weight -> model."""
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
            key = f"models.{group}.{name}"
            if name not in names:
                out.append({"key": key, "value": model, "why": "name"})
            elif group == "stages" and isinstance(model, dict):
                if name == "refine":
                    out.append({"key": key, "value": model, "why": "shape"}); continue
                for weight, m in model.items():
                    if weight not in WEIGHTS:
                        out.append({"key": f"{key}.{weight}", "value": m, "why": "name"})
                    elif m not in MODELS:
                        out.append({"key": f"{key}.{weight}", "value": m, "why": "model"})
            elif model not in MODELS:
                out.append({"key": key, "value": model, "why": "model"})
    return out


def models_of(raw, project_agents=()):
    """The models the factory runs with: STAGE_MODELS with the valid `models.stages` on top (a stage's single model
    fills its every weight), and the valid `models.agents`. A problem entry is dropped, so its key keeps today's model."""
    bad = {p["key"] for p in model_problems(raw, project_agents)}
    out = {"stages": json.loads(json.dumps(STAGE_MODELS)), "agents": {}}
    models = raw.get("models") if isinstance(raw, dict) and isinstance(raw.get("models"), dict) else {}
    stages = models.get("stages") if isinstance(models.get("stages"), dict) else {}
    for name, model in stages.items():
        key = f"models.stages.{name}"
        if key in bad or name not in STAGES:
            continue
        if isinstance(model, dict):
            out["stages"][name].update({w: m for w, m in model.items() if f"{key}.{w}" not in bad})
        else:
            out["stages"][name] = model if name == "refine" else dict.fromkeys(WEIGHTS, model)
    agents = models.get("agents") if isinstance(models.get("agents"), dict) else {}
    out["agents"].update({n: m for n, m in agents.items() if f"models.agents.{n}" not in bad})
    return out


def stage_model(stages, stage, weight):
    """The model a run of <stage> on a card of <weight> starts with, from models_of()['stages']."""
    m = stages[stage]
    return m.get(weight if weight in WEIGHTS else "standard") if isinstance(m, dict) else m


def model_problem_line(p):
    if p["why"] == "name":
        if p["key"].startswith("models.stages.") and p["key"].count(".") == 3:
            return Msg("err.model.weight", f"{p['key']}: not a weight ({', '.join(WEIGHTS)})", key=p["key"], weights=", ".join(WEIGHTS))
        return Msg("err.model.name", f"{p['key']}: not a stage or an agent here", key=p["key"])
    if p["why"] == "shape":
        if p["key"] == "models.stages.refine":
            return Msg("err.model.refine", f"{p['key']}: must be one model (Refine runs before the card has a weight)", key=p["key"])
        return Msg("err.model.shape", f"{p['key']}: must be a mapping", key=p["key"])
    return Msg("err.model.unknown", f"{p['key']}: \"{p['value']}\" is not a model the factory knows ({', '.join(MODELS)})", key=p["key"], value=p["value"], models=", ".join(MODELS))


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


LIMIT_KEYS = ("memory_max", "cpu_weight", "cpu_quota")
MEMORY_RE = re.compile(r"([1-9][0-9]*)([KMGT])")
QUOTA_RE = re.compile(r"([1-9][0-9]*)%")
MEMORY_K = {"K": 1, "M": 1024, "G": 1024 ** 2, "T": 1024 ** 3}


def is_none(v):
    return v is None or (isinstance(v, str) and v.strip().lower() == "none")


def limits_problems(raw):
    """The machine's `limits` (memory_max, cpu_weight, cpu_quota), each a value or none; every line starts with
    the field it is about: limits.<field>. Missing or None is no limit."""
    if raw is None:
        return []
    if not isinstance(raw, dict):
        return ["limits must be a mapping of memory_max, cpu_weight, cpu_quota"]
    errs = [f"limits.{k}: unknown limit (use {', '.join(LIMIT_KEYS)})" for k in raw if k not in LIMIT_KEYS]
    v = raw.get("memory_max")
    if not is_none(v) and not (isinstance(v, str) and MEMORY_RE.fullmatch(v.strip())):
        errs.append("limits.memory_max must be a whole number with K, M, G or T (like 8G), or none")
    v = raw.get("cpu_weight")
    if not is_none(v):
        w = v.strip() if isinstance(v, str) else v
        w = int(w) if isinstance(w, str) and w.isascii() and w.isdigit() else w
        if type(w) is not int or not 1 <= w <= 10000:
            errs.append("limits.cpu_weight must be a whole number from 1 to 10000, or none")
    v = raw.get("cpu_quota")
    if not is_none(v):
        cpus = os.cpu_count() or 1
        m = QUOTA_RE.fullmatch(v.strip()) if isinstance(v, str) else None
        if not m:
            errs.append("limits.cpu_quota must be a percentage like 200%, or none")
        elif int(m.group(1)) > cpus * 100:
            errs.append(f"limits.cpu_quota must be from 1% to {cpus * 100}% ({cpus} CPUs), or none")
    return errs


def machine_limits(raw):
    """{memory_max, cpu_weight, cpu_quota} as strings, "none" where there is no limit. Call it on a valid `limits`."""
    raw = raw if isinstance(raw, dict) else {}
    return {k: "none" if is_none(raw.get(k)) else str(raw[k]).strip() for k in LIMIT_KEYS}


def limits_directives(limits):
    """The systemd [Service] lines for the limits: MemoryMax=, MemoryHigh= (90% of it), CPUWeight=, CPUQuota=."""
    lim = machine_limits(limits)
    out = []
    if lim["memory_max"] != "none":
        m = MEMORY_RE.fullmatch(lim["memory_max"])
        out += [f"MemoryMax={lim['memory_max']}", f"MemoryHigh={int(m.group(1)) * MEMORY_K[m.group(2)] * 9 // 10}K"]
    if lim["cpu_weight"] != "none":
        out.append(f"CPUWeight={lim['cpu_weight']}")
    if lim["cpu_quota"] != "none":
        out.append(f"CPUQuota={lim['cpu_quota']}")
    return out


def machine_problems(raw):
    if not isinstance(raw, dict):
        return ["the file is not a YAML mapping"]
    errs = []
    if raw.get("language", "en") not in LANGS:
        errs.append(lang_problem())
    errs += runtime_problems(raw["runtime"]) if "runtime" in raw else []
    errs += cost_problems(raw.get("costs"))
    errs += limits_problems(raw.get("limits"))
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
            errs.append(Msg("err.every_min", "dispatcher.every_min must be 1, 3, 5 or 10"))
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
    """machine <validate | values <key>... | show | hours | set <key> <int> | stage-models | model-up <model> | models-check [<agent>...]> on $SHIPFLOOR_MACHINE_CONFIG."""
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
    if cmd == "limits":  # the systemd directive lines; --memory-max, --cpu-weight, --cpu-quota override the file
        over, rest_args = {}, list(args)
        while rest_args:
            flag = rest_args.pop(0)
            if flag not in ("--memory-max", "--cpu-weight", "--cpu-quota") or not rest_args:
                raise Unusable("usage: machine limits [--memory-max V] [--cpu-weight V] [--cpu-quota V]")
            over[flag[2:].replace("-", "_")] = rest_args.pop(0)
        file_limits = raw.get("limits") if isinstance(raw.get("limits"), dict) else {}
        limits = {**file_limits, **over}
        bad = limits_problems(limits)
        if bad:
            raise Unusable("; ".join(bad))
        for line in limits_directives(limits):
            print(line)
        return 0
    def project_of(args):  # the project's factory.yml, when it is given and its runtime is valid
        project = load(args[0]) if args and args[0] else None
        bad = runtime_problems(project["runtime"]) if isinstance(project, dict) and "runtime" in project else []
        if bad:
            raise Unusable(f"{args[0]} is invalid: " + "; ".join(bad))
        return project
    if cmd == "stage-models" and len(args) <= 1:  # each stage x light, standard, heavy; the project's factory.yml over this file
        project = project_of(args)
        stages = models_of(raw)["stages"]
        other = runtime_stage_models(raw, project)  # a stage off claude-code: runtime.models, never models.stages
        sys.stdout.write("".join(
            f"{(other[s][w] if s in other else stage_model(stages, s, w)) or ''}\0" for s in STAGES for w in WEIGHTS)); return 0
    if cmd == "provider" and len(args) <= 1:  # base_url NUL api_key_env (the NAME, never a value) NUL; nothing without a provider
        provider = runtime_setting(raw, project_of(args), "provider")
        if isinstance(provider, dict) and provider.get("base_url"):
            sys.stdout.write(f"{provider['base_url']}\0{provider.get('api_key_env') or ''}\0")
        return 0
    if cmd == "runtimes" and len(args) <= 1:  # the runtime of each stage, NUL-terminated; the project's factory.yml over this file
        sys.stdout.write("".join(f"{r}\0" for r in runtime_of(raw, project_of(args)))); return 0
    if cmd == "models-stages-check" and len(args) <= 1:  # models.stages.<stage> that a stage on another runtime ignores
        project = project_of(args)
        stages = raw.get("models", {}).get("stages") if isinstance(raw.get("models"), dict) else None
        for stage, rt in zip(STAGES, runtime_of(raw, project)):
            if rt != "claude-code" and isinstance(stages, dict) and stage in stages:
                print(f"models.stages.{stage} is ignored: {stage} runs on {rt}, which takes runtime.models.stages.{stage}")
        return 0
    if cmd == "model-up" and 1 <= len(args) <= 3:  # model-up <model> [<runtime> [<project factory.yml>]]
        if len(args) == 1 or args[1] == "claude-code":
            up = model_up(args[0])
        else:  # another runtime climbs runtime.ladder; none = no step-up
            ladder = runtime_setting(raw, project_of(args[2:]), "ladder")
            up = model_up(args[0], tuple(ladder) if is_str_list(ladder) else ())
        if up:
            print(up)
        return 0
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
    raise Unusable("usage: machine validate | values <key>... | show | hours | set <key> <int> | stage-models | model-up <model> | provider | models-check [<agent>...] | limits [--memory-max V] [--cpu-weight V] [--cpu-quota V]")


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


def run(argv):
    """main with the command line's error handling: the exit code (2 for an unusable config or a crash, with its message)."""
    try:
        return main(argv)
    except Unusable as e:
        print(f"shipfloor-config: {e}", file=sys.stderr)
        return 2
    except Exception as e:  # a crash is never a negative answer (exit 1): it is unusable
        print(f"shipfloor-config: internal error: {e!r}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
