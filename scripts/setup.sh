#!/bin/bash
###############################################################################
# Val Ark - Setup Script
# Installs dependencies and creates required directories
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_ok() { echo -e "[${GREEN}OK${NC}] $*"; }
log_info() { echo -e "[${BLUE}INFO${NC}] $*"; }
log_warn() { echo -e "[${YELLOW}WARN${NC}] $*"; }
log_err() { echo -e "[${RED}ERROR${NC}] $*"; }

echo ""
echo "=================================================================="
echo "  Val Ark - Setup"
echo "=================================================================="
echo ""

###############################################################################
# Create Directory Structure
###############################################################################

log_info "Creating directory structure..."

mkdir -p "${PROJECT_ROOT}/tools"
mkdir -p "${PROJECT_ROOT}/sources"
mkdir -p "${PROJECT_ROOT}/assets/ollama"
mkdir -p "${PROJECT_ROOT}/web-ui/logos"
mkdir -p "${PROJECT_ROOT}/web-ui/samples"
mkdir -p "${PROJECT_ROOT}/web-ui/diagrams"
mkdir -p "${PROJECT_ROOT}/web-ui/screenshots"

log_ok "Directories created"

###############################################################################
# Check Dependencies
###############################################################################

log_info "Checking dependencies..."

MISSING=""

check_cmd() {
    if command -v "$1" &>/dev/null; then
        local ver=$($1 --version 2>/dev/null | head -1 || echo "installed")
        echo -e "  ${GREEN}✓${NC} $1 ($ver)"
    else
        echo -e "  ${RED}✗${NC} $1 (missing)"
        MISSING="${MISSING} $1"
    fi
}

check_cmd wget
check_cmd curl
check_cmd git
check_cmd tar
check_cmd unzip

# Optional but recommended
echo ""
log_info "Optional tools:"
check_cmd cmake
check_cmd pip3
check_cmd jq

# Check for HuggingFace CLI
if [ -f "${HOME}/.local/bin/hf" ]; then
    echo -e "  ${GREEN}✓${NC} hf CLI (${HOME}/.local/bin/hf)"
elif command -v huggingface-cli &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} huggingface-cli"
else
    echo -e "  ${YELLOW}~${NC} hf CLI (optional, for large repo downloads)"
    echo "      Install: pip install huggingface_hub[cli]"
fi

echo ""

###############################################################################
# Install Missing Required Dependencies
###############################################################################

if [ -n "$MISSING" ]; then
    log_warn "Missing required tools:${MISSING}"
    echo ""

    if command -v apt-get &>/dev/null; then
        echo -n "  Install with apt? [y/N]: "
        read -r answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            sudo apt-get update -qq
            sudo apt-get install -y $MISSING
            log_ok "Dependencies installed"
        fi
    elif command -v brew &>/dev/null; then
        echo -n "  Install with brew? [y/N]: "
        read -r answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            brew install $MISSING
            log_ok "Dependencies installed"
        fi
    else
        log_info "Please install manually:${MISSING}"
    fi
else
    log_ok "All required dependencies present"
fi

###############################################################################
# Python Dependencies (Optional)
###############################################################################

echo ""
log_info "Python dependencies:"

# Check for Pillow (image optimization)
if python3 -c "from PIL import Image" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Pillow (image optimization)"
else
    echo -e "  ${YELLOW}~${NC} Pillow (optional, for image optimization)"
    if command -v pip3 &>/dev/null; then
        echo -n "  Install Pillow with pip? [y/N]: "
        read -r answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            pip3 install --user Pillow
            log_ok "Pillow installed"
        fi
    else
        echo "      Install: pip3 install Pillow"
    fi
fi

###############################################################################
# Platform Detection
###############################################################################

echo ""
log_info "Platform detection:"
ARCH=$(uname -m)
OS=$(uname -s)
echo "  OS: ${OS}"
echo "  Arch: ${ARCH}"

if [ -f /proc/device-tree/model ]; then
    MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
    echo "  Device: ${MODEL}"
fi

if command -v nvidia-smi &>/dev/null; then
    GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    echo "  GPU: ${GPU}"
fi

###############################################################################
# Disk Space
###############################################################################

echo ""
log_info "Disk space:"
df -h "${PROJECT_ROOT}" | tail -1 | awk '{printf "  Available: %s / %s (%s used)\n", $4, $2, $5}'

echo ""
echo "=================================================================="
log_ok "Setup complete!"
echo ""
echo "  Next steps:"
echo "    ./start.sh download tools     # Get tools (~4GB)"
echo "    ./start.sh download models tier1  # Edge models (~10GB)"
echo ""
echo "=================================================================="
echo ""
