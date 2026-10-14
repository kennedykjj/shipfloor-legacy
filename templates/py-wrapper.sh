#!/usr/bin/env bash
# Wrapper template: a script that sits beside lib/ and sf.py (the factory folder, or scripts/ in the plugin).
# Copy it under the script's own name; it runs `sf.py <args>` under the factory's Python.
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.  # no dirname: one process less per start
source "$HERE/lib/py.sh"
