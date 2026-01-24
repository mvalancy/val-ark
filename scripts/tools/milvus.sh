#!/bin/bash
# Val Ark - Download Milvus
source "$(dirname "$0")/_common.sh"

TOOL_NAME="milvus"
PINNED_VERSION="2.5.6"

download_milvus() {
    log "Downloading ${TOOL_NAME}..."

    local install_instructions="Milvus Vector Database
========================

Milvus is a Docker/Python-based vector database. There is no standalone
binary distribution.

Option 1 - Docker Compose (recommended for development):
  wget https://github.com/milvus-io/milvus/releases/download/v${PINNED_VERSION}/milvus-standalone-docker-compose.yml -O docker-compose.yml
  docker compose up -d

Option 2 - Docker standalone:
  docker run -d --name milvus \\
    -p 19530:19530 \\
    -p 9091:9091 \\
    -v milvus_data:/var/lib/milvus \\
    milvusdb/milvus:v${PINNED_VERSION} \\
    milvus run standalone

Option 3 - Python SDK (client only):
  pip install pymilvus

  Usage:
    from pymilvus import connections, Collection
    connections.connect(host='localhost', port='19530')

Option 4 - Milvus Lite (embedded, for testing):
  pip install milvus-lite

  Usage:
    from milvus import default_server
    default_server.start()

Documentation:
  https://milvus.io/docs
"

    local platforms="linux-arm64 linux-x86_64 macos-arm64 windows-x64"
    for platform in $platforms; do
        write_install_hint "${TOOLS_DIR}/${platform}/milvus" "milvus" "$install_instructions"
    done

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_milvus
