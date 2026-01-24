#!/bin/bash
# Val Ark - Download KiCad
source "$(dirname "$0")/_common.sh"

TOOL_NAME="kicad"
PINNED_VERSION="8.0"

download_kicad() {
    log "Downloading ${TOOL_NAME}..."

    # KiCad does not provide standalone binary downloads.
    # It uses system package managers or official installers.

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/kicad"
    write_install_hint "$dest" "kicad (linux-arm64)" "KiCad - Installation Instructions (linux-arm64)
==================================================

Ubuntu/Debian:
  sudo add-apt-repository ppa:kicad/kicad-8.0-releases
  sudo apt update
  sudo apt install kicad

Fedora:
  sudo dnf install kicad

For more info: https://www.kicad.org/download/linux/
"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/kicad"
    write_install_hint "$dest" "kicad (linux-x86_64)" "KiCad - Installation Instructions (linux-x86_64)
==================================================

Ubuntu/Debian:
  sudo add-apt-repository ppa:kicad/kicad-8.0-releases
  sudo apt update
  sudo apt install kicad

Fedora:
  sudo dnf install kicad

Flatpak:
  flatpak install flathub org.kicad.KiCad

For more info: https://www.kicad.org/download/linux/
"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/kicad"
    write_install_hint "$dest" "kicad (macos-arm64)" "KiCad - Installation Instructions (macOS)
============================================

Using Homebrew:
  brew install kicad

Or download the official DMG installer from:
  https://www.kicad.org/download/macos/

For more info: https://www.kicad.org/download/
"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/kicad"
    write_install_hint "$dest" "kicad (windows-x64)" "KiCad - Installation Instructions (Windows)
=============================================

Download the official installer from:
  https://www.kicad.org/download/windows/

Or use winget:
  winget install KiCad.KiCad

For more info: https://www.kicad.org/download/
"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_kicad
