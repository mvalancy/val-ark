#!/bin/bash
# Val Ark - Download Open WebUI
source "$(dirname "$0")/_common.sh"

TOOL_NAME="open-webui"
PINNED_VERSION="v0.5.4"

download_open_webui() {
    log "Downloading ${TOOL_NAME}..."

    # Open WebUI is a Python/Docker app - provide install instructions for all platforms
    local dest

    # linux-arm64 (Jetson)
    dest="${TOOLS_DIR}/linux-arm64/open-webui"
    ensure_dir "$dest"
    write_install_hint "$dest" "open-webui (linux-arm64)" "Open WebUI - linux-arm64 (Jetson)
=====================

Open WebUI provides a beautiful web interface for Ollama and other LLM backends.

Option 1 - pip install (recommended for Jetson):
  pip install open-webui
  open-webui serve --port 3000

Option 2 - Docker:
  docker run -d -p 3000:8080 \\
    --add-host=host.docker.internal:host-gateway \\
    -v open-webui:/app/backend/data \\
    --name open-webui \\
    ghcr.io/open-webui/open-webui:main

Make sure Ollama is running first:
  ollama serve

Then open http://localhost:3000 in your browser.

For more info: https://docs.openwebui.com/getting-started/
"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/open-webui"
    ensure_dir "$dest"
    write_install_hint "$dest" "open-webui (linux-x86_64)" "Open WebUI - linux-x86_64
=====================

Open WebUI provides a beautiful web interface for Ollama and other LLM backends.

Option 1 - pip install:
  pip install open-webui
  open-webui serve --port 3000

Option 2 - Docker (recommended):
  docker run -d -p 3000:8080 \\
    --add-host=host.docker.internal:host-gateway \\
    -v open-webui:/app/backend/data \\
    --name open-webui \\
    --gpus all \\
    ghcr.io/open-webui/open-webui:cuda

Make sure Ollama is running first:
  ollama serve

Then open http://localhost:3000 in your browser.

For more info: https://docs.openwebui.com/getting-started/
"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/open-webui"
    ensure_dir "$dest"
    write_install_hint "$dest" "open-webui (macos-arm64)" "Open WebUI - macOS ARM64
=====================

Open WebUI provides a beautiful web interface for Ollama and other LLM backends.

Option 1 - pip install:
  pip install open-webui
  open-webui serve --port 3000

Option 2 - Docker:
  docker run -d -p 3000:8080 \\
    --add-host=host.docker.internal:host-gateway \\
    -v open-webui:/app/backend/data \\
    --name open-webui \\
    ghcr.io/open-webui/open-webui:main

Make sure Ollama is running first:
  ollama serve

Then open http://localhost:3000 in your browser.

For more info: https://docs.openwebui.com/getting-started/
"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/open-webui"
    ensure_dir "$dest"
    write_install_hint "$dest" "open-webui (windows-x64)" "Open WebUI - Windows x64
=====================

Open WebUI provides a beautiful web interface for Ollama and other LLM backends.

Option 1 - pip install:
  pip install open-webui
  open-webui serve --port 3000

Option 2 - Docker Desktop:
  docker run -d -p 3000:8080 \\
    --add-host=host.docker.internal:host-gateway \\
    -v open-webui:/app/backend/data \\
    --name open-webui \\
    ghcr.io/open-webui/open-webui:main

Make sure Ollama is running first:
  ollama serve

Then open http://localhost:3000 in your browser.

For more info: https://docs.openwebui.com/getting-started/
"

    log_success "Open WebUI download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_open_webui
