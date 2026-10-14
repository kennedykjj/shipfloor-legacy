#!/usr/bin/env bash
# The dashboard's JavaScript in a real browser (scripts/test/py/dashboard_browser.py): Playwright, headless Chromium.
# BROWSER_PYTHON names the Python that has Playwright (a test-only venv, see requirements-browser.txt); default FACTORY_PYTHON.
# Without Playwright the tests skip; BROWSER_TESTS=required (CI's browser job) makes that one FAIL.
source "$(dirname "$0")/lib.sh"
FACTORY_PYTHON="${BROWSER_PYTHON:-$FACTORY_PYTHON}" py_suite dashboard_browser
finish
