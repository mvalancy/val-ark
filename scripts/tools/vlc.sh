#!/bin/bash
# Val Ark - Download VLC
source "$(dirname "$0")/_common.sh"

TOOL_NAME="vlc"
PINNED_VERSION="3.0.21"

download_vlc() {
    log "Downloading ${TOOL_NAME}..."

    # VLC is best installed via system package managers or official downloads.

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/vlc"
    write_install_hint "$dest" "vlc (linux-arm64)" "VLC Media Player - Installation Instructions (linux-arm64)
=============================================================

Ubuntu/Debian:
  sudo apt update
  sudo apt install vlc

Fedora:
  sudo dnf install vlc

Snap:
  sudo snap install vlc

Flatpak:
  flatpak install flathub org.videolan.VLC

For more info: https://www.videolan.org/vlc/download-debian.html
"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/vlc"
    write_install_hint "$dest" "vlc (linux-x86_64)" "VLC Media Player - Installation Instructions (linux-x86_64)
=============================================================

Ubuntu/Debian:
  sudo apt update
  sudo apt install vlc

Fedora:
  sudo dnf install vlc

Snap:
  sudo snap install vlc

Flatpak:
  flatpak install flathub org.videolan.VLC

For more info: https://www.videolan.org/vlc/download-debian.html
"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/vlc"
    write_install_hint "$dest" "vlc (macos-arm64)" "VLC Media Player - Installation Instructions (macOS)
======================================================

Using Homebrew:
  brew install --cask vlc

Or download the official DMG from:
  https://www.videolan.org/vlc/download-macosx.html

For more info: https://www.videolan.org/vlc/
"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/vlc"
    write_install_hint "$dest" "vlc (windows-x64)" "VLC Media Player - Installation Instructions (Windows)
=======================================================

Download the official installer from:
  https://www.videolan.org/vlc/download-windows.html

Or use winget:
  winget install VideoLAN.VLC

Or use chocolatey:
  choco install vlc

For more info: https://www.videolan.org/vlc/
"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_vlc
