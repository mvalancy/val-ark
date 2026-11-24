#!/bin/bash
# Val Ark - Download VLC
source "$(dirname "$0")/_common.sh"

TOOL_NAME="vlc"
PINNED_VERSION="3.0.23"

# Discover the latest stable VLC version from the official "last" listing
# (https://get.videolan.org/vlc/last/ contains vlc-X.Y.Z.tar.xz). Falls back
# to PINNED_VERSION when offline or the parse fails.
vlc_latest_version() {
    local ver
    ver=$(curl -fsSL --max-time 15 "https://get.videolan.org/vlc/last/" 2>/dev/null \
        | grep -oE 'vlc-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' \
        | head -1 \
        | sed -E 's/^vlc-([0-9.]+)\.tar\.xz$/\1/')
    if [ -n "$ver" ]; then
        echo "$ver"
    else
        echo "$PINNED_VERSION"
    fi
}

download_vlc() {
    log "Downloading ${TOOL_NAME}..."

    local version
    version=$(vlc_latest_version)
    if [ "$version" != "$PINNED_VERSION" ]; then
        log "VLC latest upstream version: ${version} (pinned fallback: ${PINNED_VERSION})"
    else
        log "VLC version: ${version}"
    fi

    # linux-arm64: No official portable build, use install hint
    local dest="${TOOLS_DIR}/linux-arm64/vlc"
    ensure_dir "$dest"
    local src_path=""
    src_path=$(mirror_source_tarball vlc "$version" \
        "https://get.videolan.org/vlc/${version}/vlc-${version}.tar.xz" \
        "https://download.videolan.org/pub/videolan/vlc/${version}/vlc-${version}.tar.xz") || src_path=""
    local vlc_steps="  tar xf vlc-${version}.tar.xz && cd vlc-${version}
  ./configure --prefix=/usr/local && make -j\$(nproc) && sudo make install
  (https://wiki.videolan.org/UnixCompile/)"
    build_from_source_hint vlc "VLC Media Player" linux-arm64 vlc vlc "$src_path" videolan/vlc "$vlc_steps"

    # linux-x86_64: No official portable build, use install hint
    dest="${TOOLS_DIR}/linux-x86_64/vlc"
    ensure_dir "$dest"
    build_from_source_hint vlc "VLC Media Player" linux-x86_64 vlc vlc "$src_path" videolan/vlc "$vlc_steps"

    # macos-arm64: Universal DMG from official site
    dest="${TOOLS_DIR}/macos-arm64/vlc"
    ensure_dir "$dest"
    version_gate "$dest" "$version"
    local url="https://get.videolan.org/vlc/${version}/macosx/vlc-${version}-universal.dmg"
    if download_file "$url" "${dest}/VLC-${version}.dmg" "VLC macOS"; then
        version_stamp "$dest" "$version"
    fi

    # windows-x64: Official installer
    dest="${TOOLS_DIR}/windows-x64/vlc"
    ensure_dir "$dest"
    version_gate "$dest" "$version"
    url="https://get.videolan.org/vlc/${version}/win64/vlc-${version}-win64.exe"
    if download_file "$url" "${dest}/VLC-${version}-Setup.exe" "VLC Windows"; then
        version_stamp "$dest" "$version"
    fi

    log_success "VLC download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_vlc
