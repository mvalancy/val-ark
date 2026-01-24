#!/bin/bash
###############################################################################
# Val Ark - Download FFmpeg
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="ffmpeg"

download_ffmpeg() {
    log "Downloading ${TOOL_NAME}..."

    # linux-arm64
    local LINUX_ARM64_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
    download_and_extract "$LINUX_ARM64_URL" "$TOOLS_DIR/linux-arm64/ffmpeg" "FFmpeg linux-arm64" 1

    # linux-x86_64
    local LINUX_X64_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
    download_and_extract "$LINUX_X64_URL" "$TOOLS_DIR/linux-x86_64/ffmpeg" "FFmpeg linux-x86_64" 1

    # windows-x64
    local WIN_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    download_and_extract "$WIN_URL" "$TOOLS_DIR/windows-x64/ffmpeg" "FFmpeg windows-x64"

    # macOS arm64: evermeet.cx builds
    local MACOS_DIR="$TOOLS_DIR/macos-arm64/ffmpeg"
    ensure_dir "$MACOS_DIR"

    local FFMPEG_MAC_URL="https://evermeet.cx/ffmpeg/ffmpeg-8.0.1.zip"
    local FFPROBE_MAC_URL="https://evermeet.cx/ffmpeg/ffprobe-8.0.1.zip"

    download_and_extract "$FFMPEG_MAC_URL" "$MACOS_DIR" "FFmpeg macOS arm64 (ffmpeg)"
    download_and_extract "$FFPROBE_MAC_URL" "$MACOS_DIR" "FFmpeg macOS arm64 (ffprobe)"

    log_success "FFmpeg download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_ffmpeg
