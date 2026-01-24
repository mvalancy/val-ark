#!/bin/bash
###############################################################################
# Val Ark - Screenshot & Terminal Recording Automation
#
# Usage: ./scripts/screenshots.sh [all|web|terminal]
#
# Generates:
#   docs/screenshots/*.png    - Web UI screenshots (Playwright)
#   docs/screenshots/*.svg    - Terminal recordings (asciinema + svg-term-cli)
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCREENSHOT_DIR="${PROJECT_ROOT}/docs/screenshots"
TESTS_DIR="${PROJECT_ROOT}/tests/screenshots"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$SCREENSHOT_DIR"

###############################################################################
# Web UI Screenshots (Playwright)
###############################################################################

capture_web() {
    echo -e "${BOLD}Capturing Web UI screenshots...${NC}"
    echo ""

    if [ ! -d "${TESTS_DIR}/node_modules" ]; then
        echo "  Installing Playwright dependencies..."
        (cd "$TESTS_DIR" && npm install --quiet 2>/dev/null)
        (cd "$TESTS_DIR" && npx playwright install chromium 2>/dev/null)
    fi

    if [ -f "${TESTS_DIR}/node_modules/.bin/playwright" ]; then
        (cd "$TESTS_DIR" && npx playwright test 2>&1) | while IFS= read -r line; do
            echo "  $line"
        done

        local count
        count=$(find "$SCREENSHOT_DIR" -name '*.png' 2>/dev/null | wc -l)
        echo ""
        echo -e "  ${GREEN}✓${NC} ${count} PNG screenshots in docs/screenshots/"
    else
        echo -e "  ${RED}✗${NC} Playwright not installed. Run: cd tests/screenshots && npm install"
    fi
}

###############################################################################
# Terminal Recordings (asciinema → SVG)
###############################################################################

capture_terminal() {
    echo -e "${BOLD}Capturing terminal recordings...${NC}"
    echo ""

    # Check for asciinema
    if ! command -v asciinema >/dev/null 2>&1; then
        echo -e "  ${YELLOW}!${NC} asciinema not found. Install: pip install asciinema"
        echo "    Skipping terminal recordings."
        return 1
    fi

    # Check for svg-term-cli
    local svg_term=""
    if command -v svg-term >/dev/null 2>&1; then
        svg_term="svg-term"
    elif [ -f "${TESTS_DIR}/node_modules/.bin/svg-term" ]; then
        svg_term="${TESTS_DIR}/node_modules/.bin/svg-term"
    else
        echo -e "  ${YELLOW}!${NC} svg-term-cli not found. Install: npm install -g svg-term-cli"
        echo "    Skipping SVG conversion."
        return 1
    fi

    # Record: start.sh menu
    echo "  Recording: start.sh menu..."
    local cast_menu="/tmp/val-ark-menu.cast"
    asciinema rec --overwrite -c "echo ''; printf '0\n' | bash ${PROJECT_ROOT}/start.sh 2>/dev/null || true" "$cast_menu" 2>/dev/null

    if [ -f "$cast_menu" ]; then
        $svg_term --in "$cast_menu" --out "${SCREENSHOT_DIR}/terminal-menu.svg" \
            --window --width 80 --height 24 --term xterm-256color 2>/dev/null
        rm -f "$cast_menu"
        echo -e "  ${GREEN}✓${NC} terminal-menu.svg"
    fi

    # Record: start.sh status
    echo "  Recording: start.sh status..."
    local cast_status="/tmp/val-ark-status.cast"
    asciinema rec --overwrite -c "bash ${PROJECT_ROOT}/start.sh status 2>/dev/null || true" "$cast_status" 2>/dev/null

    if [ -f "$cast_status" ]; then
        $svg_term --in "$cast_status" --out "${SCREENSHOT_DIR}/terminal-status.svg" \
            --window --width 80 --height 24 --term xterm-256color 2>/dev/null
        rm -f "$cast_status"
        echo -e "  ${GREEN}✓${NC} terminal-status.svg"
    fi

    echo ""
    local svg_count
    svg_count=$(find "$SCREENSHOT_DIR" -name '*.svg' 2>/dev/null | wc -l)
    echo -e "  ${GREEN}✓${NC} ${svg_count} SVG recordings in docs/screenshots/"
}

###############################################################################
# Main
###############################################################################

case "${1:-all}" in
    web)      capture_web ;;
    terminal) capture_terminal ;;
    all)
        capture_web
        echo ""
        capture_terminal
        echo ""
        echo -e "${GREEN}Done.${NC} Screenshots in: docs/screenshots/"
        ;;
    *)
        echo "Usage: $0 [all|web|terminal]"
        exit 1
        ;;
esac
