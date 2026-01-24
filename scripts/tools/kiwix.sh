#!/bin/bash
# Val Ark - Download Kiwix Tools
source "$(dirname "$0")/_common.sh"

TOOL_NAME="kiwix-tools"
PINNED_VERSION="3.7.0"

download_kiwix() {
    log "Downloading ${TOOL_NAME}..."

    local repo="kiwix/kiwix-tools"
    local tag="${PINNED_VERSION}"

    # linux-arm64
    local url
    url=$(github_asset_url "$repo" "$tag" "linux-aarch64")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/kiwix-tools" "kiwix-tools linux-arm64" 1
    else
        log_error "Could not find kiwix-tools linux-arm64 asset"
    fi

    # linux-x86_64
    url=$(github_asset_url "$repo" "$tag" "linux-x86_64")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/kiwix-tools" "kiwix-tools linux-x86_64" 1
    else
        log_error "Could not find kiwix-tools linux-x86_64 asset"
    fi

    # macos-arm64
    url=$(github_asset_url "$repo" "$tag" "macos-arm64")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/macos-arm64/kiwix-tools" "kiwix-tools macos-arm64" 1
    else
        log_error "Could not find kiwix-tools macos-arm64 asset"
    fi

    # windows-x64
    url=$(github_asset_url "$repo" "$tag" "win-x86_64")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/windows-x64/kiwix-tools" "kiwix-tools windows-x64" 1
    else
        log_error "Could not find kiwix-tools windows-x64 asset"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_kiwix
