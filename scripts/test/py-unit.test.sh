#!/usr/bin/env bash
# The Python package's text helpers (#162), proved by a unittest module run under `python -I -B`:
#   AC-7  text.ere_match() agrees with `grep -E` on valid patterns and raises on an invalid one
# The unittest modules are written to a temp dir by this file (a test file outside scripts/test/*.test.sh would not
# be run by the gates); the Python prints "ok" / "FAIL" lines like every test here.
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"

cat > "$T/unit.py" <<'PY'
import importlib, os, subprocess, sys, unittest

sys.dont_write_bytecode = True
SCRIPTS = os.environ["UNIT_SCRIPTS"]
sys.path.insert(0, SCRIPTS)
sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def core(name):
    try:
        return importlib.import_module("shipfloor_core." + name)
    except Exception as e:
        raise AssertionError("shipfloor_core.%s cannot be loaded: %s: %s" % (name, type(e).__name__, e))


def grep_e(pattern, text, ignore_case=False):
    r = subprocess.run(["grep", "-Ei" if ignore_case else "-E", "--", pattern], input=text.encode("utf-8"),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode


class Ere(unittest.TestCase):
    VALID = [
        (r"\bfoo\b", "a foo b", False),
        (r"\bfoo\b", "foobar", False),
        (r"\bfoo\b", "barfoo", False),
        ("a[[:space:]]b", "a b", False),
        ("a[[:space:]]b", "a\tb", False),
        ("a[[:space:]]b", "ab", False),
        ("a[[:space:]]+b", "a   b", False),
        ("^(light|standard|heavy)$", "heavy", False),
        ("^(light|standard|heavy)$", "heavier", False),
        ("^[0-9]+$", "123", False),
        ("^[0-9]+$", "12a", False),
        ("ABC", "xabcx", True),
        ("ABC", "xabcx", False),
        ("tests? [0-9]{2}", "test 42", False),
        ("tests? [0-9]{2}", "tests 4", False),
        (r"a\.b", "a.b", False),
        (r"a\.b", "axb", False),
    ]

    def test_ac7_ere_match_agrees_with_grep_e(self):
        "AC-7 ere_match agrees with grep -E on \\b, [[:space:]] and the other valid patterns"
        text = core("text")
        for pattern, line, ic in self.VALID:
            want = grep_e(pattern, line, ic)
            self.assertIn(want, (0, 1), "grep -E rejects %r" % pattern)
            got = text.ere_match(pattern, line, ignore_case=ic)
            self.assertEqual(bool(got), want == 0, "ere_match(%r, %r, ignore_case=%s) = %r, grep -E says %s" % (pattern, line, ic, got, "match" if want == 0 else "no match"))

    def test_ac7_ere_match_raises_on_an_invalid_pattern(self):
        "AC-7 ere_match raises on an invalid pattern, never 'no match'"
        text = core("text")
        for pattern in ["(", "a(b", "[a-", "[[:space:]", "a\\"]:
            self.assertEqual(grep_e(pattern, "anything"), 2, "grep -E accepts %r" % pattern)
            try:
                got = text.ere_match(pattern, "anything")
            except Exception:
                continue
            raise AssertionError("ere_match(%r, ...) returned %r instead of raising" % (pattern, got))


class R(unittest.TestResult):
    def _name(self, t):
        return t.shortDescription() or t.id()

    def addSuccess(self, t):
        super().addSuccess(t)
        print("  ok   %s" % self._name(t))

    def addFailure(self, t, err):
        super().addFailure(t, err)
        print("  FAIL %s: %s" % (self._name(t), str(err[1]).replace("\n", " ")[:400]))

    def addError(self, t, err):
        super().addError(t, err)
        print("  FAIL %s: %s: %s" % (self._name(t), err[0].__name__, str(err[1]).replace("\n", " ")[:400]))


suite = unittest.TestSuite()
for cls in (Ere,):
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(cls))
res = R()
suite.run(res)
sys.exit(0 if res.wasSuccessful() else 1)
PY

out="$(UNIT_SCRIPTS="$FACTORY_DIR" "$FACTORY_PYTHON" -I -B "$T/unit.py" 2>&1)"; rc=$?
printf '%s\n' "$out"
n="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
FAILS=$((FAILS + n))
if [ "$rc" -ne 0 ] && [ "$n" -eq 0 ]; then fail "unit.py exited $rc without a FAIL line"; fi
finish
