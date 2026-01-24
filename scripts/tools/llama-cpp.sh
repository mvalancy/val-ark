#!/bin/bash
###############################################################################
# Val Ark - Download llama.cpp
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="llama-cpp"
PINNED_VERSION="b7824"

download_llama_cpp() {
    log "Downloading ${TOOL_NAME}..."
    local TAG=$(github_latest_tag "ggml-org/llama.cpp" "$PINNED_VERSION")
    local BASE_URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}"

    # macOS arm64: prebuilt binary
    download_and_extract "${BASE_URL}/llama-${TAG}-bin-macos-arm64.tar.gz" \
        "$TOOLS_DIR/macos-arm64/llama-cpp" "llama.cpp macOS arm64"

    # Windows x64: prebuilt CPU binary
    download_and_extract "${BASE_URL}/llama-${TAG}-bin-win-cpu-x64.zip" \
        "$TOOLS_DIR/windows-x64/llama-cpp" "llama.cpp Windows x64"

    # Linux x86_64: prebuilt binary
    download_and_extract "${BASE_URL}/llama-${TAG}-bin-ubuntu-x64.tar.gz" \
        "$TOOLS_DIR/linux-x86_64/llama-cpp" "llama.cpp Linux x86_64"

    # Linux arm64: clone source (build from source on Jetson)
    clone_repo "https://github.com/ggml-org/llama.cpp.git" "$TAG" \
        "$TOOLS_DIR/linux-arm64/llama-cpp" "llama.cpp source (linux-arm64)"

    # Clone source to sources dir for web-ui detection
    clone_repo "https://github.com/ggml-org/llama.cpp.git" "$TAG" \
        "$PROJECT_ROOT/sources/llama.cpp" "llama.cpp source"

    log_success "llama.cpp download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_llama_cpp
