"""Cost of the factory's runs, read from the Claude Code transcripts (one .jsonl per session)."""
import json, re
from collections import deque
from datetime import datetime

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


def per_card(runs):
    """The mean cost of a card from [(card, US$ or None)], one entry per session: a card's cost is the sum of its
    sessions, and a card with an unpriced session is left out. Never a zero for nothing: avg is None with 0 cards."""
    sums = {}
    for card, usd in runs:
        sums[card] = None if usd is None or sums.get(card, 0) is None else sums.get(card, 0) + usd
    priced = [v for v in sums.values() if v is not None]
    return {"avg": rounded(sum(priced) / len(priced)) if priced else None, "cards": len(priced)}
