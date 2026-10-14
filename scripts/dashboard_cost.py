"""Cost of the factory's runs, read from the Claude Code transcripts (one .jsonl per session)."""
import json, os, sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # `python -I` leaves the script's folder out of the path
sys.dont_write_bytecode = True  # importing inbox_hook / shipfloor_config must not leave a __pycache__ in the installed factory

import yaml
import runtimes
from runtimes import TOKEN_KINDS, claude_code

# The transcript readers are the runtimes' (scripts/runtimes/); these names are what the dashboard has always imported.
LEGACY_STAGES = claude_code.LEGACY_STAGES  # legacy mylos stage names, still read from old transcripts (legacy aghanim too)
parse_ts = claude_code.parse_ts
parse_transcript = claude_code.parse
events = claude_code.events


def cost(tokens, prices):
    """US$ for {model: {kind: n}}, or None when a model has no price."""
    total = 0.0
    for model, t in tokens.items():
        p = prices.get(model)
        if not p:
            return None
        total += sum(t[k] * p.get(k, 0) for k in TOKEN_KINDS) / 1e6
    return total


def rounded(usd):
    return None if usd is None else round(usd, 2)


def session_cost(s, prices):
    """US$ of a session and its subagents, or None when any model has no price."""
    parts = [cost(s["tokens"], prices)] + [cost(a["tokens"], prices) for a in s["subagents"]]
    return None if None in parts else sum(parts)


def spend(sessions, prices, today):
    """sessions: dicts with issue, stage, start, tokens, subagents. The estimate per card (total None when any of its
    sessions is unpriced, stages: what the priced ones cost) and today's (an unpriced session adds nothing); today is an ISO date."""
    cards, day = {}, 0.0
    for s in sessions:
        c = session_cost(s, prices)
        card = cards.setdefault(s["issue"], {"total": 0.0, "stages": {}})
        if c is None:
            card["total"] = None
            continue
        if card["total"] is not None:
            card["total"] += c
        card["stages"][s["stage"]] = card["stages"].get(s["stage"], 0.0) + c
        if parse_ts(s["start"]).astimezone().date().isoformat() == today:
            day += c
    return {"cards": cards, "today": day}


def over(spent, costs, baselines):
    """Which limits the estimate has reached (at >=). A card's figure is its total minus its baseline (its estimate
    at its last cost block); an unknown total is never in warn or block."""
    costs = costs or {}
    def at(key):
        lim = costs.get(key)
        return sorted(n for n, c in spent["cards"].items() if lim and c["total"] is not None
                      and c["total"] - baselines.get(n, 0.0) >= lim)
    day = costs.get("day_stop")
    return {"day_stop": bool(day) and spent["today"] >= day, "warn": at("card_warn"), "block": at("card_block")}


def load_prices(home):
    for f in (Path(home) / "prices.yml", HERE / "templates" / "prices.yml", HERE.parent / "templates" / "prices.yml"):
        if f.is_file():
            try:
                return yaml.safe_load(f.read_text(encoding="utf-8")) or {}
            except (OSError, yaml.YAMLError):
                return {}
    return {}


def baselines(project_home):
    """{issue: the card's estimate at its last cost block} from <project home>/cost/<n>.json."""
    out = {}
    for f in (Path(project_home) / "cost").glob("*.json"):
        try:
            out[int(f.stem)] = float(json.loads(f.read_text(encoding="utf-8"))["total"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return out


class Transcripts:
    """Parsed transcripts kept in <home>/cost-cache.json ({"version": 2, "entries": {"<runtime>:<path>": [stamp..., parsed]}}),
    keyed by runtime and path, with the runtime's stamp (size, mtime): a cycle parses what changed. A file of any
    other version (the one before the runtime contract has none) is not believed: everything is parsed again."""
    VERSION = 2

    def __init__(self, home, runtime=None):
        self.file, self.dirty = Path(home) / "cost-cache.json", False
        self.runtime = runtime or runtimes.NAMES[0]
        try:
            raw = json.loads(self.file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raw = None
        ok = isinstance(raw, dict) and raw.get("version") == self.VERSION and isinstance(raw.get("entries"), dict)
        self.cache = raw["entries"] if ok else {}
        self.dirty = raw is not None and not ok  # an old file is replaced
        self.seen = set()

    def get(self, path):
        key = f"{self.runtime}:{path}"
        stamp, hit = runtimes.get(self.runtime).stamp(path), self.cache.get(key)
        self.seen.add(key)
        if not (isinstance(hit, list) and len(hit) == len(stamp) + 1 and hit[:-1] == stamp):
            p = runtimes.get(self.runtime).parse(path)
            hit = self.cache[key] = stamp + [{k: p[k] for k in ("stage", "issue", "start", "tokens")}]
            self.dirty = True
        return hit[-1]

    def save(self):
        gone = [k for k in self.cache if k not in self.seen and not os.path.exists(k.split(":", 1)[-1])]
        for k in gone:
            del self.cache[k]
        if not (self.dirty or gone):
            return
        tmp = self.file.with_name(f"{self.file.name}.{os.getpid()}")
        try:
            tmp.write_text(json.dumps({"version": self.VERSION, "entries": self.cache}), encoding="utf-8")
            os.replace(tmp, self.file)
        except OSError:
            pass  # the next cycle parses again


def project_sessions(claude_dir, slug, read):
    """The sessions the dispatcher ran for a project (read: path -> parsed transcript), oldest first."""
    return runtimes.sessions(slug, read, {"claude-code": claude_dir})


def read_costs(home):
    """The machine's costs mapping ({} when none); exits 2 when the machine config refuses it."""
    import shipfloor_config
    try:
        raw = yaml.safe_load((Path(home) / "config.yml").read_text(encoding="utf-8")) or {}
    except OSError:
        return {}
    except yaml.YAMLError as e:
        sys.exit(f"dashboard_cost: config.yml is not valid YAML: {e}")
    errs = shipfloor_config.machine_problems(raw)
    if errs:
        sys.exit("dashboard_cost: config.yml is invalid: " + "; ".join(errs))
    return raw.get("costs") or {}


def usd(x):
    return f"${x:.2f}"


def estimate(home, slug, claude_dir, costs):
    """(the project's spend, today's estimate across every project, the project's baselines)."""
    cache, prices, today = Transcripts(home), load_prices(home), datetime.now().date().isoformat()
    try:
        slugs = [l.split("\t")[0] for l in (Path(home) / "registry.tsv").read_text(encoding="utf-8").splitlines() if l.strip()]
    except OSError:
        slugs = []
    mine, day = spend([], prices, today), 0.0
    for p in dict.fromkeys(slugs + [slug]):
        s = spend(project_sessions(claude_dir, p, cache.get), prices, today)
        day += s["today"]
        if p == slug:
            mine = s
    cache.save()
    return dict(mine, today=day), baselines(Path(home) / "projects" / slug)


def cli(argv):
    """limits --home H --project P [--claude-dir D]: `day_stop<TAB>today<TAB>limit` when the day is stopped, then
    `block<TAB>issue` per card at card_block. block --home H --project P --issue N --out F: the comment body and the marker.
    Exit 0 ok, 1 nothing to block, 2 usage or invalid config."""
    cmd, opts, args = (argv[0] if argv else ""), {}, list(argv[1:])
    while len(args) >= 2 and args[0].startswith("--"):
        flag = args.pop(0)[2:]
        opts[flag] = args.pop(0)
    if cmd not in ("limits", "block") or args or not {"home", "project"} <= set(opts):
        print("usage: dashboard_cost.py limits|block --home H --project P [--claude-dir D] [--issue N --out F]", file=sys.stderr)
        return 2
    home, slug = opts["home"], opts["project"]
    claude_dir = opts.get("claude-dir") or os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude"
    costs = read_costs(home)
    if cmd == "limits":
        if not costs:
            return 0
        spent, base = estimate(home, slug, claude_dir, costs)
        res = over(spent, costs, base)
        if res["day_stop"]:
            print(f"day_stop\t{spent['today']:.2f}\t{costs['day_stop']:.2f}")
        for n in res["block"]:
            print(f"block\t{n}")
        return 0
    if not {"issue", "out"} <= set(opts) or not opts["issue"].isdigit() or not costs.get("card_block"):
        print("block needs --issue <n>, --out <file> and costs.card_block", file=sys.stderr)
        return 2
    n, limit = int(opts["issue"]), costs["card_block"]
    spent, base = estimate(home, slug, claude_dir, costs)
    card, before = spent["cards"].get(n), base.get(n, 0.0)
    if not card or card["total"] is None:
        print(f"issue {n} has no known estimate", file=sys.stderr)
        return 1
    marker = Path(home) / "projects" / slug / "cost" / f"{n}.json"
    try:  # the span is the stages now minus the stages at the last block
        prev = json.loads(marker.read_text(encoding="utf-8")).get("all_stages") or {}
    except (OSError, ValueError, AttributeError):
        prev = {}
    stages = {k: v - prev.get(k, 0.0) for k, v in card["stages"].items() if v - prev.get(k, 0.0) > 1e-9}
    since = "since it was last unblocked" if before else "since Inbox"
    lines = ["Cost limit: blocked.", "",
             f"Estimated total for this card: {usd(card['total'])} (an estimate from tokens and prices, not the bill).",
             f"Estimated spend {since}: {usd(card['total'] - before)}; the limit for a card is {usd(limit)}.", "",
             "Estimate per stage:"] + [f"- {k}: {usd(v)}" for k, v in stages.items()]
    marker.parent.mkdir(parents=True, exist_ok=True)
    tmp = marker.with_name(f"{marker.name}.{os.getpid()}")
    tmp.write_text(json.dumps({"at": datetime.now().astimezone().isoformat(timespec="seconds"), "limit": limit,
                               "total": card["total"], "baseline": before, "stages": stages,
                               "all_stages": card["stages"]}), encoding="utf-8")
    os.replace(tmp, marker)
    with open(opts["out"], "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return 0


def per_card(runs):
    """The mean cost of a card from [(card, US$ or None)], one entry per session: a card's cost is the sum of its
    sessions, and a card with an unpriced session is left out. Never a zero for nothing: avg is None with 0 cards."""
    sums = {}
    for card, usd in runs:
        sums[card] = None if usd is None or sums.get(card, 0) is None else sums.get(card, 0) + usd
    priced = [v for v in sums.values() if v is not None]
    return {"avg": rounded(sum(priced) / len(priced)) if priced else None, "cards": len(priced)}


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
