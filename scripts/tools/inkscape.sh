#!/bin/bash
# Val Ark - Download Inkscape
source "$(dirname "$0")/_common.sh"

TOOL_NAME="inkscape"
# Upstream download URLs on media.inkscape.org embed content-hash / dated
# filenames that cannot be derived from the version number alone, so each
# release bump must update PINNED_VERSION *and* the three URLs below
# (find them via the per-platform pages under
# https://inkscape.org/release/<version>/ and HEAD-verify).
PINNED_VERSION="1.4.4"

download_inkscape() {
    log "Downloading ${TOOL_NAME}..."

    local version="$PINNED_VERSION"

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
    version_gate "$dest" "$version"
    local url="https://media.inkscape.org/dl/resources/file/Inkscape-1.4.4.AppImage"
    if download_file "$url" "${dest}/Inkscape-${version}.AppImage" "Inkscape Linux x86_64"; then
        chmod +x "${dest}/Inkscape-${version}.AppImage" 2>/dev/null
        version_stamp "$dest" "$version"
    fi

    # macos-arm64: DMG from official site
    dest="${TOOLS_DIR}/macos-arm64/inkscape"
    version_gate "$dest" "$version"
    url="https://media.inkscape.org/dl/resources/file/Inkscape-1.4.4_arm64.dmg"
    download_file "$url" "${dest}/Inkscape-${version}_arm64.dmg" "Inkscape macOS ARM64" \
        && version_stamp "$dest" "$version"

    # windows-x64: Official signed installer
    dest="${TOOLS_DIR}/windows-x64/inkscape"
    version_gate "$dest" "$version"
    url="https://media.inkscape.org/dl/resources/file/inkscape-1.4.4_2026-05-05_dcaf3e7-x64.signed.exe"
    download_file "$url" "${dest}/Inkscape-${version}-Setup.exe" "Inkscape Windows" \
        && version_stamp "$dest" "$version"

    log_success "Inkscape download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_inkscape
