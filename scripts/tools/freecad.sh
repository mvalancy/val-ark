#!/bin/bash
# Val Ark - Download FreeCAD
source "$(dirname "$0")/_common.sh"

TOOL_NAME="freecad"
PINNED_VERSION="1.1.1"

download_freecad() {
    log "Downloading ${TOOL_NAME}..."

    local repo="FreeCAD/FreeCAD"
    local tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    # linux-x86_64: AppImage
    local dest="${TOOLS_DIR}/linux-x86_64/freecad"
    local url
    url=$(github_asset_url "$repo" "$tag" "x86_64.*AppImage")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        ensure_dir "$dest"
        local filename=$(basename "$url")
        if download_file "$url" "${dest}/${filename}" "freecad linux-x86_64"; then
            chmod +x "${dest}/${filename}" 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find FreeCAD x86_64 AppImage asset"
    fi

    # linux-arm64: AppImage if available, otherwise INSTALL.txt
    dest="${TOOLS_DIR}/linux-arm64/freecad"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*AppImage")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        ensure_dir "$dest"
        local filename=$(basename "$url")
        if download_file "$url" "${dest}/${filename}" "freecad linux-arm64"; then
            chmod +x "${dest}/${filename}" 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
    else
        write_install_hint "$dest" "freecad (linux-arm64)" "FreeCAD - linux-arm64
======================

FreeCAD ships official Linux aarch64 AppImage builds since 1.0.0, but the
asset for release ${tag} could not be resolved just now (likely a transient
GitHub API/network failure). Re-run this mirror script, or download directly:

  https://github.com/FreeCAD/FreeCAD/releases
  (look for FreeCAD_<version>-Linux-aarch64-*.AppImage)

Alternatives:
  1. conda-forge:
     conda install -c conda-forge freecad

  2. Build from source:
     https://wiki.freecad.org/Compile_on_Linux
"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/freecad"
    url=$(github_asset_url "$repo" "$tag" "macOS-arm64.*dmg")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        ensure_dir "$dest"
        local filename=$(basename "$url")
        if download_file "$url" "${dest}/${filename}" "freecad macos-arm64"; then
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find FreeCAD macOS-arm64 dmg asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/freecad"
    url=$(github_asset_url "$repo" "$tag" "Windows-x86_64.*exe")
    if [ -z "$url" ]; then
        url=$(github_asset_url "$repo" "$tag" "Windows-x86_64.*zip")
    fi
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        ensure_dir "$dest"
        local filename=$(basename "$url")
        if download_file "$url" "${dest}/${filename}" "freecad windows-x64"; then
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find FreeCAD Windows-x86_64 asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_freecad
