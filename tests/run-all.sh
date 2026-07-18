#!/bin/bash
###############################################################################
# Val Ark - unified test runner.
#
# Runs every suite and produces ONE self-contained, human-readable HTML report
# (tests/results/report.html) you can host locally with no internet:
#
#   * Bash validators  (tests/test-*.sh: deps, models, tls, tools, urls)
#   * Playwright        (server-api, web-ui, install-icons, ui-exercise)
#   * Community services e2e   (when an Ark is reachable — VALARK_URL)
#   * Fresh-VM setup tests     (opt-in: VALARK_RUN_VM=1 — Ubuntu 22/24/26)
#
# Env:
#   VALARK_URL=http://host:3000   run the services e2e against that Ark
#   VALARK_RUN_VM=1               also run the (slow) fresh-VM setup matrix
#   VALARK_NO_PLAYWRIGHT=1        skip the browser suite
#
# Exit code is non-zero if any case failed. The HTML report always renders.
###############################################################################
set -o pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${TEST_DIR}")"
RESULTS_DIR="${TEST_DIR}/results"
export VALARK_RESULTS_DIR="$RESULTS_DIR"
export REPORT_STAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
. "${TEST_DIR}/lib/results.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# Fresh results each run (keep report.html until regenerated).
mkdir -p "$RESULTS_DIR"; rm -f "$RESULTS_DIR"/*.json 2>/dev/null

# Resolve a node dir (nvm / ~/.local / mirrored / system) for Playwright + report.
NODE_DIR=""
for c in "$HOME/.local/node/bin" "${PROJECT_ROOT}"/tools/linux-*/node/bin "$HOME"/.nvm/versions/node/*/bin; do
    [ -x "$c/node" ] && NODE_DIR="$c" && break
done
[ -n "$NODE_DIR" ] || { command -v node >/dev/null 2>&1 && NODE_DIR="$(dirname "$(command -v node)")"; }
NODE="${NODE_DIR:+$NODE_DIR/}node"

echo ""
echo "=================================================================="
echo -e "  ${BOLD}Val Ark - Test Suite${NC}"
echo "=================================================================="

# --- 1. Bash validators -------------------------------------------------------
echo -e "\n${BOLD}Bash validators${NC}"
results_init "bash-validators" "Bash validators (deps / models / tls / tools / urls)"
for test_file in "${TEST_DIR}"/test-*.sh; do
    [ -f "$test_file" ] || continue
    name="$(basename "$test_file" .sh | sed 's/test-//')"
    results_run "$name" bash "$test_file"
done
results_finish

# --- 2. Playwright ------------------------------------------------------------
if [ "${VALARK_NO_PLAYWRIGHT:-0}" != "1" ] && [ -x "${TEST_DIR}/screenshots/node_modules/.bin/playwright" ]; then
    echo -e "\n${BOLD}Playwright (browser)${NC}"
    PW_JSON="${RESULTS_DIR}/.playwright.json"
    ( cd "${TEST_DIR}/screenshots" && PATH="${NODE_DIR}:$PATH" \
        PLAYWRIGHT_JSON_OUTPUT_NAME="$PW_JSON" ./node_modules/.bin/playwright test --reporter=json >/dev/null 2>&1 )
    if [ -s "$PW_JSON" ] && [ -n "$NODE_DIR" ]; then
        "$NODE" "${TEST_DIR}/report/from-playwright.mjs" "$PW_JSON" "$RESULTS_DIR"
        rm -f "$PW_JSON"
    else
        echo -e "  ${YELLOW}playwright produced no JSON${NC}"
    fi
else
    echo -e "\n  ${YELLOW}Playwright skipped${NC} (cd tests/screenshots && npm install, or VALARK_NO_PLAYWRIGHT=1)"
fi

# --- 3. Community services e2e (only when an Ark is reachable) -----------------
SVC_URL="${VALARK_URL:-http://127.0.0.1:3000}"
if curl -fsS --max-time 5 "${SVC_URL%/}/api/health" >/dev/null 2>&1; then
    echo -e "\n${BOLD}Community services e2e${NC} (@ ${SVC_URL})"
    VALARK_URL="$SVC_URL" bash "${TEST_DIR}/services/run.sh"
else
    echo -e "\n  ${YELLOW}Services e2e skipped${NC} (no Ark at ${SVC_URL}; set VALARK_URL)"
fi

# --- 4. Fresh-VM setup matrix (opt-in; slow) ----------------------------------
if [ "${VALARK_RUN_VM:-0}" = "1" ]; then
    echo -e "\n${BOLD}Fresh-VM setup matrix${NC} (Ubuntu 22/24/26)"
    bash "${TEST_DIR}/vm/run.sh"
else
    echo -e "\n  ${YELLOW}VM matrix skipped${NC} (VALARK_RUN_VM=1 to run Ubuntu 22/24/26 fresh-setup tests)"
fi

# --- 5. Unified HTML report ---------------------------------------------------
echo ""
echo "=================================================================="
if [ -n "$NODE_DIR" ]; then
    "$NODE" "${TEST_DIR}/report/generate.mjs" "$RESULTS_DIR" "${RESULTS_DIR}/report.html"
    RC=$?
    echo -e "  Report: ${BOLD}${RESULTS_DIR}/report.html${NC}"
    echo -e "  Host it: ${BOLD}(cd ${RESULTS_DIR} && python3 -m http.server 8099)${NC} -> http://<host>:8099/report.html"
else
    echo -e "  ${YELLOW}node not found — cannot render HTML report${NC}"
    # No generate.mjs to aggregate the results, so scan the suite JSONs
    # directly (results.sh writes "failed":N unspaced) — every suite (bash
    # validators, services e2e, VM matrix) records failures there, and the
    # gate must not go green just because node is missing.
    if grep -q '"failed":[1-9]' "$RESULTS_DIR"/*.json 2>/dev/null; then
        echo -e "  ${RED}suite failures recorded in ${RESULTS_DIR} — exiting non-zero${NC}"
        RC=1
    else
        RC=0
    fi
fi
echo "=================================================================="
echo ""
exit "${RC:-0}"
