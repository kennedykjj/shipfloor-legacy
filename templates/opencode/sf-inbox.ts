// Generated copy of templates/opencode/sf-inbox.ts: the factory's opencode plugin, written by `shipfloor install`.
// The owner's messages to a running card: the dashboard appends one JSON line per message to
// $SHIPFLOOR_RUN_LOCK/inbox; after each tool call this hands the new ones to the agent that used the tool, once per
// agent (a count of lines read in inbox.<agent>, as inbox_hook.py keeps it). No npm imports: node/bun built-ins only.
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const INTRO =
  "Message from the owner, sent while you work. Where it differs from your plan, the message wins: " +
  "follow it from here on and pass it on to any agent you start."

function pending(agent: string): string | null {
  const lock = process.env.SHIPFLOOR_RUN_LOCK
  if (!lock) return null
  const inbox = join(lock, "inbox")
  if (!existsSync(inbox)) return null
  const who = (agent || "lead").replace(/[^\w-]/g, "") || "lead"
  const seen = join(lock, "inbox." + who)
  const lines = readFileSync(inbox, "utf8").split("\n").filter((l) => l.length > 0)
  const n = existsSync(seen) ? parseInt(readFileSync(seen, "utf8"), 10) || 0 : 0
  if (lines.length <= n) return null
  writeFileSync(seen, String(lines.length))
  const texts: string[] = []
  for (const l of lines.slice(n)) {
    try {
      texts.push(String(JSON.parse(l).text))
    } catch {
      // a line that is not JSON is not a message
    }
  }
  return texts.length ? INTRO + "\n\n" + texts.join("\n\n") : null
}

export default async function sfInbox(ctx: any) {
  ctx.tool.hook("execute.after", async (input: any) => {
    const text = pending(input?.session?.parentID ? String(input.session.id) : "lead")
    if (text) await ctx.session.synthetic(input.session.id, text)
  })
}
