#!/bin/bash
###############################################################################
# Test: Tool download script is valid and parseable
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
check "download-tools.sh exists" test -f "${PROJECT_ROOT}/scripts/download-tools.sh"
check "download-tools.sh executable" test -x "${PROJECT_ROOT}/scripts/download-tools.sh"

# Script parses without errors
check "download-tools.sh syntax" bash -n "${PROJECT_ROOT}/scripts/download-tools.sh"

# Script shows usage on bad arg (exits non-zero, but produces output)
output=$(bash "${PROJECT_ROOT}/scripts/download-tools.sh" --help-not-exist 2>&1 || true)
if echo "$output" | grep -q "Usage"; then
    PASS=$((PASS + 1))
else
    echo "FAIL: download-tools.sh usage" >&2
    FAIL=$((FAIL + 1))
fi

[ $FAIL -eq 0 ] && exit 0 || exit 1
