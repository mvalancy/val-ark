#!/bin/bash
# Val Ark - Download Tailscale
source "$(dirname "$0")/_common.sh"

TOOL_NAME="tailscale"
PINNED_VERSION="1.104.7"   # fallback only: the stable channel keeps ONLY the newest build,
# so the version is read from https://pkgs.tailscale.com/stable/?mode=json on every run.
PKGS="https://pkgs.tailscale.com/stable"

tailscale_latest_version() {
    local v
    v=$(curl -fsSL --max-time 20 "${PKGS}/?mode=json" 2>/dev/null \
        | grep -oE '"TarballsVersion": *"[0-9][0-9.]*"' | grep -oE '[0-9][0-9.]*' | head -1)
    echo "${v:-$PINNED_VERSION}"
}

download_tailscale() {
    log "Downloading ${TOOL_NAME}..."

    local ver dest
    ver=$(tailscale_latest_version)
    log_info "tailscale: version ${ver}"

    # linux: static tarballs
    local plat arch
    for plat in linux-arm64:arm64 linux-x86_64:amd64; do
        arch="${plat#*:}"; plat="${plat%%:*}"
        dest="${TOOLS_DIR}/${plat}/tailscale"
        version_gate "$dest" "$ver"
        download_and_extract "${PKGS}/tailscale_${ver}_${arch}.tgz" "$dest" "tailscale ${plat}" 1 \
            && version_stamp "$dest" "$ver"
    done

    # macos-arm64: the standalone (non-App-Store) universal .pkg
    dest="${TOOLS_DIR}/macos-arm64/tailscale"
    version_gate "$dest" "$ver"
    if download_file "${PKGS}/Tailscale-${ver}-macos.pkg" "${dest}/Tailscale-${ver}-macos.pkg" "tailscale macos-arm64"; then
        rm -f "${dest}/INSTALL.txt" 2>/dev/null; version_stamp "$dest" "$ver"
    fi

    # windows-x64: MSI (silent install: msiexec /i tailscale-setup-<v>-amd64.msi /quiet)
    dest="${TOOLS_DIR}/windows-x64/tailscale"
    version_gate "$dest" "$ver"
    if download_file "${PKGS}/tailscale-setup-${ver}-amd64.msi" "${dest}/tailscale-setup-${ver}-amd64.msi" "tailscale windows-x64"; then
        rm -f "${dest}/INSTALL.txt" 2>/dev/null; version_stamp "$dest" "$ver"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_tailscale
