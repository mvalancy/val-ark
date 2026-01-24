#!/bin/bash
# Val Ark - Download Calibre
source "$(dirname "$0")/_common.sh"

TOOL_NAME="calibre"
PINNED_VERSION="7.23.0"

download_calibre() {
    log "Downloading ${TOOL_NAME}..."

    local BASE="https://download.calibre-ebook.com/${PINNED_VERSION}"

    # linux-x86_64: portable tarball
    local dest="${TOOLS_DIR}/linux-x86_64/calibre"
    ensure_dir "$dest"
    download_and_extract "${BASE}/calibre-${PINNED_VERSION}-x86_64.txz" "$dest" "calibre linux-x86_64" 0

    # linux-arm64: portable tarball
    dest="${TOOLS_DIR}/linux-arm64/calibre"
    ensure_dir "$dest"
    download_and_extract "${BASE}/calibre-${PINNED_VERSION}-arm64.txz" "$dest" "calibre linux-arm64" 0

    # macos-arm64: DMG
    dest="${TOOLS_DIR}/macos-arm64/calibre"
    ensure_dir "$dest"
    download_file "${BASE}/calibre-${PINNED_VERSION}.dmg" "${dest}/Calibre.dmg" "calibre macos-arm64"

    # windows-x64: portable installer
    dest="${TOOLS_DIR}/windows-x64/calibre"
    ensure_dir "$dest"
    download_file "${BASE}/calibre-portable-installer-${PINNED_VERSION}.exe" "${dest}/Calibre-Portable.exe" "calibre windows-x64"

    log_success "Calibre download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_calibre
