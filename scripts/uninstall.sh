#!/bin/bash
###############################################################################
# Val Ark - Uninstall Script
# Removes Val Ark configuration (does NOT delete models or tools)
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "=================================================================="
echo "  Val Ark - Uninstall"
echo "=================================================================="
echo ""
echo -e "${YELLOW}This will remove:${NC}"
echo "  - Cron jobs for Val Ark"
echo "  - PID files and lock files"
echo "  - Log files"
echo ""
echo -e "${GREEN}This will NOT remove:${NC}"
echo "  - Downloaded models (in /home/uat-admin/models/)"
echo "  - Downloaded tools (in ${PROJECT_ROOT}/tools/)"
echo "  - Source repos (in ${PROJECT_ROOT}/sources/)"
echo "  - The Val Ark project directory itself"
echo ""
echo -n "Proceed? [y/N]: "
read -r answer

if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Remove cron jobs
if crontab -l 2>/dev/null | grep -q "val-ark\|ai-ark"; then
    crontab -l 2>/dev/null | grep -v "val-ark\|ai-ark" | crontab -
    echo -e "[${GREEN}OK${NC}] Removed cron jobs"
else
    echo -e "[${BLUE}INFO${NC}] No cron jobs found"
fi

# Remove PID files
if [ -f "${PROJECT_ROOT}/.download_pid" ]; then
    rm -f "${PROJECT_ROOT}/.download_pid"
    echo -e "[${GREEN}OK${NC}] Removed PID file"
fi

# Remove log files
MODEL_ROOT="/home/uat-admin/models"
if [ -d "${MODEL_ROOT}/logs" ]; then
    echo -n "  Remove log files in ${MODEL_ROOT}/logs/? [y/N]: "
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        rm -rf "${MODEL_ROOT}/logs"
        echo -e "[${GREEN}OK${NC}] Removed log directory"
    fi
fi

echo ""
echo "=================================================================="
echo -e "[${GREEN}OK${NC}] Uninstall complete."
echo ""
echo "To fully remove downloaded content:"
echo "  rm -rf ${PROJECT_ROOT}/tools/"
echo "  rm -rf ${PROJECT_ROOT}/sources/"
echo "  rm -rf ${MODEL_ROOT}/"
echo "=================================================================="
echo ""
