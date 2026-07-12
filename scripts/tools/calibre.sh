#!/bin/bash
# Val Ark - Download Calibre
source "$(dirname "$0")/_common.sh"

TOOL_NAME="calibre"
PINNED_VERSION="v9.11.0"

# Calibre artifacts land under versionless names (extracted tree, Calibre.dmg,
# Calibre-Portable.exe), so a new release would otherwise be skipped as
# "already present". version_gate/version_stamp (see _common.sh) handle the
# per-platform .version marker and stale-artifact clearing.
download_calibre() {
    log "Downloading ${TOOL_NAME}..."

    # Tags are like v9.11.0; download URLs on download.calibre-ebook.com use
    # the bare version number.
    local tag
    tag=$(github_latest_tag "kovidgoyal/calibre" "$PINNED_VERSION")
    local version="${tag#v}"
    local BASE="https://download.calibre-ebook.com/${version}"

    # linux-x86_64: portable tarball
    local dest="${TOOLS_DIR}/linux-x86_64/calibre"
    version_gate "$dest" "$version"
    download_and_extract "${BASE}/calibre-${version}-x86_64.txz" "$dest" "calibre linux-x86_64" 0 \
        && version_stamp "$dest" "$version"

    # linux-arm64: portable tarball
    dest="${TOOLS_DIR}/linux-arm64/calibre"
    version_gate "$dest" "$version"
    download_and_extract "${BASE}/calibre-${version}-arm64.txz" "$dest" "calibre linux-arm64" 0 \
        && version_stamp "$dest" "$version"

    # macos-arm64: DMG
    dest="${TOOLS_DIR}/macos-arm64/calibre"
    version_gate "$dest" "$version"
    download_file "${BASE}/calibre-${version}.dmg" "${dest}/Calibre.dmg" "calibre macos-arm64" \
        && version_stamp "$dest" "$version"

    # windows-x64: portable installer
    dest="${TOOLS_DIR}/windows-x64/calibre"
    version_gate "$dest" "$version"
    download_file "${BASE}/calibre-portable-installer-${version}.exe" "${dest}/Calibre-Portable.exe" "calibre windows-x64" \
        && version_stamp "$dest" "$version"

    log_success "Calibre download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_calibre
