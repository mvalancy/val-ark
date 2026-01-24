#!/bin/bash
# Val Ark - Download Miniforge
source "$(dirname "$0")/_common.sh"

TOOL_NAME="miniforge"
PINNED_VERSION="24.11.3-0"

download_miniforge() {
    log "Downloading ${TOOL_NAME}..."

    local repo="conda-forge/miniforge"
    local tag="${PINNED_VERSION}"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/miniforge"
    local url
    url=$(github_asset_url "$repo" "$tag" "Miniforge3-Linux-aarch64.sh")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        download_file "$url" "${dest}/Miniforge3-Linux-aarch64.sh" "miniforge linux-arm64"
        chmod +x "${dest}/Miniforge3-Linux-aarch64.sh" 2>/dev/null
    else
        log_error "Could not find Miniforge3-Linux-aarch64.sh asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/miniforge"
    url=$(github_asset_url "$repo" "$tag" "Miniforge3-Linux-x86_64.sh")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        download_file "$url" "${dest}/Miniforge3-Linux-x86_64.sh" "miniforge linux-x86_64"
        chmod +x "${dest}/Miniforge3-Linux-x86_64.sh" 2>/dev/null
    else
        log_error "Could not find Miniforge3-Linux-x86_64.sh asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/miniforge"
    url=$(github_asset_url "$repo" "$tag" "Miniforge3-MacOSX-arm64.sh")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        download_file "$url" "${dest}/Miniforge3-MacOSX-arm64.sh" "miniforge macos-arm64"
        chmod +x "${dest}/Miniforge3-MacOSX-arm64.sh" 2>/dev/null
    else
        log_error "Could not find Miniforge3-MacOSX-arm64.sh asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/miniforge"
    url=$(github_asset_url "$repo" "$tag" "Miniforge3-Windows-x86_64.exe")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        download_file "$url" "${dest}/Miniforge3-Windows-x86_64.exe" "miniforge windows-x64"
    else
        log_error "Could not find Miniforge3-Windows-x86_64.exe asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_miniforge
