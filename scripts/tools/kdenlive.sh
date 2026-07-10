#!/bin/bash
# Val Ark - Download Kdenlive
source "$(dirname "$0")/_common.sh"

TOOL_NAME="kdenlive"
# Latest stable from the live tree: https://download.kde.org/stable/kdenlive/
# (older series like 25.12 are moved to the KDE Attic and vanish from /stable/).
PINNED_VERSION="26.04.3"

download_kdenlive() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"
    local major_minor="${ver%.*}"

    # linux-x86_64: AppImage
    local dest="${TOOLS_DIR}/linux-x86_64/kdenlive"
    ensure_dir "$dest"
    version_gate "$dest" "$ver"
    local url="https://download.kde.org/stable/kdenlive/${major_minor}/linux/kdenlive-${ver}-x86_64.AppImage"
    if download_file "$url" "${dest}/Kdenlive.AppImage" "kdenlive linux-x86_64"; then
        chmod +x "${dest}/Kdenlive.AppImage" 2>/dev/null
        version_stamp "$dest" "$ver"
    fi

    # linux-arm64: no official AppImage
    dest="${TOOLS_DIR}/linux-arm64/kdenlive"
    ensure_dir "$dest"
    write_install_hint "$dest" "kdenlive (linux-arm64)" "Kdenlive - linux-arm64
=====================

No official ARM64 AppImage is available. Install via package manager:

  sudo apt install kdenlive

Or via Flatpak:
  flatpak install flathub org.kde.kdenlive

For more info: https://kdenlive.org/en/download/
"

    # macos-arm64: DMG
    dest="${TOOLS_DIR}/macos-arm64/kdenlive"
    ensure_dir "$dest"
    version_gate "$dest" "$ver"
    url="https://download.kde.org/stable/kdenlive/${major_minor}/macOS/kdenlive-${ver}-arm64.dmg"
    if download_file "$url" "${dest}/Kdenlive.dmg" "kdenlive macos-arm64"; then
        version_stamp "$dest" "$ver"
    fi

    # windows-x64: installer
    dest="${TOOLS_DIR}/windows-x64/kdenlive"
    ensure_dir "$dest"
    version_gate "$dest" "$ver"
    url="https://download.kde.org/stable/kdenlive/${major_minor}/windows/kdenlive-${ver}.exe"
    if download_file "$url" "${dest}/Kdenlive-Setup.exe" "kdenlive windows-x64"; then
        version_stamp "$dest" "$ver"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_kdenlive
