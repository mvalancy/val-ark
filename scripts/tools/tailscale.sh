#!/bin/bash
# Val Ark - Download Tailscale
source "$(dirname "$0")/_common.sh"

TOOL_NAME="tailscale"
PINNED_VERSION="1.92.5"
# Note: Tailscale stable channel only keeps the latest version.
# Update this to the current stable from https://pkgs.tailscale.com/stable/

download_tailscale() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"

    # linux-arm64
    local url="https://pkgs.tailscale.com/stable/tailscale_${ver}_arm64.tgz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-arm64/tailscale" "tailscale linux-arm64" 1

    # linux-x86_64
    url="https://pkgs.tailscale.com/stable/tailscale_${ver}_amd64.tgz"
    download_and_extract "$url" "${TOOLS_DIR}/linux-x86_64/tailscale" "tailscale linux-x86_64" 1

    # macos-arm64
    write_install_hint "${TOOLS_DIR}/macos-arm64/tailscale" "tailscale" \
"Tailscale for macOS
====================

Tailscale does not provide a standalone binary for macOS.

Install via one of these methods:

1. Mac App Store:
   Search for 'Tailscale' in the Mac App Store

2. Homebrew:
   brew install tailscale

3. Direct download:
   https://tailscale.com/download/mac
"

    # windows-x64
    write_install_hint "${TOOLS_DIR}/windows-x64/tailscale" "tailscale" \
"Tailscale for Windows
======================

Download the Windows installer from:
  https://tailscale.com/download/windows

Or use winget:
  winget install tailscale.tailscale
"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_tailscale
