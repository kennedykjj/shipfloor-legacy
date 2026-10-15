"""The opencode runtime: how the factory starts `opencode run`, and how a run's end is classified. The factory has its
own config folder (OPENCODE_CONFIG_DIR, generated at `shipfloor install`): the owner's personal opencode config and the
project's own are never read. The run's permissions and its self-hosted provider travel in OPENCODE_CONFIG_CONTENT, an
environment value that never holds a key (the provider's apiKey is `{env:<NAME>}`, opencode reads the variable)."""
import json
import os
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # `python -I` leaves the script's folder out of the path

from runtimes import TOKEN_KINDS  # noqa: F401  (the contract: the readers of task 3 count in these kinds)
from shipfloor_core.defaults import OPENCODE_TRAILER

NAME = "opencode"
LABEL = "opencode"  # how a line for the owner names it
BINARY = os.environ.get("SHIPFLOOR_OPENCODE") or "opencode"
MODELS = ()  # the name is free: whatever `opencode run -m` takes (provider/model)
LADDER = ()  # the owner's runtime.ladder, when there is one
TRAILER = OPENCODE_TRAILER
PROVIDER_ID = "sf"  # the provider id the factory gives runtime.provider in the generated config
LIMIT_TYPES = ("provider.quota", "provider.rate-limit")  # the types of an `error` event that mean the account cannot run


def data_dir():
    """The factory's OPENCODE_CONFIG_DIR."""
    return Path(os.environ.get("SHIPFLOOR_OPENCODE_HOME") or Path.home() / ".shipfloor" / "runtimes" / "opencode")


def permissions(write, read):
    """The run's permission rules, a list of {permission, pattern, action}; the last match wins. Everything is allowed
    except: a directory outside the folders it may write or read, writing the folders it may only read, the web."""
    rules = [{"permission": "*", "pattern": "*", "action": "allow"},
             {"permission": "external_directory", "pattern": "*", "action": "deny"}]
    for d in [*write, *read]:
        rules.append({"permission": "external_directory", "pattern": d.rstrip("/") + "/**", "action": "allow"})
    for d in read:
        rules.append({"permission": "edit", "pattern": d.rstrip("/") + "/**", "action": "deny"})
    for tool in ("webfetch", "websearch"):
        rules.append({"permission": tool, "pattern": "*", "action": "deny"})
    return rules


def config_content(run):
    """The JSON of OPENCODE_CONFIG_CONTENT for one run."""
    cfg = {"permissions": permissions(run["write"], run.get("read") or [])}
    provider = run.get("provider")
    if provider:
        key_env = provider.get("key_env") or ""
        settings = {"baseURL": provider["base_url"]}
        if key_env:
            settings["apiKey"] = "{env:%s}" % key_env
        models = {}
        model = run.get("model") or ""
        if model.startswith(PROVIDER_ID + "/") and len(model) > len(PROVIDER_ID) + 1:
            models[model[len(PROVIDER_ID) + 1:]] = {"capabilities": {"tools": True}}
        cfg["providers"] = {PROVIDER_ID: {"package": "@ai-sdk/openai-compatible", "settings": settings, "models": models}}
        cfg["experimental"] = {"policies": [{"use": [PROVIDER_ID]}]}  # only the factory's provider may serve the run
    return cfg


def command(run):
    """(argv without the binary, environment assignments, stdin) of one run. run: stage, issue, model, control (its
    folder), write (folders it may write), read (folders it may only read), envs (assignments the factory adds),
    provider ({base_url, key_env} of runtime.provider, or None). The run starts in the control checkout (the
    dispatcher's cwd)."""
    argv = ["run", "--standalone", "--auto", "--agent", "sf-" + run["stage"], "--format", "json"]
    if run.get("model"):
        argv += ["-m", run["model"]]
    envs = [*run["envs"],
            "OPENCODE_CONFIG_DIR=" + str(data_dir()),
            "OPENCODE_DISABLE_PROJECT_CONFIG=1",
            "OPENCODE_DISABLE_MODELS_FETCH=1",
            "OPENCODE_DISABLE_AUTOUPDATE=1",
            "OPENCODE_CONFIG_CONTENT=" + json.dumps(config_content(run), separators=(",", ":"))]
    return argv, envs, "Card: #%s\n" % run["issue"]


def outcome(rc, block):
    """usage_limit when the run's JSON lines carry an `error` event of a limit type (whatever the exit code), else ok on
    exit 0, else fail. Only a top-level `error` event is the CLI speaking: what the agent says or reads is not."""
    text = block.decode("utf-8", "replace") if isinstance(block, (bytes, bytearray)) else block
    for line in text.split("\n"):
        if not line.lstrip().startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        err = ev.get("error") if isinstance(ev, dict) and ev.get("type") == "error" else None
        if isinstance(err, dict) and err.get("type") in LIMIT_TYPES:
            return "usage_limit"
    return "ok" if rc == 0 else "fail"


def doctor():
    """[(found, "opencode: opencode")]: the binary (more checks come with the readers)."""
    return [(shutil.which(BINARY) is not None, "%s: opencode" % NAME)]


# --- cost and sessions: read from opencode's own database --------------------------------------------------------------

COMMAND = None


def parse_ts(s):
    from runtimes import codex
    return codex.parse_ts(s)


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def doing(payload):
    return None


def session_files(data, slug):
    return []


def stamp(session):
    st = Path(session).stat()
    return [st.st_size, st.st_mtime_ns]


def parse(session):
    return {"stage": None, "issue": None, "start": None, "end": None, "tokens": {}, "activity": []}


def events(session):
    return []
