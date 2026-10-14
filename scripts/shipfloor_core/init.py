"""init: `shipfloor init [<repo>] [--yes]` takes a clean machine to a working factory in one guided run (#174).

Steps, each idempotent: prerequisites (fatal, before any change), install, .shipfloor/factory.yml (committed to the main
branch only after a confirmation), add, setup-board, the dispatcher, doctor. Every step prints the manual command it is
equivalent to (`$ <command>`). Without a terminal and without --yes nothing destructive happens: the exact command is
printed and the run exits 1.
"""
import os
import re
import subprocess
import sys

from . import cli, proc, project

DEVNULL = subprocess.DEVNULL
CFG = ".shipfloor/factory.yml"


class _Pending(Exception):
    """A step needs the owner: the command is printed, the run ends with 1."""


class Init:
    def __init__(self, yes):
        self.yes = yes

    # --- helpers -----------------------------------------------------------------------------------------------------

    def tty(self):
        try:
            return sys.stdin.isatty()
        except (AttributeError, ValueError):
            return False

    def step(self, title, cmd):
        cli._out("")
        cli._out("== %s" % title)
        cli._out("$ %s" % cmd)

    def confirm(self, question):
        """True with --yes or a yes at the terminal; False without either (the caller prints the command)."""
        if self.yes:
            return True
        if not self.tty():
            return False
        try:
            sys.stdout.write("%s [y/N] " % question)
            sys.stdout.flush()
            return sys.stdin.readline().strip().lower() in ("y", "yes")
        except (OSError, EOFError):
            return False

    def ask(self, question, default):
        """A line from the terminal; the default with --yes or without one."""
        if self.yes or not self.tty():
            return default
        sys.stdout.write("%s [%s] " % (question, default))
        sys.stdout.flush()
        return sys.stdin.readline().strip() or default

    def pending(self, why, cmd):
        cli._out("pending: %s" % why)
        cli._out("run it yourself:")
        cli._out("  %s" % cmd)
        cli._out("then run shipfloor init again.")
        raise _Pending()

    # --- 1. prerequisites --------------------------------------------------------------------------------------------

    def prerequisites(self):
        cli._out("== prerequisites")
        bad = []
        if not cli._have("git"):
            bad.append("git is missing: install it from https://git-scm.com/downloads")
        if not cli._have("gh"):
            bad.append("gh is missing: install it from https://cli.github.com, then run: gh auth login")
        elif cli._run(proc.gh_argv("auth", "status"), out=DEVNULL, err=DEVNULL)[0] != 0:
            bad.append("gh is not authenticated: run: gh auth login")
        if not cli._have("claude"):
            bad.append("claude is missing: install Claude Code from https://claude.com/claude-code")
        v = sys.version_info
        if tuple(v[:2]) < (3, 11):
            bad.append("python %d.%d.%d is too old: Shipfloor needs Python 3.11 or later (set FACTORY_PYTHON to one)"
                       % tuple(v[:3]))
        try:
            import yaml  # noqa: F401
        except Exception:
            bad.append("PyYAML is missing: run: pip install pyyaml")
        if bad:
            for b in bad:
                cli._out("FAIL " + b)
            cli._out("nothing was changed; fix the above and run shipfloor init again.")
            return False
        cli._out("ok   git, gh (authenticated), claude, python %d.%d.%d with PyYAML" % tuple(v[:3]))
        return True

    # --- 2. install --------------------------------------------------------------------------------------------------

    def install(self):
        src, inst = cli.source_dir(), cli._installed()
        skip = {"test", ".source", ".origin", "__pycache__", "templates"}
        if os.path.isdir(inst) and cli._same_tree(os.path.join(src, "scripts"), inst, skip) \
                and cli._same_tree(os.path.join(src, "templates"), os.path.join(inst, "templates"), set()):
            cli._out("")
            cli._out("== install")
            cli._out("already installed: %s matches %s" % (inst, src))
            return 0
        self.step("install", "shipfloor install")
        return cli.cmd_install([])

    # --- 3. factory.yml ----------------------------------------------------------------------------------------------

    def repo_slug(self, repo):
        return re.sub(r"[^a-z0-9-]+", "-", os.path.basename(repo.rstrip("/\\")).lower()).strip("-") or "project"

    def github_repo(self, repo):
        """owner/name from gh, else from the origin URL; "" when neither tells."""
        rc, out = cli._cap(proc.gh_argv("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"),
                           err=DEVNULL, cwd=repo)
        if rc == 0 and re.fullmatch(r"[^/\s]+/[^/\s]+", out):
            return out
        url = cli._git("-C", repo, "remote", "get-url", "origin", err=DEVNULL)[1]
        m = re.search(r"github\.com[:/]([^/\s]+/[^/\s]+?)(\.git)?/?$", url)
        return m.group(1) if m else ""

    def render(self, repo):
        example = os.path.join(cli.source_dir(), "examples", "factory.yml")
        data = cli._read_bytes(example)
        if data is None:
            cli.die("cannot read %s" % example)
        body = cli._t(data)
        name = self.ask("project name", self.repo_slug(repo))
        gh_repo = self.ask("GitHub repository (owner/repo)", self.github_repo(repo) or "OWNER/REPO")
        owner = self.ask("board owner (user or organization)", gh_repo.split("/")[0])
        number = self.ask("board number (GitHub Project v2)", "1")
        body = re.sub(r"(?m)^(  name: )\S+", lambda m: m.group(1) + name, body, count=1)
        body = re.sub(r"(?m)^(  repo: )\S+", lambda m: m.group(1) + gh_repo, body, count=1)
        body = re.sub(r"(?m)^board: \{.*?\}", "board: {owner: %s, number: %s}" % (owner, number), body, count=1)
        if not self.yes and self.tty() and self.ask("describe one layer instead of the example's? (y/n)", "n") == "y":
            lname = self.ask("layer name", "app")
            lpath = self.ask("layer path", "./")
            stack = self.ask("stack", "")
            build = self.ask("build command", "make test")
            test = self.ask("test command ({selector} = what to run)", "make test T={selector}")
            ran = self.ask("regex proving a test ran", "PASS")
            tests = self.ask("tests glob", "tests/**")
            layer = ("layers:\n  - name: %s\n    path: %s\n%s    build: %s\n    test: %s\n    ran: '%s'\n"
                     "    tests: ['%s']\n\n" % (lname, lpath, "    stack: %s\n" % stack if stack else "", build, test,
                                               ran, tests))
            body = re.sub(r"(?ms)^layers:\n.*?(?=^stack:)", lambda m: layer, body, count=1)
        return body

    def config(self, repo, main):
        """True when the config is on origin/<main> (committed now or before)."""
        cli._out("")
        cli._out("== %s" % CFG)
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        if cli._run(["git", "-C", repo, "fetch", "-q", "origin", main], err=DEVNULL, env=env)[0] != 0:
            cli.die("cannot fetch origin/%s in %s" % (main, repo))
        on_origin = cli._run(["git", "-C", repo, "cat-file", "-e", "origin/%s:%s" % (main, CFG)], err=DEVNULL)[0] == 0
        path = os.path.join(repo, *CFG.split("/"))
        if on_origin:
            cli._out("%s already on origin/%s: kept as it is" % (CFG, main))
            if self.tty() and not self.yes and self.confirm("replace it with a freshly generated one?"):
                self.write_and_commit(repo, main, path, self.render(repo))
            return
        if os.path.isfile(path):
            cli._out("%s exists in %s but is not on origin/%s: kept as it is" % (CFG, repo, main))
        else:
            body = self.render(repo)
            cli._out("generated from examples/factory.yml:")
            cli._out(body.rstrip("\n"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(body)
        self.commit(repo, main)

    def write_and_commit(self, repo, main, path, body):
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        self.commit(repo, main)

    def commit(self, repo, main):
        msg = "chore: add .shipfloor/factory.yml"
        cmd = ('git -C %s add %s && git -C %s commit -m "%s" -- %s && git -C %s push origin %s'
               % (repo, CFG, repo, msg, CFG, repo, main))
        self.step("commit %s to %s" % (CFG, main), cmd)
        branch = cli._git("-C", repo, "symbolic-ref", "-q", "--short", "HEAD")[1]
        if branch != main:
            self.pending("%s is on %s, not %s" % (repo, branch or "a detached HEAD", main), cmd)
        staged = [f for f in cli._git("-C", repo, "diff", "--cached", "--name-only")[1].split("\n") if f and f != CFG]
        if staged:
            self.pending("%s has staged changes that are not init's: %s" % (repo, ", ".join(staged)), cmd)
        if not self.confirm("commit and push %s to %s?" % (CFG, main)):
            self.pending("committing to your repository needs your confirmation (--yes, or a terminal)", cmd)
        for argv in (["git", "-C", repo, "add", CFG],
                     ["git", "-C", repo, "commit", "-q", "-m", msg, "--", CFG],
                     ["git", "-C", repo, "push", "-q", "origin", main]):
            if cli._run(argv)[0] != 0:
                cli.die("`%s` failed; fix that and run shipfloor init again" % " ".join(argv))

    # --- 4. add, setup-board -----------------------------------------------------------------------------------------

    def add(self, repo, main):
        """The registered slug."""
        cli._out("")
        cli._out("== project")
        rc, top = cli._git("-C", repo, "rev-parse", "--show-toplevel", err=DEVNULL)
        for line in cli._records():
            slug, path = cli._cut(line, 1), cli._cut(line, 2)
            if rc == 0 and path and (path == top or project.git_common(path) == project.git_common(top)):
                cli._out("already added: %s is registered as %s" % (top, slug))
                return slug
        self.step("add", "shipfloor add %s" % repo)
        if cli.cmd_add([repo]) != 0:
            raise cli.CliExit(1)
        for line in cli._records():
            if cli._cut(line, 2) == top:
                return cli._cut(line, 1)
        return ""

    def board(self, slug):
        self.step("set up the board", "shipfloor setup-board %s" % slug)
        rc = cli.cmd_setup_board([slug])
        if rc != 0:
            raise cli.CliExit(rc)

    # --- 5. dispatcher -----------------------------------------------------------------------------------------------

    def dispatcher(self):
        src = cli.source_dir()
        win = re.match(r"(MINGW|MSYS|CYGWIN)", proc.uname_s()) is not None
        script = os.path.join(src, "installer", "install-dispatcher.sh")
        cmd = ('powershell -File "%s"' % os.path.join(src, "installer", "install-dispatcher.ps1")) if win \
            else 'bash "%s"' % script
        cli._out("")
        cli._out("== dispatcher")
        rc, what = cli._cap(["bash", script, "--status"], err=DEVNULL)
        if rc == 0:
            cli._out("already registered (%s): kept as it is" % what.replace("registered: ", ""))
            return 0
        self.step("register the dispatcher", cmd)
        argv = ["powershell", "-File", os.path.join(src, "installer", "install-dispatcher.ps1")] if win \
            else ["bash", script]
        return cli._run(argv)[0]

    # --- run ---------------------------------------------------------------------------------------------------------

    def run(self, repo):
        if not self.prerequisites():
            return 1
        try:
            rc = self.install()
            if rc != 0:
                return rc
            if repo:
                top = cli._git("-C", repo, "rev-parse", "--show-toplevel", err=DEVNULL)
                if top[0] != 0:
                    cli.die("%s is not a git repository" % repo)
                repo = top[1]
                main = cli.main_of(repo)
                self.config(repo, main)
                slug = self.add(repo, main)
                if slug:
                    self.board(slug)
            rc = self.dispatcher()
            if rc != 0:
                return rc
        except _Pending:
            return 1
        self.step("check everything", "shipfloor doctor")
        bad = cli.cmd_doctor([])
        cli._out("")
        cli._out("next steps:")
        if repo:
            cli._out("  - put cards on the board and move one to Ready for Refinement; the dispatcher does the rest")
            cli._out("  - shipfloor dashboard   # watch the runs")
        else:
            cli._out("  - shipfloor init <repo>   # add a repository to this machine")
        return 1 if bad else 0


def run(args):
    yes, repo = False, ""
    for a in args:
        if a == "--yes":
            yes = True
        elif a.startswith("-") or repo:
            cli.die("usage: shipfloor init [<repo>] [--yes]", 2)
        else:
            repo = a
    return Init(yes).run(repo)
