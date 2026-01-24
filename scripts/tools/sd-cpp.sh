#!/bin/bash
###############################################################################
# Val Ark - Download stable-diffusion.cpp
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="sd-cpp"
PINNED_VERSION="master-484-fa61ea7"

download_sd_cpp() {
    log "Downloading ${TOOL_NAME}..."
    local TAG=$(github_latest_tag "leejet/stable-diffusion.cpp" "$PINNED_VERSION")

    # macOS arm64: asset matching "macos.*arm64"
    local MACOS_URL=$(github_asset_url "leejet/stable-diffusion.cpp" "$TAG" "macos.*arm64")
    if [ -n "$MACOS_URL" ]; then
        download_and_extract "$MACOS_URL" "$TOOLS_DIR/macos-arm64/sd-cpp" "sd.cpp macOS arm64"
    else
        log_warn "No macOS arm64 asset found for sd.cpp ${TAG}"
    fi

    # Windows x64: asset matching "win-avx2-x64" (not cuda)
    local WIN_URL=$(github_asset_url "leejet/stable-diffusion.cpp" "$TAG" "win-avx2-x64")
    if [ -n "$WIN_URL" ]; then
        download_and_extract "$WIN_URL" "$TOOLS_DIR/windows-x64/sd-cpp" "sd.cpp Windows x64"
    else
        log_warn "No Windows x64 asset found for sd.cpp ${TAG}"
    fi

    # Linux x86_64: asset matching "Linux.*x86_64" (not vulkan)
    local LINUX_URL
    LINUX_URL=$(curl -sS --connect-timeout 5 --max-time 10 -H "$(github_api_header)" \
        "https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/tags/${TAG}" 2>/dev/null \
        | grep "browser_download_url" | grep -i "Linux.*x86_64" | grep -v -i vulkan | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')
    if [ -n "$LINUX_URL" ]; then
        download_and_extract "$LINUX_URL" "$TOOLS_DIR/linux-x86_64/sd-cpp" "sd.cpp Linux x86_64"
    else
        log_warn "No Linux x86_64 asset found for sd.cpp ${TAG}"
    fi

    # Linux arm64: clone source (build from source)
    clone_repo "https://github.com/leejet/stable-diffusion.cpp.git" "$TAG" \
        "$TOOLS_DIR/linux-arm64/sd-cpp" "sd.cpp source (linux-arm64)"

    # Clone to sources dir
    clone_repo "https://github.com/leejet/stable-diffusion.cpp.git" "$TAG" \
        "$PROJECT_ROOT/sources/stable-diffusion.cpp" "stable-diffusion.cpp source"

    log_success "stable-diffusion.cpp download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_sd_cpp
