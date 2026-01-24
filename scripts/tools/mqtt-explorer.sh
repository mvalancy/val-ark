#!/bin/bash
# Val Ark - Download MQTT Explorer
source "$(dirname "$0")/_common.sh"

TOOL_NAME="mqtt-explorer"
PINNED_VERSION="v0.4.0-beta.6"

download_mqtt_explorer() {
    log "Downloading ${TOOL_NAME}..."

    local repo="thomasnordquist/MQTT-Explorer"
    local tag="${PINNED_VERSION}"

    # linux-x86_64: AppImage
    local url
    url=$(github_asset_url "$repo" "$tag" "MQTT-Explorer.*AppImage")
    if [ -n "$url" ]; then
        local dest="${TOOLS_DIR}/linux-x86_64/mqtt-explorer"
        ensure_dir "$dest"
        local filename
        filename=$(basename "$url")
        download_file "$url" "${dest}/${filename}" "mqtt-explorer linux-x86_64 AppImage"
        chmod +x "${dest}/${filename}" 2>/dev/null
    else
        log_error "Could not find MQTT-Explorer AppImage asset"
    fi

    # linux-arm64
    write_install_hint "${TOOLS_DIR}/linux-arm64/mqtt-explorer" "mqtt-explorer" \
"MQTT Explorer for Linux ARM64
===============================

MQTT Explorer does not provide an ARM64 Linux build.

Options:
1. Build from source:
   git clone https://github.com/thomasnordquist/MQTT-Explorer.git
   cd MQTT-Explorer
   npm install
   npm run build

2. Use the web-based version or run via Electron on x86_64.

3. Alternative MQTT clients for ARM64:
   - mosquitto_sub / mosquitto_pub (CLI)
   - MQTTX (https://mqttx.app/)
"

    # macos-arm64
    write_install_hint "${TOOLS_DIR}/macos-arm64/mqtt-explorer" "mqtt-explorer" \
"MQTT Explorer for macOS
========================

Download the macOS DMG from:
  https://github.com/thomasnordquist/MQTT-Explorer/releases/tag/${tag}

Or install via Homebrew:
  brew install --cask mqtt-explorer
"

    # windows-x64
    write_install_hint "${TOOLS_DIR}/windows-x64/mqtt-explorer" "mqtt-explorer" \
"MQTT Explorer for Windows
===========================

Download the Windows installer from:
  https://github.com/thomasnordquist/MQTT-Explorer/releases/tag/${tag}

Or install via Microsoft Store:
  Search for 'MQTT Explorer' in the Microsoft Store.
"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_mqtt_explorer
