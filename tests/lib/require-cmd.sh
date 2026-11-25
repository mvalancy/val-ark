#!/bin/bash
###############################################################################
# Runtime guards for bash validators that need python3 / node / another command (#255, #286).
#
# Locally, a missing runtime SKIPS the check (exit 0, "SKIP: ..."), matching the suite's
# degrade-gracefully posture. Under CI a missing runtime is a FAILURE (exit 1, "FAIL: ..."):
# a skip there would quietly switch the guard off.
#
#   . "$ROOT/tests/lib/require-cmd.sh"
#   require_cmd node "browser-report regression"     # command -v node, else skip / fail
#   require_python3 "internal-link check"            # = require_cmd python3 ...
#   [ -n "$NODE" ] || missing_cmd node "health API"  # a runtime you resolved yourself
#   if ci_is_set; then fail "…"; else echo "SKIP: …"; fi   # one case, not the whole file
#
# CI counts as set unless it is empty or (any case) false / 0 / no / off.
###############################################################################
ci_is_set() {
    case "${CI:-}" in   # bash-3 safe (no ${CI,,}): spell each case-insensitive word out
        ''|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 1 ;;
    esac
    return 0
}

# missing_cmd CMD WHAT -- always exits: 1 under CI, 0 (skip) otherwise.
missing_cmd() {
    if ci_is_set; then
        echo "FAIL: $1 not found under CI — ${2:-this check} cannot run, refusing to skip" >&2
        exit 1
    fi
    echo "SKIP: $1 not found — ${2:-this check} needs it (CI has $1)" >&2
    exit 0
}

# require_cmd CMD WHAT -- return if CMD is on PATH, else missing_cmd.
require_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    missing_cmd "$1" "${2:-}"
}

require_python3() { require_cmd python3 "${1:-}"; }
