#!/usr/bin/env bash
# run.sh --changed runs only the test files tied to what changed against a base: a changed test file,
# or a test that names a changed script; a change to a shared helper runs everything.
source "$(dirname "$0")/lib.sh"
r="$(new_repo)"; cd "$r"; mkdir -p scripts/test; cp "$FACTORY_DIR/test/run.sh" scripts/test/
echo 'echo x' > scripts/x.sh; echo 'echo y' > scripts/y.sh; echo '# helper' > scripts/test/lib.sh
printf '#!/usr/bin/env bash\n# uses x.sh\necho "  ok   a"\n' > scripts/test/a.test.sh
printf '#!/usr/bin/env bash\n# uses y.sh\necho "  ok   b"\n' > scripts/test/b.test.sh
git add -A; git commit -qm base; git branch -q base
ran() { bash scripts/test/run.sh --changed base 2>&1; }

assert_contains "$(ran)" "nothing to run"
echo 'echo x2' > scripts/x.sh
out="$(ran)"; assert_contains "$out" "== a.test.sh"
case "$out" in *"== b.test.sh"*) fail "ran a test of an unchanged script" ;; *) pass "only the affected test ran" ;; esac
git commit -qam x; echo '# new' >> scripts/test/b.test.sh
out="$(ran)"; assert_contains "$out" "== a.test.sh"; assert_contains "$out" "== b.test.sh"
git checkout -q -- scripts/test/b.test.sh; echo '# changed' >> scripts/test/lib.sh
assert_contains "$(ran)" "== 2 files"
finish
