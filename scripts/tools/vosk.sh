#!/bin/bash
###############################################################################
# Val Ark - Download Vosk
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="vosk"
PINNED_VERSION="v0.3.45"

download_vosk() {
    log "Downloading ${TOOL_NAME}..."
    # Use pinned version directly - latest releases (v0.3.50+) have no prebuilt binaries
    local TAG="$PINNED_VERSION"
    local VER="${TAG#v}"  # Strip leading 'v' for filename pattern

    local BASE_URL="https://github.com/alphacep/vosk-api/releases/download/${TAG}"

    # linux-arm64
    local LINUX_ARM64_URL="${BASE_URL}/vosk-linux-aarch64-${VER}.zip"
    download_and_extract "$LINUX_ARM64_URL" "$TOOLS_DIR/linux-arm64/vosk" "Vosk linux-arm64"

    # linux-x86_64
    local LINUX_X64_URL="${BASE_URL}/vosk-linux-x86_64-${VER}.zip"
    download_and_extract "$LINUX_X64_URL" "$TOOLS_DIR/linux-x86_64/vosk" "Vosk linux-x86_64"

    # windows-x64
    local WIN_URL="${BASE_URL}/vosk-win64-${VER}.zip"
    download_and_extract "$WIN_URL" "$TOOLS_DIR/windows-x64/vosk" "Vosk windows-x64"

    # macOS arm64: no prebuilt binary, write install instructions
    write_install_hint "$TOOLS_DIR/macos-arm64/vosk" "Vosk (macOS)" \
"Vosk for macOS arm64
================================

No prebuilt native library is available for macOS arm64.
To use Vosk on macOS, obtain it via pip:

    pip install vosk

Or with conda:

    conda install -c conda-forge vosk

Source and docs: https://alphacephei.com/vosk/
GitHub: https://github.com/alphacep/vosk-api
"

    log_success "Vosk download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_vosk
