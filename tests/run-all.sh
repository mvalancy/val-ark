#!/bin/bash
###############################################################################
# Val Ark - Test Suite Runner
# Runs all validation tests
###############################################################################

set -o pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${TEST_DIR}")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

run_test() {
    local test_script="$1"
    local test_name=$(basename "$test_script" .sh | sed 's/test-//')

    echo -n "  Testing ${test_name}... "
    if bash "$test_script" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=================================================================="
echo -e "  ${BOLD}Val Ark - Validation Suite${NC}"
echo "=================================================================="
echo ""

for test_file in "${TEST_DIR}"/test-*.sh; do
    [ -f "$test_file" ] || continue
    run_test "$test_file"
done

# Playwright suite (server API + web UI + dynamic UI exercise). Spins up its own
# ephemeral server; skipped cleanly if deps aren't installed.
PW="${TEST_DIR}/screenshots/node_modules/.bin/playwright"
if [ -x "$PW" ]; then
    # Find a node on PATH (nvm / ~/.local / system).
    PW_NODE_DIR=""
    for c in "$HOME/.local/node/bin" "$HOME"/.nvm/versions/node/*/bin; do
        [ -x "$c/node" ] && PW_NODE_DIR="$c" && break
    done
    [ -n "$PW_NODE_DIR" ] || { command -v node >/dev/null 2>&1 && PW_NODE_DIR="$(dirname "$(command -v node)")"; }
    echo -n "  Testing playwright (api + web-ui + ui-exercise)... "
    if (cd "${TEST_DIR}/screenshots" && PATH="${PW_NODE_DIR}:$PATH" "$PW" test --reporter=line >/dev/null 2>&1); then
        echo -e "${GREEN}PASS${NC}"; PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"; FAIL=$((FAIL + 1))
    fi
else
    echo -e "  Testing playwright... ${YELLOW}SKIP${NC} (cd tests/screenshots && npm install)"
fi

echo ""
echo "=================================================================="
echo -e "  Results: ${GREEN}${PASS} passed${NC} | ${RED}${FAIL} failed${NC}"
echo "=================================================================="
echo ""

[ $FAIL -eq 0 ] && exit 0 || exit 1
