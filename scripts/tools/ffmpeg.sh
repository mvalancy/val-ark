#!/bin/bash
###############################################################################
# Val Ark - Download FFmpeg
#
# linux + windows: BtbN rolling "master latest" GPL builds -- current by design.
# macos-arm64: native Apple Silicon builds from osxexperts.net. (evermeet.cx
# only ships x86_64 binaries, which would need Rosetta on M-series Macs.)
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="ffmpeg"

# osxexperts.net names its arm64 zips by major.minor with the dot stripped,
# e.g. ffmpeg81arm.zip == FFmpeg 8.1. Fallback tag if the site is unreachable.
MACOS_PINNED_TAG="81"

# Resolve the newest arm64 build tag from the osxexperts.net homepage, falling
# back to the pin. (The site rate-limits bursts, so this is a single fetch.)
resolve_macos_tag() {
    local tag
    tag=$(curl -fsSL --max-time 20 https://www.osxexperts.net/ 2>/dev/null \
        | grep -oE 'ffmpeg[0-9]+arm\.zip' | sed 's/^ffmpeg//; s/arm\.zip$//' | sort -n | tail -1)
    [ -n "$tag" ] && echo "$tag" || echo "$MACOS_PINNED_TAG"
}

download_ffmpeg() {
    log "Downloading ${TOOL_NAME}..."

    # BtbN's "latest" download URLs never change, so gate linux/windows on the
    # resolved autobuild release tag (fallback "master-latest") -- the marker
    # then names the actual build on disk instead of a constant.
    local btbn_tag
    btbn_tag=$(github_latest_tag "BtbN/FFmpeg-Builds" "master-latest")

    # "master-latest" is the FALLBACK placeholder (API rate-limited/offline),
    # not a real build id. Never trade a stamped real build for it: a flapping
    # API would otherwise wipe + re-download ~450MB per platform, twice per
    # flap. First-ever mirror (no marker yet) still proceeds.
    btbn_keep() {
        [ "$btbn_tag" = "master-latest" ] && [ -s "$1/.version" ] \
            && { log "ffmpeg $(basename "$(dirname "$1")"): keeping build $(cat "$1/.version") (tag lookup unavailable)"; return 0; } || return 1
    }

    # linux-arm64
    local LINUX_ARM64_DIR="$TOOLS_DIR/linux-arm64/ffmpeg"
    local LINUX_ARM64_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
    if ! btbn_keep "$LINUX_ARM64_DIR"; then
    version_gate "$LINUX_ARM64_DIR" "$btbn_tag"
    download_and_extract "$LINUX_ARM64_URL" "$LINUX_ARM64_DIR" "FFmpeg linux-arm64" 1 \
        && version_stamp "$LINUX_ARM64_DIR" "$btbn_tag"
    fi

    # linux-x86_64
    local LINUX_X64_DIR="$TOOLS_DIR/linux-x86_64/ffmpeg"
    local LINUX_X64_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
    if ! btbn_keep "$LINUX_X64_DIR"; then
    version_gate "$LINUX_X64_DIR" "$btbn_tag"
    download_and_extract "$LINUX_X64_URL" "$LINUX_X64_DIR" "FFmpeg linux-x86_64" 1 \
        && version_stamp "$LINUX_X64_DIR" "$btbn_tag"
    fi

    # windows-x64
    local WIN_DIR="$TOOLS_DIR/windows-x64/ffmpeg"
    local WIN_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    if ! btbn_keep "$WIN_DIR"; then
    version_gate "$WIN_DIR" "$btbn_tag"
    if download_and_extract "$WIN_URL" "$WIN_DIR" "FFmpeg windows-x64"; then
        # unzip ignores --strip-components, so the win zip lands nested one
        # level. Flatten it so bin/ffmpeg.exe sits at tools/windows-x64/ffmpeg/
        # like the linux trees (also repairs mirrors extracted before this fix).
        local wnest="$WIN_DIR/ffmpeg-master-latest-win64-gpl"
        if [ -d "$wnest" ] && [ ! -f "$WIN_DIR/bin/ffmpeg.exe" ]; then
            mv "$wnest"/* "$WIN_DIR/" 2>/dev/null && rmdir "$wnest" 2>/dev/null
        fi
        version_stamp "$WIN_DIR" "$btbn_tag"
    fi
    fi

    # macOS arm64: native Apple Silicon builds from osxexperts.net.
    # Each zip holds a single binary at the zip root (plus __MACOSX metadata).
    # download_and_extract can't be used twice into one dir -- after the first
    # extraction (+.dist archive copies) its ">=2 files" check would skip the
    # second zip -- so download each zip to a distinct .dist name and unzip
    # explicitly, ensuring BOTH binaries land.
    local MACOS_DIR="$TOOLS_DIR/macos-arm64/ffmpeg"
    ensure_dir "$MACOS_DIR"
    local mac_tag
    mac_tag="$(resolve_macos_tag)"
    version_gate "$MACOS_DIR" "$mac_tag"

    local mac_ok=1 mac_bin mac_zip
    for mac_bin in ffmpeg ffprobe; do
        mac_zip="$MACOS_DIR/.dist/${mac_bin}${mac_tag}arm.zip"
        download_file "https://www.osxexperts.net/${mac_bin}${mac_tag}arm.zip" \
            "$mac_zip" "FFmpeg macOS arm64 (${mac_bin} ${mac_tag})"
        if [ -s "$mac_zip" ] && [ ! -f "$MACOS_DIR/$mac_bin" ]; then
            unzip -o -q "$mac_zip" -x "__MACOSX/*" -d "$MACOS_DIR" 2>/dev/null \
                && chmod +x "$MACOS_DIR/$mac_bin" 2>/dev/null
        fi
        [ -f "$MACOS_DIR/$mac_bin" ] || mac_ok=0
    done
    [ "$mac_ok" = "1" ] && version_stamp "$MACOS_DIR" "$mac_tag"

    log_success "FFmpeg download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_ffmpeg
