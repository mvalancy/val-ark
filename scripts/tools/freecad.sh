#!/bin/bash
# Val Ark - Download FreeCAD
source "$(dirname "$0")/_common.sh"

TOOL_NAME="freecad"
PINNED_VERSION="1.0.0"

download_freecad() {
    log "Downloading ${TOOL_NAME}..."

    local repo="FreeCAD/FreeCAD"
    local tag="${PINNED_VERSION}"

    # linux-x86_64: AppImage
    local dest="${TOOLS_DIR}/linux-x86_64/freecad"
    local url
    url=$(github_asset_url "$repo" "$tag" "x86_64.*AppImage")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        local filename=$(basename "$url")
        download_file "$url" "${dest}/${filename}" "freecad linux-x86_64"
        chmod +x "${dest}/${filename}" 2>/dev/null
    else
        log_error "Could not find FreeCAD x86_64 AppImage asset"
    fi

    # linux-arm64: AppImage if available, otherwise INSTALL.txt
    dest="${TOOLS_DIR}/linux-arm64/freecad"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*AppImage")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        local filename=$(basename "$url")
        download_file "$url" "${dest}/${filename}" "freecad linux-arm64"
        chmod +x "${dest}/${filename}" 2>/dev/null
    else
        write_install_hint "$dest" "freecad (linux-arm64)" "FreeCAD - linux-arm64
======================

FreeCAD does not currently provide official arm64 Linux AppImage builds.

Options:
  1. Build from source:
     sudo apt install build-essential cmake python3-dev libboost-all-dev \\
       libcoin-dev libeigen3-dev libgts-dev libkdtree++-dev libmedc-dev \\
       libocct-*-dev libproj-dev libvtk9-dev libx11-dev libxerces-c-dev \\
       libzipios++-dev occt-draw pybind11-dev python3-matplotlib \\
       python3-pivy python3-ply python3-pyside2.qtcore
     git clone https://github.com/FreeCAD/FreeCAD.git
     cd FreeCAD && mkdir build && cd build
     cmake ..
     make -j\$(nproc)

  2. Use conda-forge:
     conda install -c conda-forge freecad

For more info: https://wiki.freecad.org/Compile_on_Linux
"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/freecad"
    url=$(github_asset_url "$repo" "$tag" "macOS-arm64.*dmg")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        local filename=$(basename "$url")
        download_file "$url" "${dest}/${filename}" "freecad macos-arm64"
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
        ensure_dir "$dest"
        local filename=$(basename "$url")
        download_file "$url" "${dest}/${filename}" "freecad windows-x64"
    else
        log_error "Could not find FreeCAD Windows-x86_64 asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_freecad
