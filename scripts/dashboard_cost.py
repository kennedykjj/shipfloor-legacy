"""Cost of the factory's runs, read from the Claude Code transcripts (one .jsonl per session)."""
import json, os, re, sys
from collections import deque
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # `python -I` leaves the script's folder out of the path

import yaml
from inbox_hook import INTRO

LEGACY_STAGES = {"refinar": "refine", "desenvolver": "develop", "validar": "validate", "deployar": "deploy"}  # legacy mylos
COMMAND = re.compile(r"<command-name>/(?:sf|aghanim|mylos):([a-z]+)</command-name>\s*<command-args>(\d+)</command-args>")  # legacy aghanim, legacy mylos
TOKEN_KINDS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def doing(block):
    """One line for what an assistant block does: its own words, or the tool it calls and on what."""
    if block.get("type") == "text":
        line = next((x.strip() for x in block.get("text", "").splitlines() if x.strip()), "")
        return {"kind": "says", "text": line[:200]} if line else None
    if block.get("type") == "tool_use":
        i = block.get("input") or {}
        what = i.get("description") or i.get("file_path") or i.get("pattern") or i.get("command") or i.get("prompt") or ""
        return {"kind": block.get("name") or "tool", "text": " ".join(str(what).split())[:160]}
    return None


def parse_transcript(path):
    """The card a session ran for (its first user message is the dispatcher's /sf:<stage> <n>),
    its tokens per model and the last few things it did."""
    stage = issue = start = end = None
    first_user, usage, activity = True, {}, deque(maxlen=4)
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue  # a run still writing its last line
            start, end = start or o.get("timestamp"), o.get("timestamp") or end
            msg = o.get("message") or {}
            if o.get("type") == "user" and first_user:
                first_user = False
                m = COMMAND.search(text_of(msg.get("content")))
                if m:
                    stage, issue = LEGACY_STAGES.get(m.group(1), m.group(1)), int(m.group(2))
            elif o.get("type") == "assistant" and msg.get("usage"):
                # Claude Code logs one API message once per content block, repeating its usage
                usage[msg.get("id") or len(usage)] = (msg.get("model"), msg["usage"])
            if o.get("type") == "assistant" and isinstance(msg.get("content"), list):
                for block in msg["content"]:
                    did = isinstance(block, dict) and doing(block)
                    if did:
                        activity.append(dict(did, ts=o.get("timestamp")))
    tokens = {}
    for model, u in usage.values():
        cw = u.get("cache_creation") or {}
        kinds = {"input": u.get("input_tokens"), "output": u.get("output_tokens"),
                 "cache_read": u.get("cache_read_input_tokens"),
                 "cache_write_5m": cw.get("ephemeral_5m_input_tokens") if cw else u.get("cache_creation_input_tokens"),
                 "cache_write_1h": cw.get("ephemeral_1h_input_tokens")}
        if not any(kinds.values()):
            continue
        t = tokens.setdefault(model, dict.fromkeys(TOKEN_KINDS, 0))
        for k, v in kinds.items():
            t[k] += v or 0
    return {"stage": stage, "issue": issue, "start": start, "end": end, "tokens": tokens, "activity": list(activity)}


def events(path):
    """What a session said and did, in order, and the owner's messages it was handed (inbox_hook.py)."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            ts, content, att = o.get("timestamp"), (o.get("message") or {}).get("content"), o.get("attachment") or {}
            if o.get("type") == "assistant" and isinstance(content, list):
                for block in content:
                    did = isinstance(block, dict) and doing(block)
                    if did and did["kind"] == "says":
                        did["text"] = block["text"].strip()[:4000]
                    if did:
                        out.append(dict(did, ts=ts))
            elif att.get("type") == "hook_additional_context":
                out += [{"kind": "owner", "text": c[len(INTRO):].strip(), "ts": ts}
                        for c in att.get("content") or [] if isinstance(c, str) and c.startswith(INTRO)]
    return out


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
    """Parsed transcripts kept in <home>/cost-cache.json, keyed by path, size and mtime: a cycle parses what changed."""
    def __init__(self, home):
        self.file, self.dirty = Path(home) / "cost-cache.json", False
        try:
            self.cache = json.loads(self.file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.cache = {}
        if not isinstance(self.cache, dict):
            self.cache = {}
        self.seen = set()

    def get(self, path):
        st = path.stat()
        key, hit = f"{path}", self.cache.get(f"{path}")
        self.seen.add(key)
        if not (isinstance(hit, list) and hit[:2] == [st.st_size, st.st_mtime_ns]):
            p = parse_transcript(path)
            hit = self.cache[key] = [st.st_size, st.st_mtime_ns, {k: p[k] for k in ("stage", "issue", "start", "tokens")}]
            self.dirty = True
        return hit[2]

    def save(self):
        gone = [k for k in self.cache if k not in self.seen and not os.path.exists(k)]
        for k in gone:
            del self.cache[k]
        if not (self.dirty or gone):
            return
        tmp = self.file.with_name(f"{self.file.name}.{os.getpid()}")
        try:
            tmp.write_text(json.dumps(self.cache), encoding="utf-8")
            os.replace(tmp, self.file)
        except OSError:
            pass  # the next cycle parses again


def project_sessions(claude_dir, slug, read):
    """The sessions the dispatcher ran for a project (read: path -> parsed transcript), oldest first."""
    out = []
    for d in (Path(claude_dir) / "projects").glob(f"*-projects-{slug}-control"):
        for f in d.glob("*.jsonl"):
            try:  # Claude Code may delete a transcript under us, or a line may carry a bad time
                s = read(f)
                if s["start"]:
                    parse_ts(s["start"])
                if s["stage"] and s["start"]:
                    subs = [read(a) for a in sorted((d / f.stem / "subagents").glob("*.jsonl"))]
                    out.append(dict(s, id=f.stem, subagents=subs, path=f))
            except (OSError, ValueError):
                continue
    return sorted(out, key=lambda s: s["start"])


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


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
