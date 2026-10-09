#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
M=api/src/main/resources/db/migration

spec_with() { printf '# Spec\n\n## Rollback\n\n%s\n\n## Dúvidas\n\nnenhuma\n' "$1" > spec.md; }

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$M"
echo 'ALTER TABLE a ADD COLUMN b text;' > "$M/V2__add.sql"; spec_with "não se aplica"
assert_exit 0 bash "$GATE" migration "$base" spec.md

echo 'alter table a drop column b;' > "$M/V3__drop.sql"
assert_exit 1 bash "$GATE" migration "$base" spec.md
spec_with "Reverter com V4 que recria a coluna b a partir do backup em a_b_backup."
assert_exit 0 bash "$GATE" migration "$base" spec.md

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$M"
printf -- '-- we do not drop anything here\nCREATE TABLE x (id int);\n' > "$M/V2__x.sql"; spec_with "não se aplica"
assert_exit 0 bash "$GATE" migration "$base" spec.md

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$M"
echo 'ALTER TABLE a RENAME COLUMN b TO c;' > "$M/V2__r.sql"; spec_with ""
assert_exit 1 bash "$GATE" migration "$base" spec.md
finish
