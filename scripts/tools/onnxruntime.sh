#!/bin/bash
###############################################################################
# Val Ark - Download ONNX Runtime
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="onnxruntime"
PINNED_VERSION="v1.23.2"

download_onnxruntime() {
    log "Downloading ${TOOL_NAME}..."
    local TAG=$(github_latest_tag "microsoft/onnxruntime" "$PINNED_VERSION")
    local VER="${TAG#v}"  # Strip leading 'v' for filename pattern

    local BASE_URL="https://github.com/microsoft/onnxruntime/releases/download/${TAG}"

    # linux-arm64
    local LINUX_ARM64_URL="${BASE_URL}/onnxruntime-linux-aarch64-${VER}.tgz"
    download_and_extract "$LINUX_ARM64_URL" "$TOOLS_DIR/linux-arm64/onnxruntime" "ONNX Runtime linux-arm64"

    # linux-x86_64
    local LINUX_X64_URL="${BASE_URL}/onnxruntime-linux-x64-${VER}.tgz"
    download_and_extract "$LINUX_X64_URL" "$TOOLS_DIR/linux-x86_64/onnxruntime" "ONNX Runtime linux-x86_64"

    # macOS arm64
    local MACOS_URL="${BASE_URL}/onnxruntime-osx-arm64-${VER}.tgz"
    download_and_extract "$MACOS_URL" "$TOOLS_DIR/macos-arm64/onnxruntime" "ONNX Runtime macos-arm64"

    # Windows x64
    local WIN_URL="${BASE_URL}/onnxruntime-win-x64-${VER}.zip"
    download_and_extract "$WIN_URL" "$TOOLS_DIR/windows-x64/onnxruntime" "ONNX Runtime windows-x64"

    log_success "ONNX Runtime download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_onnxruntime
