#!/bin/bash
# Val Ark - Download Inkscape
source "$(dirname "$0")/_common.sh"

TOOL_NAME="inkscape"
PINNED_VERSION="1.4"

download_inkscape() {
    log "Downloading ${TOOL_NAME}..."

    # linux-x86_64: no stable direct-download URL for AppImage (gallery IDs change)
    local dest="${TOOLS_DIR}/linux-x86_64/inkscape"
    ensure_dir "$dest"
    write_install_hint "$dest" "inkscape (linux-x86_64)" "Inkscape - linux-x86_64
=====================

Install via Flatpak:
  flatpak install flathub org.inkscape.Inkscape

Or via package manager:
  sudo apt install inkscape

Or download AppImage from: https://inkscape.org/release/inkscape-${PINNED_VERSION}/gnulinux/appimage/
"

    # linux-arm64: package manager only
    dest="${TOOLS_DIR}/linux-arm64/inkscape"
    ensure_dir "$dest"
    write_install_hint "$dest" "inkscape (linux-arm64)" "Inkscape - linux-arm64
=====================

Install via package manager:
  sudo apt install inkscape

For more info: https://inkscape.org/release/
"

    # macos-arm64: DMG from official site
    dest="${TOOLS_DIR}/macos-arm64/inkscape"
    ensure_dir "$dest"
    write_install_hint "$dest" "inkscape (macos-arm64)" "Inkscape - macOS ARM64
=====================

  brew install --cask inkscape

Or download from: https://inkscape.org/release/
"

    # windows-x64: installer from official site
    dest="${TOOLS_DIR}/windows-x64/inkscape"
    ensure_dir "$dest"
    write_install_hint "$dest" "inkscape (windows-x64)" "Inkscape - Windows x64
=====================

Download from: https://inkscape.org/release/
"

    log_success "Inkscape download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_inkscape
