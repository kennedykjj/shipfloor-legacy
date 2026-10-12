---
name: dashboard
description: Opens the factory's local dashboard (pool, live runs, logs, cost per card, review pages) in the browser. Started by "/sf:dashboard [--port N] [--no-open]".
---

# /dashboard — open the factory's local dashboard

1. Run `bash ~/.shipfloor/factory/shipfloor dashboard <the arguments given, if any>` from the project's directory as a background command: it serves until stopped, so never wait for it to exit.
2. Read its first output line, `shipfloor dashboard: <url>  (Ctrl+C stops it)`, and finish with one line carrying that `<url>`. The URL holds this machine's token, so give it exactly as printed. If the command exits instead, show its error.
