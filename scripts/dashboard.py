"""Local dashboard: one page and a JSON API over ~/.shipfloor and the Claude Code transcripts of the
factory's runs. Read-only, except the owner's decisions on a card that waits, messages to a running card and this machine's
settings (the pool and the pauses)."""
import argparse, json, os, re, secrets, shlex, shutil, statistics, subprocess, sys, threading, time, webbrowser
from collections import deque
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ in the installed scripts
sys.path.insert(0, str(HERE))
import shipfloor_config  # exits with a clear message when PyYAML is missing
import shipfloor_health
from dashboard_cost import LEGACY_STAGES, cost, events, parse_transcript, parse_ts, per_card, rounded
import yaml

# The steps a run announces with `shipfloor-config.sh step <k>`: the numbered sections of each skill, less its failure rule.
STEPS = {"refine": {1: "Pick the card", 2: "Worktree", 3: "Product Owner", 4: "UX/UI and architecture", 5: "Cybersec", 6: "Publish for review", 8: "Report"},
         "develop": {1: "Pick the card", 2: "Plan", 3: "Acceptance tests", 4: "Implementation", 5: "Last gates", 6: "Hand over to validation", 8: "Report"},
         "validate": {1: "Pick the card", 2: "Gates", 3: "Review", 4: "Pull request", 6: "Report"}}
STACKS_TTL_S = 15
PIPELINES = set(LEGACY_STAGES.values())
# What the owner may set per project on this machine (overrides.yml), and what each is when nobody set it:
# the project config's defaults for the limits, deploy.sh's own for the deploy.
KNOBS = {"limits.refine.wip": shipfloor_config.DEFAULTS["limits"]["refine"]["wip"],
         "limits.develop.wip": shipfloor_config.DEFAULTS["limits"]["develop"]["wip"],
         "deploy.timeout_min": 30, "deploy.conflict_max_files": 5}
#  how the skills open a block note: "Factory validate, step 2 (gates): blocked." or "Validate, step 2 (gates): ..."
BLOCK_LINE = re.compile(r"(?:Factory )?\b(refine|develop|validate|deploy),? step (\d+)(?:\s*\([^)\n]*\))?:?\s*(?:blocked\.?\s*)?", re.I)
# The acceptance test files of a card as they changed since its QA commit: what the acceptance-intact gate looks at.
ACCEPTANCE_DIFF = """qa="$(bash "$1" -C "$2" qa-commit "$3" 2>/dev/null)"; [ -n "$qa" ] || exit 0
mapfile -t files < <(git -C "$2" -c core.quotePath=false show --name-only --format= --diff-filter=d "$qa")
[ "${#files[@]}" -gt 0 ] && git -C "$2" -c core.quotePath=false diff --no-color -U1 "$qa" HEAD -- "${files[@]}"
"""
BOARD_TTL_S = 10  # while someone watches, the board is read again this often
FEED_LINE = re.compile(r"^(\d{4}-\d\d-\d\dT\S+) (.*)")
RUN_LINE = re.compile(r"^== (start|end) /(?:sf|aghanim|mylos):([a-z]+) (\d+)(?: exit=(\d+))? (\S+)")  # legacy aghanim, legacy mylos
# The review page inside the dashboard's drawer: the drawer already carries the title and the one
# action, so the embedded page drops its header, takes the dashboard's palette and type, and posts
# its review marks to the drawer.
EMBED_CSS = """<style>
header.top{display:none}
html:root:not([data-x]){--page:#0d1014;--sheet:#151a21;--surface:#1b212a;--ink:#ebe5d5;--muted:#8f8b80;--rule:#262e39;
--linen:#262e39;--linen-ink:#ebe5d5;--display:"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;--body:var(--display)}
@media (prefers-color-scheme:light){html:root:not([data-x]){--page:#e7e7e4;--sheet:#f4f4f2;--surface:#ececea;--ink:#23262b;
--muted:#6b6a66;--rule:#d9d9d4;--linen:#d9d9d4;--linen-ink:#23262b}}
h1,section h2{font-weight:600}
section h2{font-size:17px;line-height:1.3}
.count{display:none}
button{background:transparent;color:var(--ink);border-color:var(--rule)}
</style>
<script>
/* tells the dashboard how far the review went, so its Approve can say so (the page itself is sandboxed) */
addEventListener("load",function(){
 function send(){
  var c=document.getElementById("count");if(!c)return;
  var m=c.textContent.match(/(\\d+)\\s*of\\s*(\\d+)/);
  var chg=[].map.call(document.querySelectorAll(".item.chg"),function(it){
   var s=it.closest("section"),h=s&&s.querySelector("h2"),p=it.querySelector("p"),t=it.querySelector("textarea");
   return "- ["+(h?h.textContent:"")+"] "+(p?p.textContent:"")+"\\n  -> "+((t&&t.value.trim())||"(no note)")});
  parent.postMessage({shipfloor:"review-progress",done:m?+m[1]:0,total:m?+m[2]:0,changes:chg},"*")}
 /* the dashboard's theme: it answers "ready" with its colors, and sends them again when the owner changes theme */
 addEventListener("message",function(e){
  var m=e.data,r=document.documentElement;if(e.source!==parent||!m||m.shipfloor!=="theme")return;
  for(var k in m.vars)if(/^[a-z-]+$/.test(k))r.style.setProperty("--"+k,m.vars[k]);
  r.style.colorScheme=m.light?"light":"dark"});
 parent.postMessage({shipfloor:"ready"},"*");
 send();new MutationObserver(send).observe(document.body,{subtree:true,childList:true,characterData:true});
 document.addEventListener("input",send)});
</script>"""
OWNER_MOVES = {"Spec Review": {"approve": "Ready for Dev", "request-changes": "Ready for Refinement"},
               "Staged": {"approve": "Ready for Prod", "request-changes": "Coding"}}


def read_yaml(path):
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return {}


def find_bash(environ, windows):
    if environ.get("SHIPFLOOR_BASH"):
        return environ["SHIPFLOOR_BASH"]
    norm = lambda p: os.path.normcase(os.path.normpath(p))
    refused = set()
    if windows:  # the WSL launcher lives here and fails without a distribution
        if environ.get("SystemRoot"):
            refused.add(norm(os.path.join(environ["SystemRoot"], "System32")))
        if environ.get("LOCALAPPDATA"):
            refused.add(norm(os.path.join(environ["LOCALAPPDATA"], "Microsoft", "WindowsApps")))
    for d in environ.get("PATH", "").split(os.pathsep):
        if not d:  # an empty entry would search the current directory
            continue
        hit = shutil.which("bash", path=d)
        # on Windows which() may also find a bash in the current directory: the hit must sit in d
        if hit and norm(os.path.dirname(hit)) == norm(d) and norm(os.path.dirname(hit)) not in refused:
            return hit
    return None


_bash = None


def bash():
    global _bash
    if _bash is None:
        _bash = find_bash(os.environ, os.name == "nt")
        if _bash is None:
            raise SystemExit("shipfloor dashboard: no usable bash found: set SHIPFLOOR_BASH or start it with shipfloor dashboard")
    return _bash


NO_SCHEDULER = ("Windows only: this machine has no ShipfloorDispatcher scheduled task. "
                "Its pace is set by whatever schedules the dispatcher here.")


def scheduler():
    """(the command that sets the dispatcher's pace, None) or (None, why there is none). The minutes go last.
    SHIPFLOOR_SCHEDULER (split like a command line) overrides; "none" says there is no scheduler; else the
    installer script re-registers the Windows task."""
    given = os.environ.get("SHIPFLOOR_SCHEDULER")
    if given is not None:
        try:
            parts = [] if given.strip() == "none" else shlex.split(given)
        except ValueError:
            parts = []
        return (parts, None) if parts else (None, NO_SCHEDULER)
    if os.name != "nt":
        return None, NO_SCHEDULER
    try:  # the installed copy records the checkout it came from; a checkout is its own source
        source = (HERE / ".source").read_text(encoding="utf-8").strip() or str(HERE.parent)
    except OSError:
        source = str(HERE.parent)
    return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(Path(source) / "installer" / "install-dispatcher.ps1"), "-EveryMin"], None


def gh(*args, input=None):  # through bash, so FACTORY_GH can be a script on Windows too
    # Never --jq: started from Python on Windows, gh crashes on it (0xC0000005). Read JSON with gh_json.
    return subprocess.run([bash(), "-c", 'exec "${FACTORY_GH:-gh}" "$@"', "gh", *args],
                          input=input, capture_output=True, text=True, encoding="utf-8")


def gh_json(*args):
    """(value, None) from a gh call that prints JSON, or (None, error)."""
    r = gh(*args)
    if r.returncode != 0:
        return None, r.stderr.strip() or f"gh exited {r.returncode}"
    try:
        return json.loads(r.stdout or "null"), None
    except ValueError:
        return None, "gh did not print JSON"


class Factory:
    def __init__(self, home, claude_dir):
        self.home, self.claude_dir = Path(home), Path(claude_dir)
        self._transcripts, self._titles, self._blocked, self._reasons, self._boards = {}, {}, {}, {}, {}
        self._diffs, self._prs = {}, {}
        self._stacks = (0.0, [], 0)
        self._configs = {}
        self._snap, self._reading, self._retry = {}, set(), {}

    def projects(self):
        try:
            lines = (self.home / "registry.tsv").read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        return [line.split("\t")[0] for line in lines if line.strip()]

    def pdir(self, p):
        return self.home / "projects" / p

    def config(self, p):
        """factory.yml, read again only when it changed: the dispatcher replaces the file on every cycle, and on
        Windows a rename over a file someone has open fails."""
        f = self.pdir(p) / "factory.yml"
        try:
            st = f.stat()
        except OSError:
            return {}
        key, hit = (st.st_size, st.st_mtime), self._configs.get(p)
        if not hit or hit[0] != key:
            hit = self._configs[p] = (key, read_yaml(f))
        return hit[1]

    def prices(self):
        # the installed copy keeps templates/ next to the scripts; the plugin checkout, one level up
        for f in (self.home / "prices.yml", HERE / "templates" / "prices.yml", HERE.parent / "templates" / "prices.yml"):
            if f.is_file():
                return read_yaml(f)
        return {}

    def transcript(self, path, parse=parse_transcript):
        st = path.stat()
        key, hit = (st.st_size, st.st_mtime), self._transcripts.get((path, parse))
        if not hit or hit[0] != key:
            hit = self._transcripts[(path, parse)] = (key, parse(path))
        return hit[1]

    def sessions(self, p, issue=None):
        out = []
        for d in (self.claude_dir / "projects").glob(f"*-projects-{p}-control"):
            for f in d.glob("*.jsonl"):
                try:  # Claude Code may delete a transcript under us, or a line may carry a bad time
                    s = self.transcript(f)
                    if s["start"]:
                        parse_ts(s["start"])
                except (OSError, ValueError):
                    continue
                if s["stage"] and s["start"] and issue in (None, s["issue"]):
                    subs = [self.transcript(a) for a in sorted((d / f.stem / "subagents").glob("*.jsonl"))]
                    out.append(dict(s, id=f.stem, subagents=subs, path=f))
        return sorted(out, key=lambda s: s["start"] or "")

    def session_cost(self, s, prices):
        parts = [cost(s["tokens"], prices)] + [cost(a["tokens"], prices) for a in s["subagents"]]
        return None if None in parts else sum(parts)

    def runs(self, p, issue=None, day=None):
        """Runs as the dispatcher logged them: == start / == end lines."""
        out = []
        for log in sorted((self.pdir(p) / "logs").glob("*.log")):
            if issue is not None and not re.fullmatch(rf"\d{{4}}-\d\d-\d\d-{issue}-[a-z]+\.log", log.name):
                continue
            if day and not log.name.startswith(day + "-"):
                continue
            with open(log, encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = RUN_LINE.match(line)
                    if not m:
                        continue
                    kind, stage, n, rc, ts = m.groups()
                    if kind == "start":
                        out.append({"stage": LEGACY_STAGES.get(stage, stage), "issue": int(n), "start": ts,
                                    "end": None, "exit": None, "log": log.name})
                    elif out and out[-1]["log"] == log.name and out[-1]["end"] is None:
                        out[-1].update(end=ts, exit=int(rc))
        return out

    def board(self, p):
        """Card columns from the newer of the dispatcher's snapshot and the dashboard's own read of the board."""
        f = self.pdir(p) / "board.tsv"
        try:
            lines, at = f.read_text(encoding="utf-8").splitlines(), f.stat().st_mtime
        except OSError:
            lines, at = [], None
        own = self._snap.get(p)
        if own and (at is None or own[0] > at):
            at, lines = own
        self.read_board(p, at)
        if at is None:
            return {}, None
        return {int(c[0]): c[1] for c in (l.split("\t") for l in lines) if len(c) > 1 and c[0].isdigit()}, round(time.time() - at)

    def read_board(self, p, at):
        """The dispatcher's snapshot is as old as its last cycle, and a card the owner moves on GitHub shows only then.
        So an overview that finds the board older than BOARD_TTL_S asks GitHub again, in the background: nobody
        watching, no reads. The answer stays in memory; board.tsv is the dispatcher's to write."""
        now = time.time()
        if (at and now - at < BOARD_TTL_S) or p in self._reading or now < self._retry.get(p, 0):
            return
        self._reading.add(p)

        def read():
            try:
                env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)),
                           SHIPFLOOR_HOME=str(self.home))
                env.pop("FACTORY_BOARD_SNAPSHOT", None)
                r = subprocess.run([bash(), (HERE / "board.sh").as_posix(), "snapshot"], env=env, cwd=str(self.pdir(p)),
                                   capture_output=True, text=True, encoding="utf-8", timeout=30)
                if r.returncode == 0 and r.stdout.strip():
                    self._snap[p] = (time.time(), r.stdout.splitlines())
                else:
                    self._retry[p] = time.time() + 60  # gh down or out of quota: the dispatcher's snapshot serves meanwhile
            except (OSError, subprocess.SubprocessError):
                self._retry[p] = time.time() + 60
            finally:
                self._reading.discard(p)
        threading.Thread(target=read, daemon=True).start()

    def board_url(self, p):
        """The project board's page on GitHub, asked once; None when gh cannot tell."""
        if p not in self._boards:
            b = self.config(p).get("board") or {}
            data, _ = gh_json("project", "view", str(b.get("number")), "--owner", str(b.get("owner")), "--format", "json") if b else (None, None)
            self._boards[p] = (data or {}).get("url")
        return self._boards[p]

    def titles(self, p, wanted):
        """{n: title} for the wanted card numbers, asked of GitHub by number (100 to a call). Everything is
        re-read after 5 minutes, a number never read at the next poll; a failed read keeps what was known."""
        at, known = self._titles.get(p, (0, {}))
        stale = time.time() - at > 300
        wanted = sorted(set(wanted))
        ask = wanted if stale else [n for n in wanted if n not in known]
        owner, _, name = str(shipfloor_config.dotted(self.config(p), "project.repo")).partition("/")
        read, ok = {}, bool(ask)
        for i in range(0, len(ask), 100):
            batch = ask[i:i + 100]
            fields = " ".join(f'i{int(n)}: issueOrPullRequest(number: {int(n)}) {{ ... on Issue {{ title }} ... on PullRequest {{ title }} }}' for n in batch)
            query = f'query($owner: String!, $name: String!) {{ repository(owner: $owner, name: $name) {{ {fields} }} }}'
            r = gh("api", "graphql", "-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}")
            try:  # a number GitHub does not know makes gh exit 1 but the others are still printed
                repo = ((json.loads(r.stdout or "null") or {}).get("data") or {}).get("repository")
            except (ValueError, AttributeError):
                repo = None
            if not isinstance(repo, dict):
                ok = False
                break
            read.update({n: ((repo.get(f"i{n}") or {}).get("title") or "") for n in batch})
        if ok:
            known = {**known, **read}
            self._titles[p] = (time.time() if stale else at, known)
        return known

    def blocked(self, p):
        """{n: "owner" | "infra"} from the block labels, read at most once a minute."""
        at, known = self._blocked.get(p, (0, {}))
        if time.time() - at > 60:
            repo, known = shipfloor_config.dotted(self.config(p), "project.repo"), {}
            for label, kind in (("blocked:infra", "infra"), ("blocked", "owner")):
                issues, _ = gh_json("api", f"repos/{repo}/issues?labels={label}&state=open&per_page=100")
                known.update({i["number"]: kind for i in issues or [] if isinstance(i, dict) and "number" in i})
            self._blocked[p] = (time.time(), known)
        return known

    def stacks(self):
        """Stack slots as lib/stack.sh computes them (gate.sh stack status). Asking spawns bash, by far the
        slowest part of an overview, so one answer serves the polls of the next few seconds."""
        at, slots, queue = self._stacks
        if time.time() - at < STACKS_TTL_S:
            age = round(time.time() - at)
            return [dict(s, held_s=s["held_s"] + age) if s["state"] != "free" else s for s in slots], queue
        projects = self.projects()
        if not projects:
            return [], 0
        p = projects[0]
        env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)),
                   SHIPFLOOR_HOME=str(self.home))
        r = subprocess.run([bash(), (HERE / "gate.sh").as_posix(), "stack", "status"], env=env, cwd=str(self.pdir(p)),
                           capture_output=True, text=True, encoding="utf-8")
        slots, queue = [], 0
        for line in r.stdout.splitlines():
            f = line.split("\t")
            if f[0] == "queue":
                queue = int(f[1]) if f[1].isdigit() else 0
            elif len(f) >= 4 and f[0].isdigit():
                slots.append({"slot": int(f[0]), "state": f[1], "owner": f[2], "held_s": int(f[3] or 0),
                              "reason": f[4] if len(f) > 4 else ""})
        self._stacks = (time.time(), slots, queue)
        return slots, queue

    def skipped(self, p):
        """Why the dispatcher skips this project and since when (shipfloor-dispatch.sh writes it), or None."""
        try:
            since, _, why = (self.pdir(p) / "SKIPPED").read_text(encoding="utf-8").strip().partition("	")
        except OSError:
            return None
        return {"since": since, "reason": why} if since else None

    def block_reason(self, p, n):
        """The factory's note about the block (the skills write the step, the output and what was tried there):
        among the issue's last comments, the newest that tells of a block or a failure, a stage's own note before
        its report. Read at most once a minute per card."""
        at, reason = self._reasons.get((p, n), (0, ""))
        if time.time() - at > 60:
            repo = shipfloor_config.dotted(self.config(p), "project.repo")
            pages, _ = gh_json("api", f"repos/{repo}/issues/{n}/comments?per_page=100", "--paginate", "--slurp")
            bodies = [c.get("body") or "" for page in pages or [] for c in (page if isinstance(page, list) else [page])
                      if isinstance(c, dict)]  # GitHub lists an issue's comments oldest first
            told = [b for b in reversed(bodies[-4:]) if re.search(r"\b(blocked|failed)\b", b, re.I)]
            reason = next((b for b in told if "Factory report" not in b[:40]), told[0] if told else "")[:4000]
            self._reasons[(p, n)] = (time.time(), reason)
        return reason

    def spec(self, p, n):
        """The card's spec as its review page holds it: the problem, the acceptance criteria, the open questions."""
        try:
            html = (self.pdir(p) / "reviews" / f"{n}.html").read_text(encoding="utf-8")
            sections, _ = json.JSONDecoder().raw_decode(html, re.search(r"\bconst S ?= ?(?=\[)", html).end())
        except (OSError, ValueError, AttributeError):
            return None
        items = lambda *names: [i for s in sections if s.get("t", "").strip().lower() in names for i in s.get("items", [])]
        criteria = [m.groups() for m in (re.match(r"((?:AC|CA)-\d+)[:.]?\s+(.*)", i, re.S) for i in items("product")) if m]
        problem = next((re.sub(r"^Problem[:.]\s*", "", i) for i in items("product") if i.startswith("Problem")), "")
        return {"problem": problem, "criteria": [{"id": k, "text": t} for k, t in criteria],
                "questions": items("open questions", "dúvidas")}

    def block(self, p, n):
        """A block told in parts: the stage and step it stopped at, why, what was tried, how many times, and for
        acceptance-intact the test files as they changed."""
        reason = self.block_reason(p, n)
        blocked = [r for r in self.reports(p, n) if r["outcome"] == "blocked"]
        m = BLOCK_LINE.search(reason)
        stage, step = (m.group(1).lower(), int(m.group(2))) if m else (None, None)
        if not stage:  # a report tells the block: it names its stage, not a step
            stage = next(iter(re.findall(r"Factory report\W+(\w+)", reason)), "").lower() or None
        text = "\n".join(l for l in (reason[m.end():] if m else reason).splitlines() if not l.lstrip().startswith("|"))
        why, _, tried = text.partition("Tried:")
        intact = re.search(r"acceptance-intact\W{0,4}(?:gate\W+)?fail|fail\w*[^.\n]{0,60}acceptance-intact", reason, re.I)
        gate = "acceptance-intact" if intact or any("acceptance-intact" in str(r["failed_gates"]) for r in blocked[-1:]) else ""
        return {"stage": stage, "step": step, "steps": [{"k": k, "label": v} for k, v in sorted(STEPS.get(stage, {}).items())],
                "why": why.strip(), "tried": tried.strip(), "times": len(blocked), "gate": gate,
                "diff": self.acceptance_diff(p, n) if gate else ""}

    def acceptance_diff(self, p, n):
        at, diff = self._diffs.get((p, n), (0, ""))
        if time.time() - at > 60:
            wt = next((c[2] for c in (l.split("\t") for l in (self.home / "registry.tsv").read_text(encoding="utf-8").splitlines())
                       if c[0] == p and len(c) > 2), "")
            env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)))
            try:
                r = subprocess.run([bash(), "-c", ACCEPTANCE_DIFF, "diff", (HERE / "gate.sh").as_posix(), f"{wt}/{n}", str(n)],
                                   env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
                diff = r.stdout[:8000] if r.returncode == 0 else ""
            except (OSError, subprocess.TimeoutExpired):
                diff = ""
            self._diffs[(p, n)] = (time.time(), diff)
        return diff

    def pull(self, p, number):
        """The card's pull request as GitHub has it now: its size and whether its checks passed."""
        at, pr = self._prs.get((p, number), (0, None))
        if time.time() - at > 60:
            repo = shipfloor_config.dotted(self.config(p), "project.repo")
            d, _ = gh_json("pr", "view", str(number), "--repo", str(repo), "--json", "number,url,additions,deletions,changedFiles,statusCheckRollup")
            if isinstance(d, dict):
                checks = [(c.get("conclusion") or c.get("state") or c.get("status") or "").upper() for c in d.get("statusCheckRollup") or []]
                ci = ("none" if not checks else "failed" if any(c in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED") for c in checks)
                      else "green" if all(c in ("SUCCESS", "NEUTRAL", "SKIPPED") for c in checks) else "running")
                pr = {"number": d.get("number"), "url": d.get("url"), "files": d.get("changedFiles"),
                      "additions": d.get("additions"), "deletions": d.get("deletions"), "ci": ci}
            self._prs[(p, number)] = (time.time(), pr)
        return pr

    def decide(self, p, n):
        """What the owner reads to decide a card that waits: its spec, why it is blocked, its pull request and
        what the last validation said."""
        reports = self.reports(p, n)
        number = next((r["pr"] for r in reversed(reports) if isinstance(r.get("pr"), int)), None)
        return {"spec": self.spec(p, n), "block": self.block(p, n) if self.blocked(p).get(n) else None,
                "pr": self.pull(p, number) if number else None,
                "report": next((r for r in reversed(reports) if r["pipeline"] == "validate"), None)}

    def unblock(self, p, n):
        repo = shipfloor_config.dotted(self.config(p), "project.repo")
        errors = []
        for label in ("blocked", "blocked:infra"):
            r = gh("api", "-X", "DELETE", f"repos/{repo}/issues/{n}/labels/{label}")
            if r.returncode != 0 and "Label does not exist" not in r.stderr and "404" not in r.stderr:
                errors.append(r.stderr.strip())
        self._blocked.pop(p, None); self._reasons.pop((p, n), None)
        return (502, {"error": "; ".join(errors)}) if errors else (200, {"unblocked": True})

    def reports(self, p, n):
        out = []
        for f in sorted((self.pdir(p) / "reports-wt" / "reports").glob(f"{n}-*/*.json")):
            try:
                r = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            out.append({"file": f.name, "pipeline": r.get("pipeline") or r.get("phase"), "outcome": r.get("outcome"), "pr": r.get("pr"),
                        "gates": r.get("gates") or {}, "failed_gates": r.get("failed_gates") or r.get("gates_failed") or [],
                        "rounds": r.get("rounds"),
                        "notes": "\n".join(r["notes"]) if isinstance(r.get("notes"), list) else r.get("notes") or ""})
        return out

    def card(self, p, n):
        prices, runs = self.prices(), self.runs(p, issue=n)
        sessions = []
        for s in self.sessions(p, n):
            start = parse_ts(s["start"])
            run = next((r for r in reversed(runs) if r["stage"] == s["stage"]
                        and parse_ts(r["start"]).timestamp() <= start.timestamp() + 120), None)
            c = self.session_cost(s, prices)
            sessions.append({"id": s["id"], "stage": s["stage"], "start": s["start"], "end": s["end"],
                             "tokens": s["tokens"], "cost": None if c is None else round(c, 4),
                             "subagents": [{"tokens": a["tokens"], "cost": cost(a["tokens"], prices)} for a in s["subagents"]],
                             "exit": run and run["exit"], "log": run and run["log"]})
        costs = [s["cost"] for s in sessions]
        columns, _ = self.board(p)
        reports = self.reports(p, n)
        return {"project": p, "issue": n, "title": self.titles(p, [*columns, n]).get(n, ""), "column": columns.get(n),
                "repo": shipfloor_config.dotted(self.config(p), "project.repo"),
                "total": None if None in costs else round(sum(costs), 2), "sessions": sessions, "runs": runs,
                "reports": reports, "review": (self.pdir(p) / "reviews" / f"{n}.html").is_file(),
                "blocked": self.blocked(p).get(n),
                "block_reason": self.block_reason(p, n) if self.blocked(p).get(n) else ""}

    def pool(self):
        m = shipfloor_config.merged(read_yaml(self.home / "config.yml"), shipfloor_config.MACHINE_DEFAULTS)
        return m["pool"], m["stages"]

    def settings(self):
        """What the Settings view shows: this machine's limits (config.yml), the pauses, the dispatcher's last
        cycle, and each project's factory.yml as the dispatcher last read it from the project's repository."""
        m = shipfloor_config.merged(read_yaml(self.home / "config.yml"), shipfloor_config.MACHINE_DEFAULTS)
        cycle = None
        try:  # the health history has one line per dispatcher cycle
            with open(sorted((self.home / "logs").glob("health-*.jsonl"))[-1], encoding="utf-8") as f:
                last = json.loads(deque(f, maxlen=1)[0])
            cycle = {"at": last.get("ts"), "took_s": (last.get("cycle") or {}).get("s"), "exit": (last.get("cycle") or {}).get("exit")}
        except (OSError, ValueError, IndexError):
            pass
        registry = {c[0]: c for c in (l.split("\t") for l in self.registry()) if c[0]}
        projects = []
        for p in self.projects():
            repo, row = self.config(p), registry.get(p, [])
            cfg, _ = shipfloor_config.with_overrides(repo, shipfloor_config.overrides_of(str(self.pdir(p) / "factory.yml")))
            knob = lambda c, k: next((v for v in [shipfloor_config.dotted(c, k)] if v is not None), KNOBS[k])
            projects.append({"slug": p, "paused": (self.pdir(p) / "PAUSE").exists(), "main": row[3] if len(row) > 3 else "main",
                             "repo": shipfloor_config.dotted(cfg, "project.repo"), "board": cfg.get("board"), "board_url": self.board_url(p),
                             "knobs": {k: {"value": knob(cfg, k), "repo": knob(repo, k)} for k in KNOBS}, "context": cfg.get("context") or [],
                             "stack": cfg.get("stack") or {}, "deploy": cfg.get("deploy") or {},
                             "layers": [{k: l.get(k) for k in ("name", "path", "stack", "build", "test", "tests", "tests_only", "needs_stack")}
                                        for l in cfg.get("layers") or [] if isinstance(l, dict)]})
        every = shipfloor_config.dispatcher_every(read_yaml(self.home / "config.yml"))
        if cycle and cycle["at"] and cycle["took_s"] is not None:  # the next one starts `every` minutes after the last one started
            try:
                cycle["next_at"] = (parse_ts(cycle["at"]) - timedelta(seconds=cycle["took_s"]) + timedelta(minutes=every)).isoformat()
            except (ValueError, TypeError, AttributeError):
                pass
        if cycle:
            cycle.setdefault("next_at", None)
        command, why = scheduler()
        return {"machine": {k: m[k] for k in ("pool", "stages", "stacks", "stack_wait")}, "paused": (self.home / "PAUSE").exists(),
                "dispatcher": {"every_min": every, "choices": list(shipfloor_config.DISPATCHER_EVERY), "can_set": bool(command), "why": why},
                "cycle": cycle, "projects": projects, "prices": self.prices(), "models": self.models()}

    def project_agents(self):
        """{agent: [{project, layer}]} for every agent a registered project's layer names."""
        out = {}
        for p in self.projects():
            for l in self.config(p).get("layers") or []:
                if isinstance(l, dict) and isinstance(l.get("agent"), str):
                    out.setdefault(l["agent"], []).append({"project": p, "layer": l.get("name")})
        return out

    def models(self):
        """The Settings rows for the models: each stage and agent with its configured model, today's model, whether
        the model has a price, and (stages) the mean cost per card of the last 7 days."""
        raw, agents, prices = read_yaml(self.home / "config.yml"), self.project_agents(), self.prices()
        problems = shipfloor_config.model_problems(raw, agents)
        bad, configured = {p["key"] for p in problems}, raw.get("models") if isinstance(raw.get("models"), dict) else {}
        def row(group, name, default):
            entries = configured.get(group) if isinstance(configured.get(group), dict) else {}
            value = None if f"models.{group}.{name}" in bad else entries.get(name)
            return {"value": value, "default": default, "priced": value is None or any(k.startswith(f"claude-{value}-") for k in prices)}
        since, runs = datetime.now(timezone.utc) - timedelta(days=7), {s: [] for s in shipfloor_config.STAGES}
        for p in self.projects():
            for s in self.sessions(p):
                if s["stage"] in runs and parse_ts(s["start"]) >= since:
                    runs[s["stage"]].append(((p, s["issue"]), self.session_cost(s, prices)))
        return {"choices": list(shipfloor_config.MODELS),
                "stages": {st: dict(row("stages", st, shipfloor_config.STAGE_MODELS[st]), cost=per_card(runs[st])) for st in shipfloor_config.STAGES},
                "agents": {**{a: dict(row("agents", a, d), projects=[]) for a, d in shipfloor_config.PLUGIN_AGENTS.items()},
                           **{a: dict(row("agents", a, None), projects=ps) for a, ps in agents.items() if a not in shipfloor_config.PLUGIN_AGENTS}},
                "problems": problems}

    def registry(self):
        try:
            return (self.home / "registry.tsv").read_text(encoding="utf-8").splitlines()
        except OSError:
            return []

    def set_machine(self, changes):
        """The owner's new limits for this machine, all at once so a pool and its stages are checked together.
        Whatever else config.yml holds stays as it is. The dispatcher reads the file on its next cycle."""
        path, old = self.home / "config.yml", read_yaml(self.home / "config.yml")
        new = json.loads(json.dumps(old))
        if not isinstance(new, dict) or not isinstance(changes, dict):
            return 400, {"error": "config.yml is not a YAML mapping; fix it by hand"}
        for k in ("pool", "stacks", "stack_wait"):
            if k in changes:
                new[k] = changes[k]
        if isinstance(changes.get("stages"), dict):
            new["stages"] = dict(new["stages"] if isinstance(new.get("stages"), dict) else {}, **changes["stages"])
        if isinstance(changes.get("dispatcher"), dict) and "every_min" in changes["dispatcher"]:
            new["dispatcher"] = dict(new["dispatcher"] if isinstance(new.get("dispatcher"), dict) else {}, every_min=changes["dispatcher"]["every_min"])
        errs = shipfloor_config.machine_problems(new)
        if isinstance(changes.get("models"), dict):
            models = new["models"] if isinstance(new.get("models"), dict) else {}
            for group in ("stages", "agents"):
                if isinstance(changes["models"].get(group), dict):
                    rows = dict(models[group] if isinstance(models.get(group), dict) else {}, **changes["models"][group])
                    models[group] = {n: m for n, m in rows.items() if m is not None}
            new["models"] = {g: rows for g, rows in models.items() if rows != {}}
            if not new["models"]:
                del new["models"]
            agents = self.project_agents()
            before = shipfloor_config.model_problems(old, agents)
            errs += [f"{p['key']}: not a stage or an agent here. Nothing was saved." if p["why"] == "name"
                     else f"{p['key']}: must be a mapping. Nothing was saved." if p["why"] == "shape"
                     else f"{p['key']}: \"{p['value']}\" is not a model the factory knows. Nothing was saved."
                     for p in shipfloor_config.model_problems(new, agents) if p not in before]
        if errs:
            return 400, {"error": "; ".join(errs)}
        every = shipfloor_config.dispatcher_every(new)
        if every != shipfloor_config.dispatcher_every(read_yaml(path)):  # the task is told first: if it refuses, nothing is saved
            command, why = scheduler()
            if not command:
                return 409, {"error": why}
            try:
                r = subprocess.run([*command, str(every)], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
                lines = [l.strip() for l in (r.stdout + "\n" + r.stderr).splitlines() if l.strip()]
                if r.returncode != 0:
                    return 409, {"error": (lines or [f"the scheduler exited {r.returncode}"])[-1]}
            except subprocess.TimeoutExpired:
                return 409, {"error": "the scheduler did not answer in 60 seconds"}
            except OSError as e:
                return 409, {"error": f"the scheduler could not start: {e}"}
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("# shipfloor machine config: runs at once on this machine (pool) and per stage\n")
            yaml.safe_dump(new, f, sort_keys=False)
        return 200, self.settings()

    def set_project(self, project, values):
        """The owner's overrides of a project's operational limits on this machine: {knob: number, or null to go
        back to what the repository says}. Kept in the project's overrides.yml, which the config readers lay over
        factory.yml; checked with the whole config before it is written."""
        if project not in self.projects() or not isinstance(values, dict) or not set(values) <= set(KNOBS):
            return 400, {"error": "unknown project or setting"}
        path, repo = self.pdir(project) / "overrides.yml", self.config(project)
        over = read_yaml(path)
        over = json.loads(json.dumps(over)) if isinstance(over, dict) else {}
        for key, v in values.items():
            *parents, leaf = key.split(".")
            at = over
            for k in parents:
                at = at.setdefault(k, {})
            if v is None:
                at.pop(leaf, None)
            else:
                at[leaf] = v
        prune = lambda d: {k: w for k, w in ((k, prune(w) if isinstance(w, dict) else w) for k, w in d.items()) if w != {}}
        over = prune(over)
        new, errs = shipfloor_config.with_overrides(repo, over)
        errs += [e for e in shipfloor_config.problems(new) if e not in shipfloor_config.problems(repo)] if over else []
        if errs:
            return 400, {"error": "; ".join(errs)}
        if over:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write("# this machine's overrides of the project's operational limits; set in the dashboard's Settings\n")
                yaml.safe_dump(over, f, sort_keys=False)
        else:
            path.unlink(missing_ok=True)
        return 200, self.settings()

    def set_pause(self, project, paused):
        """Pause or resume the whole factory (no project) or one project: the PAUSE file `shipfloor pause` writes."""
        if project is not None and project not in self.projects():
            return 404, {"error": f"no project {project}"}
        f = (self.pdir(project) if project else self.home) / "PAUSE"
        if paused:
            f.touch()
        else:
            f.unlink(missing_ok=True)
        return 200, self.settings()

    def live(self, p):
        out = []
        for d in (self.pdir(p) / "locks").glob("*-*.lock"):
            m = re.fullmatch(r"([a-z]+)-(\d+)\.lock", d.name)
            if not m or m.group(1) not in PIPELINES:  # deploysh-<n>.lock is the deploy script's own, inside the deploy run
                continue
            stage, n = m.group(1), int(m.group(2))
            try:
                epoch = int((d / "info").read_text().split()[1])
                started = datetime.fromtimestamp(epoch, timezone.utc).isoformat()
            except (OSError, ValueError, IndexError):
                started = None
            last = [r for r in self.runs(p, issue=n) if r["stage"] == stage][-1:]
            names, step = STEPS.get(stage, {}), None
            try:  # the step the run last announced, as its place among the stage's steps
                k, at = (d / "step").read_text().split()[:2]
                if int(k) in names:
                    step = {"i": sorted(names).index(int(k)) + 1, "label": names[int(k)],
                            "since": datetime.fromtimestamp(int(at), timezone.utc).isoformat()}
            except (OSError, ValueError):
                pass
            out.append({"project": p, "issue": n, "stage": stage, "started": started, "step": step, "steps": len(names),
                        "orphan": bool(last and last[0]["end"])})  # the run ended and left its lock
        return out

    def inbox(self, p, n):
        """The inbox of the run working on the card now, or None: the run's hook reads it (inbox_hook.py)."""
        run = next((r for r in self.live(p) if r["issue"] == n and not r["orphan"]), None)
        return run and self.pdir(p) / "locks" / f"{run['stage']}-{n}.lock" / "inbox"

    def session(self, p, n):
        """The card's latest session as it happens: the lead's and its subagents' steps in one timeline,
        and the owner's messages the lead has not read yet."""
        out = []
        for s in self.sessions(p, n)[-1:]:
            out = list(self.transcript(s["path"], events))
            for a in (s["path"].parent / s["id"] / "subagents").glob("*.jsonl"):
                out += [dict(e, sub=True) for e in self.transcript(a, events)]
        inbox, pending = self.inbox(p, n), []
        if inbox and inbox.is_file():
            seen = inbox.with_name("inbox.lead")
            pending = [json.loads(x) for x in inbox.read_text(encoding="utf-8").splitlines()][int(seen.read_text()) if seen.is_file() else 0:]
        return {"events": sorted(out, key=lambda e: e["ts"] or "")[-300:], "pending": pending, "running": bool(inbox)}

    def message(self, p, n, text):
        inbox = self.inbox(p, n)
        if not text.strip():
            return 400, {"error": "the message is empty"}
        if not inbox:
            return 409, {"error": "no run is working on this card now, so nobody would read the message"}
        with open(inbox, "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "text": text.strip()[:4000]}) + "\n")
        return 200, {"queued": True}

    def usage_limited(self):
        for log in self.home.glob("projects/*/logs/*.log"):
            if log.stat().st_mtime > time.time() - 1800:
                text = log.read_text(encoding="utf-8", errors="replace")
                if "hit your session limit" in text[max(0, text.rfind("== start")):]:
                    return True
        return False

    def overview(self):
        size, slots = self.pool()
        prices, today = self.prices(), datetime.now().date().isoformat()
        live, projects, finished, today_cost = [], [], [], 0.0
        for p in self.projects():
            runs = self.live(p)
            live += runs
            per_card, doing, hours = {}, {}, {}
            hour = lambda ts: parse_ts(ts).astimezone().hour
            all_runs, spent = self.runs(p), {}  # spent: what each of today's runs cost, by (log, start)
            for s in self.sessions(p):
                doing[(s["issue"], s["stage"])] = s["activity"]  # sessions come oldest first: the latest wins
                c = self.session_cost(s, prices)
                prev = per_card.get(s["issue"], 0.0)
                per_card[s["issue"]] = None if c is None or prev is None else prev + c
                if c and parse_ts(s["start"]).astimezone().date().isoformat() == today:
                    today_cost += c
                    # as in card(): a session belongs to the last run of its stage that started before it
                    run = next((r for r in reversed(all_runs) if r["issue"] == s["issue"] and r["stage"] == s["stage"]
                                and parse_ts(r["start"]).timestamp() <= parse_ts(s["start"]).timestamp() + 120), None)
                    if run:
                        spent[(run["log"], run["start"])] = spent.get((run["log"], run["start"]), 0.0) + c
                    hours.setdefault(hour(s["start"]), {"ok": 0, "failed": 0, "cost": 0.0})["cost"] += c
            for r in runs:
                r["activity"] = doing.get((r["issue"], r["stage"]), [])
            running = {r["issue"]: r["stage"] for r in runs if not r["orphan"]}
            columns, age = self.board(p)
            titles, blocked = self.titles(p, columns), self.blocked(p)
            # how long a stage usually takes (its clean runs) and when each card's last run ended
            took, since = {}, {}
            for r in all_runs:
                if r["end"]:
                    since[r["issue"]] = r["end"]
                    if r["log"].startswith(today):
                        hours.setdefault(hour(r["end"]), {"ok": 0, "failed": 0, "cost": 0.0})["ok" if r["exit"] == 0 else "failed"] += 1
                    if r["exit"] == 0:
                        took.setdefault(r["stage"], []).append((parse_ts(r["end"]) - parse_ts(r["start"])).total_seconds())
            projects.append({"slug": p, "paused": (self.pdir(p) / "PAUSE").exists(), "board_age_s": age,
                             "skipped": self.skipped(p),
                             "typical_s": {st: round(statistics.median(v)) for st, v in took.items()},
                             "hours": [dict(hours.get(h, {"ok": 0, "failed": 0, "cost": 0.0}), h=h)
                                       for h in range(min(hours, default=0), datetime.now().hour + 1)] if hours else [],
                             "ended": sorted((dict(r, cost=rounded(spent.get((r["log"], r["start"])))) for r in all_runs
                                              if r["end"] and r["log"].startswith(today)),
                                             key=lambda r: parse_ts(r["end"]), reverse=True)[:80],  # newest first
                             "repo": (self.config(p).get("project") or {}).get("repo"), "board_url": self.board_url(p),
                             "cards": [{"issue": n, "title": titles.get(n, ""), "column": col, "since": since.get(n),
                                        "cost": rounded(per_card.get(n, 0.0)),
                                        "running": running.get(n), "awaiting": col in OWNER_MOVES,
                                        "blocked": blocked.get(n)}
                                       for n, col in columns.items()]})
            finished += [r for r in self.runs(p, day=today) if r["end"]]
        used = {st: sum(1 for r in live if r["stage"] == st and not r["orphan"]) for st in slots}
        stacks, queue = self.stacks()
        return {"pool": {"size": size, "used": sum(used.values()),
                         "stages": {st: {"slots": slots[st], "running": used[st]} for st in slots}},
                "paused": (self.home / "PAUSE").exists(), "usage_limited": self.usage_limited(),
                "alerts": shipfloor_health.alerts(self.home),
                "runs": live, "projects": projects, "stacks": stacks, "queue": queue,
                "today": {"runs": len(finished), "ok": sum(r["exit"] == 0 for r in finished),
                          "failed": sum(r["exit"] != 0 for r in finished), "cost": round(today_cost, 2)}}

    def board_row(self, p, n):
        """(the card's row on the live board: number, column, item id; or None), or (None, error)."""
        env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)))
        snap = subprocess.run([bash(), (HERE / "board.sh").as_posix(), "snapshot"], env=env,
                              capture_output=True, text=True, encoding="utf-8")
        if snap.returncode != 0:
            return None, "cannot read the board: " + snap.stderr.strip()
        return next((c for c in (l.split("\t") for l in snap.stdout.splitlines()) if c[0] == str(n)), None), None

    def accept(self, p, n, text):
        """The owner takes the card's acceptance test edits as they stand (shipfloor accept), and the block comes off."""
        if not text.strip():
            return 400, {"error": "write why the edits are right: it is recorded with the acceptance"}
        r = subprocess.run([bash(), (HERE / "shipfloor").as_posix(), "accept", p, str(n), text.strip()],
                           env=dict(os.environ, SHIPFLOOR_HOME=str(self.home)), capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            return 502, {"error": "nothing accepted, the card is still blocked: " + (r.stderr.strip() or r.stdout.strip())}
        self._diffs.pop((p, n), None)
        code, body = self.unblock(p, n)
        return code, dict(body, accepted=r.stdout.strip())

    def send_back(self, p, n, text):
        """A blocked card goes back to Coding with the owner's note: the comment first, then the move, then the block
        comes off."""
        if not text.strip():
            return 400, {"error": "write what should be done"}
        if not self.blocked(p).get(n):
            return 409, {"error": f"#{n} is not blocked now"}
        cfg = self.config(p)
        owner, num, repo = (shipfloor_config.dotted(cfg, k) for k in ("board.owner", "board.number", "project.repo"))
        row, err = self.board_row(p, n)
        if err or not row:
            return (502, {"error": err}) if err else (409, {"error": f"#{n} is not on the board"})
        r = gh("issue", "comment", str(n), "--repo", str(repo), "--body-file", "-", input=text)
        if r.returncode != 0:
            return 502, {"error": "comment failed, nothing moved: " + r.stderr.strip()}
        err = None if row[1] == "Coding" else self.move(p, owner, num, row[2], "Coding")
        if err:
            return 502, {"error": err, "commented": True}
        code, body = self.unblock(p, n)
        return code, dict(body, moved_to="Coding")

    def act(self, p, n, action, seen, text, move_only):
        """The owner's approve / request-changes. Moves with gh directly: board.sh move refuses
        owner-only columns on purpose (the agents' guardrail), and an owner path there would be open to agents."""
        cfg = self.config(p)
        owner, num, repo = (shipfloor_config.dotted(cfg, k) for k in ("board.owner", "board.number", "project.repo"))
        row, err = self.board_row(p, n)
        if err:
            return 502, {"error": err}
        column = row[1] if row else None
        if column not in OWNER_MOVES or column != seen:
            return 409, {"error": f"#{n} is in {column or 'no column'} now", "column": column}
        target = OWNER_MOVES[column][action]
        # request-changes always says why; an approval may carry a note too (an answer to the spec's open question)
        commented = not move_only and (action == "request-changes" or bool(text.strip()))
        if commented:
            if not text.strip():
                return 400, {"error": "write what should change"}
            r = gh("issue", "comment", str(n), "--repo", str(repo), "--body-file", "-", input=text)
            if r.returncode != 0:
                return 502, {"error": "comment failed, nothing moved: " + r.stderr.strip()}
        err = self.move(p, owner, num, row[2], target)
        if err:
            return 502, {"error": err, "commented": commented}
        return 200, {"moved_to": target}

    def move(self, p, owner, num, item, target):
        fields, err = gh_json("project", "field-list", str(num), "--owner", owner, "--format", "json")
        if err:
            return "cannot read the board columns: " + err
        status = next((f for f in (fields or {}).get("fields", []) if f.get("name") == "Status"), None)
        if not status:
            return "the board has no Status field"
        try:
            project_id, field_id = (self.pdir(p) / "board-ids").read_text().split()[:2]
        except (OSError, ValueError):
            project, err = gh_json("project", "view", str(num), "--owner", owner, "--format", "json")
            if err:
                return "cannot read the board ids: " + err
            project_id, field_id = project.get("id", ""), status.get("id", "")
        option = next((o["id"] for o in status.get("options", [])
                       if re.sub(r"^[^A-Za-z]+ ", "", o.get("name", "")) == target), None)  # columns carry an owner mark
        if not option:
            return f"no column '{target}' on the board"
        r = gh("project", "item-edit", "--project-id", project_id, "--id", item,
               "--field-id", field_id, "--single-select-option-id", option)
        return None if r.returncode == 0 else "move failed: " + r.stderr.strip()

    def log(self, p, name, start):
        f = self.pdir(p) / "logs" / name
        if not re.fullmatch(r"[\w.-]+\.log", name) or ".." in name or not f.is_file():
            return None
        size = f.stat().st_size
        start = max(0, size - 65536) if start < 0 else min(start, size)
        with open(f, "rb") as fh:
            fh.seek(start)
            return {"text": fh.read(size - start).decode("utf-8", "replace"), "next": size}

    def lang(self):
        """The machine's language (~/.shipfloor/config.yml) and its catalog for the page, lang/dashboard.<code>.json:
        'exact' replaces a whole piece of text, 'rx' rewrites a phrase inside one. English has none."""
        code = str(read_yaml(self.home / "config.yml").get("language", "en"))
        f = HERE / "lang" / f"dashboard.{code}.json"
        try:
            cat = json.loads(f.read_text(encoding="utf-8")) if re.fullmatch(r"[A-Za-z-]{2,10}", code) else {}
        except (OSError, ValueError):
            cat = {}
        return {"language": code, "exact": cat.get("exact", {}), "rx": cat.get("rx", [])}

    def feed(self, limit=400):
        """One timeline: the dispatcher's and the stacks' log lines, and one line per run, at the time it
        ended (or started, while it still runs)."""
        out = []
        for source in ("dispatcher", "stacks"):
            f = self.home / "logs" / f"{source}.log"
            try:
                with open(f, "rb") as fh:
                    cut = max(0, f.stat().st_size - 65536)
                    fh.seek(cut)
                    lines = fh.read().decode("utf-8", "replace").splitlines()[1 if cut else 0:]
            except OSError:
                continue
            ts = ""  # a line with no time is a command's stderr: it happened at the timed line above it
            for line in lines:
                m = FEED_LINE.match(line)
                ts, text = m.groups() if m else (ts, line)
                if text.strip():
                    out.append({"ts": ts, "source": source, "text": text})
        today = datetime.now().date()
        for p in self.projects():
            for day in (today - timedelta(days=1), today):
                for r in self.runs(p, day=day.isoformat()):
                    out.append({"source": p, "issue": r["issue"], "log": r["log"], "start": r["start"], "end": r["end"],
                                "exit": r["exit"] if r["end"] else None, "ts": r["end"] or r["start"],
                                "text": f"{r['stage']} #{r['issue']}"})

        def at(e):
            try:
                return parse_ts(e["ts"]).timestamp()
            except (ValueError, TypeError):
                return 0.0
        return {"events": sorted(out, key=at)[-limit:]}  # the sort is stable: untimed lines keep their place


class Handler(BaseHTTPRequestHandler):
    factory, token = None, ""

    def log_message(self, *args):
        pass

    def send(self, code, body, kind="application/json", headers=()):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def allowed(self, query=None):
        """The API wants the token in a header, which a page cannot send cross-origin without a preflight
        this server never answers; only the review iframe's GET may carry it in the URL."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        given = self.headers.get("X-Shipfloor-Token") or (query or {}).get("t", [""])[0]
        return host in ("127.0.0.1", "localhost") and secrets.compare_digest(given.encode(), self.token.encode())

    def do_GET(self):
        url = urlparse(self.path)
        q, parts = parse_qs(url.query), [unquote(x) for x in url.path.strip("/").split("/")]
        if url.path == "/":
            return self.send(200, (HERE / "dashboard.html").read_bytes(), "text/html; charset=utf-8")
        if not self.allowed(q if parts[0] == "review" else None):
            return self.send(403, {"error": "missing or wrong token"})
        f = self.factory
        known = len(parts) > 2 and parts[2] in f.projects()
        try:
            if parts == ["api", "overview"]:
                return self.send(200, f.overview())
            if parts == ["api", "lang"]:
                return self.send(200, f.lang())
            if parts == ["api", "settings"]:
                return self.send(200, f.settings())
            if parts == ["api", "feed"]:
                return self.send(200, f.feed())
            if known and len(parts) == 4 and parts[:2] == ["api", "card"] and parts[3].isdigit():
                return self.send(200, f.card(parts[2], int(parts[3])))
            if known and len(parts) == 4 and parts[:2] == ["api", "decide"] and parts[3].isdigit():
                return self.send(200, f.decide(parts[2], int(parts[3])))
            if known and len(parts) == 4 and parts[:2] == ["api", "live"] and parts[3].isdigit():
                return self.send(200, f.session(parts[2], int(parts[3])))
            if known and len(parts) == 4 and parts[:2] == ["api", "log"]:
                start = q.get("from", ["-1"])[0]
                body = f.log(parts[2], parts[3], int(start) if start.lstrip("-").isdigit() else -1)
                if body:
                    return self.send(200, body)
            if len(parts) == 3 and parts[0] == "review" and parts[1] in f.projects() and parts[2].isdigit():
                page = f.pdir(parts[1]) / "reviews" / f"{parts[2]}.html"
                if page.is_file():
                    html = page.read_bytes()
                    if q.get("embed") == ["1"]:
                        html = html.replace(b"</head>", EMBED_CSS.encode() + b"</head>", 1)
                    # agents write these pages: sandboxed, they get an opaque origin and cannot call the API
                    return self.send(200, html, "text/html; charset=utf-8",
                                     [("Content-Security-Policy", "sandbox allow-scripts")])
        except Exception as e:  # one bad file must not take the page down
            return self.send(500, {"error": f"{type(e).__name__}: {e}"})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        parts = url.path.strip("/").split("/")
        if not self.allowed():
            return self.send(403, {"error": "missing or wrong token"})
        if parts in (["api", "settings", "machine"], ["api", "settings", "pause"], ["api", "settings", "project"]):
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                if parts[2] == "machine":
                    return self.send(*self.factory.set_machine(body))
                if parts[2] == "project":
                    return self.send(*self.factory.set_project(body.get("project"), body.get("values")))
                return self.send(*self.factory.set_pause(body.get("project"), bool(body.get("paused"))))
            except ValueError:
                return self.send(400, {"error": "body is not JSON"})
            except Exception as e:
                return self.send(500, {"error": f"{type(e).__name__}: {e}"})
        if not (len(parts) == 5 and parts[:2] == ["api", "card"] and parts[2] in self.factory.projects()
                and parts[3].isdigit() and parts[4] in ("approve", "request-changes", "unblock", "message", "accept", "send-back")):
            return self.send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            return self.send(400, {"error": "body is not JSON"})
        try:
            if parts[4] == "message":
                return self.send(*self.factory.message(parts[2], int(parts[3]), str(body.get("text", ""))))
            if parts[4] in ("accept", "send-back"):
                fn = self.factory.accept if parts[4] == "accept" else self.factory.send_back
                return self.send(*fn(parts[2], int(parts[3]), str(body.get("text", ""))))
            if parts[4] == "unblock":
                return self.send(*self.factory.unblock(parts[2], int(parts[3])))
            self.send(*self.factory.act(parts[2], int(parts[3]), parts[4], body.get("column"),
                                        str(body.get("text", "")), bool(body.get("move_only"))))
        except Exception as e:
            self.send(500, {"error": f"{type(e).__name__}: {e}"})


class Server(ThreadingHTTPServer):
    allow_reuse_address = os.name != "nt"  # on Windows SO_REUSEADDR lets a second server share the port


def main():
    a = argparse.ArgumentParser(prog="shipfloor dashboard")
    a.add_argument("--home", required=True)
    a.add_argument("--port", type=int, default=7717)
    a.add_argument("--no-open", action="store_true")
    args = a.parse_args()
    bash()
    Handler.factory = Factory(args.home, os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    Handler.token = secrets.token_urlsafe(16)
    server = None
    for port in [0] if args.port == 0 else range(args.port, args.port + 10):
        try:
            server = Server(("127.0.0.1", port), Handler)
            break
        except OSError:
            continue
    if not server:
        sys.exit(f"shipfloor dashboard: ports {args.port}-{args.port + 9} are taken")
    url = f"http://127.0.0.1:{server.server_address[1]}/?t={Handler.token}"
    print(f"shipfloor dashboard: {url}  (Ctrl+C stops it)", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
