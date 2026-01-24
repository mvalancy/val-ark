#!/bin/bash
# Val Ark - Download InfluxDB
source "$(dirname "$0")/_common.sh"

TOOL_NAME="influxdb"
PINNED_VERSION="2.7.11"

download_influxdb() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"

    # linux-arm64
    local url="https://dl.influxdata.com/influxdb/releases/influxdb2-${ver}_linux_arm64.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/influxdb" "influxdb linux-arm64" 1

    # linux-x86_64
    url="https://dl.influxdata.com/influxdb/releases/influxdb2-${ver}_linux_amd64.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/influxdb" "influxdb linux-x86_64" 1

    # macos-arm64
    write_install_hint "${TOOLS_DIR}/macos-arm64/influxdb" "influxdb" \
"InfluxDB for macOS
====================

Install via Homebrew:
  brew install influxdb

Or download from:
  https://portal.influxdata.com/downloads/

Start the service:
  influxd

Access the UI at:
  http://localhost:8086
"

    # windows-x64
    write_install_hint "${TOOLS_DIR}/windows-x64/influxdb" "influxdb" \
"InfluxDB for Windows
=====================

Download the Windows binary from:
  https://portal.influxdata.com/downloads/

Or use the direct link:
  https://dl.influxdata.com/influxdb/releases/influxdb2-${ver}-windows-amd64.zip

Extract and run:
  influxd.exe

Access the UI at:
  http://localhost:8086
"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_influxdb
