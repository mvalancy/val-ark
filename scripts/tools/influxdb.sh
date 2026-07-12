#!/bin/bash
# Val Ark - Download InfluxDB 2.x (server + influx CLI)
#
# Mirrors the LATEST 2.x line. Note: influxdata/influxdb's /releases/latest
# points at the 3.x (Rust) line, so the server version is resolved from the
# tags list filtered to v2.* (semver-sorted), falling back to the pin offline.
# The `influx` client CLI is a SEPARATE artifact (influxdata/influx-cli) that
# a 2.x server is hard to administer without — mirrored alongside the server.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="influxdb"
PINNED_VERSION="2.9.1"        # latest 2.x server
PINNED_CLI_VERSION="2.8.0"    # latest influx-cli

# Latest v2.* tag from the tags API (releases/latest would return 3.x).
influxdb2_latest() {
    local tag
    tag=$(curl -fsSL --connect-timeout 15 \
            ${GITHUB_TOKEN:+-H "Authorization: token ${GITHUB_TOKEN}"} \
            "https://api.github.com/repos/influxdata/influxdb/tags?per_page=100" 2>/dev/null \
          | grep -oE '"name": *"v2\.[0-9]+\.[0-9]+"' | grep -oE 'v2\.[0-9]+\.[0-9]+' \
          | sort -V | tail -1)
    echo "${tag#v}"
}

download_influxdb() {
    log "Downloading ${TOOL_NAME}..."

    local ver cli_ver cli_tag
    ver="$(influxdb2_latest)"; [ -n "$ver" ] || ver="${PINNED_VERSION}"
    cli_tag=$(github_latest_tag "influxdata/influx-cli" "v${PINNED_CLI_VERSION}")
    cli_ver="${cli_tag#v}"
    log "InfluxDB server ${ver}, influx CLI ${cli_ver}"

    local stamp="server-${ver}+cli-${cli_ver}" base="https://dl.influxdata.com/influxdb/releases"
    local dest

    # linux-arm64
    dest="${TOOLS_DIR}/linux-arm64/influxdb"
    version_gate "$dest" "$stamp"
    download_and_extract "${base}/influxdb2-${ver}_linux_arm64.tar.gz" "$dest" "influxdb linux-arm64" 1 \
        && download_and_extract "${base}/influxdb2-client-${cli_ver}-linux-arm64.tar.gz" "${dest}/cli" "influx-cli linux-arm64" 1 \
        && version_stamp "$dest" "$stamp"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/influxdb"
    version_gate "$dest" "$stamp"
    download_and_extract "${base}/influxdb2-${ver}_linux_amd64.tar.gz" "$dest" "influxdb linux-x86_64" 1 \
        && download_and_extract "${base}/influxdb2-client-${cli_ver}-linux-amd64.tar.gz" "${dest}/cli" "influx-cli linux-x86_64" 1 \
        && version_stamp "$dest" "$stamp"

    # macos-arm64 — upstream ships NO arm64 darwin server build for the 2.x
    # line; the Intel (darwin_amd64) build runs fine under Rosetta 2. Mirror it
    # with an honest README rather than leaving macOS users with nothing.
    dest="${TOOLS_DIR}/macos-arm64/influxdb"
    version_gate "$dest" "$stamp"
    if download_and_extract "${base}/influxdb2-${ver}_darwin_amd64.tar.gz" "$dest" "influxdb macos (x86_64/Rosetta)" 1 \
        && download_and_extract "${base}/influxdb2-client-${cli_ver}-darwin-amd64.tar.gz" "${dest}/cli" "influx-cli macos (x86_64/Rosetta)" 1; then
        cat > "${dest}/README.txt" <<'EOF'
InfluxDB 2.x for macOS
======================
Upstream ships only x86_64 (Intel) darwin builds for the 2.x line.
These binaries run on Apple Silicon via Rosetta 2:
  softwareupdate --install-rosetta   # once, if not already installed
  ./influxd                          # server (UI at http://localhost:8086)
  ./cli/influx                       # client CLI
Native alternative when online: brew install influxdb
EOF
        version_stamp "$dest" "$stamp"
    fi

    # windows-x64 (unzip ignores --strip-components: flatten nested dirs)
    dest="${TOOLS_DIR}/windows-x64/influxdb"
    version_gate "$dest" "$stamp"
    if download_and_extract "${base}/influxdb2-${ver}-windows_amd64.zip" "$dest" "influxdb windows-x64" 0 \
        && download_and_extract "${base}/influxdb2-client-${cli_ver}-windows-amd64.zip" "${dest}/cli" "influx-cli windows-x64" 0; then
        local nest
        for nest in "${dest}/influxdb2-${ver}" "${dest}/influxdb2_windows_amd64" \
                    "${dest}/cli/influxdb2-client-${cli_ver}-windows-amd64"; do
            if [ -d "$nest" ]; then
                mv "$nest"/* "$(dirname "$nest")"/ 2>/dev/null
                rmdir "$nest" 2>/dev/null
            fi
        done
        version_stamp "$dest" "$stamp"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_influxdb
