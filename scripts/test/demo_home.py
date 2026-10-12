"""The sample of the demo stack: demo_home.py <state folder> writes a factory home (<state>/home), the Claude Code
transcripts (<state>/claude) and the data of the gh stand-in (<state>/gh) for two projects in opposite states: atlas
is busy (every kind of card, run and cost the dashboard draws), beacon is quiet (paused, an old board, nothing to do).
The content is the same on every call; every time is counted from the call. Standard library only."""
import json, os, sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
NOW = datetime.now().astimezone().replace(microsecond=0)
MIDNIGHT = NOW.replace(hour=0, minute=0, second=0)
MODEL, OPUS, UNPRICED = "claude-sonnet-5-5", "claude-opus-5-5", "claude-nova-9-0"  # the last one is not in templates/prices.yml
SMALL, HEAVY = (20000, 6000, 150000, 30000), (900000, 300000, 14000000, 700000)  # input, output, cache read, cache write
MARKS = {"Inbox": "👤", "Ready for Refinement": "👤", "Technical Refinement": "🤖", "Spec Review": "👤", "Ready for Dev": "👤",
         "Coding": "🤖", "Validation": "🤖", "Staged": "👤", "Ready for Prod": "👤", "Done": "🤖"}
STEPS = {"refine": ["Pick the card", "Worktree", "Product Owner", "UX/UI and architecture", "Cybersec", "Publish for review", "Report"],
         "develop": ["Pick the card", "Plan", "Acceptance tests", "Implementation", "Last gates", "Hand over to validation", "Report"],
         "validate": ["Pick the card", "Gates", "Review", "Pull request", "Report"],
         "deploy": ["Merge", "Wait for CI", "Deploy", "Health check", "Report"]}
PROJECTS = {
    "atlas": {"number": 1, "repo": "demo/atlas", "cards": [
        (96, "Done", "Add a health endpoint to the API"),
        (101, "Done", "Paginate the audit log"),
        (120, "Staged", "Replace the polling loop in the sync worker with a queue consumer and keep the retry policy"),
        (118, "Validation", "Round the checkout total half up, as the invoice does"),
        (122, "Validation", "Cache the price list between requests"),
        (1204, "Coding", "Keep the cart total right when a coupon is removed"),
        (124, "Ready for Dev", "Retry webhook deliveries with exponential backoff"),
        (127, "Spec Review", "Rate limit the public search API per token"),
        (129, "Spec Review", "Show the last sync time on the account page"),
        (131, "Technical Refinement", "Export the weekly report as CSV")]},
    "beacon": {"number": 2, "repo": "demo/beacon", "cards": [
        (3, "Done", "Set up the marketing site"),
        (5, "Done", "Add the pricing page"),
        (8, "Inbox", "Add a dark mode toggle"),
        (9, "Inbox", "Translate the footer")]},
}
counter = [0]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def day(n, hour, minute=0):
    return (NOW - timedelta(days=n)).replace(hour=hour, minute=minute, second=0)


def today(t):
    return max(t, MIDNIGHT + timedelta(minutes=1))


def iso(t):
    return t.isoformat(timespec="seconds")


def zulu(t):
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def usage(i, o, r, w):
    return {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": r, "cache_creation_input_tokens": w,
            "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": w}}


def says(text):
    return {"type": "text", "text": text}


def tool(name, **given):
    return {"type": "tool_use", "name": name, "input": given}


def session(claude, slug, issue, stage, start, minutes, model=MODEL, size=SMALL, blocks=(), sub=False):
    """One Claude Code session of a run: the dispatcher's command, then the blocks it wrote (each logged with its
    message's usage, as Claude Code does), and optionally a subagent."""
    counter[0] += 1
    sid = f"demo-{counter[0]:04d}"
    folder = claude / "projects" / f"C--demo-shipfloor-projects-{slug}-control"
    blocks = list(blocks) or [says(f"{stage.capitalize()} of #{issue} done."), tool("Bash", description="Run the gates")]
    lines = [{"type": "user", "timestamp": zulu(start), "message": {"role": "user", "content":
              f"<command-message>sf:{stage}</command-message>\n<command-name>/sf:{stage}</command-name>\n<command-args>{issue}</command-args>"}}]
    for i, block in enumerate(blocks):
        at = start + timedelta(seconds=minutes * 60 * (i + 1) / (len(blocks) + 1))
        lines.append({"type": "assistant", "timestamp": zulu(at), "message": {"id": f"msg_{sid}", "model": model, "usage": usage(*size), "content": [block]}})
    write(folder / f"{sid}.jsonl", "".join(json.dumps(x) + "\n" for x in lines))
    if sub:
        agent = {"type": "assistant", "timestamp": zulu(start + timedelta(minutes=minutes / 2)),
                 "message": {"id": f"msg_{sid}_a", "model": MODEL, "usage": usage(*SMALL), "content": [says("Reviewed the diff for the sync worker.")]}}
        write(folder / sid / "subagents" / "agent-review.jsonl", json.dumps(agent) + "\n")


def run_log(home, slug, issue, stage, runs, upto=None):
    """logs/<day>-<n>-<stage>.log with a == start and (when it ended) a == end line per run, and what the run did between."""
    steps, lines = STEPS[stage][:upto], []
    for start, end, code in runs:
        lines.append(f"== start /sf:{stage} {issue} {iso(start)} pid={4000 + issue % 900}")
        span = ((end or NOW) - start) / (len(steps) * 3 + 1)
        for k, label in enumerate(steps):
            at = (start + span * (3 * k + 1)).strftime("%H:%M:%S")
            lines += [f"[{at}] step {k + 1}: {label}", f"[{at}]   reading the card, the spec and the code it touches", f"[{at}]   ok"]
        if end:
            lines.append(f"== end /sf:{stage} {issue} exit={code} {iso(end)}")
    write(home / "projects" / slug / "logs" / f"{runs[0][0].date().isoformat()}-{issue}-{stage}.log", "\n".join(lines) + "\n")


def review_page(home, slug, issue, sections):
    html = (HERE.parent / "review-template.html").read_text(encoding="utf-8")
    for k, v in {"__DATA__": json.dumps(sections, ensure_ascii=False), "__ISSUE__": str(issue), "__TITLE__": "Rate limit the public search API per token",
                 "__BRANCH__": f"feat/{issue}-rate-limit-search", "__SPEC__": f"docs/superpowers/specs/{issue}.md", "__DATE__": date.today().strftime("%d/%m/%Y"),
                 "__KEY__": f"{slug}-spec-{issue}-review"}.items():
        html = html.replace(k, v)
    write(home / "projects" / slug / "reviews" / f"{issue}.html", html)


def report(home, slug, issue, name, pipeline, outcome, gates=None, failed=(), pr=None, notes=""):
    body = {"pipeline": pipeline, "outcome": outcome, "gates": gates or {}, "failed_gates": list(failed), "pr": pr, "rounds": 1, "notes": notes}
    write(home / "projects" / slug / "reports-wt" / "reports" / f"{issue}-demo" / f"{name}.json", json.dumps(body, indent=1) + "\n")


def factory_yml(slug, repo, number, tests_dir):
    return f"""project:
  name: {slug}
  repo: {repo}
board: {{owner: demo, number: {number}}}
context: [PRODUCT.md, CLAUDE.md, docs/architecture.md]
forbidden: [docs/internal/]
stack: {{url: "http://127.0.0.1:8080/"}}
deploy: {{ci_workflow: CI, environment: production}}
limits:
  develop: {{wip: 2}}
layers:
  - name: app
    path: ./
    stack: Python 3
    build: python -m compileall -q src
    test: python -m pytest {{selector}}
    ran: '[1-9][0-9]* passed'
    tests: ['{tests_dir}/**']
  - name: e2e
    path: ./
    tests_only: true
    needs_stack: true
    test: python -m pytest e2e/{{selector}}
    ran: '[1-9][0-9]* passed'
    tests: ['e2e/**']
"""


def main():
    state = Path(sys.argv[1])
    home, claude, gh = state / "home", state / "claude", state / "gh"
    for d in (home / "logs", claude / "projects", gh):
        d.mkdir(parents=True, exist_ok=True)
    write(home / "registry.tsv", "".join(f"{slug}\t{state.as_posix()}/checkouts/{slug}\t{state.as_posix()}/worktrees/{slug}\tmain\n" for slug in PROJECTS))
    write(home / "config.yml", "# shipfloor machine config: the demo's sample\nlanguage: en\npool: 6\nstages:\n  refine: 1\n  develop: 2\n  validate: 1\n  deploy: 1\n"
          "stacks: 3\ndispatcher:\n  every_min: 10\n")
    for slug, p in PROJECTS.items():
        write(home / "projects" / slug / "factory.yml", factory_yml(slug, p["repo"], p["number"], "tests"))
        for d in ("logs", "locks", "reviews"):
            (home / "projects" / slug / d).mkdir(parents=True, exist_ok=True)
        write(home / "projects" / slug / "board.tsv", "".join(f"{n}\t{col}\tPVTI_{slug}_{n}\n" for n, col, _ in p["cards"]))

    # atlas: the busy project
    a = "atlas"
    A = home / "projects" / a
    write(A / "overrides.yml", "limits:\n  develop:\n    wip: 3\n")
    B0 = max((NOW - timedelta(minutes=90)).replace(minute=0, second=0), MIDNIGHT)  # the hour with a clean and a failed run
    r124 = (today(B0 - timedelta(minutes=55)), today(B0 - timedelta(minutes=35)), 0)
    r129 = (B0 + timedelta(minutes=2), B0 + timedelta(minutes=11), 0)
    r122 = (B0 + timedelta(minutes=25), B0 + timedelta(minutes=31), 3)
    # runs and their sessions, per card
    for n, rounds in ((96, [(4, "refine", 10, 22), (4, "develop", 13, 41), (3, "validate", 9, 14), (3, "deploy", 15, 6)]),
                      (101, [(4, "refine", 11, 19), (3, "develop", 10, 36), (3, "validate", 13, 11), (3, "deploy", 16, 5)])):
        for d, stage, h, mins in rounds:
            start = day(d, h)
            run_log(home, a, n, stage, [(start, start + timedelta(minutes=mins), 0)])
            if stage != "deploy":
                session(claude, a, n, stage, start + timedelta(seconds=5), mins, model=UNPRICED if (n, stage) == (101, "develop") else MODEL)
    for stage, d, h, mins, code, size, sub in (("refine", 5, 11, 18, 0, SMALL, False), ("develop", 2, 14, 52, 1, SMALL, False),
                                                ("develop", 1, 9, 47, 0, HEAVY, True), ("validate", 1, 11, 12, 0, SMALL, False)):
        start = day(d, h, 30 if h == 9 else 0)
        run_log(home, a, 120, stage, [(start, start + timedelta(minutes=mins), code)])
        session(claude, a, 120, stage, start + timedelta(seconds=5), mins, model=OPUS if size == HEAVY else MODEL, size=size, sub=sub)
    v1, v2 = day(1, 15), day(1, 17)
    for stage, d, h, mins, code in (("refine", 3, 10, 17, 0), ("develop", 2, 16, 44, 0)):
        start = day(d, h)
        run_log(home, a, 118, stage, [(start, start + timedelta(minutes=mins), code)])
        session(claude, a, 118, stage, start + timedelta(seconds=5), mins)
    run_log(home, a, 118, "validate", [(v1, v1 + timedelta(minutes=9), 2), (v2, v2 + timedelta(minutes=8), 2)])
    session(claude, a, 118, "validate", v1 + timedelta(seconds=5), 9)
    session(claude, a, 118, "validate", v2 + timedelta(seconds=5), 8)
    for stage, d, h, mins in (("refine", 2, 10, 21), ("develop", 1, 13, 39)):
        start = day(d, h)
        run_log(home, a, 122, stage, [(start, start + timedelta(minutes=mins), 0)])
        session(claude, a, 122, stage, start + timedelta(seconds=5), mins)
    run_log(home, a, 122, "validate", [r122])
    session(claude, a, 122, "validate", r122[0] + timedelta(seconds=5), 6)
    run_log(home, a, 124, "refine", [r124])
    session(claude, a, 124, "refine", r124[0] + timedelta(seconds=5), 20)
    run_log(home, a, 129, "refine", [r129])
    session(claude, a, 129, "refine", r129[0] + timedelta(seconds=5), 9)
    start = day(1, 16)
    run_log(home, a, 127, "refine", [(start, start + timedelta(minutes=23), 0)])
    session(claude, a, 127, "refine", start + timedelta(seconds=5), 23)
    start = day(1, 10)
    run_log(home, a, 1204, "refine", [(start, start + timedelta(minutes=20), 0)])
    session(claude, a, 1204, "refine", start + timedelta(seconds=5), 20)

    # the two runs in progress: a refine at its fourth step, and a develop that has not reported a step yet
    s131, s1204 = NOW - timedelta(minutes=14), NOW - timedelta(minutes=37)
    run_log(home, a, 131, "refine", [(s131, None, None)], upto=4)
    write(A / "locks" / "refine-131.lock" / "info", f"1 {int(s131.timestamp())} 131\n")
    write(A / "locks" / "refine-131.lock" / "step", f"4\t{int((NOW - timedelta(minutes=3)).timestamp())}\n")
    session(claude, a, 131, "refine", s131 + timedelta(seconds=5), 13, blocks=[
        says("Drafting the UX notes for the CSV export: the columns, the header row and what an empty week looks like."),
        tool("Read", file_path="app/reports/weekly.py"), tool("Grep", pattern="def render_week"), tool("Bash", description="List the report templates")])
    run_log(home, a, 1204, "develop", [(s1204, None, None)], upto=5)
    write(A / "locks" / "develop-1204.lock" / "info", f"1 {int(s1204.timestamp())} 1204\n")
    session(claude, a, 1204, "develop", s1204 + timedelta(seconds=5), 36, blocks=[
        says("The coupon removal clears the discount but not the cached total; fixing the cart service."),
        tool("Edit", file_path="app/cart/service.py"), tool("Bash", description="Run the cart tests")])

    review_page(home, a, 127, [
        {"id": "open-questions", "t": "Open questions", "intro": "", "items": ["Should signed-in tokens get a higher limit than anonymous ones?"], "ro": False},
        {"id": "product", "t": "Product", "intro": "", "ro": True, "items": [
            "Problem: one client can use up the search API for everyone else.",
            "AC-1: Given a token that sent 60 requests in a minute, when it sends another, then the API answers 429 with a Retry-After header.",
            "AC-2: Given a token under its limit, when it searches, then the answer is unchanged."]},
        {"id": "architecture", "t": "Architecture", "intro": "", "ro": True, "items": [
            "The limit lives in the gateway middleware, counted per token in the existing cache.", "No new table and no migration."]}])
    report(home, a, 120, "01-refine", "refine", "pass")
    report(home, a, 120, "02-develop", "develop", "failed", {"build": "pass", "tests": "fail"}, ["tests"], notes="Two sync tests failed on the retry delay.")
    report(home, a, 120, "03-develop", "develop", "done", {"build": "pass", "tests": "pass", "acceptance": "pass"})
    report(home, a, 120, "04-validate", "validate", "pass", {"build": "pass", "tests": "pass", "e2e": "pass"}, pr=342)
    report(home, a, 118, "01-validate", "validate", "blocked", {"build": "pass", "tests": "pass", "e2e": "fail"}, ["e2e"])
    report(home, a, 122, "01-validate", "validate", "blocked", {"stack": "fail"}, ["stack"])

    # beacon: the quiet project, paused, its board read long ago
    write(home / "projects" / "beacon" / "PAUSE", "")
    old = (NOW - timedelta(minutes=8)).timestamp()
    os.utime(home / "projects" / "beacon" / "board.tsv", (old, old))

    # the dispatcher's and the stacks' logs, and one health line
    minute = lambda m: iso(NOW - timedelta(minutes=m))
    write(home / "logs" / "dispatcher.log", "".join(f"{minute(m)} shipfloor: {text}\n" for m, text in (
        (72, "cycle start"), (71, "atlas: refine 129 started"), (60, "atlas: refine 129 ended exit=0"), (58, "atlas: validate 122 started"),
        (52, "atlas: validate 122 failed: the stack did not come back, labelled blocked:infra"), (38, "atlas: develop 1204 started"),
        (30, "beacon: paused, skipped this cycle"), (15, "atlas: refine 131 started"), (1, "cycle end: 2 runs, 1 card waiting"))))
    write(home / "logs" / "stacks.log", f"{minute(55)} slot 0 up for atlas validate 122 at http://127.0.0.1:20000/\n")
    write(home / "logs" / f"health-{NOW:%Y-%m}.jsonl", json.dumps({"ts": iso(NOW), "cycle": {"s": 6, "exit": 0, "overlap": False}, "paused": False,
          "usage_limited": False, "pool": {"size": 6, "used": 2}, "idle": [], "over": []}) + "\n")

    # the gh stand-in's data: the board, the issues, their labels and comments, the pull request
    blocked_note = ("Factory validate, step 2 (gates): blocked.\n"
                    "The owner must decide: whether the checkout total rounds half up, as the invoice does, or half to even, as the test expects.\n"
                    "Failed gate: e2e checkout totals.\n"
                    "Tried: reran the e2e gate twice, bisected the failing test to the rounding helper and read the spec for a rounding rule.")
    state_json = {
        "fields": [{"name": "Status", "id": "FLD_status", "options": [{"name": f"{m} {c}", "id": f"opt{i + 1}"} for i, (c, m) in enumerate(MARKS.items())]}],
        "projects": {str(p["number"]): {"id": f"PVT_{slug}", "title": f"{slug} board", "url": f"https://github.com/orgs/demo/projects/{p['number']}",
                                        "refuse": slug == "beacon", "mirror": (home / "projects" / slug / "board.tsv").as_posix() if slug == "atlas" else "",
                                        "items": [[n, f"{MARKS[col]} {col}", f"PVTI_{slug}_{n}"] for n, col, _ in p["cards"]]}
                     for slug, p in PROJECTS.items()},
        "repos": {p["repo"]: {"issues": [{"number": n, "title": title} for n, _, title in p["cards"]],
                              "labels": {"118": ["blocked"], "122": ["blocked:infra"]} if slug == "atlas" else {},
                              "comments": {"118": [{"body": "Spec approved."}, {"body": blocked_note}],
                                           "122": [{"body": "**Validate blocked (infrastructure)**: the stack did not come back after two tries.\nFailed gate: stack up."}]}
                              if slug == "atlas" else {},
                              "prs": {"342": {"number": 342, "url": "https://github.com/demo/atlas/pull/342", "title": "Queue consumer for the sync worker",
                                              "additions": 412, "deletions": 187, "changedFiles": 14,
                                              "statusCheckRollup": [{"conclusion": "SUCCESS"}, {"conclusion": "SUCCESS"}]}} if slug == "atlas" else {}}
                  for slug, p in PROJECTS.items()}}
    write(gh / "state.json", json.dumps(state_json, ensure_ascii=False))


if __name__ == "__main__":
    main()
