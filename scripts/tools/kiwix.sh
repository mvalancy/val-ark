#!/bin/bash
# Val Ark - Download Kiwix Tools
source "$(dirname "$0")/_common.sh"

TOOL_NAME="kiwix"
PINNED_VERSION="3.7.0"

download_kiwix() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"
    local base_url="https://download.kiwix.org/release/kiwix-tools"

    # linux-arm64
    local url="${base_url}/kiwix-tools_linux-aarch64-${ver}.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/kiwix" "kiwix linux-arm64" 1

    # linux-x86_64
    url="${base_url}/kiwix-tools_linux-x86_64-${ver}.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/kiwix" "kiwix linux-x86_64" 1

    # macos-arm64
    url="${base_url}/kiwix-tools_macos-arm64-${ver}.tar.gz"
    download_and_extract "$url" "${TOOLS_DIR}/macos-arm64/kiwix" "kiwix macos-arm64" 1

    # windows-x64 (no win-x86_64 build for 3.7.0; provide win-i686 and install hint)
    url="${base_url}/kiwix-tools_win-i686-${ver}.zip"
    download_and_extract "$url" "${TOOLS_DIR}/windows-x64/kiwix" "kiwix windows-x64 (i686)" 0

    write_install_hint "${TOOLS_DIR}/windows-x64/kiwix" "kiwix" \
"Kiwix Tools for Windows
=========================

Note: The included build is 32-bit (i686) which runs on 64-bit Windows.
A native 64-bit Windows build is available starting from version 3.8.0.

If you need a native x86_64 build, download from:
  https://download.kiwix.org/release/kiwix-tools/

Included tools:
  - kiwix-serve    (serve ZIM files over HTTP)
  - kiwix-manage   (manage ZIM library)
  - kiwix-search   (full-text search in ZIM files)
"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_kiwix
