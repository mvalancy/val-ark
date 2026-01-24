#!/bin/bash
# Val Ark - Download Blender
source "$(dirname "$0")/_common.sh"

TOOL_NAME="blender"
PINNED_VERSION="4.4.0"

download_blender() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"
    local mirror="https://download.blender.org/release/Blender4.4"

    # linux-x86_64
    local dest="${TOOLS_DIR}/linux-x86_64/blender"
    local url="${mirror}/blender-${ver}-linux-x64.tar.xz"
    download_and_extract "$url" "$dest" "blender linux-x86_64" 1

    # linux-arm64: no official arm64 Linux build
    dest="${TOOLS_DIR}/linux-arm64/blender"
    write_install_hint "$dest" "blender (linux-arm64)" "Blender - linux-arm64
======================

Blender does not provide official arm64 Linux builds.

Options:
  1. Build from source:
     git clone https://projects.blender.org/blender/blender.git
     cd blender
     make update
     make

  2. Use snap (if available for arm64):
     sudo snap install blender --classic

  3. Use the x86_64 version with emulation (not recommended for performance)

For more info: https://www.blender.org/download/
"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/blender"
    url="${mirror}/blender-${ver}-macos-arm64.dmg"
    ensure_dir "$dest"
    download_file "$url" "${dest}/blender-${ver}-macos-arm64.dmg" "blender macos-arm64"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/blender"
    url="${mirror}/blender-${ver}-windows-x64.zip"
    download_and_extract "$url" "$dest" "blender windows-x64" 0
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_blender
