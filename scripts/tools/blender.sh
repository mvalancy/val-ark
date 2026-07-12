#!/bin/bash
# Val Ark - Download Blender
source "$(dirname "$0")/_common.sh"

TOOL_NAME="blender"
PINNED_VERSION="5.1.2"   # fallback when download.blender.org is unreachable

RELEASE_BASE="https://download.blender.org/release"

# Resolve the newest stable release from the live download.blender.org index:
# highest BlenderX.Y series directory, then the newest blender-X.Y.Z asset in
# it. Falls back to PINNED_VERSION (series dir derived from it) when offline.
# Sets BLENDER_VER (X.Y.Z) and BLENDER_MIRROR (series directory URL).
resolve_blender_version() {
    BLENDER_VER="$PINNED_VERSION"
    BLENDER_MIRROR="${RELEASE_BASE}/Blender${PINNED_VERSION%.*}"

    local series
    series=$(curl -fsSL --max-time 20 "${RELEASE_BASE}/" 2>/dev/null \
        | grep -oE 'href="Blender[0-9]+\.[0-9]+/"' \
        | sed 's/^href="//; s/\/"$//' | sort -V | tail -1)
    [ -n "$series" ] || return 0

    local ver
    ver=$(curl -fsSL --max-time 20 "${RELEASE_BASE}/${series}/" 2>/dev/null \
        | grep -oE 'blender-[0-9]+\.[0-9]+\.[0-9]+' \
        | sed 's/^blender-//' | sort -Vu | tail -1)
    [ -n "$ver" ] || return 0

    BLENDER_VER="$ver"
    BLENDER_MIRROR="${RELEASE_BASE}/${series}"
}

download_blender() {
    log "Downloading ${TOOL_NAME}..."

    resolve_blender_version
    local ver="$BLENDER_VER"
    local mirror="$BLENDER_MIRROR"
    log_info "blender: resolved version ${ver} (${mirror})"

    # linux-x86_64
    local dest="${TOOLS_DIR}/linux-x86_64/blender"
    local url="${mirror}/blender-${ver}-linux-x64.tar.xz"
    version_gate "$dest" "$ver"
    download_and_extract "$url" "$dest" "blender ${ver} linux-x86_64" 1 \
        && version_stamp "$dest" "$ver"

    # linux-arm64: no official arm64 Linux build (release dir ships only
    # linux-x64, macos-arm64, and windows-x64/arm64 assets)
    dest="${TOOLS_DIR}/linux-arm64/blender"
    write_install_hint "$dest" "blender (linux-arm64)" "Blender - linux-arm64
======================

Blender does not provide official arm64 Linux builds.

Options:
  1. Build from source:
     git clone https://projects.blender.org/blender/blender.git
     cd blender
     make update
     make

  2. Use snap (if available for arm64):
     sudo snap install blender --classic

  3. Use the x86_64 version with emulation (not recommended for performance)

For more info: https://www.blender.org/download/
"

    # macos-arm64 (dmg mirrored as-is for offline install)
    dest="${TOOLS_DIR}/macos-arm64/blender"
    url="${mirror}/blender-${ver}-macos-arm64.dmg"
    version_gate "$dest" "$ver"
    ensure_dir "$dest"
    download_file "$url" "${dest}/blender-${ver}-macos-arm64.dmg" "blender ${ver} macos-arm64" \
        && version_stamp "$dest" "$ver"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/blender"
    url="${mirror}/blender-${ver}-windows-x64.zip"
    version_gate "$dest" "$ver"
    if download_and_extract "$url" "$dest" "blender ${ver} windows-x64" 0; then
        # unzip ignores --strip-components, so the zip lands nested one level.
        # Flatten it so blender.exe sits at tools/windows-x64/blender/ (same
        # trick as node.sh).
        local wnest="${dest}/blender-${ver}-windows-x64"
        if [ -d "$wnest" ] && [ ! -f "${dest}/blender.exe" ]; then
            mv "$wnest"/* "$dest"/ 2>/dev/null && rmdir "$wnest" 2>/dev/null
        fi
        version_stamp "$dest" "$ver"
    fi

    log_success "${TOOL_NAME} download complete (${ver})."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_blender
