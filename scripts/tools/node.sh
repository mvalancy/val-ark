#!/bin/bash
# Val Ark - Mirror the Node.js runtime (portable, LTS)
#
# Some community services need a modern Node that the host may not ship: NodeBB v4
# and current The Lounge require Node >=22, but many offline/ARM hosts run Node
# 18/20. Mirroring a portable Node 22 LTS into the tools tree lets Val Ark run
# those services with its OWN runtime, fully offline, regardless of system Node.
# The service scripts (scripts/services/forum.sh, chat.sh) prefer this build.
#
# This script ONLY mirrors binaries into the tools tree; it installs nothing
# system-wide and is idempotent.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="node"
PINNED_VERSION="v22.22.3"   # Node 22 LTS ("Jod"); fallback if the dist index is unreachable

# Resolve the newest v22 LTS from nodejs.org, falling back to the pin.
resolve_node_lts() {
    local v
    v=$(curl -fsSL --max-time 20 https://nodejs.org/dist/index.json 2>/dev/null \
        | grep -oE '"version":"v22\.[0-9]+\.[0-9]+"' | head -1 | sed 's/.*"v/v/; s/"$//')
    [ -n "$v" ] && echo "$v" || echo "$PINNED_VERSION"
}

download_node() {
    log "Downloading ${TOOL_NAME} (portable Node.js LTS runtime)..."
    local ver; ver="$(resolve_node_lts)"
    local base="https://nodejs.org/dist/${ver}"

    # linux-arm64 (Jetson Orin/Thor, GB10, ARM servers)
    download_and_extract "${base}/node-${ver}-linux-arm64.tar.xz" \
        "${TOOLS_DIR}/linux-arm64/node" "node ${ver} linux-arm64" 1

    # linux-x86_64
    download_and_extract "${base}/node-${ver}-linux-x64.tar.xz" \
        "${TOOLS_DIR}/linux-x86_64/node" "node ${ver} linux-x86_64" 1

    # macos-arm64 (Apple Silicon)
    download_and_extract "${base}/node-${ver}-darwin-arm64.tar.xz" \
        "${TOOLS_DIR}/macos-arm64/node" "node ${ver} macos-arm64" 1

    # windows-x64 ships a .zip; mirror it as an archive for offline install.
    download_and_extract "${base}/node-${ver}-win-x64.zip" \
        "${TOOLS_DIR}/windows-x64/node" "node ${ver} windows-x64" 1

    log_success "${TOOL_NAME} download complete (${ver})."
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_node
