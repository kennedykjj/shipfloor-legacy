"""Runs one in-process test module of scripts/test/py/ and prints the suite's "ok" / "FAIL" lines.

usage: python -I -B run.py <module> [test-name-pattern]   (the driver is py_suite in lib.sh)
A test's name is its docstring's first line, else its id. The product package is imported from scripts/ beside
this folder; tests get doubles for external tools (git, gh, claude) from support.py, never the real ones.
"""
import os
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))  # scripts/: shipfloor_core and the scripts/*.py modules
for stream in (sys.stdout, sys.stderr):
    stream.reconfigure(encoding="utf-8", newline="\n")


class Lines(unittest.TestResult):
    def _name(self, t):
        return t.shortDescription() or t.id().split(".", 1)[-1]

    def addSuccess(self, t):
        super().addSuccess(t)
        print("  ok   %s" % self._name(t), flush=True)

    def _bad(self, t, err, kind=""):
        msg = str(err[1]).replace("\n", " ")[:400]
        print("  FAIL %s: %s%s" % (self._name(t), kind, msg), flush=True)

    def addFailure(self, t, err):
        super().addFailure(t, err)
        self._bad(t, err)

    def addError(self, t, err):
        super().addError(t, err)
        self._bad(t, err, err[0].__name__ + ": ")

    def addSkip(self, t, reason):
        super().addSkip(t, reason)
        print("  ok   %s (skipped: %s)" % (self._name(t), reason), flush=True)


def main(argv):
    if not argv:
        print("usage: run.py <module> [pattern]", file=sys.stderr)
        return 2
    loader = unittest.TestLoader()
    if len(argv) > 1:
        loader.testNamePatterns = ["*%s*" % argv[1]]
    suite = loader.loadTestsFromName(argv[0])
    res = Lines()
    suite.run(res)
    if not res.testsRun:
        print("  FAIL %s: no test ran" % argv[0])
        return 1
    return 0 if res.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
