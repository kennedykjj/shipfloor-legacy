#!/usr/bin/env bash
# suite: integration
# acceptance-intact ignores files the QA commit deleted.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
r="$(new_repo)"; cd "$r"; mkdir -p web/i18n web/e2e; echo old > web/i18n/index.test.ts; git add -A; git commit -qm base
git rm -q web/i18n/index.test.ts; echo new > web/e2e/i18n.spec.ts; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
finish
