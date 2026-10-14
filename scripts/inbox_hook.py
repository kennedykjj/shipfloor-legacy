"""The owner's messages to a running card: the dashboard appends one JSON line per message to
<run lock>/inbox, and this PostToolUse hook hands the new ones to the agent that just used a tool.
Every agent of the run, the lead and each subagent, gets each message once: it keeps its own count
of lines read in <run lock>/inbox.<agent id>, the lead in inbox.lead."""
import json, os, re, sys
from pathlib import Path

INTRO = ("Message from the owner, sent while you work. Where it differs from your plan, the message wins: "
         "follow it from here on and pass it on to any agent you start.")


def codex_agent(lock, session):
    """Who a Codex hook call is for. Codex names the session, not the agent: the first session to call is the run's
    lead (inbox.codex-lead keeps its id, taken atomically), every other one is a subagent with its own count."""
    session = re.sub(r"[^\w-]", "", str(session or "lead")) or "lead"
    mark = Path(lock) / "inbox.codex-lead"
    try:
        fd = os.open(mark, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        with os.fdopen(fd, "w") as f:
            f.write(session)
        return "lead"
    except FileExistsError:
        return "lead" if mark.read_text(encoding="utf-8").strip() == session else session


def main(codex=False):
    """codex: the hook is Codex's (its input names a session_id, not an agent_id); outside a run it does nothing."""
    lock = os.environ.get("SHIPFLOOR_RUN_LOCK")
    if codex and not (lock and (Path(lock) / "inbox").is_file()):
        return
    inbox = Path(lock or os.environ["SHIPFLOOR_RUN_LOCK"]) / "inbox"
    data = json.load(sys.stdin)
    who = codex_agent(lock, data.get("session_id")) if codex else re.sub(r"[^\w-]", "", str(data.get("agent_id") or "lead"))
    seen = inbox.with_name(f"inbox.{who}")
    lines = inbox.read_text(encoding="utf-8").splitlines()
    n = int(seen.read_text()) if seen.exists() else 0
    if len(lines) <= n:
        return
    seen.write_text(str(len(lines)))
    new = "\n\n".join(json.loads(x)["text"] for x in lines[n:])
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": f"{INTRO}\n\n{new}"}}))


if __name__ == "__main__":
    main(codex="--codex" in sys.argv[1:])
