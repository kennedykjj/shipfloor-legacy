"""Local dashboard: one page and a JSON API over ~/.shipfloor and the Claude Code transcripts of the
factory's runs. Read-only, except the owner's decisions on a card that waits, messages to a running card and this machine's
settings (the pool and the pauses)."""
import argparse, hashlib, json, os, re, secrets, shlex, shutil, statistics, subprocess, sys, threading, time, webbrowser
from collections import deque
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ in the installed scripts
sys.path.insert(0, str(HERE))
import shipfloor_config  # exits with a clear message when PyYAML is missing
from shipfloor_core.defaults import DEPLOY_DEFAULTS
import shipfloor_health
from shipfloor_core import board_history, deps
import dashboard_cost
import runtimes
from dashboard_cost import LEGACY_STAGES, cost, parse_transcript, parse_ts, per_card, rounded
import yaml

# The steps a run announces with `shipfloor-config.sh step <k>`: the numbered sections of each skill, less its failure rule.
STEPS = {"refine": {1: "Pick the card", 2: "Worktree", 3: "Product Owner", 4: "UX/UI and architecture", 5: "Cybersec", 6: "Publish for review", 8: "Report"},
         "develop": {1: "Pick the card", 2: "Plan", 3: "Acceptance tests", 4: "Implementation", 5: "Last gates", 6: "Hand over to validation", 8: "Report"},
         "validate": {1: "Pick the card", 2: "Gates", 3: "Review", 4: "Pull request", 6: "Report"}}
STACKS_TTL_S = 15
PIPELINES = set(LEGACY_STAGES.values())
# What the owner may set per project on this machine (overrides.yml), and what each is when nobody set it:
# the project config's defaults for the limits, the deploy's own (shipfloor_core/defaults.py) for the deploy.
KNOBS = {"limits.refine.wip": shipfloor_config.DEFAULTS["limits"]["refine"]["wip"],
         "limits.develop.wip": shipfloor_config.DEFAULTS["limits"]["develop"]["wip"],
         **{"deploy." + k: DEPLOY_DEFAULTS[k] for k in shipfloor_config.OVERRIDABLE_DEPLOY}}
#  how the skills open a block note: "Factory validate, step 2 (gates): blocked." or "Validate, step 2 (gates): ..."
BLOCK_LINE = re.compile(r"(?:Factory )?\b(refine|develop|validate|deploy),? step (\d+)(?:\s*\([^)\n]*\))?:?\s*(?:blocked\.?\s*)?", re.I)
# The acceptance test files of a card as they changed since its QA commit: what the acceptance-intact gate looks at.
ACCEPTANCE_DIFF = """qa="$(bash "$1" -C "$2" qa-commit "$3" 2>/dev/null)"; [ -n "$qa" ] || exit 0
mapfile -t files < <(git -C "$2" -c core.quotePath=false show --name-only --format= --diff-filter=d "$qa")
[ "${#files[@]}" -gt 0 ] && git -C "$2" -c core.quotePath=false diff --no-color -U1 "$qa" HEAD -- "${files[@]}"
"""
# The acceptance test files of the newest QA commit as they changed against the QA commit before it (what qa-amend counts).
AMEND_DIFF = """qa="$(bash "$1" -C "$2" qa-commit "$3" 2>/dev/null)"; [ -n "$qa" ] || exit 0
prev="$(git -C "$2" log --format=%H -1 -E --grep "acceptance tests for #$3([^0-9]|\\$)" "$qa^" 2>/dev/null)"; [ -n "$prev" ] || exit 0
mapfile -t files < <(git -C "$2" -c core.quotePath=false show --name-only --format= --diff-filter=d "$qa")
[ "${#files[@]}" -gt 0 ] && git -C "$2" -c core.quotePath=false diff --no-color -U1 "$prev" "$qa" -- "${files[@]}"
"""
COST_BLOCK = "Cost limit: blocked."  # how the dispatcher opens the note of a block by cost
BOARD_TTL_S = 10  # while someone watches, the board is read again this often
FEED_LINE = re.compile(r"^(\d{4}-\d\d-\d\dT\S+) (.*)")
RUN_LINE = re.compile(r"^== (start|end) /(?:sf|aghanim|mylos):([a-z]+) (\d+)(?: exit=(\d+))? (\S+)")  # legacy aghanim, legacy mylos
RUN_MODEL = re.compile(r" model=([a-z0-9.-]+)")  # the start line's model, when the dispatcher passed one
# the dispatcher's note that a develop run ended on a failed gate and the next one runs one model up
STEPUP_LINE = re.compile(r"^== step-up /sf:([a-z]+) (\d+) (\S+) -> (\S+): gate (\S+) failed")
WEIGHT_LINE = re.compile(r"^\*\*Weight:\*\*")
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
/* the dashboard's theme: listening and "ready" come first, while the page parses, so the colors land before it paints;
   "themed" says they were applied, and the dashboard shows the frame then; sends them again when the owner changes theme */
addEventListener("message",function(e){
 var m=e.data,r=document.documentElement;if(e.source!==parent||!m||m.shipfloor!=="theme")return;
 for(var k in m.vars)if(/^[a-z-]+$/.test(k))r.style.setProperty("--"+k,m.vars[k]);
 r.style.colorScheme=m.light?"light":"dark";
 parent.postMessage({shipfloor:"themed"},"*")});
parent.postMessage({shipfloor:"ready"},"*");
/* tells the dashboard how far the review went, so its Approve can say so (the page itself is sandboxed) */
addEventListener("load",function(){
 function send(){
  var c=document.getElementById("count");if(!c)return;
  var m=c.textContent.match(/(\\d+)\\s*of\\s*(\\d+)/);
  var chg=[].map.call(document.querySelectorAll(".item.chg"),function(it){
   var s=it.closest("section"),h=s&&s.querySelector("h2"),p=it.querySelector("p"),t=it.querySelector("textarea");
   return "- ["+(h?h.textContent:"")+"] "+(p?p.textContent:"")+"\\n  -> "+((t&&t.value.trim())||"(no note)")});
  parent.postMessage({shipfloor:"review-progress",done:m?+m[1]:0,total:m?+m[2]:0,changes:chg},"*");
  /* the marks go to the drawer too, which saves them on the server (st is the page's own top-level let) */
  try{var j=JSON.stringify(st);if(j!==last){last=j;parent.postMessage({shipfloor:"review-marks",rev:sv&&sv.rev,marks:st},"*")}}catch(e){}}
 /* the server's marks replace the browser's own before the first send, so a reopened review shows them */
 var last="",sv=window.__shipfloorMarks;
 try{if(sv&&sv.marks&&Object.keys(sv.marks).length&&typeof st!=="undefined"&&typeof render==="function"){st=sv.marks;render()}
  if(typeof st!=="undefined")last=JSON.stringify(st)}catch(e){}
 send();new MutationObserver(send).observe(document.body,{subtree:true,childList:true,characterData:true});
 document.addEventListener("input",send)});
</script>"""
# The labels a returned card's review page shows (#177), with their English text: the embedded page gets them in the
# machine's language with the theme (labels_block); the standalone page carries the English ones itself.
RV_LABELS = (shipfloor_config.Msg("rv.new", "New"), shipfloor_config.Msg("rv.changed", "Changed"),
             shipfloor_config.Msg("rv.removed", "Removed"), shipfloor_config.Msg("rv.before", "Before"),
             shipfloor_config.Msg("rv.request", "Your request"),
             shipfloor_config.Msg("rv.since", "{n, plural, one {# statement changed since your request} other {# statements changed since your request}}"),
             # the page's own controls: the counter, Copy review, Clear marks and each statement's Keep / Change
             shipfloor_config.Msg("rv.of", "of {n} reviewed"), shipfloor_config.Msg("rv.copy", "Copy review"),
             shipfloor_config.Msg("rv.copied", "copied"), shipfloor_config.Msg("rv.selected", "selected: press Ctrl+C"),
             shipfloor_config.Msg("rv.clear", "Clear marks"), shipfloor_config.Msg("rv.clear_confirm", "Confirm clear"),
             shipfloor_config.Msg("rv.keep", "Keep"), shipfloor_config.Msg("rv.change", "Change"),
             shipfloor_config.Msg("rv.what", "What to change?"))
# The moves the owner makes from the dashboard, M1 to M7 of #125: from -> [(to, a note is required)]. Nothing else moves
# a card from here. In Spec Review and Staged the move without a note is Approve, the one with a note Request changes.
OWNER_MOVES = {"Inbox": [("Ready for Refinement", False)],
               "Ready for Refinement": [("Inbox", False)],
               "Spec Review": [("Ready for Dev", False), ("Ready for Refinement", True)],
               "Ready for Dev": [("Ready for Refinement", True)],
               "Staged": [("Ready for Prod", False), ("Coding", True)]}
AWAITING = ("Spec Review", "Staged")  # the columns where the factory waits for the owner's decision
ORDERED = ("Inbox", "Ready for Refinement", "Ready for Dev")  # the owner sets their order (#128); the dispatcher takes from the top
LINED = (*ORDERED, "Ready for Prod")  # a card there shows its place in line
# Where a card blocked for the owner can be taken back (#127): from Coding or Validation there is code to redo from the
# approved spec; from any other column ("*") only the spec or the Inbox. The card's own column is never a target.
BLOCKED_MOVES = {"Coding": ("Inbox", "Ready for Refinement", "Ready for Dev"),
                 "Validation": ("Inbox", "Ready for Refinement", "Ready for Dev"),
                 "*": ("Inbox", "Ready for Refinement")}
HISTORY_DAYS = 92  # the longest period the History shows: past a quarter the bars of a day are too thin to read or click
HISTORY_PAGE = 50  # runs per page of the maximized History's table
LOCKED = {"run": "a run is in progress", "infra": "blocked by infrastructure, the factory retries",
          "blocked": "it is blocked and waits for your call in the card"}



def refused(errs):
    """A refusal: its reasons in English (error), and each one as the page translates it (errors): a shipfloor_config.Msg
    gives its key and values, any other reason only its text."""
    def one(e):
        if isinstance(e, shipfloor_config.Msg):
            return e.as_json()
        field = re.match(r"limits\.(memory_max|cpu_weight|cpu_quota)\b", str(e))  # the machine limits name their field
        return {"key": field.group(0), "text": str(e)} if field else {"text": str(e)}
    return {"error": "; ".join(errs), "errors": [one(e) for e in errs]}


def catalogs():
    """{code: the language's name in itself} for each code of LANGS that has a dashboard catalog, in LANGS' order."""
    out = {}
    for code in shipfloor_config.LANGS:
        try:
            out[code] = json.loads((HERE / "lang" / f"dashboard.{code}.json").read_text(encoding="utf-8"))["name"]
        except (OSError, ValueError, KeyError):
            pass
    return out


def catalog(code):
    """The messages of lang/dashboard.<code>.json, {} when there is none."""
    try:
        return json.loads((HERE / "lang" / f"dashboard.{code}.json").read_text(encoding="utf-8")).get("messages", {}) if code in shipfloor_config.LANGS else {}
    except (OSError, ValueError):
        return {}

def number(s):  # ASCII digits only: str.isdigit() also accepts "²" and the like, which int() rejects
    return bool(re.fullmatch(r"[0-9]+", s))


def history_period(today, days=None, start=None, end=None):
    """The period a History query asks for and its neighbours, as ISO dates: (period, None), or (None, why it is refused).
    days: the N days that end today; or start and end, both included. A day is a calendar day of this machine."""
    if start is not None or end is not None:
        if not all(isinstance(x, str) and re.fullmatch(r"\d{4}-\d\d-\d\d", x) for x in (start, end)):
            return None, "from and to must both be dates as YYYY-MM-DD"
        try:
            a, b = date.fromisoformat(start), date.fromisoformat(end)
        except ValueError:
            return None, "from and to must both be dates as YYYY-MM-DD"
        if b < a:
            return None, "the end date is before the start date"
        if b > today:
            return None, "that date is in the future"
    else:
        if days is not None and not (isinstance(days, str) and number(days)):
            return None, f"days must be 1 to {HISTORY_DAYS}"
        n = int(days or 1)
        if not 1 <= n <= HISTORY_DAYS:
            return None, f"days must be 1 to {HISTORY_DAYS}"
        a, b = today - timedelta(days=n - 1), today
    n = (b - a).days + 1
    if n > HISTORY_DAYS:
        return None, f"pick {HISTORY_DAYS} days at most"
    span = lambda x, y: {"from": x.isoformat(), "to": y.isoformat()}
    present = b == today
    last = min(b + timedelta(days=n), today)  # the next period never passes today: it ends there, the same length
    return {**span(a, b), "days": n, "unit": "hour" if n == 1 else "day", "present": present,
            "prev": span(a - timedelta(days=n), a - timedelta(days=1)),
            "next": None if present else span(last - timedelta(days=n - 1), last),
            "now": None if present else span(today - timedelta(days=n - 1), today)}, None


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


Msg = shipfloor_config.Msg
NO_TASK = Msg("disp.no_task", "Windows only: this machine has no ShipfloorDispatcher scheduled task. "
              "Its pace is set by whatever schedules the dispatcher here.")
NO_INSTALLER = Msg("disp.no_installer", "installer/install-dispatcher.sh is not on this machine, so the dispatcher's pace "
                   "cannot be changed from here. Its pace is set by whatever schedules the dispatcher.")
NOT_REGISTERED = Msg("disp.not_registered", "The dispatcher is not registered on this machine. Register it with "
                     "bash installer/install-dispatcher.sh, then set its pace here.")
_reg = {"at": 0.0, "value": None, "env": None}
_reg_lock = threading.Lock()


def registration():
    """The installed registration (shipfloor_health.registration), read again at most every 15 s: the overview asks for
    it every 2 s and the status runs the installer."""
    env = os.environ.get("SHIPFLOOR_INSTALLER_STATUS")
    with _reg_lock:
        if time.monotonic() - _reg["at"] > 15 or _reg["at"] == 0.0 or _reg["env"] != env:
            _reg["env"] = env
            try:
                sh = bash()
            except SystemExit:
                sh = None
            _reg["value"], _reg["at"] = shipfloor_health.registration(sh), time.monotonic()
        return _reg["value"]


def forget_registration():
    with _reg_lock:
        _reg["at"] = 0.0


def scheduler():
    """(the command that sets the dispatcher's pace, None) or (None, why there is none, a Msg). The minutes go last.
    SHIPFLOOR_SCHEDULER (split like a command line) overrides; "none" says there is no scheduler; else on Windows the
    installer script re-registers the task, on Linux and macOS install-dispatcher.sh re-registers its timer, agent or
    cron line (only one that is registered: Settings never registers the dispatcher by itself)."""
    given = os.environ.get("SHIPFLOOR_SCHEDULER")
    if given is not None:
        try:
            parts = [] if given.strip() == "none" else shlex.split(given)
        except ValueError:
            parts = []
        return (parts, None) if parts else (None, NO_TASK if os.name == "nt" else NO_INSTALLER)
    if os.name != "nt":
        script = installer_script()
        if not script.is_file():
            return None, NO_INSTALLER
        if not (registration() or {}).get("kind"):  # nothing registered, or a status it could not read
            return None, NOT_REGISTERED
        return [bash(), str(script), "--every-min"], None
    try:  # the installed copy records the checkout it came from; a checkout is its own source
        source = (HERE / ".source").read_text(encoding="utf-8").strip() or str(HERE.parent)
    except OSError:
        source = str(HERE.parent)
    return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(Path(source) / "installer" / "install-dispatcher.ps1"), "-EveryMin"], None


def pace_now(home):
    """The minutes between cycles the dispatcher runs at: the installed registration's pace where it can be read, else
    dispatcher.every_min of config.yml (Windows, or nothing registered)."""
    return shipfloor_health.registered_every(registration()) or shipfloor_config.dispatcher_every(read_yaml(Path(home) / "config.yml"))


def dispatcher_choices(now=None):
    """The paces Settings offers: Windows' Task Scheduler and cron repeat at most once a minute, so they have no 30 seconds;
    a pace the registration runs at that is not a choice is offered too, so the select can show it."""
    reg = registration() if os.name != "nt" else None
    out = [c for c in shipfloor_config.DISPATCHER_EVERY if c >= 1 or (os.name != "nt" and (reg or {}).get("kind") != "cron")]
    return sorted(out + [now]) if now is not None and now not in out else out


NO_LIMITS = "Resource limits are applied on Linux with systemd only. They are saved but not applied here."


def installer_script():
    try:  # the installed copy records the checkout it came from; a checkout is its own source
        source = (HERE / ".source").read_text(encoding="utf-8").strip() or str(HERE.parent)
    except OSError:
        source = str(HERE.parent)
    return Path(source) / "installer" / "install-dispatcher.sh"


def limits_applier():
    """The command that installs the dispatcher with the machine's limits (the flags go last), or None where there is
    none. SHIPFLOOR_LIMITS_APPLIER (split like a command line) overrides, "none" says there is none; else on Linux
    install-dispatcher.sh; elsewhere the limits are saved and not applied."""
    given = os.environ.get("SHIPFLOOR_LIMITS_APPLIER")
    if given is not None:
        try:
            return None if given.strip() == "none" else shlex.split(given) or None
        except ValueError:
            return None
    return [bash(), str(installer_script())] if sys.platform.startswith("linux") else None


def limits_in_effect():
    """{memory_max, cpu_weight, cpu_quota} the installed systemd unit carries (None for none), or None when there is no
    such unit or this system has no limits to read."""
    if not sys.platform.startswith("linux"):
        return None
    line = ((registration() or {}).get("limits") or "").strip()
    if line == "limits: none":
        return dict.fromkeys(shipfloor_config.LIMIT_KEYS)
    pairs = dict(w.split("=", 1) for w in line[len("limits:"):].split() if "=" in w)
    if not pairs:
        return None
    return {k: None if pairs.get(k, "none") == "none" else pairs[k] for k in shipfloor_config.LIMIT_KEYS}


def silent_banner(home):
    """The overview's "silent": how long the dispatcher has been quiet and the platform's commands to check and
    reinstall its scheduled job; None while the newest health line is within 3x the pace (the one it runs at)."""
    s = shipfloor_health.silence(home, pace_now(home))
    if not s:
        return None
    try:  # as scheduler(): the installed copy records the checkout it came from
        source = (HERE / ".source").read_text(encoding="utf-8").strip() or str(HERE.parent)
    except OSError:
        source = str(HERE.parent)
    installer = Path(source) / "installer"
    if os.name == "nt":
        check = "Get-ScheduledTask -TaskName ShipfloorDispatcher"
        reinstall = f"powershell -File {installer / 'install-dispatcher.ps1'}"
    else:
        check = f"bash {installer / 'install-dispatcher.sh'} --status"
        reinstall = f"bash {installer / 'install-dispatcher.sh'}"
    return {"min": round(s["min"]), "every": s["every"], "check": check, "reinstall": reinstall}


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


def page_source():
    """dashboard.html as the browser gets it: the page is one self-contained file, but its twelve @font-face rules are
    woff2 data URIs (~270 KB of base64) that nobody edits, so the source keeps them in fonts/dashboard-fonts.css and
    the `/*@dashboard-fonts*/` line of the page's <style> stands for them. An agent reading or editing the page never
    has to read the fonts."""
    html = (HERE / "dashboard.html").read_text(encoding="utf-8")
    fonts = (HERE / "fonts" / "dashboard-fonts.css").read_text(encoding="utf-8")
    return html.replace("/*@dashboard-fonts*/\n", fonts, 1)


def clean_deploys(runs):
    """{issue: end} of the last clean deploy each card had among these runs: what "done" means in the History's totals
    and on the belt (#B2)."""
    done = {}
    for r in runs:
        if r["stage"] == "deploy" and r["exit"] == 0 and r["end"] and (r["issue"] not in done or parse_ts(r["end"]) > parse_ts(done[r["issue"]])):
            done[r["issue"]] = r["end"]
    return done


def done_on(runs, day):
    """The cards done on a local date (YYYY-MM-DD): a clean deploy that ended that day, as the History's Today counts them."""
    return clean_deploys([r for r in runs if r["end"] and parse_ts(r["end"]).astimezone().date().isoformat() == day])


class Factory:
    def __init__(self, home, claude_dir):
        self.home, self.claude_dir = Path(home), Path(claude_dir)
        self._transcripts, self._titles, self._blocked, self._reasons, self._boards = {}, {}, {}, {}, {}
        self._diffs, self._prs, self._opened = {}, {}, {}
        self._stacks = (0.0, [], 0)
        self._configs = {}
        self._snap, self._reading, self._retry = {}, set(), {}
        self._entered = {}

    def projects(self):
        try:
            lines = (self.home / "registry.tsv").read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        return [line.split("\t")[0] for line in lines if line.strip()]

    def pdir(self, p):
        return self.home / "projects" / p

    def page_rev(self, p, n):
        """First 16 hex of the page's SHA-256: a rebuilt page has another rev, so old marks stop applying. None without a page."""
        try:
            return hashlib.sha256((self.pdir(p) / "reviews" / f"{n}.html").read_bytes()).hexdigest()[:16]
        except OSError:
            return None

    def marks_block(self, p, n):
        """The <script> that hands the stored marks to the embedded page. < > & are escaped so a note cannot close the script."""
        rev, marks = self.page_rev(p, n), {}
        try:
            d = json.loads((self.pdir(p) / "reviews" / f"{n}.marks.json").read_text(encoding="utf-8"))
            if rev and d.get("rev") == rev and isinstance(d.get("marks"), dict):
                marks = d["marks"]
        except (OSError, ValueError, AttributeError):
            pass
        j = json.dumps({"rev": rev, "marks": marks}).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
        return f"<script>window.__shipfloorMarks={j}</script>"

    def labels_block(self):
        """The <script> that hands the embedded page the labels of a returned card (RV_LABELS) in the machine's language,
        English where its catalog lacks one: the page is sandboxed and cannot read the dashboard's catalogs itself."""
        lang = self.lang()
        messages = {m.key: lang["messages"].get(m.key) or lang["en"].get(m.key) or str(m) for m in RV_LABELS}
        j = json.dumps({"language": lang["language"], "messages": messages}, ensure_ascii=False)
        j = j.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
        return f"<script>window.__shipfloorLabels={j}</script>"

    def save_marks(self, p, n, body):
        """Keeps the Keep/Change marks of a review page (reviews/<n>.marks.json). Nothing is stored on a refusal."""
        rev = self.page_rev(p, n)
        if rev is None:
            return 404, {"error": "no review page"}
        m = body.get("marks") if isinstance(body, dict) else None
        if not isinstance(m, dict) or len(m) > 500 or not isinstance(body.get("rev"), str):
            return 400, {"error": "marks are not in the expected shape"}
        for k, v in m.items():
            if not (re.fullmatch(r"[a-z0-9-]{1,80}", k) and isinstance(v, dict) and v.get("s") in ("ok", "chg")
                    and isinstance(v.get("n"), str) and len(v["n"]) <= 2000):
                return 400, {"error": f"mark '{k[:80]}' is not valid"}
        if body["rev"] != rev:
            return 409, {"error": "the page changed since these marks were made"}
        f = self.pdir(p) / "reviews" / f"{n}.marks.json"
        if not m:
            f.unlink(missing_ok=True)
            return 200, {"ok": True}
        tmp = f.with_name(f"{n}.marks.json.tmp")
        tmp.write_text(json.dumps({"rev": rev, "marks": {k: {"s": v["s"], "n": v["n"]} for k, v in m.items()}}), encoding="utf-8")
        os.replace(tmp, f)
        return 200, {"ok": True}

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
        return dashboard_cost.load_prices(self.home)

    def costs(self):
        """The machine's cost limits in US$ (config.yml), None for a limit that is absent or not a valid number."""
        raw = read_yaml(self.home / "config.yml")
        raw = raw.get("costs") if isinstance(raw, dict) else None
        raw = raw if isinstance(raw, dict) else {}
        return {k: raw[k] if k in raw and not shipfloor_config.cost_problems({k: raw[k]}) else None
                for k in shipfloor_config.COST_KEYS}

    def transcript(self, path, parse=parse_transcript):
        st = path.stat()
        key, hit = (st.st_size, st.st_mtime), self._transcripts.get((path, parse))
        if not hit or hit[0] != key:
            hit = self._transcripts[(path, parse)] = (key, parse(path))
        return hit[1]

    def sessions(self, p, issue=None):
        found = runtimes.sessions(p, self.transcript, {"claude-code": self.claude_dir})
        return [s for s in found if issue in (None, s["issue"])]

    def runs(self, p, issue=None, day=None):
        """Runs as the dispatcher logged them: == start / == end lines, the model each one started with, and the
        step-up between a run that failed a gate and the one that ran again one model up."""
        out, pending = [], {}
        for log in sorted((self.pdir(p) / "logs").glob("*.log")):
            if issue is not None and not re.fullmatch(rf"\d{{4}}-\d\d-\d\d-{issue}-[a-z]+\.log", log.name):
                continue
            if day and not log.name.startswith(day + "-"):
                continue
            with open(log, encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = RUN_LINE.match(line)
                    up = None if m else STEPUP_LINE.match(line)
                    if up:
                        stage, n, frm, to, gate = up.groups()
                        pending[(stage, int(n))] = {"from": frm, "to": to, "gates": [gate]}
                        if out and out[-1]["log"] == log.name:
                            out[-1]["again"] = to
                        continue
                    if not m:
                        continue
                    kind, stage, n, rc, ts = m.groups()
                    if kind == "start":
                        stage, model = LEGACY_STAGES.get(stage, stage), RUN_MODEL.search(line)
                        out.append({"stage": stage, "issue": int(n), "start": ts, "end": None, "exit": None, "log": log.name,
                                    "model": model and model.group(1), "stepped": pending.pop((stage, int(n)), None), "again": None})
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
        return {int(c[0]): c[1] for c in (l.split("\t") for l in lines) if len(c) > 1 and number(c[0])}, round(time.time() - at)

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
            fields = " ".join(f'i{int(n)}: issueOrPullRequest(number: {int(n)}) {{ ... on Issue {{ title createdAt }} ... on PullRequest {{ title createdAt }} }}' for n in batch)
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
            self._opened.setdefault(p, {}).update({n: (repo.get(f"i{n}") or {}).get("createdAt") for n in batch})
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
        if not self.pdir(p).is_dir():
            return [], 0  # no home directory yet (a cycle creates it): no slots to report, and nothing to cache
        env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)),
                   SHIPFLOOR_HOME=str(self.home))
        r = subprocess.run([bash(), (HERE / "gate.sh").as_posix(), "stack", "status"], env=env, cwd=str(self.pdir(p)),
                           capture_output=True, text=True, encoding="utf-8")
        slots, queue = [], 0
        for line in r.stdout.splitlines():
            f = line.split("\t")
            if f[0] == "queue":
                queue = int(f[1]) if number(f[1]) else 0
            elif len(f) >= 4 and number(f[0]):
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

    def me(self):
        """This factory's GitHub login, read once; None while it cannot be read."""
        if not getattr(self, "_me", None):
            user, _ = gh_json("api", "user")
            self._me = user.get("login") if isinstance(user, dict) else None
        return self._me

    def block_reason(self, p, n):
        """The factory's note about the block (the skills write the step, the output and what was tried there):
        among the issue's last comments, the newest that tells of a block or a failure, a stage's own note before
        its report. Read at most once a minute per card."""
        at, reason = self._reasons.get((p, n), (0, ""))
        if time.time() - at > 60:
            repo = shipfloor_config.dotted(self.config(p), "project.repo")
            pages, _ = gh_json("api", f"repos/{repo}/issues/{n}/comments?per_page=100", "--paginate", "--slurp")
            # anyone can comment on a public repository: the note is one the factory's user or a trusted commenter wrote
            me, who = self.me(), set(shipfloor_config.dotted(self.config(p), "trusted_commenters") or [])
            bodies = [c.get("body") or "" for page in pages or [] for c in (page if isinstance(page, list) else [page])
                      if isinstance(c, dict) and (not me or "*" in who or (c.get("user") or {}).get("login", me) in who | {me})]  # oldest first
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

    def cost_mark(self, p, n):
        """The figures of a block by the cost limit, from its marker cost/<n>.json; None when it cannot be read."""
        try:
            mark = json.loads((self.pdir(p) / "cost" / f"{n}.json").read_text(encoding="utf-8"))
            before, whole = float(mark.get("baseline") or 0), float(mark["total"])
            return {"limit": mark.get("limit"), "total": round(whole - before, 4), "baseline": before, "card_total": whole,
                    "stages": mark.get("stages") or {}}
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return None

    def block_line(self, p, n):
        """One plain line for the list: what the note says the owner must decide, else the gate that failed, else "".
        Taken from the note only, never composed; a block by the cost limit is told by its figures instead."""
        reason = self.block_reason(p, n)
        if reason.lstrip().startswith(COST_BLOCK):
            return ""
        plain = lambda t: " ".join(re.sub(r"^\s*[-*]\s*", "", t.replace("**", "").replace("`", "")).split())
        decide = next((l for l in reason.splitlines() if re.search(r"must decide|owner must|needs? you to", l, re.I)), "")
        decide = re.sub(r"^[^:]*(must decide|owner must|needs? you to)[^:]*:\s*", "", plain(decide), flags=re.I)
        if decide:
            return (decide[0].upper() + decide[1:])[:500]
        gate = re.search(r"failed gates?:\**\s*([^.\n]+)", reason, re.I)
        return f"Failed gate: {plain(gate.group(1))}"[:500] if gate and plain(gate.group(1)) else ""

    def block(self, p, n):
        """A block told in parts: the stage and step it stopped at, why, what was tried, how many times, and for
        acceptance-intact the test files as they changed."""
        reason = self.block_reason(p, n)
        blocked = [r for r in self.reports(p, n) if r["outcome"] == "blocked"]
        mark = self.cost_mark(p, n) if reason.lstrip().startswith(COST_BLOCK) else None  # the newest note must still be this block's
        if mark:
            return {"kind": "cost", "stage": None, "step": None, "steps": [], "why": reason.strip(), "tried": "",
                    "times": len(blocked), "gate": "", "diff": "", **mark}
        m = BLOCK_LINE.search(reason)
        stage, step = (m.group(1).lower(), int(m.group(2))) if m else (None, None)
        if not stage:  # a report tells the block: it names its stage, not a step
            stage = next(iter(re.findall(r"Factory report\W+(\w+)", reason)), "").lower() or None
        text = "\n".join(l for l in (reason[m.end():] if m else reason).splitlines() if not l.lstrip().startswith("|"))
        why, _, tried = text.partition("Tried:")
        intact = re.search(r"acceptance-intact\W{0,4}(?:gate\W+)?fail|fail\w*[^.\n]{0,60}acceptance-intact", reason, re.I)
        gate = "acceptance-intact" if intact or any("acceptance-intact" in str(r["failed_gates"]) for r in blocked[-1:]) else ""
        if "qa-amend" in reason and "the owner decides now" in reason:  # the extra amendment is the owner's call (#204)
            return {"kind": "stage", "stage": stage, "step": step, "steps": [{"k": k, "label": v} for k, v in sorted(STEPS.get(stage, {}).items())],
                    "why": why.strip(), "tried": tried.strip(), "times": len(blocked), "gate": "qa-amend",
                    "diff": self.acceptance_diff(p, n, AMEND_DIFF, "amend"), "approved": self.amend_ok(p, n)}
        return {"kind": "stage", "stage": stage, "step": step, "steps": [{"k": k, "label": v} for k, v in sorted(STEPS.get(stage, {}).items())],
                "why": why.strip(), "tried": tried.strip(), "times": len(blocked), "gate": gate,
                "diff": self.acceptance_diff(p, n) if gate else ""}

    def block_brief(self, p, n, kind):
        """What the list tells of a card the owner must unblock: block_line, and block_cost for a block by the cost limit."""
        if kind != "owner":
            return {"block_line": "", "block_cost": None}
        mark = self.cost_mark(p, n) if self.block_reason(p, n).lstrip().startswith(COST_BLOCK) else None
        return {"block_line": "" if mark else self.block_line(p, n),
                "block_cost": {k: mark[k] for k in ("total", "limit", "baseline")} if mark else None}

    def amend_ok(self, p, n):
        """Whether the issue already carries qa-amend-ok (added by hand): then the note keeps Unblock & retry."""
        repo = shipfloor_config.dotted(self.config(p), "project.repo")
        issue, _ = gh_json("api", f"repos/{repo}/issues/{n}")
        return any(isinstance(l, dict) and l.get("name") == "qa-amend-ok" for l in (issue or {}).get("labels") or [])

    def approve_amend(self, p, n):
        """The owner allows one more amendment of the card's acceptance tests: the label qa-amend-ok, then the block comes off.
        A label that cannot be written leaves the card blocked."""
        locked, err = self.lock(p, n)
        if err:
            return 502, {"error": err}
        if locked != "blocked":
            return 409, {"error": LOCKED[locked] if locked else "it is not blocked now", "locked": locked}
        repo = shipfloor_config.dotted(self.config(p), "project.repo")
        r = gh("api", f"repos/{repo}/issues/{n}/labels", "-f", "labels[]=qa-amend-ok")
        if r.returncode != 0:
            return 502, {"error": r.stderr.strip() or "gh could not add the label"}
        return self.unblock(p, n)

    def acceptance_diff(self, p, n, script=ACCEPTANCE_DIFF, kind=""):
        at, diff = self._diffs.get((p, n, kind) if kind else (p, n), (0, ""))
        if time.time() - at > 60:
            wt = next((c[2] for c in (l.split("\t") for l in (self.home / "registry.tsv").read_text(encoding="utf-8").splitlines())
                       if c[0] == p and len(c) > 2), "")
            env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)))
            try:
                r = subprocess.run([bash(), "-c", script, "diff", (HERE / "gate.sh").as_posix(), f"{wt}/{n}", str(n)],
                                   env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
                diff = r.stdout[:8000] if r.returncode == 0 else ""
            except (OSError, subprocess.TimeoutExpired):
                diff = ""
            self._diffs[(p, n, kind) if kind else (p, n)] = (time.time(), diff)
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

    def day(self, p):
        """Today's board history and the marks of the logbook line (#184): a finished run of today is ok, or bad when
        its report says blocked/infra or it exited non-zero; a card that left Spec Review/Staged (or another owner move
        of OWNER_MOVES) between two history lines is a decision at the later line. Keys only, never English. Read on every call."""
        today = datetime.now().astimezone().date()
        lines = board_history.day(self.pdir(p), today)
        reports = {}
        for f in (self.pdir(p) / "reports-wt" / "reports").glob("*-*/*.json"):
            m = re.fullmatch(r"(?P<stage>.+)-(?P<ts>\d{4}-\d\d-\d\dT\d{6})\.json", f.name)
            if not m:  # a report not stamped with its time (the demo's 01-refine.json) marks nothing
                continue
            try:
                at = datetime.strptime(m["ts"], "%Y-%m-%dT%H%M%S").astimezone()
                outcome = json.loads(f.read_text(encoding="utf-8")).get("outcome")
                issue = int(f.parent.name.split("-")[0])
            except (OSError, ValueError, AttributeError):
                continue
            reports.setdefault((issue, m["stage"]), []).append((at, outcome))
        marks = []
        for r in self.runs(p, day=today.isoformat()):
            if not r["end"]:
                continue
            start, end = parse_ts(r["start"]), parse_ts(r["end"])
            if end.astimezone().date() != today:
                continue
            outcomes = [o for at, o in reports.get((r["issue"], r["stage"]), []) if start <= at <= end + timedelta(seconds=60)]
            bad = r["exit"] != 0 or any(o in ("blocked", "infra") for o in outcomes)
            marks.append({"t": r["end"], "kind": "bad" if bad else "ok", "n": r["issue"], "stage": r["stage"],
                          "what": "blocked" if bad else "ended"})
        for before, after in zip(lines, lines[1:]):
            old, new = before.get("cards") or {}, after.get("cards") or {}
            for n, col in new.items():
                was = old.get(n)
                note = dict(OWNER_MOVES.get(was, ())).get(col) if was and was != col else None
                if was not in AWAITING or col not in dict(OWNER_MOVES[was]) or not number(n):
                    continue
                what = "requested-changes" if note else "approved-spec" if was == "Spec Review" else "approved-pr"
                marks.append({"t": after["t"], "kind": "decision", "n": int(n), "what": what})
        marks.sort(key=lambda m: parse_ts(m["t"]).timestamp())
        return {"date": today.isoformat(), "now": datetime.now().astimezone().isoformat(timespec="seconds"), "board": lines, "marks": marks}

    def brief(self, p, n):
        """The decision brief of a card (reviews/<n>.brief.json, made by #178): the parsed object, or None when the file
        is missing, unreadable, unparseable or not an object. Never raises."""
        try:
            b = json.loads((self.pdir(p) / "reviews" / f"{n}.brief.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return b if isinstance(b, dict) else None

    def brief_row(self, p, n, col):
        """The one-word verdict and the number of flags for the list row; only for the cards waiting on the owner."""
        b = self.brief(p, n) if col in AWAITING else None
        if not b:
            return {"verdict": None, "flags": 0}
        v, f = b.get("verdict"), b.get("flags")
        return {"verdict": v if v in ("routine", "look") else None, "flags": len(f) if isinstance(f, list) else 0}

    def card(self, p, n):
        prices, runs = self.prices(), self.runs(p, issue=n)
        sessions, found = [], self.sessions(p, n)
        for s in found:
            start = parse_ts(s["start"])
            run = next((r for r in reversed(runs) if r["stage"] == s["stage"]
                        and parse_ts(r["start"]).timestamp() <= start.timestamp() + 120), None)
            c = dashboard_cost.session_cost(s, prices)
            main = max(s["tokens"].items(), key=lambda kv: sum(v or 0 for v in kv[1].values()), default=(None, {}))[0]
            sessions.append({"id": s["id"], "stage": s["stage"], "start": s["start"], "end": s["end"],
                             "tokens": s["tokens"], "cost": None if c is None else round(c, 4),
                             "subagents": [{"tokens": a["tokens"], "cost": cost(a["tokens"], prices, a.get("cost"))} for a in s["subagents"]],
                             "exit": run and run["exit"], "log": run and run["log"],
                             "model": (run and run.get("model")) or main, "stepped": run and run.get("stepped")})
        total = dashboard_cost.spend(found, prices, datetime.now().date().isoformat())["cards"].get(n, {"total": 0.0})["total"]
        columns, _ = self.board(p)
        reports = self.reports(p, n)
        weight, weight_set = self.weight(p, n)
        return {"project": p, "issue": n, "title": self.titles(p, [*columns, n]).get(n, ""), "column": columns.get(n),
                "weight": weight, "weight_set": weight_set, "weight_models": self.weight_models(),
                "repo": shipfloor_config.dotted(self.config(p), "project.repo"),
                "total": rounded(total), "baseline": dashboard_cost.baselines(self.pdir(p)).get(n, 0.0), "sessions": sessions, "runs": runs,
                "reports": reports, "review": (self.pdir(p) / "reviews" / f"{n}.html").is_file(),
                "blocked": self.blocked(p).get(n), "brief": self.brief(p, n),
                "block_reason": self.block_reason(p, n) if self.blocked(p).get(n) else ""}

    def card_spec(self, p, n):
        """The card's spec in its worktree (<worktrees>/<n>/<specs>*-<slug>-design.md, the slug from the worktree's
        branch), as lib/project.sh's shipfloor_card_spec finds it; None when there is none yet."""
        row = next((c for c in (l.split("\t") for l in self.registry()) if c[0] == p), [])
        wt = Path(row[2] if len(row) > 2 and row[2] else self.pdir(p) / "wt") / str(n)
        try:
            head = (wt / ".git").read_text(encoding="utf-8").strip()
            git = Path(head[len("gitdir:"):].strip()) if head.startswith("gitdir:") else wt / ".git"
            branch = (git / "HEAD").read_text(encoding="utf-8").strip()
        except OSError:
            try:
                branch = ((wt / ".git" / "HEAD").read_text(encoding="utf-8").strip())
            except OSError:
                return None
        prefix = f"ref: refs/heads/feat/{n}-"
        if not branch.startswith(prefix) or len(branch) == len(prefix):
            return None
        specs = shipfloor_config.dotted(self.config(p), "paths.specs") or shipfloor_config.DEFAULTS["paths"]["specs"]
        found = sorted((wt / specs).glob(f"*-{branch[len(prefix):]}-design.md"))
        return found[0] if found else None

    def weight(self, p, n):
        """(weight, set): the weight the card's spec header names, standard when it names none (set False);
        (None, False) before the card has a spec."""
        spec = self.card_spec(p, n)
        if spec is None:
            return None, False
        try:
            lines = []
            for line in spec.read_text(encoding="utf-8").splitlines():
                if line.startswith("## "):
                    break
                if WEIGHT_LINE.match(line):
                    lines.append(line[len("**Weight:**"):].strip().strip("`"))
        except OSError:
            return None, False
        ok = len(lines) == 1 and lines[0] in shipfloor_config.WEIGHTS
        return (lines[0], True) if ok else ("standard", False)

    def weight_models(self):
        """{weight: model} Develop starts with now, from the machine config."""
        return dict(shipfloor_config.models_of(read_yaml(self.home / "config.yml"))["stages"]["develop"])

    def set_weight(self, p, n, weight):
        """The owner's weight for a card in Spec Review: `shipfloor weight` writes, commits and pushes the spec line."""
        if weight not in shipfloor_config.WEIGHTS:
            return 400, {"error": f"the weight is one of {', '.join(shipfloor_config.WEIGHTS)}"}
        r = subprocess.run([bash(), (HERE / "shipfloor").as_posix(), "weight", p, str(n), weight],
                           env=dict(os.environ, SHIPFLOOR_HOME=str(self.home)), capture_output=True, text=True, encoding="utf-8", errors="replace")
        why = re.sub(r"^shipfloor: ", "", (r.stderr.strip() or r.stdout.strip()).splitlines()[-1] if (r.stderr.strip() or r.stdout.strip()) else "")
        if r.returncode == 3:
            gone = shipfloor_config.Msg("err.not_spec_review", "the card is no longer in Spec Review.")
            return 409, refused([why]) if why and why != gone else refused([gone])
        if r.returncode != 0:
            return (400 if r.returncode == 2 else 500), {"error": why or f"shipfloor weight exited {r.returncode}"}
        return 200, {"weight": weight, "model": self.weight_models().get(weight)}

    def pool(self):
        m = shipfloor_config.merged(read_yaml(self.home / "config.yml"), shipfloor_config.MACHINE_DEFAULTS)
        return m["pool"], m["stages"]

    def hours(self):
        """The working hours as hours_state reads them now. Malformed, the windows are the value as written, one text each."""
        raw = read_yaml(self.home / "config.yml")
        state = shipfloor_config.hours_state(raw, shipfloor_config.now())
        if state["error"]:
            value = raw["hours"]
            state["windows"] = [str(w) for w in value] if isinstance(value, list) else [str(value)]
        return state

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
        projects, unpriced, today = [], 0, datetime.now().date().isoformat()
        for p in self.projects():
            columns, _ = self.board(p)
            known = dashboard_cost.spend(self.sessions(p), self.prices(), today)["cards"]
            unpriced += sum(1 for n in columns if n in known and known[n]["total"] is None)
            repo, row = self.config(p), registry.get(p, [])
            over = shipfloor_config.overrides_of(str(self.pdir(p) / "factory.yml"))
            cfg, _ = shipfloor_config.with_overrides(repo, over)
            knob = lambda c, k: next((v for v in [shipfloor_config.dotted(c, k)] if v is not None), KNOBS[k])
            projects.append({"slug": p, "paused": (self.pdir(p) / "PAUSE").exists(), "main": row[3] if len(row) > 3 else "main",
                             "repo": shipfloor_config.dotted(cfg, "project.repo"), "board": cfg.get("board"), "board_url": self.board_url(p),
                             "knobs": {k: {"value": knob(cfg, k), "repo": knob(repo, k)} for k in KNOBS}, "context": cfg.get("context") or [],
                             "stack": cfg.get("stack") or {}, "deploy": cfg.get("deploy") or {},
                             # code: in effect; repo: what factory.yml yields; from: who decided; set: factory.yml has the key
                             "language": {"code": cfg.get("language") or "en", "repo": repo.get("language") or "en",
                                          "from": "machine" if isinstance(over, dict) and "language" in over else "repository",
                                          "set": repo.get("language") is not None, "file": ".shipfloor/factory.yml"},
                             "layers": [{k: l.get(k) for k in ("name", "path", "stack", "build", "test", "tests", "tests_only", "needs_stack")}
                                        for l in cfg.get("layers") or [] if isinstance(l, dict)]})
        every = pace_now(self.home)
        if cycle and cycle["at"] and cycle["took_s"] is not None:  # the next one starts `every` minutes after the last one started
            try:
                cycle["next_at"] = (parse_ts(cycle["at"]) - timedelta(seconds=cycle["took_s"]) + timedelta(minutes=every)).isoformat()
            except (ValueError, TypeError, AttributeError):
                pass
        if cycle:
            cycle.setdefault("next_at", None)
        command, why = scheduler()
        saved = shipfloor_config.machine_limits(read_yaml(self.home / "config.yml").get("limits"))
        limits = {**{k: None if v == "none" else v for k, v in saved.items()}, "in_effect": limits_in_effect(),
                  "supported": limits_applier() is not None, "why": None if limits_applier() else NO_LIMITS}
        return {"machine": {**{k: m[k] for k in ("pool", "stages", "stacks", "stack_wait", "notify")}, "windows": os.name == "nt", "language": m.get("language") or "en", "costs": self.costs(), "limits": limits},
                "languages": catalogs(), "paused": (self.home / "PAUSE").exists(),
                "dispatcher": {"every_min": every, "choices": dispatcher_choices(every), "can_set": bool(command),
                               "why": str(why) if why else None, "why_msg": why.as_json() if why else None,
                               "configured": shipfloor_config.dispatcher_every(read_yaml(self.home / "config.yml")),
                               "registered": (registration() or {}).get("kind")},
                "cycle": cycle, "projects": projects, "prices": self.prices(), "models": self.models(), "hours": self.hours(), "unpriced": unpriced}

    def project_agents(self):
        """{agent: [{project, layer}]} for every agent a registered project's layer names."""
        out = {}
        for p in self.projects():
            for l in self.config(p).get("layers") or []:
                if isinstance(l, dict) and isinstance(l.get("agent"), str):
                    out.setdefault(l["agent"], []).append({"project": p, "layer": l.get("name")})
        return out

    @staticmethod
    def free_stages(raw):
        """{stage: runtime name} of the stages whose runtime has no list of models (its name is free text)."""
        if shipfloor_config.runtime_problems(raw.get("runtime") if isinstance(raw, dict) else None):
            return {}
        names = dict(zip(shipfloor_config.STAGES, shipfloor_config.runtime_of(raw)))
        return {st: rt for st, rt in names.items() if not runtimes.get(rt).MODELS}

    def models(self):
        """The Settings rows for the models: each stage and agent with its configured model, today's model, whether
        the model has a price, and (stages) the mean cost per card of the last 7 days."""
        raw, agents, prices = read_yaml(self.home / "config.yml"), self.project_agents(), self.prices()
        problems = shipfloor_config.model_problems(raw, agents)
        bad, configured = {p["key"] for p in problems}, raw.get("models") if isinstance(raw.get("models"), dict) else {}
        priced = lambda value: value is None or any(k.startswith(f"claude-{value}-") for k in prices)
        def row(group, name, default):
            entries = configured.get(group) if isinstance(configured.get(group), dict) else {}
            value = None if f"models.{group}.{name}" in bad else entries.get(name)
            if isinstance(default, dict):  # a stage per weight: a single model fills the three
                value = {w: None if f"models.{group}.{name}.{w}" in bad else value.get(w) if isinstance(value, dict) else value
                         for w in shipfloor_config.WEIGHTS}
                return {"value": value, "default": dict(default), "priced": {w: priced(v) for w, v in value.items()}}
            return {"value": value, "default": default, "priced": priced(value)}
        since, runs = datetime.now(timezone.utc) - timedelta(days=7), {s: [] for s in shipfloor_config.STAGES}
        for p in self.projects():
            for s in self.sessions(p):
                if s["stage"] in runs and parse_ts(s["start"]) >= since:
                    runs[s["stage"]].append(((p, s["issue"]), dashboard_cost.session_cost(s, prices)))
        free = self.free_stages(raw)
        rt_stages = (shipfloor_config.runtime_setting(raw, None, "models") or {}).get("stages") if free else None
        rt_stages = rt_stages if isinstance(rt_stages, dict) else {}

        def free_row(st):  # the runtime's own model, any name: priced only when prices.yml has exactly that name
            value, weights = rt_stages.get(st), shipfloor_config.WEIGHTS
            text = lambda v: v.strip() if isinstance(v, str) and v.strip() else None
            if st == "refine":
                value = text(value)
                return {"value": value, "default": None, "priced": value is None or value in prices}
            value = {w: text(value.get(w)) if isinstance(value, dict) else text(value) for w in weights}
            return {"value": value, "default": dict.fromkeys(weights), "priced": {w: v is None or v in prices for w, v in value.items()}}
        stages = {st: dict(free_row(st) if st in free else row("stages", st, shipfloor_config.STAGE_MODELS[st]),
                           cost=per_card(runs[st]), runtime=free.get(st, "claude-code"), free=st in free)
                  for st in shipfloor_config.STAGES}
        return {"choices": list(shipfloor_config.MODELS),
                "stages": stages,
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
        for k in ("pool", "stacks", "stack_wait", "language"):
            if k in changes:
                new[k] = changes[k]
        if isinstance(changes.get("stages"), dict):
            new["stages"] = dict(new["stages"] if isinstance(new.get("stages"), dict) else {}, **changes["stages"])
        if "costs" in changes:  # {limit: number}; null clears a limit, and an empty costs is left out of the file
            if not isinstance(changes["costs"], dict):
                return 400, {"error": "costs must be a mapping of limit: US$"}
            costs = dict(new["costs"]) if isinstance(new.get("costs"), dict) else {}
            for k, v in changes["costs"].items():
                if v is None:
                    costs.pop(k, None)
                else:
                    costs[k] = v
            if costs:
                new["costs"] = costs
            else:
                new.pop("costs", None)
        if "limits" in changes:  # {memory_max, cpu_weight, cpu_quota}; null or empty clears one, and no limit is left out of the file
            if not isinstance(changes["limits"], dict):
                return 400, refused(["limits must be a mapping of memory_max, cpu_weight, cpu_quota"])
            lim = dict(new["limits"]) if isinstance(new.get("limits"), dict) else {}
            for k, v in changes["limits"].items():
                if isinstance(v, str):
                    v = v.strip()
                    v = int(v) if k == "cpu_weight" and v.isascii() and v.isdigit() else v
                if v is None or v == "" or (isinstance(v, str) and v.lower() == "none"):
                    lim.pop(k, None)
                else:
                    lim[k] = v
            if lim:
                new["limits"] = lim
            else:
                new.pop("limits", None)
        if "notify" in changes:
            had, ch = new.get("notify") or {}, changes["notify"]
            if isinstance(had, dict) and isinstance(ch, dict):  # key by key; events and channels too
                had = {**had, **{k: {**(had.get(k) if isinstance(had.get(k), dict) else {}), **v} if k in ("events", "channels") and isinstance(v, dict) else v for k, v in ch.items()}}
            new["notify"] = had if isinstance(ch, dict) and isinstance(had, dict) else ch
        if "hours" in changes:  # a list of windows sets it; null or [] goes back to always
            if changes["hours"] in (None, []):
                new.pop("hours", None)
            else:
                new["hours"] = changes["hours"]
        if isinstance(changes.get("dispatcher"), dict) and "every_min" in changes["dispatcher"]:
            new["dispatcher"] = dict(new["dispatcher"] if isinstance(new.get("dispatcher"), dict) else {}, every_min=changes["dispatcher"]["every_min"])
        if "language" in changes and not isinstance(changes["language"], str):
            return 400, refused([shipfloor_config.lang_problem()])
        errs =shipfloor_config.machine_problems(new) + (shipfloor_config.hours_problems(new) if "hours" in changes else [])
        if isinstance(changes.get("models"), dict):
            models = new["models"] if isinstance(new.get("models"), dict) else {}
            free = self.free_stages(new)  # their model is the runtime's own: it goes to runtime.models, any name
            def merge(rows, name, ch):
                if isinstance(ch, dict) and name != "refine":  # per weight; null removes that weight
                    had = rows.get(name)
                    had = dict(had) if isinstance(had, dict) else dict.fromkeys(shipfloor_config.WEIGHTS, had) if isinstance(had, str) else {}
                    had.update(ch)
                    ch = {w: m for w, m in had.items() if m is not None} or None
                rows[name] = ch
            for group in ("stages", "agents"):
                if isinstance(changes["models"].get(group), dict):
                    rows = dict(models[group] if isinstance(models.get(group), dict) else {})
                    for name, ch in changes["models"][group].items():
                        if group == "stages" and name in free:
                            rt = new["runtime"] if isinstance(new.get("runtime"), dict) else {"default": new["runtime"]}
                            rtm = dict(rt["models"]) if isinstance(rt.get("models"), dict) else {}
                            rts = dict(rtm["stages"]) if isinstance(rtm.get("stages"), dict) else {}
                            clean = lambda m: m.strip() or None if isinstance(m, str) else m
                            merge(rts, name, {w: clean(m) for w, m in ch.items()} if isinstance(ch, dict) else clean(ch))
                            rtm["stages"] = {n: m for n, m in rts.items() if m is not None}
                            rtm = {g: v for g, v in rtm.items() if v != {}}
                            rt = {k: v for k, v in rt.items() if k != "models"}
                            new["runtime"] = dict(rt, models=rtm) if rtm else rt
                            errs += shipfloor_config.runtime_problems(new["runtime"])
                        else:
                            merge(rows, name, ch)
                    models[group] = {n: m for n, m in rows.items() if m is not None}
            new["models"] = {g: rows for g, rows in models.items() if rows != {}}
            if not new["models"]:
                del new["models"]
            agents = self.project_agents()
            before = shipfloor_config.model_problems(old, agents)
            Msg = shipfloor_config.Msg
            errs += [Msg("err.unsaved", f"{line}. Nothing was saved.", line=line) for line in
                     (shipfloor_config.model_problem_line(p) if p["why"] in ("name", "shape")
                      else Msg("err.model.unknown_short", f"{p['key']}: \"{p['value']}\" is not a model the factory knows", key=p["key"], value=p["value"])
                      for p in shipfloor_config.model_problems(new, agents) if p not in before)]
        if errs:
            return 400, refused(errs)
        every = shipfloor_config.dispatcher_every(new)
        asked = isinstance(changes.get("dispatcher"), dict) and "every_min" in changes["dispatcher"]
        # the task is told first: if it refuses, nothing is saved. A pace asked for that config.yml already has is told
        # too when the registration runs at another one (it was installed by hand, or before the config changed).
        if every != shipfloor_config.dispatcher_every(read_yaml(path)) or (asked and every != pace_now(self.home)):
            command, why = scheduler()
            if not command:
                return 409, refused([why])
            try:
                r = subprocess.run([*command, str(every)], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
                lines = [l.strip() for l in (r.stdout + "\n" + r.stderr).splitlines() if l.strip()]
                if r.returncode != 0:  # the scheduler's own last line, as it says it
                    return 409, {"error": lines[-1]} if lines else refused([Msg("err.sched.exit", f"the scheduler exited {r.returncode}", code=r.returncode)])
            except subprocess.TimeoutExpired:
                return 409, refused([Msg("err.sched.timeout", "the scheduler did not answer in 60 seconds")])
            except OSError as e:
                return 409, refused([Msg("err.sched.start", f"the scheduler could not start: {e}", error=str(e))])
            finally:
                forget_registration()
        want = shipfloor_config.machine_limits(new.get("limits"))
        if want != shipfloor_config.machine_limits(old.get("limits")):  # told first, as the pace: if it refuses, nothing is saved
            command = limits_applier()
            if command:
                flags = [a for k in shipfloor_config.LIMIT_KEYS for a in ("--" + k.replace("_", "-"), want[k])]
                try:
                    r = subprocess.run([*command, *flags], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
                    lines = [l.strip() for l in (r.stdout + "\n" + r.stderr).splitlines() if l.strip()]
                    if r.returncode != 0:
                        return 409, {"error": (lines or [f"the installer exited {r.returncode}"])[-1]}
                except subprocess.TimeoutExpired:
                    return 409, {"error": "the installer did not answer in 60 seconds"}
                except OSError as e:
                    return 409, {"error": f"the installer could not start: {e}"}
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("# shipfloor machine config: runs at once on this machine (pool) and per stage\n")
            yaml.safe_dump(new, f, sort_keys=False)
        return 200, self.settings()

    def set_project(self, project, values):
        """The owner's overrides of a project on this machine: {knob: number, or null to go back to what the
        repository says}, and language: a code of LANGS, or null. Kept in the project's overrides.yml, which the
        config readers lay over factory.yml; checked with the whole config before it is written."""
        if project not in self.projects() or not isinstance(values, dict) or not set(values) <= set(KNOBS) | {"language"}:
            return 400, {"error": "unknown project or setting"}
        if "language" in values and values["language"] is not None and (not isinstance(values["language"], str) or values["language"] not in shipfloor_config.LANGS):
            return 400, refused([shipfloor_config.lang_problem()])
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
            return 400, refused(errs)
        if over:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write("# this machine's overrides of the project; set in the dashboard's Settings\n")
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
            read = runtimes.get(s["runtime"]).events
            out = list(self.transcript(s["path"], read))
            for a in s["subagent_paths"]:
                out += [dict(e, sub=True) for e in self.transcript(a, read)]
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

    def github_limited(self):  # the mark a board read refused for GitHub's API limit leaves (dispatch.sh, #190)
        mark = self.home / "github-limited"
        window = 60 * int(os.environ.get("SHIPFLOOR_GITHUB_LIMIT_MIN") or 10)
        return mark.exists() and mark.stat().st_mtime > time.time() - window

    def usage_limited(self):
        return self.limited_runtime() is not None

    def limited_runtime(self):
        """The runtime whose usage limit holds the factory now, None when none does."""
        for log in self.home.glob("projects/*/logs/*.log"):
            if log.stat().st_mtime > time.time() - 1800:
                name = runtimes.limited_runtime(log.read_text(encoding="utf-8", errors="replace"))
                if name:
                    return name
        return None

    def entered(self, p, columns):
        """{n: ISO time} of when each card came into its board column, from the board history (#184); a card whose column
        the history does not show yet (it moved after the last line) or that never changed column there has none. The
        history is read again only when one of its files changed."""
        sig = tuple((f.name, f.stat().st_size, f.stat().st_mtime) for f in sorted((self.pdir(p) / "logs").glob("board-*.jsonl")))
        hit = self._entered.get(p)
        if not hit or hit[0] != sig:
            hit = self._entered[p] = (sig, board_history.entered(str(self.pdir(p))), board_history._last_cards(str(self.pdir(p))) or {})
        _, at, last = hit
        return {n: at[str(n)] for n, col in columns.items() if str(n) in at and last.get(str(n)) == col}

    def stop_hold(self, p, n, column):
        """The dispatcher's hold on a card whose last two runs stopped without doing their stage (stopped/<n>, #264):
        {why, stage, column, at, times} while it holds, as dispatch.stopped_hold decides (two marks or more, and the card
        still in the column the last run started from); None otherwise."""
        try:
            rows = [l.split("\t") for l in (self.pdir(p) / "stopped" / str(n)).read_text(encoding="utf-8").split("\n")]
        except (OSError, UnicodeDecodeError):
            return None
        rows = [r for r in rows if len(r) == 4]
        if len(rows) < 2 or (rows[-1][3] and column and column != rows[-1][3]):
            return None
        try:
            at = datetime.fromtimestamp(int(rows[-1][0])).astimezone().isoformat(timespec="seconds")
        except (ValueError, OverflowError, OSError):
            at = None
        return {"why": rows[-1][2], "stage": rows[-1][1], "column": rows[-1][3], "at": at, "times": len(rows)}

    @staticmethod
    def card_deps(record, columns, n):
        """A card's dependencies from the dispatcher's record (deps.json), each in its board column, "closed", or "open"
        when open but off the board; deps_unread when the dispatcher could not read them. The dashboard asks GitHub nothing."""
        entry = record.get(str(n))
        if not isinstance(entry, dict):
            return {"deps": [], "deps_unread": False}
        out = []
        for d in entry.get("deps") or []:
            if not isinstance(d, dict) or not isinstance(d.get("n"), int):
                continue
            state = "closed" if d.get("state") == "closed" else columns.get(d["n"]) or "open"
            out.append({"n": d["n"], "title": str(d.get("title") or ""), "state": state})
        return {"deps": out, "deps_unread": entry.get("read") is False}

    def shipped(self, p, columns, titles, done, per_card):
        """The cards done today (done_on) that are in Done, newest first: {issue, title, pr, at, cost}. `at` is when the
        card's clean deploy ended, `pr` the last pull request a report names, `cost` its Inbox-to-now estimate (None when unpriced)."""
        out = []
        for n, col in columns.items():
            at = done.get(n)
            if col != "Done" or not at:
                continue
            pr = next((r["pr"] for r in reversed(self.reports(p, n)) if isinstance(r.get("pr"), int)), None)
            out.append({"issue": n, "title": titles.get(n, ""), "pr": pr, "at": at, "cost": rounded(per_card.get(n, 0.0))})
        return sorted(out, key=lambda x: parse_ts(x["at"]).timestamp(), reverse=True)

    def overview(self):
        size, slots = self.pool()
        prices, today, limits = self.prices(), datetime.now().date().isoformat(), self.costs()
        live, projects, finished, today_cost = [], [], [], 0.0
        for p in self.projects():
            runs = self.live(p)
            live += runs
            doing, all_runs, sessions = {}, self.runs(p), self.sessions(p)
            estimate, base = dashboard_cost.spend(sessions, prices, today), dashboard_cost.baselines(self.pdir(p))
            per_card = {n: c["total"] for n, c in estimate["cards"].items()}
            warned = dashboard_cost.over(estimate, limits, base)["warn"]
            today_cost += estimate["today"]
            for s in sessions:
                doing[(s["issue"], s["stage"])] = s["activity"]  # sessions come oldest first: the latest wins
            for r in runs:
                r["activity"] = doing.get((r["issue"], r["stage"]), [])
            running = {r["issue"]: r["stage"] for r in runs if not r["orphan"]}
            columns, age = self.board(p)
            titles, blocked, record = self.titles(p, columns), self.blocked(p), deps.load(str(self.pdir(p)))
            opened, place, line = self._opened.get(p, {}), {}, {}
            for n, col in columns.items():  # columns come in board order: a card's place in line is its rank there
                if col in LINED:
                    line[col] = place[n] = line.get(col, 0) + 1
            # how long a stage usually takes (its clean runs); since when each card is where it is: when it came into its
            # column by the board history (#184), else when its last run ended
            took, since = {}, {}
            for r in all_runs:
                if r["end"]:
                    since[r["issue"]] = r["end"]
                    if r["exit"] == 0:
                        took.setdefault(r["stage"], []).append((parse_ts(r["end"]) - parse_ts(r["start"])).total_seconds())
            since.update(self.entered(p, columns))
            done = done_on(all_runs, today)
            projects.append({"slug": p, "paused": (self.pdir(p) / "PAUSE").exists(), "board_age_s": age,
                             "skipped": self.skipped(p), "done_today": len(done),
                             "typical_s": {st: round(statistics.median(v)) for st, v in took.items()},
                             "repo": (self.config(p).get("project") or {}).get("repo"), "board_url": self.board_url(p),
                             "cards": [{"issue": n, "title": titles.get(n, ""), "column": col, "since": since.get(n),
                                        "cost": rounded(per_card.get(n, 0.0)),
                                        "over": "warn" if n in warned else None,
                                        "spent": None if per_card.get(n, 0.0) is None else per_card.get(n, 0.0) - base.get(n, 0.0),
                                        "running": running.get(n), "awaiting": col in AWAITING,
                                        "review": col in AWAITING and (self.pdir(p) / "reviews" / f"{n}.html").is_file(),
                                        "lock": "run" if n in running else {"infra": "infra", "owner": "blocked"}.get(blocked.get(n)),
                                        "opened": opened.get(n), "position": place.get(n),
                                        "blocked": blocked.get(n), "done_at": done.get(n),
                                        "stopped": None if n in running or blocked.get(n) == "infra" else self.stop_hold(p, n, col),  # infra: the factory retries it
                                        **self.brief_row(p, n, col),
                                        **self.block_brief(p, n, blocked.get(n)),
                                        **self.card_deps(record, columns, n)}
                                       for n, col in columns.items()],
                             "shipped": self.shipped(p, columns, titles, done, per_card)})
            finished += [r for r in self.runs(p, day=today) if r["end"]]
        used = {st: sum(1 for r in live if r["stage"] == st and not r["orphan"]) for st in slots}
        mine = {st: {} for st in slots}  # the slots are shared by every project: who holds each one
        for r in live:
            if not r["orphan"] and r["stage"] in mine:
                mine[r["stage"]][r["project"]] = mine[r["stage"]].get(r["project"], 0) + 1
        stacks, queue = self.stacks()
        day_stopped = dashboard_cost.over({"cards": {}, "today": today_cost}, limits, {})["day_stop"]
        return {"pool": {"size": size, "used": sum(used.values()),
                         "stages": {st: {"slots": slots[st], "running": used[st], "by_project": mine[st]} for st in slots}},
                "paused": (self.home / "PAUSE").exists(), "usage_limited": self.usage_limited(), "hours": self.hours(),
                "alerts": shipfloor_health.findings(self.home, skip_silence=True), "silent": silent_banner(self.home),
                "runs": live, "projects": projects, "stacks": stacks, "queue": queue,
                "moves": {f: [{"to": to, "note": note} for to, note in m] for f, m in OWNER_MOVES.items()}, "ordered": list(ORDERED),
                "take_back": {f: list(m) for f, m in BLOCKED_MOVES.items()},
                "today": {"runs": len(finished), "ok": sum(r["exit"] == 0 for r in finished),
                          "failed": sum(r["exit"] != 0 for r in finished), "cost": round(today_cost, 2)},
                "costs": dict(limits, day_stopped=day_stopped)}

    def run_costs(self, runs, sessions, prices):
        """{(log, start): US$} of each run that ended, from its sessions; None when one of them has no price. As in card(),
        a session belongs to the last run of its card and stage that started before it; a run still going has none yet."""
        by, out = {}, {}
        for r in runs:
            by.setdefault((r["issue"], r["stage"]), []).append(r)
        for s in sessions:
            at = parse_ts(s["start"]).timestamp() + 120
            run = next((r for r in reversed(by.get((s["issue"], s["stage"]), [])) if parse_ts(r["start"]).timestamp() <= at), None)
            if run and run["end"]:
                key, c = (run["log"], run["start"]), dashboard_cost.session_cost(s, prices)
                out[key] = None if c is None or out.get(key, 0.0) is None else out.get(key, 0.0) + c
        return out

    def history(self, p, per, page=1):
        """The History panel over a period (history_period): the runs that ended in it by hour or by day, its totals and
        the previous period's, how long a stage took, one page of its runs (newest first) and its cards by cost.
        A run belongs to the day and hour its end falls in, on this machine's clock, and carries its sessions' cost."""
        prices, runs, sessions = self.prices(), self.runs(p), self.sessions(p)
        costs, day = self.run_costs(runs, sessions, prices), lambda r: parse_ts(r["end"]).astimezone()
        cost = lambda r: costs.get((r["log"], r["start"]), 0.0)  # a run with no session cost nothing; rounded, so the totals equal the rows
        ended = sorted((dict(r, cost=None if cost(r) is None else round(cost(r), 2)) for r in runs if r["end"]),
                       key=lambda r: parse_ts(r["end"]).timestamp(), reverse=True)
        within = lambda span: [r for r in ended if span["from"] <= day(r).date().isoformat() <= span["to"]]
        mine, before = within(per), within(per["prev"])
        columns, _ = self.board(p)
        titles = self.titles(p, [*columns, *(r["issue"] for r in mine + before)])
        opened = self._opened.get(p, {})

        def figures(rs):
            done = clean_deploys(rs)
            waits = []
            for n, end in done.items():
                try:  # a card whose creation GitHub did not give is left out of the median
                    if opened.get(n):
                        waits.append((parse_ts(end) - parse_ts(opened[n])).total_seconds())
                except (TypeError, ValueError):
                    continue
            return {"done": len(done), "ok": sum(r["exit"] == 0 for r in rs), "failed": sum(r["exit"] != 0 for r in rs),
                    "cost": round(sum(r["cost"] for r in rs if r["cost"] is not None), 2),
                    "unpriced": sum(r["cost"] is None for r in rs),
                    "median_s": round(statistics.median(waits)) if waits else None, "median_of": len(waits)}

        if per["unit"] == "hour":
            now = datetime.now()
            slots = [{"h": h} for h in range(0, now.hour + 1 if per["present"] else 24)]
            slot = lambda r: day(r).hour
        else:
            a = date.fromisoformat(per["from"])
            slots = [{"day": (a + timedelta(days=i)).isoformat()} for i in range(per["days"])]
            slot = lambda r: (day(r).date() - a).days
        for b in slots:
            b.update(ok=0, failed=0, cost=0.0, unpriced=0)
        for r in mine:
            i = slot(r)
            if 0 <= i < len(slots):
                b = slots[i]
                b["ok" if r["exit"] == 0 else "failed"] += 1
                if r["cost"] is None:
                    b["unpriced"] += 1
                else:
                    b["cost"] = round(b["cost"] + r["cost"], 2)
        took = {}
        for r in mine:
            if r["exit"] == 0:
                took.setdefault(r["stage"], []).append((parse_ts(r["end"]) - parse_ts(r["start"])).total_seconds())
        pages = max(1, -(-len(mine) // HISTORY_PAGE))
        page = min(max(1, page), pages)
        estimate = dashboard_cost.spend(sessions, prices, date.today().isoformat())["cards"]
        cards = [{"issue": n, "title": titles.get(n, ""), "column": columns.get(n), "runs": sum(r["issue"] == n for r in mine),
                  "cost": rounded((estimate.get(n) or {"total": 0.0})["total"])} for n in sorted({r["issue"] for r in mine})]
        cards.sort(key=lambda c: (c["cost"] is None, -(c["cost"] or 0), c["issue"]))  # the costliest first, unpriced last
        return {**{k: per[k] for k in ("from", "to", "days", "unit", "present", "prev", "next", "now")},
                "buckets": slots, "totals": figures(mine), "previous": figures(before),
                "typical_s": {st: round(statistics.median(v)) for st, v in took.items()},
                "runs": [{"issue": r["issue"], "title": titles.get(r["issue"], ""), "stage": r["stage"], "start": r["start"],
                          "end": r["end"], "exit": r["exit"], "log": r["log"], "cost": r["cost"]}
                         for r in mine[(page - 1) * HISTORY_PAGE:page * HISTORY_PAGE]],
                "runs_total": len(mine), "page": page, "pages": pages, "cards": cards, "empty": not mine}

    def board_rows(self, p):
        """(every row of the live board in board order: number, column, item id), or (None, error)."""
        env = dict(os.environ, FACTORY_CONFIG=str(self.pdir(p) / "factory.yml"), FACTORY_HOME=str(self.pdir(p)))
        snap = subprocess.run([bash(), (HERE / "board.sh").as_posix(), "snapshot"], env=env,
                              capture_output=True, text=True, encoding="utf-8")
        if snap.returncode != 0:
            return None, "cannot read the board: " + snap.stderr.strip()
        return [c for c in (l.split("\t") for l in snap.stdout.splitlines()) if len(c) > 2 and number(c[0])], None

    def board_row(self, p, n):
        """(the card's row on the live board: number, column, item id; or None), or (None, error)."""
        rows, err = self.board_rows(p)
        return (None, err) if err else (next((c for c in rows if c[0] == str(n)), None), None)

    def keep_rows(self, p, rows):
        """The board as a write of the owner's just left it becomes the dashboard's own read, so the next overview shows it
        without waiting for the dispatcher; board.tsv stays the dispatcher's to write."""
        self._snap[p] = (time.time(), ["\t".join(r) for r in rows])

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
        """The owner's approve / request-changes on a Spec Review or Staged card: the move of that column without a note,
        or the one with a note."""
        if seen not in AWAITING:  # as before #125: a card outside those columns has nothing to decide, whatever the board says
            row, err = self.board_row(p, n)
            if err:
                return 502, {"error": err}
            return 409, {"error": f"#{n} is in {row[1] if row else 'no column'} now", "column": row and row[1]}
        to = next(t for t, note in OWNER_MOVES[seen] if note == (action == "request-changes"))
        return self.owner_move(p, n, seen, to, text, move_only)

    def lock(self, p, n):
        """(why the card cannot move now: "run", "infra", "blocked" or None, error). Read now, not from the minute-old cache."""
        if any(r["issue"] == n and not r["orphan"] for r in self.live(p)):
            return "run", None
        issue, err = gh_json("api", f"repos/{shipfloor_config.dotted(self.config(p), 'project.repo')}/issues/{n}")
        if err:
            return None, "cannot read the card's labels: " + err
        names = {l.get("name") for l in (issue or {}).get("labels") or [] if isinstance(l, dict)}
        return ("infra" if "blocked:infra" in names else "blocked" if "blocked" in names else None), None

    def owner_move(self, p, n, seen, to, text, move_only):
        """A move of M1 to M7. Moves with gh directly: board.sh move refuses owner-only columns on purpose (the agents'
        guardrail), and an owner path there would be open to agents. A note goes on the issue before the move."""
        cfg = self.config(p)
        owner, num, repo = (shipfloor_config.dotted(cfg, k) for k in ("board.owner", "board.number", "project.repo"))
        rows, err = self.board_rows(p)
        if err:
            return 502, {"error": err}
        row = next((r for r in rows if r[0] == str(n)), None)
        column = row[1] if row else None
        if column != seen:
            return 409, {"error": f"#{n} is in {column or 'no column'} now", "column": column}
        note = dict(OWNER_MOVES.get(column, ())).get(to) if isinstance(to, str) else None
        if note is None:
            return 403, {"error": f"the owner does not move a card from {column} to {to or 'nowhere'}"}
        locked, err = self.lock(p, n)
        if err:
            return 502, {"error": err}
        if locked:
            return 423, {"error": LOCKED[locked], "locked": locked}
        # a note move always says why; any other move may carry a note too (an answer to the spec's open question)
        commented = not move_only and (note or bool(text.strip()))
        if commented:
            if not text.strip():
                return 400, {"error": "write what should change"}
            r = gh("issue", "comment", str(n), "--repo", str(repo), "--body-file", "-", input=text)
            if r.returncode != 0:
                return 502, {"error": "comment failed, nothing moved: " + r.stderr.strip()}
        rest = [r for r in rows if r is not row]
        last = [r for r in rest if r[1] == to][-1:]
        if to in ORDERED and last:  # a Status change keeps the item's place, which may be the top of the queue: it goes last
            err = self.place(p, owner, num, row[2], last[0][2])
            if err:
                return 502, {"error": err, "commented": commented}
            rest.insert(rest.index(last[0]) + 1, row)
        else:
            rest = rows
        err = self.move(p, owner, num, row[2], to)
        if err:
            return 502, {"error": err, "commented": commented}
        self.keep_rows(p, [[r[0], to, r[2]] if r is row else r for r in rest])
        return 200, {"moved_to": to}

    def take_back(self, p, n, to, text):
        """A card blocked for the owner goes back to Ready for Dev, Ready for Refinement or the Inbox (#127), in this order:
        the comment (when there is one), the card's open pull request closed (Inbox only, its branch kept), the move, the
        block off. A failure stops there and leaves the card blocked where it was, so the same move can be repeated.
        A card the dispatcher holds after two stopped runs (stop_hold) is taken back the same way, and its marks go."""
        if not isinstance(to, str) or to not in BLOCKED_MOVES["Coding"]:
            return 400, {"error": f"a blocked card goes to {', '.join(BLOCKED_MOVES['Coding'])}, not {to or 'nowhere'}"}
        rows, err = self.board_rows(p)
        if err:
            return 502, {"error": err}
        row = next((r for r in rows if r[0] == str(n)), None)
        if not row:
            return 409, {"error": f"#{n} is not on the board", "column": None}
        column = row[1]
        locked, err = self.lock(p, n)  # read now: a card unblocked a moment ago must not be moved as blocked
        if err:
            return 502, {"error": err}
        held = None if locked else self.stop_hold(p, n, column)
        if locked != "blocked" and not held:
            why = LOCKED[locked] if locked else "it is not blocked now"
            return 409, {"error": why, "column": column, "locked": locked}
        if to == column or to not in BLOCKED_MOVES.get(column, BLOCKED_MOVES["*"]):
            return 409, {"error": f"a card blocked in {column} does not go to {to}", "column": column}
        cfg = self.config(p)
        owner, num, repo = (shipfloor_config.dotted(cfg, k) for k in ("board.owner", "board.number", "project.repo"))
        commented, closed = False, None
        if text.strip():
            r = gh("issue", "comment", str(n), "--repo", str(repo), "--body-file", "-", input=text)
            if r.returncode != 0:
                return 502, {"error": "comment failed, nothing moved: " + r.stderr.strip(), "commented": False, "pr_closed": None}
            commented = True
        if to == "Inbox":  # the card's pull request, found by its branch feat/<n>-...; none open is not an error
            prs, err = gh_json("pr", "list", "--repo", str(repo), "--state", "open", "--json", "number,headRefName", "--limit", "200")
            if err:
                return 502, {"error": "cannot read the pull requests, nothing moved: " + err, "commented": commented, "pr_closed": None}
            for pr in prs or []:
                if isinstance(pr, dict) and str(pr.get("headRefName") or "").startswith(f"feat/{n}-"):
                    r = gh("pr", "close", str(pr.get("number")), "--repo", str(repo))  # no --delete-branch: the branch stays
                    if r.returncode != 0:
                        return 502, {"error": "closing the pull request failed, nothing moved: " + r.stderr.strip(),
                                     "commented": commented, "pr_closed": closed}
                    closed = closed or pr.get("number")
        rest = [r for r in rows if r is not row]
        last = [r for r in rest if r[1] == to][-1:]
        if to in ORDERED and last:  # as owner_move: a Status change keeps the item's place, which may be the top of the queue
            err = self.place(p, owner, num, row[2], last[0][2])
            if err:
                return 502, {"error": err, "commented": commented, "pr_closed": closed}
            rest.insert(rest.index(last[0]) + 1, row)
        else:
            rest = rows
        err = self.move(p, owner, num, row[2], to)
        if err:
            return 502, {"error": err, "commented": commented, "pr_closed": closed}
        self.keep_rows(p, [[r[0], to, r[2]] if r is row else r for r in rest])
        if held:  # the dispatcher would drop the marks at its next cycle, seeing the new column: gone now, so the page agrees
            (self.pdir(p) / "stopped" / str(n)).unlink(missing_ok=True)
            return 200, {"moved_to": to, "commented": commented, "pr_closed": closed, "unblocked": False}
        code, body = self.unblock(p, n)
        if code != 200:
            return 502, {"error": "moved, but the block did not come off: " + body.get("error", ""), "commented": commented,
                         "pr_closed": closed, "moved_to": to}
        return 200, {"moved_to": to, "commented": commented, "pr_closed": closed, "unblocked": True}

    def owner_reorder(self, p, n, seen, before):
        """The card goes right before `before` in its column, or last for None (#128). `seen` and `before` are what the
        page saw: a board that changed since is refused, not reordered somewhere else."""
        if before is not None and (isinstance(before, bool) or not isinstance(before, int)):
            return 400, {"error": "before must be a card number or null"}
        if before == n:
            return 400, {"error": f"#{n} cannot go before itself"}
        if seen not in ORDERED:
            return 403, {"error": f"the order of {seen or 'no column'} is not the owner's to set"}
        rows, err = self.board_rows(p)
        if err:
            return 502, {"error": err}
        mine = [r for r in rows if r[1] == seen]
        row = next((r for r in mine if r[0] == str(n)), None)
        if not row:
            return 409, {"error": f"it is no longer in {seen}", "column": seen, "gone": n}
        if before is not None and not any(r[0] == str(before) for r in mine):
            return 409, {"error": f"#{before} is no longer in {seen}", "column": seen, "gone": before}
        locked, err = self.lock(p, n)
        if err:
            return 502, {"error": err}
        if locked:
            return 423, {"error": LOCKED[locked], "locked": locked}
        rest = [r for r in rows if r is not row]
        if before is None:
            after = ([r for r in rest if r[1] == seen][-1:] or [None])[0]
        else:
            i = next(i for i, r in enumerate(rest) if r[0] == str(before))
            after = rest[i - 1] if i else None
        rest.insert(rest.index(after) + 1 if after else 0, row)
        position = [r[0] for r in rest if r[1] == seen].index(str(n)) + 1
        if rest == rows:
            return 200, {"position": position}
        cfg = self.config(p)
        err = self.place(p, shipfloor_config.dotted(cfg, "board.owner"), shipfloor_config.dotted(cfg, "board.number"), row[2], after and after[2])
        if err:
            return 502, {"error": err}
        self.keep_rows(p, rest)
        return 200, {"position": position}

    def place(self, p, owner, num, item, after):
        """Puts the item right after another one in the project's order, or first without `after`."""
        project_id, err = self.project_id(p, owner, num)
        if err:
            return err
        query = ("mutation($project: ID!, $item: ID!, $after: ID) { updateProjectV2ItemPosition(input: "
                 "{projectId: $project, itemId: $item, afterId: $after}) { clientMutationId } }")
        r = gh("api", "graphql", "-f", f"query={query}", "-f", f"project={project_id}", "-f", f"item={item}",
               *(("-f", f"after={after}") if after else ()))
        return None if r.returncode == 0 else "reorder failed, nothing moved: " + r.stderr.strip()

    def project_id(self, p, owner, num):
        try:
            return (self.pdir(p) / "board-ids").read_text().split()[0], None
        except (OSError, IndexError):
            project, err = gh_json("project", "view", str(num), "--owner", owner, "--format", "json")
            return (None, "cannot read the board ids: " + err) if err else ((project or {}).get("id", ""), None)

    def comment(self, p, n, text):
        """A comment on the issue after a move already left (the toast's Comment); it moves nothing."""
        if not text.strip():
            return 400, {"error": "the comment is empty"}
        repo = shipfloor_config.dotted(self.config(p), "project.repo")
        r = gh("issue", "comment", str(n), "--repo", str(repo), "--body-file", "-", input=text)
        if r.returncode != 0:
            return 502, {"error": "comment failed: " + r.stderr.strip()}
        return 200, {"commented": True}

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
        """The machine's language (~/.shipfloor/config.yml, English when it names none the dashboard has) and the page's
        catalogs: that language's messages and the English ones, which a key the first lacks falls back to."""
        code = str(read_yaml(self.home / "config.yml").get("language", "en"))
        code = code if code in catalogs() else "en"
        return {"language": code, "messages": catalog(code), "en": catalog("en")}

    def page(self):
        """dashboard.html with lang() in it (#lang-data) and its language declared on <html>, so the first paint is
        already in that language and the browser picks the language's glyphs and case rules."""
        lang = self.lang()
        data = json.dumps(lang, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
        html = page_source()
        html = html.replace('<html lang="en">', f'<html lang="{lang["language"]}">', 1)
        html = html.replace('<script type="application/json" id="lang-data">null</script>', f'<script type="application/json" id="lang-data">{data}</script>', 1)
        return html.encode("utf-8")

    def feed(self, limit=400):
        """One timeline: the dispatcher's and the stacks' log lines, and one event per run, at the time it ended
        (or started, while it still runs), with what is known of what it left behind. A log line repeated in a
        row is one event: how many times ("n") and since when ("since")."""
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
                if not text.strip():
                    continue
                if m and out and out[-1]["source"] == source and out[-1]["text"] == text:
                    out[-1].update(n=out[-1]["n"] + 1, ts=ts)
                else:
                    out.append({"ts": ts, "source": source, "text": text, "n": 1, "since": ts})
        today = datetime.now().date()
        for p in self.projects():
            runs = [r for day in (today - timedelta(days=1), today) for r in self.runs(p, day=day.isoformat())]
            if runs:
                out.extend(self.feed_runs(p, runs))

        def at(e):
            try:
                return parse_ts(e["ts"]).timestamp()
            except (ValueError, TypeError):
                return 0.0
        return {"events": sorted(out, key=at)[-limit:]}  # the sort is stable: untimed lines keep their place

    def feed_runs(self, p, runs):
        """A feed event per run, with what each one left behind, every piece from its own source: the card's
        title, the estimated cost of the run's sessions, the pull request and the failed gates its report names,
        and, on a card's newest run, the column the card is in now. A run with
        no end is running only while its lock is there, and then it carries its step; otherwise its end was lost."""
        prices, (columns, _) = self.prices(), self.board(p)
        titles = self.titles(p, sorted({*columns, *(r["issue"] for r in runs)}))
        began = lambda x: parse_ts(x["start"]).timestamp()
        spent, reports, newest = {}, {}, {}
        live = {(x["stage"], x["issue"]): x for x in self.live(p) if not x["orphan"]}
        for s in self.sessions(p):  # a session belongs to a run the way a card's Sessions tab pairs them
            mine = [r for r in runs if r["issue"] == s["issue"] and r["stage"] == s["stage"] and began(r) <= began(s) + 120]
            if mine:
                key, c = (mine[-1]["log"], mine[-1]["start"]), dashboard_cost.session_cost(s, prices)
                spent[key] = None if c is None or spent.get(key, 0) is None else spent.get(key, 0) + c
        for r in runs:
            if r["issue"] not in newest or began(r) > began(newest[r["issue"]]):
                newest[r["issue"]] = r

        def report(r):  # the report this run wrote: its stage, and a file name stamped inside the run
            if r["issue"] not in reports:
                reports[r["issue"]] = self.reports(p, r["issue"])
            stamp = lambda ts: ts[:19].replace(":", "")
            mine = [x for x in reports[r["issue"]] if x["file"].startswith(r["stage"] + "-")
                    and stamp(r["start"]) <= x["file"][len(r["stage"]) + 1:-5] <= stamp(r["end"])]
            return mine[-1] if mine else {}

        out = []
        for r in runs:
            n, key = r["issue"], (r["log"], r["start"])
            e = {"source": p, "issue": n, "stage": r["stage"], "title": titles.get(n, ""), "log": r["log"], "start": r["start"],
                 "end": r["end"], "exit": r["exit"] if r["end"] else None, "ts": r["end"] or r["start"], "text": f"{r['stage']} #{n}"}
            if key in spent:
                e["cost"] = None if spent[key] is None else round(spent[key], 2)
            if r.get("model"):
                e["model"] = r["model"]
            if r.get("stepped"):
                e["stepped"] = {"from": r["stepped"]["from"], "to": r.get("model") or r["stepped"]["to"], "gates": r["stepped"]["gates"]}
            if r.get("again"):
                e["again"] = r["again"]
            if r["end"]:
                rep = report(r)
                if isinstance(rep.get("pr"), int):
                    e["pr"] = rep["pr"]
                if isinstance(rep.get("failed_gates"), list) and rep["failed_gates"]:
                    e["failed"] = [str(g) for g in rep["failed_gates"]]
                if newest[n] is r and columns.get(n):
                    e.update(column=columns[n], you=columns[n] in AWAITING)
            else:
                now = live.get((r["stage"], n)) if newest[n] is r else None
                if now is None:
                    e["lost"] = True
                elif now["step"]:
                    e["step"] = {"i": now["step"]["i"], "of": now["steps"], "label": now["step"]["label"]}
            out.append(e)
        return out


class Handler(BaseHTTPRequestHandler):
    factory, token = None, ""

    def log_message(self, *args):
        pass

    def send(self, code, body, kind="application/json", headers=()):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        try:
            self.send_response(code)
            for k, v in headers:
                self.send_header(k, v)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
        except ConnectionError:
            pass  # the tab closed before the answer: the action already ran, nobody is left to tell

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
            return self.send(200, self.factory.page(), "text/html; charset=utf-8")
        if url.path == "/favicon.ico":  # the browser asks without a token; nothing to show
            return self.send(204, b"")
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
            if known and len(parts) == 3 and parts[:2] == ["api", "history"]:
                one = lambda k: q[k][0] if k in q else None
                per, why = history_period(datetime.now().date(), one("days"), one("from"), one("to"))
                if why:
                    return self.send(400, {"error": why})
                page = one("page") or "1"
                return self.send(200, f.history(parts[2], per, int(page) if number(page) else 1))
            if known and len(parts) == 3 and parts[:2] == ["api", "day"]:
                return self.send(200, f.day(parts[2]))
            if known and len(parts) == 4 and parts[:2] == ["api", "card"] and number(parts[3]):
                return self.send(200, f.card(parts[2], int(parts[3])))
            if known and len(parts) == 4 and parts[:2] == ["api", "decide"] and number(parts[3]):
                return self.send(200, f.decide(parts[2], int(parts[3])))
            if known and len(parts) == 4 and parts[:2] == ["api", "live"] and number(parts[3]):
                return self.send(200, f.session(parts[2], int(parts[3])))
            if known and len(parts) == 4 and parts[:2] == ["api", "log"]:
                start = q.get("from", ["-1"])[0]
                body = f.log(parts[2], parts[3], int(start) if re.fullmatch(r"-?[0-9]+", start) else -1)
                if body:
                    return self.send(200, body)
            if len(parts) == 3 and parts[0] == "review" and parts[1] in f.projects() and number(parts[2]):
                page = f.pdir(parts[1]) / "reviews" / f"{parts[2]}.html"
                if page.is_file():
                    html = page.read_bytes()
                    if q.get("embed") == ["1"]:
                        html = html.replace(b"</head>", f.marks_block(parts[1], int(parts[2])).encode() + f.labels_block().encode() + EMBED_CSS.encode() + b"</head>", 1)
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
        if len(parts) == 5 and parts[:2] == ["api", "card"] and parts[4] == "marks" and parts[3].isdigit() and parts[2] in self.factory.projects():
            size = int(self.headers.get("Content-Length") or 0)
            if size > 256 * 1024:  # decided before reading anything
                self.close_connection = True
                return self.send(400, {"error": "body is over 256 KB"})
            try:
                body = json.loads(self.rfile.read(size) or b"{}")
            except ValueError:
                return self.send(400, {"error": "body is not JSON"})
            try:
                return self.send(*self.factory.save_marks(parts[2], int(parts[3]), body))
            except Exception as e:
                return self.send(500, {"error": f"{type(e).__name__}: {e}"})
        if not (len(parts) == 5 and parts[:2] == ["api", "card"] and parts[2] in self.factory.projects()
                and number(parts[3]) and parts[4] in ("approve", "request-changes", "move", "reorder", "comment", "take-back", "unblock", "message", "accept", "send-back", "weight", "approve-amend")):
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
            if parts[4] == "approve-amend":
                return self.send(*self.factory.approve_amend(parts[2], int(parts[3])))
            if parts[4] == "weight":
                return self.send(*self.factory.set_weight(parts[2], int(parts[3]), body.get("weight")))
            if parts[4] == "move":
                return self.send(*self.factory.owner_move(parts[2], int(parts[3]), body.get("column"), body.get("to"),
                                                          str(body.get("text") or ""), bool(body.get("move_only"))))
            if parts[4] == "reorder":
                return self.send(*self.factory.owner_reorder(parts[2], int(parts[3]), body.get("column"), body.get("before")))
            if parts[4] == "take-back":
                return self.send(*self.factory.take_back(parts[2], int(parts[3]), body.get("to"), str(body.get("text") or "")))
            if parts[4] == "comment":
                return self.send(*self.factory.comment(parts[2], int(parts[3]), str(body.get("text") or "")))
            self.send(*self.factory.act(parts[2], int(parts[3]), parts[4], body.get("column"),
                                        str(body.get("text", "")), bool(body.get("move_only"))))
        except Exception as e:
            self.send(500, {"error": f"{type(e).__name__}: {e}"})


class Server(ThreadingHTTPServer):
    allow_reuse_address = os.name != "nt"  # on Windows SO_REUSEADDR lets a second server share the port


def link_token(home):
    """The link's secret, kept in <home>/dashboard.token so a link survives a restart.
    A missing or damaged file is replaced by a new token; an unwritable home keeps it in memory."""
    path = Path(home) / "dashboard.token"
    try:
        saved = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        saved = ""
    if re.fullmatch(r"[A-Za-z0-9_-]{22}", saved):
        return saved
    token = secrets.token_urlsafe(16)
    tmp = path.with_name(path.name + ".tmp")
    try:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(token + "\n")
        os.replace(tmp, path)
    except OSError:
        print("shipfloor dashboard: could not save the link's secret; this link will not survive a restart", file=sys.stderr, flush=True)
    return token


def main():
    a = argparse.ArgumentParser(prog="shipfloor dashboard")
    a.add_argument("--home", required=True)
    a.add_argument("--port", type=int, default=7717)
    a.add_argument("--no-open", action="store_true")
    a.add_argument("--token", default="")  # a fixed token for a demo on sample data; empty keeps the random one
    args = a.parse_args()
    bash()
    Handler.factory = Factory(args.home, os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    Handler.token = args.token or link_token(args.home)
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
    port_file = Path(args.home) / "dashboard.port"
    try:
        tmp = port_file.with_name("dashboard.port.tmp")
        tmp.write_text(f"{server.server_address[1]}\n", encoding="utf-8")
        os.replace(tmp, port_file)
    except OSError:
        pass  # without it a push just carries no link
    print(f"shipfloor dashboard: {url}  (Ctrl+C stops it)", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        port_file.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
