#!/bin/bash
###############################################################################
# Val Ark - Setup Script
# Installs dependencies and creates required directories
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Resolve WHERE Val Ark keeps its data (.env / autodetect). Sourcing this gives
# us DATA_ROOT, the data-tree paths, valark_ensure_layout, and valark_env_summary
# so setup shows the user the real storage location — not the OS/boot disk.
if [ -f "${SCRIPT_DIR}/lib/valark-env.sh" ]; then
    # shellcheck source=lib/valark-env.sh
    . "${SCRIPT_DIR}/lib/valark-env.sh"
fi

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

# Repo-local asset dirs (part of the web UI — these genuinely live in the repo).
mkdir -p "${PROJECT_ROOT}/web-ui/logos" \
         "${PROJECT_ROOT}/web-ui/samples" \
         "${PROJECT_ROOT}/web-ui/diagrams" \
         "${PROJECT_ROOT}/web-ui/screenshots"

# Data trees (tools/models/content/sources/assets/...) belong on the resolved
# DATA_ROOT, not on the OS/boot volume. valark_ensure_layout creates them there
# and symlinks them back into the repo so the big disk is always used.
if command -v valark_ensure_layout >/dev/null 2>&1; then
    valark_ensure_layout
    mkdir -p "${ASSETS_DIR}/ollama" 2>/dev/null || true
    log_ok "Directories created (data trees on ${DATA_ROOT})"
else
    mkdir -p "${PROJECT_ROOT}/tools" "${PROJECT_ROOT}/sources" \
             "${PROJECT_ROOT}/assets/ollama"
    log_ok "Directories created"
fi

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
# Node.js Runtime (required by the zero-dep web server, scripts/server.js)
###############################################################################
# The web UI/API server is plain Node with no npm deps, but it still needs a
# Node binary. A fresh ARM64 NAS appliance (chips such as the Rockchip RK3588)
# often ships without one, so
# bootstrap a portable build into ~/.local/node — exactly where start.sh looks.

echo ""
log_info "Node.js runtime (web server):"
NODE_BIN="${HOME}/.local/node/bin/node"
if command -v node >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} node ($(node --version 2>/dev/null)) in PATH"
elif [ -x "$NODE_BIN" ]; then
    echo -e "  ${GREEN}✓${NC} node ($("$NODE_BIN" --version 2>/dev/null)) at ~/.local/node"
else
    echo -e "  ${YELLOW}~${NC} node not found — the web server (scripts/server.js) needs it."
    NODE_VER="${VALARK_NODE_VERSION:-v20.18.1}"
    case "$(uname -m)" in
        aarch64|arm64) NODE_ARCH="linux-arm64" ;;
        x86_64|amd64)  NODE_ARCH="linux-x64" ;;
        *)             NODE_ARCH="" ;;
    esac
    if [ "$(uname -s)" != "Linux" ] || [ -z "$NODE_ARCH" ]; then
        log_warn "No portable Node build known for $(uname -s)/$(uname -m) — install Node manually."
    else
        echo -n "  Download portable Node ${NODE_VER} (${NODE_ARCH}) into ~/.local/node? [Y/n]: "
        read -r answer
        if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
            _url="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-${NODE_ARCH}.tar.xz"
            _tmp="$(mktemp -d)"
            if curl -fL --retry 3 --connect-timeout 15 -o "${_tmp}/node.tar.xz" "$_url"; then
                mkdir -p "${HOME}/.local/node"
                if tar -xJf "${_tmp}/node.tar.xz" -C "${HOME}/.local/node" --strip-components=1 \
                   && [ -x "$NODE_BIN" ]; then
                    log_ok "Node installed: $("$NODE_BIN" --version) (~/.local/node)"
                else
                    log_err "Node extraction failed."
                fi
            else
                log_err "Node download failed: $_url"
            fi
            rm -rf "$_tmp"
        fi
    fi
fi

###############################################################################
# TLS CA bundle (repair a stale system trust store)
###############################################################################
# ARM64 NAS appliances (e.g. RK3588-class boxes) often ship an old CA store that fails TLS to newer
# download hosts (download.kde.org, curl.se, ...). If so, fetch a current bundle
# into the state dir; _common.sh points every tool download at it via CURL_CA_BUNDLE.

echo ""
log_info "TLS trust (CA certificates):"
CA_DEST="${STATE_DIR:-${PROJECT_ROOT}/state}/cacert.pem"
if curl -fsS --max-time 15 -o /dev/null https://download.kde.org/ 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} system CA store validates modern hosts"
elif [ -s "$CA_DEST" ] && curl -fsS --max-time 15 --cacert "$CA_DEST" -o /dev/null https://download.kde.org/ 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} using Val Ark CA bundle: ${CA_DEST}"
else
    echo -e "  ${YELLOW}~${NC} system CA store is stale — fetching a current bundle..."
    mkdir -p "$(dirname "$CA_DEST")"
    if curl -fsSL --max-time 30 -o "$CA_DEST" \
         https://raw.githubusercontent.com/bagder/ca-bundle/master/ca-bundle.crt \
       && grep -q "BEGIN CERTIFICATE" "$CA_DEST"; then
        log_ok "Fresh CA bundle installed ($(grep -c 'BEGIN CERT' "$CA_DEST") certs) — downloads will use it"
    else
        rm -f "$CA_DEST"
        log_warn "Could not fetch a fresh CA bundle; some tool downloads may fail TLS verification."
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
log_info "Storage location (where Val Ark keeps its data):"
if command -v valark_env_summary >/dev/null 2>&1; then
    valark_env_summary | sed 's/^/  /'
    # Loudly warn if the data root resolves onto the OS/boot volume — otherwise
    # the librarian would try to "fill" the system disk instead of a data disk.
    _root_src=$(df -P "${DATA_ROOT}" 2>/dev/null | awk 'NR==2{print $1}')
    _os_src=$(df -P / 2>/dev/null | awk 'NR==2{print $1}')
    if [ "${DATA_ROOT}" = "${PROJECT_ROOT}" ] || [ "${_root_src}" = "${_os_src}" ]; then
        echo ""
        log_warn "DATA_ROOT is on the OS/boot volume — Val Ark would fill your system disk!"
        log_warn "Point it at a big disk: set VAL_ARK_DATA=/path/to/disk in .env (see .env.example)."
    fi
else
    df -h "${PROJECT_ROOT}" | tail -1 | awk '{printf "  Available: %s / %s (%s used)\n", $4, $2, $5}'
fi

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
