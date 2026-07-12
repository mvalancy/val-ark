#!/bin/bash
# Val Ark - Download Grafana OSS (dashboards/visualization for the metrics stack)
source "$(dirname "$0")/_common.sh"

TOOL_NAME="Grafana"
PINNED_VERSION="13.1.0"

download_grafana() {
    log "Downloading ${TOOL_NAME}..."

    local tag ver
    tag=$(github_latest_tag "grafana/grafana" "v${PINNED_VERSION}")
    ver="${tag#v}"
    log "Grafana OSS ${ver}"

    local base="https://dl.grafana.com/oss/release" dest

    # linux-arm64
    dest="${TOOLS_DIR}/linux-arm64/grafana"
    version_gate "$dest" "$ver"
    download_and_extract "${base}/grafana-${ver}.linux-arm64.tar.gz" "$dest" "grafana linux-arm64" 1 \
        && version_stamp "$dest" "$ver"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/grafana"
    version_gate "$dest" "$ver"
    download_and_extract "${base}/grafana-${ver}.linux-amd64.tar.gz" "$dest" "grafana linux-x86_64" 1 \
        && version_stamp "$dest" "$ver"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/grafana"
    version_gate "$dest" "$ver"
    download_and_extract "${base}/grafana-${ver}.darwin-arm64.tar.gz" "$dest" "grafana macos-arm64" 1 \
        && version_stamp "$dest" "$ver"

    # windows-x64 (unzip ignores --strip-components: flatten the nested dir)
    dest="${TOOLS_DIR}/windows-x64/grafana"
    version_gate "$dest" "$ver"
    if download_and_extract "${base}/grafana-${ver}.windows-amd64.zip" "$dest" "grafana windows-x64" 0; then
        local wnest="${dest}/grafana-v${ver}"
        [ -d "$wnest" ] || wnest="${dest}/grafana-${ver}"
        if [ -d "$wnest" ] && [ ! -f "${dest}/bin/grafana.exe" ]; then
            mv "$wnest"/* "$dest"/ 2>/dev/null
            rmdir "$wnest" 2>/dev/null
        fi
        version_stamp "$dest" "$ver"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_grafana
