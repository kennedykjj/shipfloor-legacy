"""The owner's messages to a running card: the dashboard appends one JSON line per message to
<run lock>/inbox, and this PostToolUse hook hands the new ones to the agent that just used a tool.
Every agent of the run, the lead and each subagent, gets each message once: it keeps its own count
of lines read in <run lock>/inbox.<agent id>, the lead in inbox.lead."""
import json, os, re, sys
from pathlib import Path

INTRO = ("Message from the owner, sent while you work. Where it differs from your plan, the message wins: "
         "follow it from here on and pass it on to any agent you start.")


def main():
    inbox = Path(os.environ["SHIPFLOOR_RUN_LOCK"]) / "inbox"
    who = re.sub(r"[^\w-]", "", str(json.load(sys.stdin).get("agent_id") or "lead"))
    seen = inbox.with_name(f"inbox.{who}")
    lines = inbox.read_text(encoding="utf-8").splitlines()
    n = int(seen.read_text()) if seen.exists() else 0
    if len(lines) <= n:
        return
    seen.write_text(str(len(lines)))
    new = "\n\n".join(json.loads(x)["text"] for x in lines[n:])
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": f"{INTRO}\n\n{new}"}}))


if __name__ == "__main__":
    main()
