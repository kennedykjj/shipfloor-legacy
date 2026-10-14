#!/usr/bin/env bash
# The Python package's process and text helpers (#162), proved by unittest modules run under `python -I -B`:
#   AC-5  proc.gh() issues the calls board.sh makes today, argv byte for byte, --jq included (fake-gh's call log)
#   AC-7  text.ere_match() agrees with `grep -E` on valid patterns and raises on an invalid one
# The unittest modules are written to a temp dir by this file (a test file outside scripts/test/*.test.sh would not
# be run by the gates); the Python prints "ok" / "FAIL" lines like every test here.
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"

# ---- AC-5 reference: the calls board.sh makes today, recorded argv by argv (NUL-separated, one extra NUL ends a call)
export FAKE_GH_BIN="$FACTORY_DIR/test/fake-gh"
cat > "$T/rec-gh" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\0' "$@"; printf '\0'; } >> "$REC_LOG"
exec "$FAKE_GH_BIN" "$@"
EOF
chmod +x "$T/rec-gh"
mkdir -p "$T/bin"; cp "$T/rec-gh" "$T/bin/gh"; chmod +x "$T/bin/gh"   # "fake-gh on PATH": the name gh

seed_gh() {  # seed_gh <dir>: what the board.sh calls below read
  mkdir -p "$1"
  printf 'I1\t25\t👤 Ready for Refinement\nI3\t33\t👤 Spec Review\nI4\t40\t🤖 Coding\nI5\t41\t🤖 Validation\n' > "$1/items.tsv"
  printf '{"number":7,"title":"Seven","body":"b","comments":[]}\n' > "$1/issue-7.json"
  printf '41\n' > "$1/infra"
}
A="$T/ref"; seed_gh "$A"
ref_run() {  # ref_run <board.sh args...>
  FAKE_GH_DIR="$A" REC_LOG="$T/ref.rec" FACTORY_GH="$T/rec-gh" FACTORY_HOME="$(mktemp -d)" bash "$FACTORY_DIR/board.sh" "$@" >/dev/null 2>&1
}
: > "$T/ref.rec"
ref_run items
ref_run eligible Coding
ref_run move 40 Validation
ref_run infra
ref_run label 41 add blocked:infra
ref_run label 41 remove blocked:infra
ref_run issue 7
[ -s "$T/ref.rec" ] && pass "reference: board.sh made $(tr -cd '\n' < "$A/calls" | wc -c | tr -d ' ') gh calls" || fail "reference: board.sh made no gh call"

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


class Gh(unittest.TestCase):
    def test_ac5_gh_issues_the_boards_calls_byte_identical(self):
        "AC-5 gh() issues the calls board.sh makes today, byte-identical argv, --jq included"
        proc = core("proc")
        ref = open(os.environ["UNIT_REF_REC"], "rb").read()
        calls = [c.split(b"\0") for c in ref.split(b"\0\0") if c]
        self.assertTrue(calls, "the reference run recorded no call")
        env = {
            "FAKE_GH_DIR": os.environ["UNIT_GH_B"],
            "REC_LOG": os.environ["UNIT_REC_B"],
            "FACTORY_GH": os.environ["UNIT_REC_GH"],
            "PATH": os.environ["UNIT_BIN"] + os.pathsep + os.environ["PATH"],
        }
        os.environ.update(env)
        for argv in calls:
            args = [a.decode("utf-8") for a in argv]
            try:
                proc.gh(*args)
            except Exception as e:
                raise AssertionError("gh%s raised %s: %s" % (args[:2], type(e).__name__, e))
        got = open(os.environ["UNIT_REC_B"], "rb").read()
        self.assertEqual(got, ref, "argv recorded through gh() differs from the one board.sh issues")
        want_log = open(os.environ["UNIT_GH_A"] + "/calls", "rb").read()
        got_log = open(os.environ["UNIT_GH_B"] + "/calls", "rb").read()
        self.assertEqual(got_log, want_log, "fake-gh's call log differs")
        self.assertTrue(any(b"--jq" in c for c in calls), "the reference has no --jq call")


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
for cls in (Gh, Ere):
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(cls))
res = R()
suite.run(res)
sys.exit(0 if res.wasSuccessful() else 1)
PY

seed_gh "$T/b"; : > "$T/b.rec"
out="$(UNIT_SCRIPTS="$FACTORY_DIR" UNIT_REF_REC="$T/ref.rec" UNIT_GH_A="$A" UNIT_GH_B="$T/b" UNIT_REC_B="$T/b.rec" \
  UNIT_REC_GH="$T/rec-gh" UNIT_BIN="$T/bin" "$FACTORY_PYTHON" -I -B "$T/unit.py" 2>&1)"; rc=$?
printf '%s\n' "$out"
n="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
FAILS=$((FAILS + n))
if [ "$rc" -ne 0 ] && [ "$n" -eq 0 ]; then fail "unit.py exited $rc without a FAIL line"; fi
finish
