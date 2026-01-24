#!/bin/bash
# Val Ark - Download Syncthing
source "$(dirname "$0")/_common.sh"

TOOL_NAME="syncthing"
PINNED_VERSION="v1.29.2"

download_syncthing() {
    log "Downloading ${TOOL_NAME}..."

    local repo="syncthing/syncthing"
    local tag="${PINNED_VERSION}"

    # linux-arm64
    local url
    url=$(github_asset_url "$repo" "$tag" "linux-arm64.*tar.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/syncthing" "syncthing linux-arm64" 1
    else
        log_error "Could not find syncthing linux-arm64 asset"
    fi

    # linux-x86_64
    url=$(github_asset_url "$repo" "$tag" "linux-amd64.*tar.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/syncthing" "syncthing linux-x86_64" 1
    else
        log_error "Could not find syncthing linux-x86_64 asset"
    fi

    # macos-arm64 (macOS releases are .zip, not .tar.gz)
    url=$(github_asset_url "$repo" "$tag" "macos-arm64.*zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/macos-arm64/syncthing" "syncthing macos-arm64" 0
    else
        log_error "Could not find syncthing macos-arm64 asset"
    fi

    # windows-x64
    url=$(github_asset_url "$repo" "$tag" "windows-amd64.*zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/windows-x64/syncthing" "syncthing windows-x64" 0
    else
        log_error "Could not find syncthing windows-x64 asset"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_syncthing
