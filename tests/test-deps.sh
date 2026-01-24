#!/bin/bash
###############################################################################
# Test: Required dependencies are available
###############################################################################

PASS=0
FAIL=0

check() {
    if command -v "$1" &>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "MISSING: $1" >&2
        FAIL=$((FAIL + 1))
    fi
}

check wget
check curl
check git
check tar
check bash

[ $FAIL -eq 0 ] && exit 0 || exit 1
