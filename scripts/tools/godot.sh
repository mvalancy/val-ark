#!/bin/bash
# Val Ark - Download Godot
source "$(dirname "$0")/_common.sh"

TOOL_NAME="godot"
PINNED_VERSION="4.4-stable"

download_godot() {
    log "Downloading ${TOOL_NAME}..."

    local repo="godotengine/godot"
    local tag="${PINNED_VERSION}"

    # linux-x86_64
    local dest="${TOOLS_DIR}/linux-x86_64/godot"
    local url
    url=$(github_asset_url "$repo" "$tag" "Godot.*linux.*x86_64.zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "godot linux-x86_64" 0
        # Make the binary executable
        find "$dest" -name "Godot*" -type f -exec chmod +x {} \; 2>/dev/null
    else
        log_error "Could not find Godot linux x86_64 asset"
    fi

    # linux-arm64
    dest="${TOOLS_DIR}/linux-arm64/godot"
    url=$(github_asset_url "$repo" "$tag" "Godot.*linux.*arm64.zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "godot linux-arm64" 0
        find "$dest" -name "Godot*" -type f -exec chmod +x {} \; 2>/dev/null
    else
        log_warn "No Godot linux arm64 asset found - may not be available for this release"
        write_install_hint "$dest" "godot (linux-arm64)" "Godot - linux-arm64
=====================

Godot may not have official arm64 Linux builds for this release.

Options:
  1. Build from source:
     git clone https://github.com/godotengine/godot.git
     cd godot
     git checkout ${tag}
     scons platform=linuxbsd arch=arm64

  2. Check for newer releases with arm64 support:
     https://github.com/godotengine/godot/releases

For more info: https://docs.godotengine.org/en/stable/contributing/development/compiling/
"
    fi

    # macos-arm64 (universal binary)
    dest="${TOOLS_DIR}/macos-arm64/godot"
    url=$(github_asset_url "$repo" "$tag" "Godot.*macos.*universal.zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "godot macos-arm64" 0
    else
        log_error "Could not find Godot macos universal asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/godot"
    url=$(github_asset_url "$repo" "$tag" "Godot.*win64.exe.zip")
    if [ -n "$url" ]; then
        download_and_extract "$url" "$dest" "godot windows-x64" 0
    else
        log_error "Could not find Godot win64 asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_godot
