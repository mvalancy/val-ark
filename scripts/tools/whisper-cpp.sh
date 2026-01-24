#!/bin/bash
###############################################################################
# Val Ark - Download whisper.cpp
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="whisper-cpp"
PINNED_VERSION="v1.8.3"

download_whisper_cpp() {
    log "Downloading ${TOOL_NAME}..."
    local TAG=$(github_latest_tag "ggml-org/whisper.cpp" "$PINNED_VERSION")
    local BASE_URL="https://github.com/ggml-org/whisper.cpp/releases/download/${TAG}"

    # Windows x64: prebuilt binary
    download_and_extract "${BASE_URL}/whisper-bin-x64.zip" \
        "$TOOLS_DIR/windows-x64/whisper-cpp" "whisper.cpp Windows x64"

    # All other platforms: clone source
    clone_repo "https://github.com/ggml-org/whisper.cpp.git" "$TAG" \
        "$TOOLS_DIR/macos-arm64/whisper-cpp" "whisper.cpp source (macos-arm64)"

    clone_repo "https://github.com/ggml-org/whisper.cpp.git" "$TAG" \
        "$TOOLS_DIR/linux-x86_64/whisper-cpp" "whisper.cpp source (linux-x86_64)"

    clone_repo "https://github.com/ggml-org/whisper.cpp.git" "$TAG" \
        "$TOOLS_DIR/linux-arm64/whisper-cpp" "whisper.cpp source (linux-arm64)"

    # Clone to sources dir
    clone_repo "https://github.com/ggml-org/whisper.cpp.git" "$TAG" \
        "$PROJECT_ROOT/sources/whisper.cpp" "whisper.cpp source"

    log_success "whisper.cpp download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_whisper_cpp
