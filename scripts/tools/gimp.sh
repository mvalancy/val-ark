#!/bin/bash
# Val Ark - Download GIMP
source "$(dirname "$0")/_common.sh"

TOOL_NAME="gimp"
PINNED_VERSION="2.10.38"

download_gimp() {
    log "Downloading ${TOOL_NAME}..."

    local BASE="https://download.gimp.org/gimp/v2.10"

    # linux-x86_64: flatpak is the official method, provide install hint
    local dest="${TOOLS_DIR}/linux-x86_64/gimp"
    ensure_dir "$dest"
    write_install_hint "$dest" "gimp (linux-x86_64)" "GIMP - linux-x86_64
=====================

Install via Flatpak (recommended by GIMP project):
  flatpak install flathub org.gimp.GIMP

Or via package manager:
  sudo apt install gimp

For more info: https://www.gimp.org/downloads/
"

    # linux-arm64: package manager only
    dest="${TOOLS_DIR}/linux-arm64/gimp"
    ensure_dir "$dest"
    write_install_hint "$dest" "gimp (linux-arm64)" "GIMP - linux-arm64
=====================

Install via package manager:
  sudo apt install gimp

For more info: https://www.gimp.org/downloads/
"

    # macos-arm64: DMG from official site
    dest="${TOOLS_DIR}/macos-arm64/gimp"
    ensure_dir "$dest"
    local mac_url="${BASE}/osx/gimp-${PINNED_VERSION}-arm64.dmg"
    download_file "$mac_url" "${dest}/GIMP.dmg" "gimp macos-arm64" || \
        write_install_hint "$dest" "gimp (macos-arm64)" "GIMP - macOS ARM64
=====================

  brew install --cask gimp

Or download from: https://www.gimp.org/downloads/
"

    # windows-x64: installer from official site
    dest="${TOOLS_DIR}/windows-x64/gimp"
    ensure_dir "$dest"
    local win_url="${BASE}/windows/gimp-${PINNED_VERSION}-setup.exe"
    download_file "$win_url" "${dest}/GIMP-Setup.exe" "gimp windows-x64" || \
        write_install_hint "$dest" "gimp (windows-x64)" "GIMP - Windows x64
=====================

Download from: https://www.gimp.org/downloads/
"

    log_success "GIMP download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_gimp
