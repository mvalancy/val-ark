#!/bin/bash
###############################################################################
# Val Ark - Download llama.cpp
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="llama-cpp"
PINNED_VERSION="b7818"

download_llama_cpp() {
    log "Downloading ${TOOL_NAME}..."
    local TAG=$(github_latest_tag "ggml-org/llama.cpp" "$PINNED_VERSION")

    # macOS arm64: prebuilt binary
    local MACOS_URL=$(github_asset_url "ggml-org/llama.cpp" "$TAG" "macos-arm64.zip")
    if [ -n "$MACOS_URL" ]; then
        download_and_extract "$MACOS_URL" "$TOOLS_DIR/macos-arm64/llama-cpp" "llama.cpp macOS arm64"
    else
        log_warn "No macOS arm64 asset found for llama.cpp ${TAG}"
    fi

    # Windows x64: prebuilt binary (not cuda)
    local WIN_URL=$(github_asset_url "ggml-org/llama.cpp" "$TAG" "win-x64.zip" | grep -v -i cuda | head -1)
    if [ -z "$WIN_URL" ]; then
        # Retry: get all win-x64.zip assets and filter out cuda
        WIN_URL=$(curl -sS -H "$(github_api_header)" \
            "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${TAG}" 2>/dev/null \
            | grep "browser_download_url" | grep -i "win-x64.zip" | grep -v -i cuda | head -1 \
            | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')
    fi
    if [ -n "$WIN_URL" ]; then
        download_and_extract "$WIN_URL" "$TOOLS_DIR/windows-x64/llama-cpp" "llama.cpp Windows x64"
    else
        log_warn "No Windows x64 asset found for llama.cpp ${TAG}"
    fi

    # Linux x86_64: prebuilt binary
    local LINUX_URL=$(github_asset_url "ggml-org/llama.cpp" "$TAG" "ubuntu-x64.zip")
    if [ -n "$LINUX_URL" ]; then
        download_and_extract "$LINUX_URL" "$TOOLS_DIR/linux-x86_64/llama-cpp" "llama.cpp Linux x86_64"
    else
        log_warn "No Linux x86_64 asset found for llama.cpp ${TAG}"
    fi

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
