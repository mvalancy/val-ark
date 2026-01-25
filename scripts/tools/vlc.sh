#!/bin/bash
# Val Ark - Download VLC
source "$(dirname "$0")/_common.sh"

TOOL_NAME="vlc"
PINNED_VERSION="3.0.21"

download_vlc() {
    log "Downloading ${TOOL_NAME}..."

    # linux-arm64: No official portable build, use install hint
    local dest="${TOOLS_DIR}/linux-arm64/vlc"
    ensure_dir "$dest"
    write_install_hint "$dest" "vlc (linux-arm64)" "VLC Media Player - linux-arm64
==============================

Install via package manager:
  sudo apt install vlc

Or via Flatpak:
  flatpak install flathub org.videolan.VLC
"

    # linux-x86_64: No official portable build, use install hint
    dest="${TOOLS_DIR}/linux-x86_64/vlc"
    ensure_dir "$dest"
    write_install_hint "$dest" "vlc (linux-x86_64)" "VLC Media Player - linux-x86_64
===============================

Install via package manager:
  sudo apt install vlc

Or via Snap:
  sudo snap install vlc

Or via Flatpak:
  flatpak install flathub org.videolan.VLC
"

    # macos-arm64: Universal DMG from official site
    dest="${TOOLS_DIR}/macos-arm64/vlc"
    ensure_dir "$dest"
    local url="https://get.videolan.org/vlc/${PINNED_VERSION}/macosx/vlc-${PINNED_VERSION}-universal.dmg"
    download_file "$url" "${dest}/VLC-${PINNED_VERSION}.dmg" "VLC macOS"

    # windows-x64: Official installer
    dest="${TOOLS_DIR}/windows-x64/vlc"
    ensure_dir "$dest"
    url="https://get.videolan.org/vlc/${PINNED_VERSION}/win64/vlc-${PINNED_VERSION}-win64.exe"
    download_file "$url" "${dest}/VLC-${PINNED_VERSION}-Setup.exe" "VLC Windows"

    log_success "VLC download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_vlc
