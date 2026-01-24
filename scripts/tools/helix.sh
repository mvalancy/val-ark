#!/bin/bash
# Val Ark - Download Helix
source "$(dirname "$0")/_common.sh"

TOOL_NAME="helix"
PINNED_VERSION="25.01.1"

download_helix() {
    log "Downloading ${TOOL_NAME}..."

    local repo="helix-editor/helix"
    local tag="${PINNED_VERSION}"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/helix"
    local url
    url=$(github_asset_url "$repo" "$tag" "aarch64-linux.*tar.xz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "helix linux-arm64" 1
    else
        log_error "Could not find helix aarch64-linux asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/helix"
    url=$(github_asset_url "$repo" "$tag" "x86_64-linux.*tar.xz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "helix linux-x86_64" 1
    else
        log_error "Could not find helix x86_64-linux asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/helix"
    url=$(github_asset_url "$repo" "$tag" "aarch64-macos.*tar.xz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "helix macos-arm64" 1
    else
        log_error "Could not find helix aarch64-macos asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/helix"
    url=$(github_asset_url "$repo" "$tag" "x86_64-windows.*zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "helix windows-x64" 0
    else
        log_error "Could not find helix x86_64-windows asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_helix
