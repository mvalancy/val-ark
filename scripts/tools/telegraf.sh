#!/bin/bash
# Val Ark - Download Telegraf (latest stable, all four platforms)
source "$(dirname "$0")/_common.sh"

TOOL_NAME="telegraf"
PINNED_VERSION="1.39.1"

download_telegraf() {
    log "Downloading ${TOOL_NAME}..."

    local tag ver
    tag=$(github_latest_tag "influxdata/telegraf" "v${PINNED_VERSION}")
    ver="${tag#v}"
    log "Telegraf ${ver}"

    local base="https://dl.influxdata.com/telegraf/releases" dest

    # linux-arm64
    dest="${TOOLS_DIR}/linux-arm64/telegraf"
    version_gate "$dest" "$ver"
    download_and_extract "${base}/telegraf-${ver}_linux_arm64.tar.gz" "$dest" "telegraf linux-arm64" 1 \
        && version_stamp "$dest" "$ver"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/telegraf"
    version_gate "$dest" "$ver"
    download_and_extract "${base}/telegraf-${ver}_linux_amd64.tar.gz" "$dest" "telegraf linux-x86_64" 1 \
        && version_stamp "$dest" "$ver"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/telegraf"
    version_gate "$dest" "$ver"
    download_and_extract "${base}/telegraf-${ver}_darwin_arm64.tar.gz" "$dest" "telegraf macos-arm64" 1 \
        && version_stamp "$dest" "$ver"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/telegraf"
    version_gate "$dest" "$ver"
    download_and_extract "${base}/telegraf-${ver}_windows_amd64.zip" "$dest" "telegraf windows-x64" 0 \
        && version_stamp "$dest" "$ver"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_telegraf
