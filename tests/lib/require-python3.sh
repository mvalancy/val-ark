#!/bin/bash
###############################################################################
# require_python3 WHAT -- the python3 guard for every python-based bash validator (#255).
#
# Locally a box without python3 skips the check (exit 0, "SKIP: ..."), matching the suite's
# degrade-gracefully posture. Under CI (the CI env var set, as GitHub Actions does) a missing
# python3 is a FAILURE (exit 1): otherwise the guard would quietly switch itself off there.
#   . "$ROOT/tests/lib/require-python3.sh"; require_python3 "internal-link check"
# CI=false / CI=0 count as "not CI".
###############################################################################
require_python3() {
    command -v python3 >/dev/null 2>&1 && return 0
    case "${CI:-}" in
        ''|false|0)
            echo "SKIP: python3 not found — ${1:-this check} needs it (CI has python3)" >&2
            exit 0 ;;
        *)
            echo "FAIL: python3 not found under CI — ${1:-this check} cannot run, refusing to skip" >&2
            exit 1 ;;
    esac
}
