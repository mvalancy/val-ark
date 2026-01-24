#!/bin/bash
###############################################################################
# Val Ark - Online-Optional Tool Server
# Entry point: interactive menu + CLI arguments
#
# Created by Matthew Valancy
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/scripts"
TESTS="${SCRIPT_DIR}/tests"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

###############################################################################
# Cron Management
###############################################################################

CRON_CMD="cd ${SCRIPT_DIR} && ./start.sh update >> /var/log/val-ark-update.log 2>&1"
CRON_SCHEDULE="0 3 * * 0"
CRON_LINE="${CRON_SCHEDULE} ${CRON_CMD}"

cron_install() {
    (crontab -l 2>/dev/null | grep -v "val-ark-update"; echo "$CRON_LINE") | crontab -
    echo -e "  ${GREEN}✓${NC} Weekly cron job installed (Sundays at 3 AM)"
    echo "    ${CRON_LINE}"
}

cron_remove() {
    crontab -l 2>/dev/null | grep -v "val-ark-update" | crontab -
    echo -e "  ${GREEN}✓${NC} Cron job removed"
}

cron_status() {
    echo ""
    echo -e "  ${BOLD}Val Ark cron entries:${NC}"
    echo ""
    local entries
    entries=$(crontab -l 2>/dev/null | grep "val-ark" || true)
    if [ -n "$entries" ]; then
        echo "  $entries"
    else
        echo "  (none)"
    fi
    echo ""
}

cron_menu() {
    echo ""
    echo -e "  ${BOLD}Cron Job${NC}"
    echo ""
    echo "  1) Install    Weekly auto-update (Sundays 3 AM)"
    echo "  2) Remove     Remove cron job"
    echo "  3) Status     Show current entries"
    echo ""
    echo "  0) Back"
    echo ""
    echo -n "  Enter choice [0-3]: "
    read -r choice

    case "$choice" in
        1) cron_install ;;
        2) cron_remove ;;
        3) cron_status ;;
        0|"") return ;;
        *) echo -e "  ${RED}Invalid choice${NC}"; cron_menu ;;
    esac
}

###############################################################################
# CLI Mode
###############################################################################

show_help() {
    echo ""
    echo -e "${BOLD}Val Ark${NC} - Online-Optional Tool Server"
    echo ""
    echo "Usage: ./start.sh [command] [options]"
    echo ""
    echo "Commands:"
    echo "  setup                    Install dependencies, create directories"
    echo "  download tools           Download tools (smallest first, then AI engines)"
    echo "  download models tier1    Download edge/mobile models (small, fast)"
    echo "  download models tier2    Download balanced workstation models"
    echo "  download models tier3    Download large models (space permitting)"
    echo "  download models all      Download all model tiers"
    echo "  download all             Download everything (tools first, then models)"
    echo "  update                   Update tools and assets"
    echo "  monitor                  Watch active downloads"
    echo "  status                   Show what's installed"
    echo "  test                     Run validation suite"
    echo "  screenshots [web|terminal]  Capture screenshots and terminal recordings"
    echo "  cron install             Install weekly auto-update cron job"
    echo "  cron remove              Remove cron job"
    echo "  cron status              Show current cron entries"
    echo "  uninstall                Remove Val Ark configuration"
    echo "  help                     Show this help"
    echo ""
    echo "Examples:"
    echo "  ./start.sh setup"
    echo "  ./start.sh download tools"
    echo "  ./start.sh download models tier1"
    echo "  ./start.sh download all"
    echo "  ./start.sh cron install"
    echo "  ./start.sh screenshots"
    echo ""
}

###############################################################################
# Download Submenu (interactive)
###############################################################################

download_menu() {
    echo ""
    echo -e "  ${BOLD}Download what?${NC}"
    echo ""
    echo "  1) Tools (small utilities first, then AI engines)"
    echo "  2) Models - Tier 1 (small/fast, phones & edge)"
    echo "  3) Models - Tier 2 (balanced workstation)"
    echo "  4) Models - Tier 3 (large, space permitting)"
    echo "  5) Models - All tiers"
    echo "  6) Everything (tools first, then models by tier)"
    echo ""
    echo "  0) Back"
    echo ""
    echo -n "  Enter choice [0-6]: "
    read -r choice

    case "$choice" in
        1) exec bash "${SCRIPTS}/download-tools.sh" all ;;
        2) exec bash "${SCRIPTS}/download-models.sh" tier1 ;;
        3) exec bash "${SCRIPTS}/download-models.sh" tier2 ;;
        4) exec bash "${SCRIPTS}/download-models.sh" tier3 ;;
        5) exec bash "${SCRIPTS}/download-models.sh" all ;;
        6)
            bash "${SCRIPTS}/download-tools.sh" all
            bash "${SCRIPTS}/download-models.sh" all
            ;;
        0|"") return ;;
        *) echo -e "  ${RED}Invalid choice${NC}"; download_menu ;;
    esac
}

###############################################################################
# Interactive Menu
###############################################################################

interactive_menu() {
    while true; do
        echo ""
        echo -e "${DIM}══════════════════════════════════════${NC}"
        echo -e "  ${BOLD}Val Ark${NC} - Online-Optional Tool Server"
        echo -e "${DIM}══════════════════════════════════════${NC}"
        echo ""
        echo "  1) Setup       Install dependencies, create directories"
        echo "  2) Download    Download tools and models (by priority)"
        echo "  3) Update      Update tools and assets"
        echo "  4) Monitor     Watch active downloads"
        echo "  5) Status      Show what's installed"
        echo "  6) Test        Run validation suite"
        echo "  7) Uninstall   Remove Val Ark configuration"
        echo "  8) Help        Show detailed help"
        echo "  9) Cron        Manage auto-update schedule"
        echo ""
        echo "  0) Exit"
        echo ""
        echo -n "  Enter choice [0-9]: "
        read -r choice

        case "$choice" in
            1) exec bash "${SCRIPTS}/setup.sh" ;;
            2) download_menu ;;
            3) exec bash "${SCRIPTS}/update.sh" all ;;
            4) exec bash "${SCRIPTS}/monitor.sh" ;;
            5) exec bash "${SCRIPTS}/status.sh" ;;
            6) exec bash "${TESTS}/run-all.sh" ;;
            7) exec bash "${SCRIPTS}/uninstall.sh" ;;
            8) show_help ;;
            9) cron_menu ;;
            0|"") echo ""; exit 0 ;;
            *) echo -e "  ${RED}Invalid choice${NC}" ;;
        esac
    done
}

###############################################################################
# CLI Dispatch
###############################################################################

case "${1:-}" in
    setup)
        exec bash "${SCRIPTS}/setup.sh"
        ;;
    download)
        case "${2:-}" in
            tools)
                exec bash "${SCRIPTS}/download-tools.sh" all
                ;;
            models)
                case "${3:-all}" in
                    tier1) exec bash "${SCRIPTS}/download-models.sh" tier1 ;;
                    tier2) exec bash "${SCRIPTS}/download-models.sh" tier2 ;;
                    tier3) exec bash "${SCRIPTS}/download-models.sh" tier3 ;;
                    all)   exec bash "${SCRIPTS}/download-models.sh" all ;;
                    *)
                        echo "Usage: $0 download models [tier1|tier2|tier3|all]"
                        exit 1
                        ;;
                esac
                ;;
            all)
                bash "${SCRIPTS}/download-tools.sh" all
                exec bash "${SCRIPTS}/download-models.sh" all
                ;;
            "")
                download_menu
                ;;
            *)
                echo "Usage: $0 download [tools|models|all]"
                exit 1
                ;;
        esac
        ;;
    update)
        exec bash "${SCRIPTS}/update.sh" "${2:-all}"
        ;;
    monitor)
        exec bash "${SCRIPTS}/monitor.sh"
        ;;
    status)
        exec bash "${SCRIPTS}/status.sh"
        ;;
    test)
        exec bash "${TESTS}/run-all.sh"
        ;;
    uninstall)
        exec bash "${SCRIPTS}/uninstall.sh"
        ;;
    cron)
        case "${2:-}" in
            install) cron_install ;;
            remove)  cron_remove ;;
            status)  cron_status ;;
            "")      cron_menu ;;
            *)
                echo "Usage: $0 cron [install|remove|status]"
                exit 1
                ;;
        esac
        ;;
    screenshots)
        exec bash "${SCRIPTS}/screenshots.sh" "${2:-all}"
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        interactive_menu
        ;;
    *)
        echo -e "${RED}Unknown command:${NC} $1"
        show_help
        exit 1
        ;;
esac
