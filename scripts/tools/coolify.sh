#!/bin/bash
# Val Ark - Download Coolify
source "$(dirname "$0")/_common.sh"

TOOL_NAME="coolify"
PINNED_VERSION="4.0.0"

download_coolify() {
    log "Downloading ${TOOL_NAME}..."

    local install_instructions="Coolify - Self-hosting Platform
==================================

Coolify is a Docker-based deployment platform (self-hosted alternative
to Heroku/Netlify/Vercel). It requires Docker and runs as a service.

Install (Linux, recommended):
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

Requirements:
  - Linux server (Ubuntu 22.04+ recommended)
  - Docker Engine
  - Minimum 2 CPU cores, 2GB RAM
  - Root/sudo access

After installation:
  - Access the dashboard at http://your-server-ip:8000
  - Follow the setup wizard to configure your instance

Manual install / development:
  git clone https://github.com/coollabsio/coolify.git
  cd coolify
  docker compose up -d

Documentation:
  https://coolify.io/docs

Note: Coolify is designed to run on a Linux server. For macOS/Windows
development, use Docker Desktop with the docker compose method above.
"

    local platforms="linux-arm64 linux-x86_64 macos-arm64 windows-x64"
    for platform in $platforms; do
        write_install_hint "${TOOLS_DIR}/${platform}/coolify" "coolify" "$install_instructions"
    done

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_coolify
