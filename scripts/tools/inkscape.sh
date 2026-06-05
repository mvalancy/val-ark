#!/bin/bash
# Val Ark - Download Inkscape
source "$(dirname "$0")/_common.sh"

TOOL_NAME="inkscape"
PINNED_VERSION="1.4"

download_inkscape() {
    log "Downloading ${TOOL_NAME}..."

    # linux-arm64: No official AppImage, use install hint
    local dest="${TOOLS_DIR}/linux-arm64/inkscape"
    ensure_dir "$dest"
    write_install_hint "$dest" "inkscape (linux-arm64)" "Inkscape - linux-arm64
======================

Install via package manager:
  sudo apt install inkscape

Or via Flatpak:
  flatpak install flathub org.inkscape.Inkscape
"

    # linux-x86_64: AppImage from official releases
    dest="${TOOLS_DIR}/linux-x86_64/inkscape"
    ensure_dir "$dest"
    # AppImage URL from Inkscape's official releases
    local url="https://media.inkscape.org/dl/resources/file/Inkscape-091e20e-x86_64.AppImage"
    download_file "$url" "${dest}/Inkscape-${PINNED_VERSION}.AppImage" "Inkscape Linux x86_64"
    chmod +x "${dest}/Inkscape-${PINNED_VERSION}.AppImage" 2>/dev/null

    # macos-arm64: DMG from official site
    dest="${TOOLS_DIR}/macos-arm64/inkscape"
    ensure_dir "$dest"
    url="https://media.inkscape.org/dl/resources/file/Inkscape-1.4.028868_arm64.dmg"
    download_file "$url" "${dest}/Inkscape-${PINNED_VERSION}.dmg" "Inkscape macOS ARM64"

    # windows-x64: Official installer
    dest="${TOOLS_DIR}/windows-x64/inkscape"
    ensure_dir "$dest"
    url="https://media.inkscape.org/dl/resources/file/inkscape-1.4_2024-10-11_86a8ad7-x64.exe"
    download_file "$url" "${dest}/Inkscape-${PINNED_VERSION}-Setup.exe" "Inkscape Windows"

    log_success "Inkscape download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_inkscape
