"""demo: `shipfloor demo` plays one fake card through the factory, with no real repository, no network and no LLM.

It builds a temporary home with a local bare "origin" and a clone of a tiny sample project (one Python file and a unittest
layer), registers it as the factory would, and moves one card through refine, develop, validate and deploy. The real
parts are the board moves (board.sh, against the gh stand-in in scripts/demo/gh), the gates (gate.sh red, green and
build), the git commits and the reports (report.sh). The recorded parts are what each agent would have written (the spec,
the code change, the run logs): written by this module, and said so on screen. No `claude` process is ever started and
the caller's ~/.shipfloor is never read or written: the processes the demo starts get a home of their own.

    shipfloor demo [--no-dashboard] [--keep]

Without --no-dashboard the dashboard of this checkout is served on the temporary home, opened in the browser, and kept
until Enter or Ctrl+C. The temporary home is removed at the end (on an error and on Ctrl+C too), unless --keep.
"""
import contextlib
import io
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import webbrowser
from datetime import datetime, timedelta

from . import cli

SLUG, REPO, N = "sample", "demo/sample", 1
TITLE = "Greet the user by name, and say hello to the world when there is no name"
BRANCH = "feat/1-greet-by-name"
COLUMNS = (("Inbox", "👤"), ("Ready for Refinement", "👤"), ("Technical Refinement", "🤖"), ("Spec Review", "👤"),
           ("Ready for Dev", "👤"), ("Coding", "🤖"), ("Validation", "🤖"), ("Staged", "👤"), ("Ready for Prod", "👤"),
           ("Done", "🤖"))
STEPS = {"refine": ["Pick the card", "Worktree", "Product Owner", "UX/UI and architecture", "Cybersec", "Publish for review", "Report"],
         "develop": ["Pick the card", "Plan", "Acceptance tests", "Implementation", "Last gates", "Hand over to validation", "Report"],
         "validate": ["Pick the card", "Gates", "Review", "Pull request", "Report"],
         "deploy": ["Merge", "Wait for CI", "Deploy", "Health check", "Report"]}
USAGE = "usage: shipfloor demo [--no-dashboard] [--keep]"
PACE = 0.0  # seconds between two narration lines: set when the output is a terminal, so a person can read along

GREETER_OLD = 'def greet(name):\n    return f"Hello, {name}!"\n'
GREETER_NEW = 'def greet(name=""):\n    return f"Hello, {name or \'world\'}!"\n'
TESTS = '''import unittest

from greeter import greet


class GreetTest(unittest.TestCase):
    def test_greets_by_name(self):
        self.assertEqual(greet("Ada"), "Hello, Ada!")

    def test_greets_the_world_when_there_is_no_name(self):
        self.assertEqual(greet(""), "Hello, world!")
        self.assertEqual(greet(), "Hello, world!")
'''


class DemoError(Exception):
    pass


def say(text=""):
    print(text, flush=True)
    if PACE:
        time.sleep(PACE)


def _iso(t):
    return t.isoformat(timespec="seconds")


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def _factory_yml():
    py = sys.executable.replace("\\", "/").replace("'", "''")
    return f"""project:
  name: {SLUG}
  repo: {REPO}
board: {{owner: demo, number: 1}}
layers:
  - name: app
    path: ./
    stack: Python 3
    build: '"{py}" -m unittest discover -s tests -t . -q'
    test: '"{py}" -m unittest {{selector}}'
    ran: 'Ran [1-9][0-9]* tests?'
    tests: ['tests/**']
"""


def _spec(date, resolved):
    question = ("- Resolved by the owner: an empty name greets the world.\n" if resolved else
                "- Should an empty name greet the world, or be refused with an error? The owner decides.\n")
    return f"""# Greet by name, and the world when there is no name: spec

**Issue:** #{N} · **Branch:** `{BRANCH}` · **Date:** {date}
**Roles:** PO, Tech Lead
**Weight:** light

> Recorded by `shipfloor demo`: no LLM ran, this is the text an agent would have written.

## Product
**Problem:** `greet()` says "Hello, !" when it gets no name.
**Acceptance criteria**
- AC-1: Given a name, when `greet` is called, then it says "Hello, <name>!".
- AC-2: Given no name, when `greet` is called, then it says "Hello, world!".

## Architecture
One function in `greeter.py`; no new file and no migration.

## Test plan

| AC | Layer | Test file |
|---|---|---|
| AC-1 | app | `tests/test_greeter.py` |
| AC-2 | app | `tests/test_greeter.py` |

## Open questions
{question}"""


class Demo:
    def __init__(self, root):
        self.root = root
        self.home = os.path.join(root, "home")
        self.user = os.path.join(root, "user")
        self.ghdir = os.path.join(root, "gh")
        self.origin = os.path.join(root, "origin.git")
        self.checkout = os.path.join(root, "checkout")
        self.work = os.path.join(root, "work")
        self.pdir = os.path.join(self.home, "projects", SLUG)
        self.control = os.path.join(self.pdir, "control")
        self.wt = os.path.join(self.pdir, "wt", str(N))
        self.scripts = cli.HERE
        self.column = "Inbox"
        self.env = {}
        self.server = None

    # ---- the environment of every process the demo starts: its own home, its own gh, nothing of the caller's factory
    def prepare_env(self):
        for k in list(os.environ):
            if k.startswith(("FACTORY_", "SHIPFLOOR_")):
                del os.environ[k]
        for d in (self.home, self.user, self.ghdir, self.work, os.path.join(self.root, "claude")):
            os.makedirs(d, exist_ok=True)
        gh = os.path.join(self.ghdir, "gh")  # an LF copy: a checkout with core.autocrlf gives the stand-in CRLF
        with open(os.path.join(self.scripts, "demo", "gh"), "rb") as f:
            data = f.read().replace(b"\r", b"")
        with open(gh, "wb") as f:
            f.write(data)
        os.chmod(gh, os.stat(gh).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        bash = shutil.which("bash") or "bash"
        os.environ.update({
            "HOME": self.user, "USERPROFILE": self.user, "SHIPFLOOR_HOME": self.home,
            "CLAUDE_CONFIG_DIR": os.path.join(self.root, "claude"),
            "FACTORY_GH": gh, "SHIPFLOOR_DEMO_GH": self.ghdir, "SHIPFLOOR_DEMO_STATE": self.root,
            "FACTORY_PYTHON": sys.executable, "SHIPFLOOR_BASH": bash, "PYTHONDONTWRITEBYTECODE": "1",
            "SHIPFLOOR_SCHEDULER": '"%s" -c \'echo "$1" >> "$SHIPFLOOR_DEMO_STATE/scheduler.log"\' stub' % bash.replace("\\", "/"),
            "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Demo Agent", "GIT_AUTHOR_EMAIL": "demo@example.invalid",
            "GIT_COMMITTER_NAME": "Demo Agent", "GIT_COMMITTER_EMAIL": "demo@example.invalid",
            "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "init.defaultBranch", "GIT_CONFIG_VALUE_0": "main",
            "GIT_CONFIG_KEY_1": "commit.gpgsign", "GIT_CONFIG_VALUE_1": "false",
            "GIT_CONFIG_KEY_2": "core.autocrlf", "GIT_CONFIG_VALUE_2": "false",
        })
        self.gh = gh

    # ---- processes
    def sh(self, argv, cwd=None, input=None, ok=True):
        sys.stdout.flush()
        r = subprocess.run(argv, cwd=cwd, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
        if ok and r.returncode != 0:
            raise DemoError("%s failed (exit %d): %s" % (" ".join(argv[:4]), r.returncode, (err or out).strip()[-600:]))
        return r.returncode, out, err

    def git(self, cwd, *args):
        return self.sh(["git", *args], cwd=cwd)[1].strip()

    def script(self, name, *args):
        return self.sh(["bash", os.path.join(self.scripts, name), *args], cwd=self.control)

    def gate(self, *args, expect=0):
        rc, out, err = self.sh(["bash", os.path.join(self.scripts, "gate.sh"), "-C", self.wt, *args], cwd=self.control, ok=False)
        lines = [l for l in err.splitlines() if l.strip()]
        verdict = lines[-1] if lines else "gate: no verdict"
        say("  " + verdict)
        if rc != expect:
            raise DemoError("%s: exit %d, wanted %d:\n%s" % (" ".join(args), rc, expect, (err + out).strip()[-600:]))
        return out

    # ---- the board
    def gh_edit(self, column):
        ids = {name: "opt%d" % (i + 1) for i, (name, _) in enumerate(COLUMNS)}
        self.sh([self.gh, "project", "item-edit", "--project-id", "PVT_sample", "--id", "PVTI_%d" % N,
                 "--field-id", "FLD_status", "--single-select-option-id", ids[column]])

    def move(self, column):
        """The factory moves the card (board.sh refuses the columns only the owner may enter or leave)."""
        self.script("board.sh", "move", str(N), column)
        say("board: %s -> %s" % (self.column, column))
        self.column = column

    def owner_move(self, column):
        self.gh_edit(column)
        say("board: %s -> %s (moved by the owner)" % (self.column, column))
        self.column = column

    def comment(self, text):
        self.sh([self.gh, "issue", "comment", str(N), "--repo", REPO, "--body-file", "-"], input=text.encode("utf-8"))

    # ---- the recorded runs
    def start(self, stage, what):
        say("run /sf:%s #%d: no LLM ran, this run is a recorded transcript. %s" % (stage, N, what))
        return datetime.now().astimezone()

    def finish(self, stage, started):
        ended = max(datetime.now().astimezone(), started + timedelta(seconds=2))
        steps = STEPS[stage]
        span = (ended - started) / (len(steps) * 3 + 1)
        lines = ["== start /sf:%s %d %s pid=%d" % (stage, N, _iso(started), 4100 + len(stage))]
        for k, label in enumerate(steps):
            at = (started + span * (3 * k + 1)).strftime("%H:%M:%S")
            lines += ["[%s] step %d: %s" % (at, k + 1, label), "[%s]   (recorded transcript: no LLM ran)" % at, "[%s]   ok" % at]
        lines.append("== end /sf:%s %d exit=0 %s" % (stage, N, _iso(ended)))
        path = os.path.join(self.pdir, "logs", "%s-%d-%s.log" % (started.strftime("%Y-%m-%d"), N, stage))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        return started, ended

    def report(self, stage, window, outcome, gates=(), pr=None, notes=""):
        import json
        started, ended = window
        body = {"issue": str(N), "slug": "greet-by-name", "pipeline": stage, "started_at": _iso(started), "finished_at": _iso(ended),
                "outcome": outcome, "agents": [{"role": "recorded transcript", "tokens": 0, "duration_s": int((ended - started).total_seconds())}],
                "rounds": {}, "gates": {g: "pass" for g in gates}, "gates_failed": [], "flaky": [], "gates_reused": [],
                "manual_edit": False, "pr": pr, "notes": notes}
        jpath, mpath = os.path.join(self.work, "report.json"), os.path.join(self.work, "report.md")
        _write(jpath, json.dumps(body, indent=1) + "\n")
        _write(mpath, "# %s of #%d: %s\n\nRecorded by `shipfloor demo`: no LLM ran.\n%s\n" % (stage, N, outcome, notes))
        self.script("report.sh", str(N), "greet-by-name", stage, jpath, mpath)
        say("report: %s of #%d committed to the factory-reports branch (%s)" % (stage, N, outcome))
        if outcome == "blocked":
            time.sleep(1.1)  # report names carry the second: the refine run that follows needs another one

    # ---- the sample project, the board and the registration
    def build_sample(self):
        self.sh(["git", "init", "-q", "--bare", self.origin])
        self.sh(["git", "symbolic-ref", "HEAD", "refs/heads/main"], cwd=self.origin)
        os.makedirs(self.checkout)
        self.git(self.checkout, "init", "-q")
        self.git(self.checkout, "checkout", "-q", "-b", "main")
        _write(os.path.join(self.checkout, "greeter.py"), GREETER_OLD)
        _write(os.path.join(self.checkout, "README.md"), "# sample\n\nThe project `shipfloor demo` plays a card on.\n")
        _write(os.path.join(self.checkout, ".gitignore"), "__pycache__/\n")
        _write(os.path.join(self.checkout, ".shipfloor", "factory.yml"), _factory_yml())
        self.git(self.checkout, "add", "-A")
        self.git(self.checkout, "commit", "-q", "-m", "chore: the sample project")
        self.git(self.checkout, "remote", "add", "origin", self.origin)
        self.git(self.checkout, "push", "-q", "origin", "main")
        self.git(self.checkout, "remote", "set-head", "origin", "main")

    def register(self):
        _write(os.path.join(self.home, "config.yml"),
               "# shipfloor machine config: the demo's\nlanguage: en\npool: 4\nstages:\n  refine: 1\n  develop: 1\n  validate: 1\n  deploy: 1\nstacks: 1\n")
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = cli.cmd_add([self.checkout, "--main", "main"])
        except cli.CliExit as e:
            rc = e.code
        if rc != 0:
            raise DemoError("cannot register the sample project: %s" % buf.getvalue().strip())
        cli.use(SLUG)
        import json
        options = [{"name": "%s %s" % (mark, name), "id": "opt%d" % (i + 1)} for i, (name, mark) in enumerate(COLUMNS)]
        board = os.path.join(self.pdir, "board.tsv")
        state = {"fields": [{"name": "Status", "id": "FLD_status", "options": options}],
                 "projects": {"1": {"id": "PVT_sample", "title": "sample board", "url": "https://github.com/orgs/demo/projects/1",
                                    "refuse": False, "mirror": board, "items": [[N, "👤 Inbox", "PVTI_%d" % N]]}},
                 "repos": {REPO: {"issues": [{"number": N, "title": TITLE}], "labels": {}, "comments": {}, "prs": {}}}}
        _write(os.path.join(self.ghdir, "state.json"), json.dumps(state, ensure_ascii=False))
        _write(board, "%d\tInbox\tPVTI_%d\n" % (N, N))

    # ---- the story
    def play(self):
        date = datetime.now().strftime("%Y-%m-%d")
        spec = os.path.join(self.wt, "docs", "superpowers", "specs", "%s-greet-by-name-design.md" % date)
        t0 = time.time()
        say('card #%d "%s" sits in Inbox of the sample board.' % (N, TITLE))
        self.owner_move("Ready for Refinement")

        say()
        say("== refine ==")
        self.move("Technical Refinement")
        began = self.start("refine", "Agents: Product Owner, UX/UI and Tech Lead, Cybersec.")
        self.sh(["git", "worktree", "add", "-q", "-b", BRANCH, self.wt, "origin/main"], cwd=self.checkout)
        _write(spec, _spec(date, False))
        self.git(self.wt, "add", "-A")
        self.git(self.wt, "commit", "-q", "-m", "docs(greet-by-name): spec draft for #%d" % N)
        self.git(self.wt, "push", "-q", "origin", "HEAD:" + BRANCH)
        say("spec written: docs/superpowers/specs/%s-greet-by-name-design.md, committed and pushed on %s" % (date, BRANCH))
        say("the run has a question only the owner can answer: it stops and marks the card blocked.")
        self.script("board.sh", "label", str(N), "add", "blocked")
        self.comment("Factory refine, step 3 (Product Owner): blocked.\n"
                     "The owner must decide: should an empty name greet the world, or be refused with an error?\n"
                     "Tried: read the card and the code; the card does not say.\n")
        say("block: label `blocked` and a comment on #%d: the block goes to the owner." % N)
        self.report("refine", self.finish("refine", began), "blocked", notes="Open question for the owner: an empty name.")
        say("owner: answers in the comment (greet the world) and removes the label.")
        self.comment("Greet the world.")
        self.script("board.sh", "label", str(N), "remove", "blocked")

        began = self.start("refine", "The card is eligible again; the run takes the answer.")
        _write(spec, _spec(date, True))
        self.git(self.wt, "add", "-A")
        self.git(self.wt, "commit", "-q", "-m", "docs(greet-by-name): spec for #%d" % N)
        self.git(self.wt, "push", "-q", "origin", "HEAD:" + BRANCH)
        say("spec updated with the owner's answer.")
        self.move("Spec Review")
        self.report("refine", self.finish("refine", began), "ok", notes="Spec ready for the owner's review.")
        say("owner: approves the spec (approval 1 of 2).")
        self.owner_move("Ready for Dev")

        say()
        say("== develop ==")
        self.move("Coding")
        began = self.start("develop", "Agents: QA Engineer, then Engineer.")
        _write(os.path.join(self.wt, "tests", "__init__.py"), "")
        _write(os.path.join(self.wt, "tests", "test_greeter.py"), TESTS)
        self.git(self.wt, "add", "-A")
        self.git(self.wt, "commit", "-q", "-m", "test(greeter): acceptance tests for #%d" % N)
        qa = self.git(self.wt, "rev-parse", "HEAD")
        say("QA commits the acceptance tests first: tests/test_greeter.py.")
        say("gate red app tests.test_greeter: the tests must fail on an assertion before any code exists.")
        out = self.gate("red", "app", "tests.test_greeter")
        found = next((l.strip() for l in out.splitlines() if "AssertionError" in l), "")
        if found:
            say("  they fail the right way: " + found)
        _write(os.path.join(self.wt, "greeter.py"), GREETER_NEW)
        self.git(self.wt, "add", "-A")
        self.git(self.wt, "commit", "-q", "-m", "feat(greeter): greet the world when there is no name")
        say("the Engineer writes the code in greeter.py: greet() takes an optional name.")
        say("gate green app tests.test_greeter: the same tests must now run and pass.")
        self.gate("green", "app", "tests.test_greeter")
        say("gate acceptance-intact: the tests are still the ones QA committed.")
        self.gate("acceptance-intact", qa)
        say("gate build origin/main: the layer builds.")
        self.gate("build", "origin/main")
        self.git(self.wt, "push", "-q", "origin", "HEAD:" + BRANCH)
        self.move("Validation")
        self.report("develop", self.finish("develop", began), "ok", gates=("red", "green", "build"))

        say()
        say("== validate ==")
        began = self.start("validate", "Agents: Reviewer.")
        say("gate green app tests.test_greeter: run again on the branch that goes to review.")
        self.gate("green", "app", "tests.test_greeter")
        url = self.sh([self.gh, "pr", "create", "--repo", REPO, "--head", BRANCH, "--base", "main",
                       "--title", "feat(greeter): greet the world when there is no name", "--body", "Recorded by shipfloor demo."])[1].strip()
        pr = int(url.rsplit("/", 1)[-1])
        say("pull request #%d opened (on the demo's gh stand-in, nothing left this machine)." % pr)
        self.move("Staged")
        self.report("validate", self.finish("validate", began), "ok", gates=("green", "build"), pr=pr)
        say("owner: approves the release (approval 2 of 2).")
        self.owner_move("Ready for Prod")

        say()
        say("== deploy ==")
        began = self.start("deploy", "Agent: Deployer.")
        self.git(self.checkout, "fetch", "-q", "origin")
        self.git(self.checkout, "merge", "-q", "--no-ff", "origin/" + BRANCH, "-m", "Merge pull request #%d from %s" % (pr, BRANCH))
        self.git(self.checkout, "push", "-q", "origin", "main")
        self.sh([self.gh, "pr", "merge", str(pr), "--repo", REPO, "--merge"])
        say("pull request #%d merged into main of the local origin (there is no CI or production in the demo)." % pr)
        self.move("Done")
        self.report("deploy", self.finish("deploy", began), "ok", pr=pr)

        say()
        say("the card crossed the factory in %d seconds: Inbox, refine, develop, validate, deploy, Done." % (time.time() - t0))
        say("real: the board moves, the gates, the git commits and the reports. recorded: what the agents wrote. no LLM ran.")

    # ---- the dashboard
    def dashboard(self):
        log_path = os.path.join(self.root, "dashboard.log")
        log = open(log_path, "wb")
        try:
            self.server = subprocess.Popen([sys.executable, "-I", os.path.join(self.scripts, "dashboard.py"), "--home", self.home,
                                            "--port", "0", "--no-open"], stdout=log, stderr=subprocess.STDOUT,
                                           stdin=subprocess.DEVNULL, cwd=self.root)
        finally:
            log.close()
        url, deadline = "", time.time() + 30
        while not url and time.time() < deadline:
            if self.server.poll() is not None:
                break
            with open(log_path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    at = line.find("http://")
                    if at >= 0:
                        url = line[at:].split()[0]
                        break
            if not url:
                time.sleep(0.1)
        if not url:
            raise DemoError("the dashboard did not start")
        say()
        say("dashboard on the temporary home: " + url)
        try:
            webbrowser.open(url)
        except Exception:  # no browser is not a failure: the address is on screen
            pass
        try:  # the first read asks the stand-in for titles and labels: ask now, so the page finds them cached
            token = url.split("?t=", 1)[-1]
            urllib.request.urlopen(urllib.request.Request(url.split("?")[0] + "api/overview", headers={"X-Shipfloor-Token": token}), timeout=30).read()
        except Exception:
            pass
        say("press Enter (or Ctrl+C) to stop the dashboard and finish.")
        try:
            sys.stdin.readline()
        except (KeyboardInterrupt, OSError):
            pass

    def stop_server(self):
        p, self.server = self.server, None
        if not p or p.poll() is not None:
            return
        p.terminate()
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def _rmtree(path):
    def fix(func, p, _exc):
        try:
            os.chmod(p, stat.S_IWRITE | stat.S_IREAD | stat.S_IEXEC)
            func(p)
        except OSError:
            pass
    for _ in range(5):
        shutil.rmtree(path, onerror=fix)
        if not os.path.exists(path):
            return
        time.sleep(0.3)


def _banner(root):
    say("shipfloor demo: one fake card crosses the factory, from Inbox to Done, on this machine.")
    say("no LLM ran, and none will: the agents' runs you will see are recorded transcripts, written by this demo.")
    say("What is real: the board moves, the gates (scripts that run the sample's tests), the git commits and the reports.")
    say("Nothing leaves this machine: no network, no GitHub, no tokens. Your ~/.shipfloor is not touched.")
    say("temporary home: " + root)
    say()


def main(args):
    global PACE
    keep = no_dashboard = False
    for a in args:
        if a == "--keep":
            keep = True
        elif a == "--no-dashboard":
            no_dashboard = True
        else:
            print(USAGE, file=sys.stderr)
            return 2
    PACE = 0.25 if sys.stdout.isatty() else 0.0
    saved_env = dict(os.environ)
    saved_term = None
    root = tempfile.mkdtemp(prefix="shipfloor-demo-")
    demo = Demo(root)
    code = 0
    try:
        try:
            saved_term = signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        except (ValueError, OSError, AttributeError):
            saved_term = None
        _banner(root)
        demo.prepare_env()
        demo.build_sample()
        demo.register()
        demo.play()
        if not no_dashboard:
            demo.dashboard()
    except KeyboardInterrupt:
        say("stopped.")
        code = 130
    except (DemoError, cli.CliExit, OSError) as e:
        sys.stdout.flush()
        print("shipfloor demo: %s" % (e if str(e) else "failed"), file=sys.stderr)
        code = 1
    finally:
        demo.stop_server()
        if keep:
            say("kept: the temporary home is %s (SHIPFLOOR_HOME=%s/home shipfloor dashboard)" % (root, root))
        else:
            _rmtree(root)
        if saved_term is not None:
            signal.signal(signal.SIGTERM, saved_term)
        os.environ.clear()
        os.environ.update(saved_env)
    return code
