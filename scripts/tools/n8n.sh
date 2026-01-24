#!/bin/bash
# Val Ark - Download n8n
source "$(dirname "$0")/_common.sh"

TOOL_NAME="n8n"
PINNED_VERSION="latest"

download_n8n() {
    log "Downloading ${TOOL_NAME}..."

    local instructions="n8n - Workflow Automation Installation Instructions
====================================================

n8n is distributed as an npm package or Docker image.

Option 1 - npm (all platforms):
  npm install -g n8n
  n8n start

Option 2 - Docker:
  docker run -it --rm \\
    --name n8n \\
    -p 5678:5678 \\
    -v ~/.n8n:/home/node/.n8n \\
    docker.n8n.io/n8nio/n8n

Option 3 - npx (no install):
  npx n8n

Requirements:
  - Node.js 18+ (for npm install)
  - Or Docker (for container-based setup)

Access the UI at: http://localhost:5678

For more info: https://docs.n8n.io/hosting/installation/
"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/n8n"
    write_install_hint "$dest" "n8n (linux-arm64)" "$instructions"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/n8n"
    write_install_hint "$dest" "n8n (linux-x86_64)" "$instructions"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/n8n"
    write_install_hint "$dest" "n8n (macos-arm64)" "$instructions"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/n8n"
    write_install_hint "$dest" "n8n (windows-x64)" "$instructions"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_n8n
