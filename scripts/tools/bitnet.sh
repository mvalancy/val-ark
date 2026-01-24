#!/bin/bash
###############################################################################
# Val Ark - Download BitNet.cpp
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="bitnet"
PINNED_VERSION="main"

download_bitnet() {
    log "Downloading ${TOOL_NAME}..."

    # Source only - no prebuilt releases available
    # Clone to linux-arm64 tools dir for Jetson build
    clone_repo "https://github.com/microsoft/BitNet.git" "$PINNED_VERSION" \
        "$TOOLS_DIR/linux-arm64/bitnet/source" "BitNet source (linux-arm64)"

    # Clone to linux-x86_64 tools dir
    clone_repo "https://github.com/microsoft/BitNet.git" "$PINNED_VERSION" \
        "$TOOLS_DIR/linux-x86_64/bitnet/source" "BitNet source (linux-x86_64)"

    # Clone to macos-arm64 tools dir
    clone_repo "https://github.com/microsoft/BitNet.git" "$PINNED_VERSION" \
        "$TOOLS_DIR/macos-arm64/bitnet/source" "BitNet source (macos-arm64)"

    # Clone to windows-x64 tools dir
    clone_repo "https://github.com/microsoft/BitNet.git" "$PINNED_VERSION" \
        "$TOOLS_DIR/windows-x64/bitnet/source" "BitNet source (windows-x64)"

    # Clone to sources dir
    clone_repo "https://github.com/microsoft/BitNet.git" "$PINNED_VERSION" \
        "$PROJECT_ROOT/sources/BitNet" "BitNet source"

    log_success "BitNet.cpp download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_bitnet
