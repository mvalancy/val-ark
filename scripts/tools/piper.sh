#!/bin/bash
###############################################################################
# Val Ark - Download Piper TTS
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="piper"
PINNED_VERSION="2023.11.14-2"

download_piper() {
    log "Downloading ${TOOL_NAME}..."
    local TAG=$(github_latest_tag "rhasspy/piper" "$PINNED_VERSION")

    # linux-arm64
    local LINUX_ARM64_URL=$(github_asset_url "rhasspy/piper" "$TAG" "linux_aarch64.tar.gz")
    if [ -n "$LINUX_ARM64_URL" ]; then
        download_and_extract "$LINUX_ARM64_URL" "$TOOLS_DIR/linux-arm64/piper" "Piper linux-arm64"
    else
        log_warn "No linux-arm64 asset found for Piper ${TAG}"
    fi

    # linux-x86_64
    local LINUX_X64_URL=$(github_asset_url "rhasspy/piper" "$TAG" "linux_x86_64.tar.gz")
    if [ -n "$LINUX_X64_URL" ]; then
        download_and_extract "$LINUX_X64_URL" "$TOOLS_DIR/linux-x86_64/piper" "Piper linux-x86_64"
    else
        log_warn "No linux-x86_64 asset found for Piper ${TAG}"
    fi

    # macos-arm64 (native)
    local MACOS_URL=$(github_asset_url "rhasspy/piper" "$TAG" "macos_aarch64.tar.gz")
    if [ -n "$MACOS_URL" ]; then
        download_and_extract "$MACOS_URL" "$TOOLS_DIR/macos-arm64/piper" "Piper macos-arm64"
    else
        log_warn "No macOS arm64 asset found for Piper ${TAG}"
    fi

    # windows-x64
    local WIN_URL=$(github_asset_url "rhasspy/piper" "$TAG" "windows_amd64.zip")
    if [ -n "$WIN_URL" ]; then
        download_and_extract "$WIN_URL" "$TOOLS_DIR/windows-x64/piper" "Piper windows-x64"
    else
        log_warn "No Windows x64 asset found for Piper ${TAG}"
    fi

    log_success "Piper TTS download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_piper
