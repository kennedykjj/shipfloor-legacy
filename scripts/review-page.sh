#!/usr/bin/env bash
# Builds the local interactive review page for an issue spec.
# usage: review-page.sh <spec.md> <issue> <branch> <out.html>
set -uo pipefail
[ $# -eq 4 ] || { echo "usage: review-page.sh <spec.md> <issue> <branch> <out.html>" >&2; exit 2; }
[ -f "$1" ] || { echo "review-page: spec not found: $1" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$4")"
w() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
python -I "$(w "$HERE/review_page.py")" "$(w "$1")" "$2" "$3" "$(w "$4")" "$(w "$HERE/review-template.html")" "$1" "${FACTORY_PROJECT:-}"
