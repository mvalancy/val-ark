#!/bin/bash
# Val Ark - Download SeaweedFS
# Distributed object/file store (S3-compatible) — a fast, flat storage layer
# that complements the NFS/Syncthing mirror for the fleet.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="seaweedfs"
PINNED_VERSION="4.38"

download_seaweedfs() {
    log "Downloading ${TOOL_NAME}..."

    local repo="seaweedfs/seaweedfs"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    # SeaweedFS release archives contain the single `weed` binary at the root
    # (no top-level dir), so strip-components is 0. The plain (non _large_disk,
    # non _full) build is the portable default; _large_disk suits >2 TB volumes.

    # linux-arm64 (Jetson Orin/Thor, GB10, RK3588 / this UT2)
    local url
    url=$(github_asset_url "$repo" "$tag" "/linux_arm64.tar.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/seaweedfs" "seaweedfs linux-arm64" 0
    else
        log_error "Could not find seaweedfs linux-arm64 asset"
    fi

    # linux-x86_64
    url=$(github_asset_url "$repo" "$tag" "/linux_amd64.tar.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/seaweedfs" "seaweedfs linux-x86_64" 0
    else
        log_error "Could not find seaweedfs linux-x86_64 asset"
    fi

    # macos-arm64
    url=$(github_asset_url "$repo" "$tag" "/darwin_arm64.tar.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/macos-arm64/seaweedfs" "seaweedfs macos-arm64" 0
    else
        log_error "Could not find seaweedfs macos-arm64 asset"
    fi

    # windows-x64
    url=$(github_asset_url "$repo" "$tag" "/windows_amd64.zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "${TOOLS_DIR}/windows-x64/seaweedfs" "seaweedfs windows-x64" 0
    else
        log_error "Could not find seaweedfs windows-x64 asset"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_seaweedfs
