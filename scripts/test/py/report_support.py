"""Helpers for the in-process report suites (report_ops.py, report_brief.py, review_pages.py): real git repos and bare
remotes in the test's temp dir, a test identity for the commits the product makes, and a product main() called in this
process with its cwd, stdout and stderr caught."""
import contextlib
import io
import os
import subprocess

import support


def git(*args, cwd=None, check=True):
    """git with the test's identity; its stdout without the trailing newline."""
    r = subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "core.autocrlf=false", *args],
                       cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and r.returncode != 0:
        raise AssertionError("git %s: %s" % (" ".join(args), r.stderr))
    return r.stdout.rstrip("\n")


class ReportCase(support.Case):
    def setUp(self):
        super().setUp()
        for k in ("AUTHOR", "COMMITTER"):  # the commits report.py makes
            os.environ["GIT_%s_NAME" % k] = "t"
            os.environ["GIT_%s_EMAIL" % k] = "t@t"
        self.n = 0

    def fresh(self, name):
        self.n += 1
        return self.path("%s-%d" % (name, self.n))

    def bare(self):
        """An empty bare remote."""
        d = self.fresh("remote")
        git("init", "-q", "--bare", "-b", "main", d)
        return d

    def repo(self, remote=None, push=False):
        """A repo with one commit (README.md) on main, origin = remote when given (main pushed when push)."""
        d = self.fresh("repo")
        git("init", "-q", "-b", "main", d)
        with open(os.path.join(d, "README.md"), "w") as f:
            f.write("base\n")
        git("-C", d, "add", "-A")
        git("-C", d, "commit", "-qm", "base")
        if remote:
            git("-C", d, "remote", "add", "origin", remote)
            if push:
                git("-C", d, "push", "-q", "origin", "main")
        return d

    def call(self, fn, argv, cwd=None):
        """fn(argv) in this process from cwd (default: the temp dir): (rc, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()
        here = os.getcwd()
        os.chdir(cwd or self.tmp)
        saved = [os.dup(1), os.dup(2)]
        sink = os.open(os.path.join(self.tmp, "children.out"), os.O_WRONLY | os.O_CREAT | os.O_APPEND)
        try:  # what the processes it starts print (git's) goes to a file, not to the suite's lines
            os.dup2(sink, 1)
            os.dup2(sink, 2)
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = fn(list(argv))
        finally:
            os.dup2(saved[0], 1)
            os.dup2(saved[1], 2)
            for fd in saved + [sink]:
                os.close(fd)
            os.chdir(here)
        return rc, out.getvalue(), err.getvalue()
