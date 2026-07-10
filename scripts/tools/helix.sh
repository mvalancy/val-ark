#!/bin/bash
# Val Ark - Download Helix
source "$(dirname "$0")/_common.sh"

TOOL_NAME="helix"
PINNED_VERSION="25.07.1"

download_helix() {
    log "Downloading ${TOOL_NAME}..."

    local repo="helix-editor/helix"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/helix"
    local url
    url=$(github_asset_url "$repo" "$tag" "aarch64-linux.*tar.xz")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        download_and_extract "$url" "$dest" "helix linux-arm64" 1 \
            && version_stamp "$dest" "$tag"
    else
        log_error "Could not find helix aarch64-linux asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/helix"
    url=$(github_asset_url "$repo" "$tag" "x86_64-linux.*tar.xz")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        download_and_extract "$url" "$dest" "helix linux-x86_64" 1 \
            && version_stamp "$dest" "$tag"
    else
        log_error "Could not find helix x86_64-linux asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/helix"
    url=$(github_asset_url "$repo" "$tag" "aarch64-macos.*tar.xz")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        download_and_extract "$url" "$dest" "helix macos-arm64" 1 \
            && version_stamp "$dest" "$tag"
    else
        log_error "Could not find helix aarch64-macos asset"
    fi

    # windows-x64 (zip: unzip ignores --strip-components, so it lands nested)
    dest="${TOOLS_DIR}/windows-x64/helix"
    url=$(github_asset_url "$repo" "$tag" "x86_64-windows.*zip")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        if download_and_extract "$url" "$dest" "helix windows-x64" 0; then
            # Flatten helix-<ver>-x86_64-windows/ so hx.exe sits at the dest
            # root like the other platforms (same fix as scripts/tools/node.sh).
            local wnest="${dest}/helix-${tag}-x86_64-windows"
            if [ -d "$wnest" ] && [ ! -f "${dest}/hx.exe" ]; then
                mv "$wnest"/* "${dest}/" 2>/dev/null && rmdir "$wnest" 2>/dev/null
            fi
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find helix x86_64-windows asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_helix
