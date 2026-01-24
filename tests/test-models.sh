#!/bin/bash
###############################################################################
# Test: Model download script is valid and parseable
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Script exists and is executable
check "download-models.sh exists" test -f "${PROJECT_ROOT}/scripts/download-models.sh"
check "download-models.sh executable" test -x "${PROJECT_ROOT}/scripts/download-models.sh"

# Script parses without errors
check "download-models.sh syntax" bash -n "${PROJECT_ROOT}/scripts/download-models.sh"

# start.sh exists and is executable
check "start.sh exists" test -f "${PROJECT_ROOT}/start.sh"
check "start.sh executable" test -x "${PROJECT_ROOT}/start.sh"
check "start.sh syntax" bash -n "${PROJECT_ROOT}/start.sh"

[ $FAIL -eq 0 ] && exit 0 || exit 1
