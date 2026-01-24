#!/bin/bash
###############################################################################
# Val Ark - Download Ollama
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="ollama"
PINNED_VERSION="v0.15.0"

download_ollama() {
    log "Downloading ${TOOL_NAME}..."
    # Use ollama.com/download (official CDN) instead of GitHub releases
    local BASE_URL="https://ollama.com/download"

    # linux-arm64: tar.zst archive (jetpack6 variant for Jetson Orin)
    local ARM64_URL="${BASE_URL}/ollama-linux-arm64-jetpack6.tar.zst"
    download_and_extract "$ARM64_URL" "$TOOLS_DIR/linux-arm64/ollama" "ollama linux-arm64 (jetpack6)"

    # linux-x86_64: tar.zst archive
    local X64_URL="${BASE_URL}/ollama-linux-amd64.tar.zst"
    download_and_extract "$X64_URL" "$TOOLS_DIR/linux-x86_64/ollama" "ollama linux-x86_64"

    # macos-arm64: tgz archive
    local MAC_URL="${BASE_URL}/ollama-darwin.tgz"
    download_and_extract "$MAC_URL" "$TOOLS_DIR/macos-arm64/ollama" "ollama macos-arm64"

    # windows-x64: zip archive
    local WIN_URL="${BASE_URL}/ollama-windows-amd64.zip"
    download_and_extract "$WIN_URL" "$TOOLS_DIR/windows-x64/ollama" "ollama windows-x64"

    log_success "Ollama download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_ollama
