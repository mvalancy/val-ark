#!/bin/bash
# Val Ark - Download yt-dlp
source "$(dirname "$0")/_common.sh"

TOOL_NAME="yt-dlp"
PINNED_VERSION="2024.12.23"

download_yt_dlp() {
    log "Downloading ${TOOL_NAME}..."

    local repo="yt-dlp/yt-dlp"
    local tag="${PINNED_VERSION}"
    local base_url="https://github.com/yt-dlp/yt-dlp/releases/download/${tag}"

    # linux-x86_64: standalone binary
    local dest="${TOOLS_DIR}/linux-x86_64/yt-dlp"
    ensure_dir "$dest"
    download_file "${base_url}/yt-dlp_linux" "${dest}/yt-dlp" "yt-dlp linux-x86_64"
    chmod +x "${dest}/yt-dlp" 2>/dev/null

    # linux-arm64: standalone binary
    dest="${TOOLS_DIR}/linux-arm64/yt-dlp"
    ensure_dir "$dest"
    download_file "${base_url}/yt-dlp_linux_aarch64" "${dest}/yt-dlp" "yt-dlp linux-arm64"
    chmod +x "${dest}/yt-dlp" 2>/dev/null

    # macos-arm64: universal binary
    dest="${TOOLS_DIR}/macos-arm64/yt-dlp"
    ensure_dir "$dest"
    download_file "${base_url}/yt-dlp_macos" "${dest}/yt-dlp" "yt-dlp macos-arm64"
    chmod +x "${dest}/yt-dlp" 2>/dev/null

    # windows-x64: exe
    dest="${TOOLS_DIR}/windows-x64/yt-dlp"
    ensure_dir "$dest"
    download_file "${base_url}/yt-dlp.exe" "${dest}/yt-dlp.exe" "yt-dlp windows-x64"

    log_success "yt-dlp download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_yt_dlp
