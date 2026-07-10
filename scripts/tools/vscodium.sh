#!/bin/bash
# Val Ark - Download VSCodium
source "$(dirname "$0")/_common.sh"

TOOL_NAME="vscodium"
PINNED_VERSION="1.126.04524"

download_vscodium() {
    log "Downloading ${TOOL_NAME}..."

    local repo="VSCodium/vscodium"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/vscodium"
    local url
    url=$(github_asset_url "$repo" "$tag" "VSCodium-linux-arm64.*tar.gz")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        download_and_extract "$url" "$dest" "vscodium linux-arm64" 0 \
            && version_stamp "$dest" "$tag"
    else
        log_error "Could not find VSCodium linux-arm64 asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/vscodium"
    url=$(github_asset_url "$repo" "$tag" "VSCodium-linux-x64.*tar.gz")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        download_and_extract "$url" "$dest" "vscodium linux-x86_64" 0 \
            && version_stamp "$dest" "$tag"
    else
        log_error "Could not find VSCodium linux-x64 asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/vscodium"
    url=$(github_asset_url "$repo" "$tag" "VSCodium-darwin-arm64.*zip")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        download_and_extract "$url" "$dest" "vscodium macos-arm64" 0 \
            && version_stamp "$dest" "$tag"
    else
        log_error "Could not find VSCodium darwin-arm64 asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/vscodium"
    url=$(github_asset_url "$repo" "$tag" "VSCodium-win32-x64.*zip")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        download_and_extract "$url" "$dest" "vscodium windows-x64" 0 \
            && version_stamp "$dest" "$tag"
    else
        log_error "Could not find VSCodium win32-x64 asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_vscodium
