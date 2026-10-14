#!/usr/bin/env bash
# Builds the local interactive review page for an issue spec. The logic is shipfloor_core/review_page.py.
# usage: review-page.sh <spec.md> <issue> <branch> <out.html> [--request-file F]
#        review-page.sh --diff <old.md> <new.md>
set -- review-page "$@"
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
source "$HERE/lib/py.sh"
