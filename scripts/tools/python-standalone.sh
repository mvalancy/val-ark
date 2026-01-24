#!/bin/bash
# Val Ark - Download Python Standalone
source "$(dirname "$0")/_common.sh"

TOOL_NAME="python-standalone"
PINNED_VERSION="20250106"

download_python_standalone() {
    log "Downloading ${TOOL_NAME}..."

    local repo="astral-sh/python-build-standalone"
    local tag="${PINNED_VERSION}"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/python-standalone"
    local url
    url=$(github_asset_url "$repo" "$tag" "cpython-3.12.*aarch64-unknown-linux-gnu-install_only\.tar\.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "python-standalone linux-arm64" 1
    else
        log_error "Could not find python-standalone aarch64-linux asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/python-standalone"
    url=$(github_asset_url "$repo" "$tag" "cpython-3.12.*x86_64-unknown-linux-gnu-install_only\.tar\.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "python-standalone linux-x86_64" 1
    else
        log_error "Could not find python-standalone x86_64-linux asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/python-standalone"
    url=$(github_asset_url "$repo" "$tag" "cpython-3.12.*aarch64-apple-darwin-install_only\.tar\.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "python-standalone macos-arm64" 1
    else
        log_error "Could not find python-standalone aarch64-macos asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/python-standalone"
    url=$(github_asset_url "$repo" "$tag" "cpython-3.12.*x86_64-pc-windows-msvc-install_only\.tar\.gz")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "python-standalone windows-x64" 1
    else
        log_error "Could not find python-standalone windows-x64 asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_python_standalone
