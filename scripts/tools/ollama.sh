#!/bin/bash
# Val Ark - Download Ollama
source "$(dirname "$0")/_common.sh"

TOOL_NAME="ollama"
PINNED_VERSION="v0.6.2"

download_ollama() {
    log "Downloading ${TOOL_NAME}..."

    local tag="${PINNED_VERSION}"
    local base_url="https://github.com/ollama/ollama/releases/download/${tag}"

    # linux-arm64: raw binary
    local dest="${TOOLS_DIR}/linux-arm64/ollama"
    ensure_dir "$dest"
    download_file "${base_url}/ollama-linux-arm64" "${dest}/ollama" "ollama linux-arm64"
    chmod +x "${dest}/ollama" 2>/dev/null

    # linux-x86_64: raw binary
    dest="${TOOLS_DIR}/linux-x86_64/ollama"
    ensure_dir "$dest"
    download_file "${base_url}/ollama-linux-amd64" "${dest}/ollama" "ollama linux-x86_64"
    chmod +x "${dest}/ollama" 2>/dev/null

    # macos-arm64: zip archive
    dest="${TOOLS_DIR}/macos-arm64/ollama"
    download_and_extract "${base_url}/Ollama-darwin.zip" "$dest" "ollama macos-arm64" 0

    # windows-x64: installer exe
    dest="${TOOLS_DIR}/windows-x64/ollama"
    ensure_dir "$dest"
    download_file "${base_url}/OllamaSetup.exe" "${dest}/OllamaSetup.exe" "ollama windows-x64"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_ollama
