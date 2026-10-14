#!/usr/bin/env bash
# deploy.sh, the rest: a local_ci timeout (124) and no timeout binary, ci_findings with GitHub's failed logs, and the
# pt-BR text of every comment (markers and CONFLICT lines stay English). Exit code and what the fake gh recorded.
source "$(dirname "$0")/deploy-lib.sh"
export FAKE_GH="$FACTORY_DIR/test/fake-gh-deploy"
gh_with() {  # gh_with '<shell>': the fake gh behind a snippet that may answer a call itself (L logs it) or let it through
  printf '#!/usr/bin/env bash\nL() { echo "$*" >> "$FG/calls"; }\n%s\nexec bash "%s" "$@"\n' "$1" "$FAKE_GH" > "$T/gh"
  chmod +x "$T/gh"; export FACTORY_GH="$T/gh"
}
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out")"; }
posted() { case "$(cat "$FG/calls" 2>/dev/null)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
dcfg() { sed -i '/^deploy:/d' "$FACTORY_CONFIG"; printf 'deploy: %s\n' "$1" >> "$FACTORY_CONFIG"; }
lci() { dcfg "{local_ci: '$1'}"; }
ptbr() { echo "language: pt-BR" >> "$FACTORY_CONFIG"; }
head_of() { git --git-dir="$remote" rev-parse feat/7-x; }
not_in() { case "$1" in *"$2"*) fail "found '$2' in: $1" ;; *) pass "no '$2'" ;; esac; }

# AC-7: local_ci times out (exit 124) after merging main → Coding, "did not finish"; nothing merged
scene behind; lci 'exit 124'; code="$(run 7)"
want "$code" 4 "local_ci timeout after merging main → Coding"
[ "$(cat "$FG/status")" = Coding ] && pass "timeout: card in Coding" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "Back to Coding: CI did not finish on the PR after merging main ("
assert_contains "$(cat "$T/out")" "local CI did not finish on "
assert_contains "$(cat "$T/out")" " in 30 min"
posted "pr merge" && fail "timeout: merged" || pass "timeout: nothing merged"
[ ! -e "$FACTORY_HOME/tmp/7/fix.parent" ] && pass "timeout: no fix round" || fail "fix round started"
# ...with nothing merged in, it blocks for the owner instead
setup; lci 'exit 124'; code="$(run 7)"
want "$code" 5 "local_ci timeout on the approved head → blocked"
assert_contains "$(cat "$FG/comments")" "Factory deploy stopped: CI failed on the PR ("
assert_contains "$(cat "$FG/labels")" blocked
posted "pr merge" && fail "timeout on the approved head: merged" || pass "timeout on the approved head: nothing merged"

# no timeout binary: the command still runs (without a limit) and decides the outcome
NT="$(mktemp -d)"; IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do [ -d "$d" ] && ln -sf -t "$NT" "$d"/* 2>/dev/null; done; rm -f "$NT/timeout"
if [ -z "$(PATH="$NT" bash -c 'command -v timeout')" ]; then
  pass "a PATH without timeout"
  scene behind; lci 'echo ran > "$FG/ran"; test -f web/other.ts && test -f api/A.kt'; code="$(PATH="$NT" run 7)"
  want "$code" 0 "no timeout binary: green local_ci ships"
  [ -s "$FG/ran" ] && pass "no timeout binary: the command ran" || fail "the command did not run"
  [ "$(cat "$FG/status")" = Done ] && pass "no timeout binary: card in Done" || fail "status $(cat "$FG/status")"
  assert_contains "$(cat "$T/out")" "local CI passed on"
  assert_contains "$(cat "$FG/comments")" "Deployed: merge"
  scene behind; lci 'echo "suite: 2 FAIL without timeout"; exit 1'; code="$(PATH="$NT" run 7)"
  want "$code" 3 "no timeout binary: red local_ci → fix round"
  assert_contains "$(cat "$FACTORY_HOME/tmp/7/fix.findings")" "suite: 2 FAIL without timeout"
  posted "pr merge" && fail "no timeout binary: merged a red card" || pass "no timeout binary: nothing merged"
  scene behind; lci 'exit 124'; code="$(PATH="$NT" run 7)"
  want "$code" 4 "no timeout binary: the command's own 124 → Coding"
  assert_contains "$(cat "$FG/comments")" "Back to Coding: CI did not finish on the PR after merging main ("
else
  fail "could not build a PATH without timeout"
fi

# ci_findings: the red checks and the end of each failed run's log from GitHub, in the fix round's findings
scene behind; echo "api=FAILURE" > "$FG/ci"
gh_with 'case "$*" in
  "run list"*conclusion*) L "$*"; printf "41\n42\nabc\n"; exit 0 ;;
  "run view 41"*--log-failed*) L "$*"; seq 1 200 | sed "s/^/L41 /"; exit 0 ;;
  "run view 42"*--log-failed*) L "$*"; echo "LOG42 only line"; exit 0 ;;
esac'
code="$(run 7)"; want "$code" 3 "red CI after merging main → fix round with GitHub's logs"
f="$(cat "$FACTORY_HOME/tmp/7/fix.findings")"
assert_contains "$f" "checks on $(head_of): api=FAILURE"
assert_contains "$f" "L41 200"
assert_contains "$f" "L41 51"
not_in "$f" "L41 50"
assert_contains "$f" "LOG42 only line"
posted "run view abc" && fail "asked for the log of a run that is not a number" || pass "a non-numeric run id is skipped"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "findings: card stays in Ready for Prod" || fail "status $(cat "$FG/status")"
posted "pr merge" && fail "findings: merged" || pass "findings: nothing merged"
# with deploy.local_ci the logs are the command's, and GitHub's runs are not asked for
scene behind; lci 'echo "local says no"; exit 1'
gh_with 'case "$*" in "run list"*conclusion*) L "$*"; echo 41; exit 0 ;; "run view"*--log-failed*) L "$*"; echo "GITHUB LOG"; exit 0 ;; esac'
code="$(run 7)"; want "$code" 3 "red local CI → fix round"
f="$(cat "$FACTORY_HOME/tmp/7/fix.findings")"
assert_contains "$f" "local says no"
not_in "$f" "GITHUB LOG"
posted "run list" && fail "asked GitHub for failed runs with local_ci" || pass "local_ci: GitHub's runs not asked for"

# language pt-BR: the comments are in Portuguese, the markers and CONFLICT lines stay in English
# blocked
setup; ptbr; touch "$FG/no-pr"; code="$(run 7)"; want "$code" 5 "pt-BR: blocked"
assert_contains "$(cat "$FG/comments")" "O deploy da fábrica parou: esperava um PR aberto para #7, encontrou: none"
assert_contains "$(cat "$FG/labels")" blocked
not_in "$(cat "$FG/comments")" "Factory deploy stopped"
# approval
setup; ptbr; w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
echo sneaky > "$w/api/B.kt"; git -C "$w" add -A; git -C "$w" commit -qm sneaky; git -C "$w" push -q origin feat/7-x
code="$(run 7)"; want "$code" 5 "pt-BR: unapproved head blocked"
assert_contains "$(cat "$FG/comments")" "O deploy da fábrica parou: o PR #78 mudou depois de ir para Staged (o head "
assert_contains "$(cat "$FG/comments")" "não é o staged-head nem um merge da main registrado sobre ele)"
# fork
setup; ptbr; gh_with 'case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@" | awk -F"\t" -v OFS="\t" "{ \$3 = \"true\"; print }"; exit 0 ;; esac'
code="$(run 7)"; want "$code" 5 "pt-BR: fork blocked"
assert_contains "$(cat "$FG/comments")" "O deploy da fábrica parou: o PR #78 vem de um fork; a fábrica só faz deploy dos próprios branches"
# Back to Coding
setup; ptbr; on_branch "$M/V2__card.sql" card; main_commit "$M/V2__card.sql" main; code="$(run 7)"
want "$code" 4 "pt-BR: migration conflict → Coding"
assert_contains "$(cat "$FG/comments")" "Voltou para Coding: uma migration conflita com a main: "
assert_contains "$(cat "$T/out")" ": voltou para Coding: uma migration conflita com a main: "
# a conflict handed over: CONFLICT lines English, the instruction translated
setup; ptbr; on_branch shared.txt card; main_commit shared.txt main; code="$(run 7)"
want "$code" 3 "pt-BR: conflict handed over"
assert_contains "$(cat "$T/out")" "CONFLICT shared.txt"
assert_contains "$(cat "$T/out")" "resolva estes conflitos, faça o commit e rode: deploy.sh 7 --continue"
not_in "$(cat "$T/out")" "resolve these conflicts"
# a fix round from red CI: log in Portuguese, findings and markers in English; then a small fix ships
scene behind; ptbr; echo "api=FAILURE" > "$FG/ci"; code="$(run 7)"; want "$code" 3 "pt-BR: red CI → fix round"
assert_contains "$(cat "$T/out")" "rodada de conserto 1 de 2: o CI falhou no PR depois do merge da main ("
assert_contains "$(cat "$FACTORY_HOME/tmp/7/fix.findings")" "checks on "
assert_contains "$(cat "$FG/comments")" "deploy-merge: "
fix api/A.kt 3; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"; want "$code" 0 "pt-BR: small fix ships"
assert_contains "$(cat "$T/out")" "conserto pequeno (1 arquivos, "
assert_contains "$(cat "$FG/comments")" "deploy-fix: "
assert_contains "$(cat "$FG/comments")" "Deploy feito: merge $(cat "$FG/merged") · "
assert_contains "$(cat "$FG/comments")" " min desde o início desta execução do deploy."
not_in "$(cat "$FG/comments")" "Deployed:"
# a large fix → Staged, the marker line stays English
scene behind; ptbr; echo "api=FAILURE" > "$FG/ci"; code="$(run 7)"
fix api/N.kt 200; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"; want "$code" 4 "pt-BR: large fix → Staged"
assert_contains "$(cat "$FG/comments")" "Voltou para Staged: o deploy mesclou a main e um agente consertou o que quebrou ("
assert_contains "$(cat "$FG/comments")" "O conserto tem 1 arquivos e 200 linhas: mais do que deploy.fix_max_files=3 / fix_max_lines=40 deixam passar sem você. Revise o diff "
assert_contains "$(cat "$FG/comments")" "staged-head: $(head_of)"
# production failed, with the log of the failed run, and the revert PR
setup; ptbr; dcfg '{ci_workflow: CI}'; echo "completed failure" > "$FG/concl-1"; echo "completed failure" > "$FG/rerun-1"
gh_with 'case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; "run view"*--log-failed*) L "$*"; echo "FAILED LOG: boom"; exit 0 ;; esac'
code="$(run 7)"; want "$code" 6 "pt-BR: production failed"
assert_contains "$(cat "$FG/comments")" "O deploy em produção falhou: o CI da main falhou (execução 1: failure). PR de revert: https://github.com/acme/shop/pull/999"
assert_contains "$(cat "$FG/comments")" "Fim do log da execução que falhou:"
assert_contains "$(cat "$FG/comments")" "FAILED LOG: boom"
assert_contains "$(cat "$FG/comments")" "staged-head: $(git --git-dir="$remote" rev-parse refs/heads/revert/7)"
assert_contains "$(cat "$T/out")" "falhou depois do merge: o CI da main falhou (execução 1: failure); revert "
assert_contains "$(cat "$T/out")" "rodando os jobs falhos mais uma vez"
# a revert that cannot be prepared
setup; ptbr; echo 22 > "$FG/curl"; git -C "$repo" push -q origin feat/7-x:refs/heads/revert/7; code="$(run 7)"; want "$code" 6 "pt-BR: revert by hand"
assert_contains "$(cat "$FG/comments")" "O deploy em produção falhou: o health check falhou: https://shop.example/health. O revert não pôde ser preparado automaticamente: reverta $(cat "$FG/merged") à mão."
finish
