#!/bin/bash
# Val Ark - Download GIMP
source "$(dirname "$0")/_common.sh"

TOOL_NAME="gimp"
PINNED_VERSION="3.2.4"

GIMP_DL_ROOT="https://download.gimp.org/gimp"

# Series directory for a version: 3.2.4 -> v3.2
gimp_series_dir() {
    local ver="$1"
    echo "v${ver%.*}"
}

# Best-effort live discovery of the newest stable 3.x release by parsing the
# upstream directory listings. Stable series have an even minor version
# (3.0, 3.2, ...); odd minors (3.1, 2.99, ...) are development series.
# Falls back to the pin when offline or the listing shape changes.
gimp_latest_version() {
    local index series ver minor

    # 1. Newest stable series dir from the top-level index (v3.0, v3.2, ...)
    index=$(curl -fsSL --connect-timeout 5 --max-time 15 "${GIMP_DL_ROOT}/" 2>/dev/null)
    series=$(echo "$index" \
        | grep -oE 'href="v3\.[0-9]+/"' \
        | grep -oE 'v3\.[0-9]+' | sort -u -V \
        | while read -r s; do
              minor="${s#v3.}"
              [ $(( minor % 2 )) -eq 0 ] && echo "$s"
          done | tail -1)

    # 2. Newest point release inside that series (from the linux/ AppImage names)
    if [ -n "$series" ]; then
        ver=$(curl -fsSL --connect-timeout 5 --max-time 15 "${GIMP_DL_ROOT}/${series}/linux/" 2>/dev/null \
            | grep -oE 'GIMP-[0-9]+\.[0-9]+\.[0-9]+-x86_64\.AppImage' \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u -V | tail -1)
    fi

    if [ -z "$ver" ]; then
        log_warn "Could not resolve latest GIMP version, using pin: ${PINNED_VERSION}" >&2
        echo "$PINNED_VERSION"
    else
        log_info "Resolved GIMP -> ${ver}" >&2
        echo "$ver"
    fi
}

download_gimp() {
    log "Downloading ${TOOL_NAME}..."

    local VERSION SERIES BASE
    VERSION=$(gimp_latest_version)
    SERIES=$(gimp_series_dir "$VERSION")
    BASE="${GIMP_DL_ROOT}/${SERIES}"

    # linux-x86_64: official AppImage
    local dest="${TOOLS_DIR}/linux-x86_64/gimp"
    version_gate "$dest" "$VERSION"
    if download_file "${BASE}/linux/GIMP-${VERSION}-x86_64.AppImage" \
            "${dest}/GIMP-${VERSION}-x86_64.AppImage" "gimp linux-x86_64"; then
        chmod +x "${dest}/GIMP-${VERSION}-x86_64.AppImage" 2>/dev/null
        rm -f "${dest}/INSTALL.txt"   # stale hint from the pre-AppImage era
        version_stamp "$dest" "$VERSION"
    else
        write_install_hint "$dest" "gimp (linux-x86_64)" "GIMP - linux-x86_64
=====================

Install via Flatpak (recommended by GIMP project):
  flatpak install flathub org.gimp.GIMP

Or via package manager:
  sudo apt install gimp

For more info: https://www.gimp.org/downloads/
"
    fi

    # linux-arm64: official AppImage (new with GIMP 3.x)
    dest="${TOOLS_DIR}/linux-arm64/gimp"
    version_gate "$dest" "$VERSION"
    if download_file "${BASE}/linux/GIMP-${VERSION}-aarch64.AppImage" \
            "${dest}/GIMP-${VERSION}-aarch64.AppImage" "gimp linux-arm64"; then
        chmod +x "${dest}/GIMP-${VERSION}-aarch64.AppImage" 2>/dev/null
        rm -f "${dest}/INSTALL.txt"   # stale hint from the pre-AppImage era
        version_stamp "$dest" "$VERSION"
    else
        write_install_hint "$dest" "gimp (linux-arm64)" "GIMP - linux-arm64
=====================

Install via package manager:
  sudo apt install gimp

For more info: https://www.gimp.org/downloads/
"
    fi

    # macos-arm64: DMG from official site (3.x moved osx/ -> macos/)
    dest="${TOOLS_DIR}/macos-arm64/gimp"
    version_gate "$dest" "$VERSION"
    if download_file "${BASE}/macos/gimp-${VERSION}-arm64.dmg" \
            "${dest}/gimp-${VERSION}-arm64.dmg" "gimp macos-arm64"; then
        version_stamp "$dest" "$VERSION"
    else
        write_install_hint "$dest" "gimp (macos-arm64)" "GIMP - macOS ARM64
=====================

  brew install --cask gimp

Or download from: https://www.gimp.org/downloads/
"
    fi

    # windows-x64: installer from official site
    dest="${TOOLS_DIR}/windows-x64/gimp"
    version_gate "$dest" "$VERSION"
    if download_file "${BASE}/windows/gimp-${VERSION}-setup.exe" \
            "${dest}/gimp-${VERSION}-setup.exe" "gimp windows-x64"; then
        version_stamp "$dest" "$VERSION"
    else
        write_install_hint "$dest" "gimp (windows-x64)" "GIMP - Windows x64
=====================

Download from: https://www.gimp.org/downloads/
"
    fi

    log_success "GIMP download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_gimp
