#!/bin/bash
# Val Ark - Download MQTT Explorer
source "$(dirname "$0")/_common.sh"

TOOL_NAME="mqtt-explorer"
PINNED_VERSION="v0.4.0-beta.6"

download_mqtt_explorer() {
    log "Downloading ${TOOL_NAME}..."

    local repo="thomasnordquist/MQTT-Explorer"
    local tag="${PINNED_VERSION}"

    # linux-x86_64: AppImage (the x86_64 build has no arch suffix)
    # Filename format: MQTT-Explorer-<version>.AppImage (no -arm64 or -armv7l suffix)
    local ver_strip="${tag#v}"
    local url="https://github.com/${repo}/releases/download/${tag}/MQTT-Explorer-${ver_strip}.AppImage"
    local dest="${TOOLS_DIR}/linux-x86_64/mqtt-explorer"
    ensure_dir "$dest"
    local filename="MQTT-Explorer-${ver_strip}.AppImage"
    download_file "$url" "${dest}/${filename}" "mqtt-explorer linux-x86_64 AppImage"
    chmod +x "${dest}/${filename}" 2>/dev/null

    # linux-arm64: ARM64 AppImage
    url="https://github.com/${repo}/releases/download/${tag}/MQTT-Explorer-${ver_strip}-arm64.AppImage"
    local dest_arm64="${TOOLS_DIR}/linux-arm64/mqtt-explorer"
    ensure_dir "$dest_arm64"
    download_file "$url" "${dest_arm64}/MQTT-Explorer-${ver_strip}-arm64.AppImage" "mqtt-explorer linux-arm64 AppImage"
    chmod +x "${dest_arm64}/MQTT-Explorer-${ver_strip}-arm64.AppImage" 2>/dev/null

    # macos-arm64: DMG
    url="https://github.com/${repo}/releases/download/${tag}/MQTT-Explorer-${ver_strip}-arm64.dmg"
    local dest_macos="${TOOLS_DIR}/macos-arm64/mqtt-explorer"
    ensure_dir "$dest_macos"
    download_file "$url" "${dest_macos}/MQTT-Explorer-${ver_strip}-arm64.dmg" "mqtt-explorer macos-arm64 DMG"

    # windows-x64: Setup exe
    url="https://github.com/${repo}/releases/download/${tag}/MQTT-Explorer-Setup-${ver_strip}.exe"
    local dest_win="${TOOLS_DIR}/windows-x64/mqtt-explorer"
    ensure_dir "$dest_win"
    download_file "$url" "${dest_win}/MQTT-Explorer-Setup-${ver_strip}.exe" "mqtt-explorer windows-x64 Setup"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_mqtt_explorer
