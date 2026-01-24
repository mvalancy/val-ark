#!/bin/bash
# Val Ark - Download Telegraf
source "$(dirname "$0")/_common.sh"

TOOL_NAME="telegraf"
PINNED_VERSION="1.37.1"

download_telegraf() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"

    # linux-arm64
    local url="https://dl.influxdata.com/telegraf/releases/telegraf-${ver}_linux_arm64.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/telegraf" "telegraf linux-arm64" 1

    # linux-x86_64
    url="https://dl.influxdata.com/telegraf/releases/telegraf-${ver}_linux_amd64.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/telegraf" "telegraf linux-x86_64" 1

    # macos-arm64
    url="https://dl.influxdata.com/telegraf/releases/telegraf-${ver}_darwin_arm64.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/macos-arm64/telegraf" "telegraf macos-arm64" 1

    # windows-x64
    url="https://dl.influxdata.com/telegraf/releases/telegraf-${ver}_windows_amd64.zip"
    download_and_extract "$url" "${TOOLS_DIR}/windows-x64/telegraf" "telegraf windows-x64" 1

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_telegraf
