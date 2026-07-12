#!/bin/bash
# Val Ark - Download Godot
source "$(dirname "$0")/_common.sh"

TOOL_NAME="godot"
PINNED_VERSION="4.7-stable"

download_godot() {
    log "Downloading ${TOOL_NAME}..."

    local repo="godotengine/godot"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    # linux-x86_64
    local dest="${TOOLS_DIR}/linux-x86_64/godot"
    local url
    url=$(github_asset_url "$repo" "$tag" "stable_linux.x86_64.zip")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        if download_and_extract "$url" "$dest" "godot linux-x86_64" 0; then
            # Make the binary executable
            find "$dest" -name "Godot*" -type f -exec chmod +x {} \; 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find Godot linux x86_64 asset"
    fi

    # linux-arm64 (official linux.arm64 builds exist since 4.4)
    dest="${TOOLS_DIR}/linux-arm64/godot"
    url=$(github_asset_url "$repo" "$tag" "stable_linux.arm64.zip")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        if download_and_extract "$url" "$dest" "godot linux-arm64" 0; then
            find "$dest" -name "Godot*" -type f -exec chmod +x {} \; 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find Godot linux arm64 asset"
    fi

    # macos-arm64 (universal binary)
    dest="${TOOLS_DIR}/macos-arm64/godot"
    url=$(github_asset_url "$repo" "$tag" "stable_macos.universal.zip")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        if download_and_extract "$url" "$dest" "godot macos-arm64" 0; then
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find Godot macos universal asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/godot"
    url=$(github_asset_url "$repo" "$tag" "stable_win64.exe.zip")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        if download_and_extract "$url" "$dest" "godot windows-x64" 0; then
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find Godot win64 asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_godot
