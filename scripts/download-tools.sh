#!/bin/bash
###############################################################################
# Val Ark - Tool Binary Downloader
# Downloads inference engines & utilities for:
#   macOS arm64, Windows x64, Linux arm64 (Jetson), Linux x86_64 (Ubuntu)
#
# Tools: llama.cpp, whisper.cpp, Piper TTS, stable-diffusion.cpp,
#        ONNX Runtime, FFmpeg, Vosk
#
# Features:
# - Downloads prebuilt binaries where available
# - Clones source for platforms requiring build-from-source
# - Generates build scripts: Jetson CUDA, macOS Metal, Linux x86_64
# - Dynamic GitHub release tag resolution with pinned fallbacks
# - Resume-capable, retry logic, never aborts
###############################################################################

set -o pipefail

# Configuration
TOOLS_ROOT="/home/uat-admin/models/tools"
LOG_DIR="${TOOLS_ROOT}/logs"
LOG_FILE="${LOG_DIR}/tools_download_$(date +%Y%m%d_%H%M%S).log"
MAX_RETRIES=5
RETRY_DELAY=15
SCRIPT_START=$(date +%s)

# Optional GitHub token for higher API rate limits (60/hr without, 5000/hr with)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Pinned known-good versions (fallback if API fails)
PIN_LLAMA="b7818"
PIN_WHISPER="v1.8.3"
PIN_PIPER="2023.11.14-2"
PIN_SD="master-484-fa61ea7"
PIN_ONNX="v1.23.2"
PIN_VOSK="v0.3.45"

# Counters
DOWNLOAD_SUCCESS=0
DOWNLOAD_FAILED=0
DOWNLOAD_SKIPPED=0
DOWNLOAD_TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

###############################################################################
# Helper Functions
###############################################################################

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

log_success() { log "${GREEN}SUCCESS${NC}: $*"; }
log_error() { log "${RED}ERROR${NC}: $*"; }
log_info() { log "${BLUE}INFO${NC}: $*"; }
log_warn() { log "${YELLOW}WARN${NC}: $*"; }

elapsed_since() {
    local start=$1
    local now=$(date +%s)
    local diff=$((now - start))
    local hours=$((diff / 3600))
    local mins=$(( (diff % 3600) / 60 ))
    local secs=$((diff % 60))
    if [ $hours -gt 0 ]; then
        echo "${hours}h ${mins}m ${secs}s"
    elif [ $mins -gt 0 ]; then
        echo "${mins}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

ensure_dir() {
    mkdir -p "$1" 2>/dev/null || true
}

print_progress() {
    local pct=0
    if [ $DOWNLOAD_TOTAL -gt 0 ]; then
        pct=$(( (DOWNLOAD_SUCCESS + DOWNLOAD_FAILED + DOWNLOAD_SKIPPED) * 100 / DOWNLOAD_TOTAL ))
    fi
    log_info "Progress: ${pct}% | Success: ${DOWNLOAD_SUCCESS} | Failed: ${DOWNLOAD_FAILED} | Skipped: ${DOWNLOAD_SKIPPED} | Elapsed: $(elapsed_since $SCRIPT_START)"
}

###############################################################################
# GitHub API Helpers
###############################################################################

github_api_header() {
    if [ -n "$GITHUB_TOKEN" ]; then
        echo "Authorization: token ${GITHUB_TOKEN}"
    else
        echo "X-No-Auth: true"
    fi
}

# Resolve latest release tag for a GitHub repo
# Usage: github_latest_tag "ggml-org/llama.cpp"
github_latest_tag() {
    local repo="$1"
    local fallback="$2"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"

    local tag
    tag=$(curl -sS -H "$(github_api_header)" "$api_url" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$tag" ]; then
        # Output log to stderr so $() only captures the tag
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC}: Could not resolve latest for ${repo}, using: ${fallback}" >&2
        echo "$fallback"
    else
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}INFO${NC}: Resolved ${repo} -> ${tag}" >&2
        echo "$tag"
    fi
}

# Find asset download URL matching a pattern in a release
# Usage: github_asset_url "repo" "tag" "pattern"
github_asset_url() {
    local repo="$1"
    local tag="$2"
    local pattern="$3"
    local api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"

    local url
    url=$(curl -sS -H "$(github_api_header)" "$api_url" 2>/dev/null \
        | grep "browser_download_url" | grep -i "$pattern" | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

    echo "$url"
}

###############################################################################
# Download Helpers
###############################################################################

# Download a file with retries (never aborts script)
download_file() {
    local url="$1"
    local dest_path="$2"
    local label="${3:-$(basename "$dest_path")}"
    local attempt=1
    local dl_start=$(date +%s)

    ensure_dir "$(dirname "$dest_path")"

    if [ -f "$dest_path" ] && [ -s "$dest_path" ]; then
        log_info "Already exists: ${label} ($(du -h "$dest_path" 2>/dev/null | cut -f1)) - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        return 0
    fi

    [ -f "$dest_path" ] && [ ! -s "$dest_path" ] && rm -f "$dest_path" 2>/dev/null

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading ${label} (attempt ${attempt}/${MAX_RETRIES})"

        local wget_output
        wget_output=$(wget -c --progress=dot:mega --timeout=60 --tries=1 \
            "$url" -O "$dest_path" 2>&1)
        local status=$?

        echo "$wget_output" | tail -5 >> "$LOG_FILE" 2>/dev/null || true

        if [ $status -eq 0 ] && [ -f "$dest_path" ] && [ -s "$dest_path" ]; then
            local size=$(du -h "$dest_path" 2>/dev/null | cut -f1)
            log_success "Downloaded: ${label} (${size}) in $(elapsed_since $dl_start)"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            print_progress
            return 0
        else
            if echo "$wget_output" | grep -qi "404\|not found"; then
                log_error "HTTP 404: ${label}"
                break
            fi
            if echo "$wget_output" | grep -qi "401\|403"; then
                log_error "HTTP 401/403: ${label}"
                break
            fi
            attempt=$((attempt + 1))
            if [ $attempt -le $MAX_RETRIES ]; then
                local delay=$((RETRY_DELAY * attempt))
                log_info "Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done

    log_error "FAILED: ${label}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${label} -- ${url}" >> "${LOG_DIR}/failed_tool_downloads.txt"
    DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    print_progress
    return 0
}

# Download and extract an archive
download_and_extract() {
    local url="$1"
    local dest_dir="$2"
    local label="${3:-$(basename "$url")}"
    local strip="${4:-0}"

    ensure_dir "$dest_dir"

    # Check if already extracted (has files in dest_dir)
    local existing=$(find "$dest_dir" -type f 2>/dev/null | head -3 | wc -l)
    if [ "$existing" -gt 1 ]; then
        local existing_size=$(du -sh "$dest_dir" 2>/dev/null | cut -f1)
        log_info "Already extracted: ${label} (${existing_size}) - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        return 0
    fi

    local archive_name=$(basename "$url")
    local tmp_file="${dest_dir}/.tmp_${archive_name}"

    download_file "$url" "$tmp_file" "$label"

    if [ ! -f "$tmp_file" ] || [ ! -s "$tmp_file" ]; then
        return 0
    fi

    log_info "Extracting: ${label}"

    local extract_status=0
    case "$archive_name" in
        *.tar.gz|*.tgz)
            if [ "$strip" -gt 0 ]; then
                tar -xzf "$tmp_file" -C "$dest_dir" --strip-components="$strip" 2>>"$LOG_FILE" || extract_status=$?
            else
                tar -xzf "$tmp_file" -C "$dest_dir" 2>>"$LOG_FILE" || extract_status=$?
            fi
            ;;
        *.tar.xz)
            if [ "$strip" -gt 0 ]; then
                tar -xJf "$tmp_file" -C "$dest_dir" --strip-components="$strip" 2>>"$LOG_FILE" || extract_status=$?
            else
                tar -xJf "$tmp_file" -C "$dest_dir" 2>>"$LOG_FILE" || extract_status=$?
            fi
            ;;
        *.zip)
            unzip -o -q "$tmp_file" -d "$dest_dir" 2>>"$LOG_FILE" || extract_status=$?
            ;;
        *)
            log_error "Unknown archive type: ${archive_name}"
            extract_status=1
            ;;
    esac

    if [ $extract_status -ne 0 ]; then
        log_error "Extraction failed for ${label}"
    else
        log_success "Extracted: ${label} to ${dest_dir}"
    fi

    rm -f "$tmp_file" 2>/dev/null || true
    return 0
}

# Shallow clone a git repo at a specific tag
clone_repo() {
    local repo_url="$1"
    local tag="$2"
    local dest_dir="$3"
    local label="${4:-$(basename "$repo_url" .git)}"
    local dl_start=$(date +%s)

    if [ -d "$dest_dir/.git" ]; then
        log_info "Source already cloned: ${label} - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        return 0
    fi

    ensure_dir "$(dirname "$dest_dir")"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Cloning ${label} @ ${tag} (attempt ${attempt}/${MAX_RETRIES})"

        if git clone --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules \
            "$repo_url" "$dest_dir" 2>>"$LOG_FILE"; then
            local size=$(du -sh "$dest_dir" 2>/dev/null | cut -f1)
            log_success "Cloned: ${label} @ ${tag} (${size}) in $(elapsed_since $dl_start)"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            print_progress
            return 0
        fi

        rm -rf "$dest_dir" 2>/dev/null || true
        attempt=$((attempt + 1))
        if [ $attempt -le $MAX_RETRIES ]; then
            sleep $((RETRY_DELAY * attempt))
        fi
    done

    log_error "FAILED clone: ${label}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CLONE: ${label} @ ${tag}" >> "${LOG_DIR}/failed_tool_downloads.txt"
    DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    print_progress
    return 0
}

###############################################################################
# Tool Downloads
###############################################################################

download_llama_cpp() {
    log "============================================================"
    log "TOOL: llama.cpp (LLM/VLM inference engine)"
    log "============================================================"

    local LLAMA_DIR="${TOOLS_ROOT}/llama.cpp"
    local TAG=$(github_latest_tag "ggml-org/llama.cpp" "$PIN_LLAMA")

    # macOS arm64 - prebuilt binary
    local mac_url="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-bin-macos-arm64.tar.gz"
    download_and_extract "$mac_url" "${LLAMA_DIR}/macos-arm64" "llama.cpp macOS arm64 (${TAG})" 1

    # Windows x64 CPU - prebuilt binary
    local win_url="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-bin-win-cpu-x64.zip"
    download_and_extract "$win_url" "${LLAMA_DIR}/windows-x64" "llama.cpp Windows x64 CPU (${TAG})"

    # Windows x64 CUDA - prebuilt binary
    local win_cuda_url=$(github_asset_url "ggml-org/llama.cpp" "$TAG" "win-cuda.*x64.zip")
    if [ -n "$win_cuda_url" ]; then
        download_and_extract "$win_cuda_url" "${LLAMA_DIR}/windows-x64-cuda" "llama.cpp Windows x64 CUDA (${TAG})"
    else
        log_warn "Could not find CUDA Windows binary for llama.cpp ${TAG}"
    fi

    # Linux x86_64 - prebuilt binary
    local linux_url="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-bin-ubuntu-x64.tar.gz"
    download_and_extract "$linux_url" "${LLAMA_DIR}/linux-x86_64" "llama.cpp Linux x86_64 (${TAG})" 1

    # Linux arm64 - clone source for building (no prebuilt for Jetson/CUDA)
    clone_repo "https://github.com/ggml-org/llama.cpp.git" "$TAG" \
        "${LLAMA_DIR}/source" "llama.cpp source"
}

download_whisper_cpp() {
    log "============================================================"
    log "TOOL: whisper.cpp (Speech-to-Text engine)"
    log "============================================================"

    local WHISPER_DIR="${TOOLS_ROOT}/whisper.cpp"
    local TAG=$(github_latest_tag "ggml-org/whisper.cpp" "$PIN_WHISPER")

    # Windows x64 - prebuilt binary
    local win_url="https://github.com/ggml-org/whisper.cpp/releases/download/${TAG}/whisper-bin-x64.zip"
    download_and_extract "$win_url" "${WHISPER_DIR}/windows-x64" "whisper.cpp Windows x64 (${TAG})"

    # Windows x64 CUDA variant
    local win_cuda_url=$(github_asset_url "ggml-org/whisper.cpp" "$TAG" "cublas-12.*bin-x64.zip")
    if [ -z "$win_cuda_url" ]; then
        win_cuda_url=$(github_asset_url "ggml-org/whisper.cpp" "$TAG" "cublas.*bin-x64.zip")
    fi
    if [ -n "$win_cuda_url" ]; then
        download_and_extract "$win_cuda_url" "${WHISPER_DIR}/windows-x64-cuda" "whisper.cpp Windows CUDA (${TAG})"
    fi

    # macOS + Linux arm64 + Linux x86_64 - clone source (no prebuilt CLI binaries)
    clone_repo "https://github.com/ggml-org/whisper.cpp.git" "$TAG" \
        "${WHISPER_DIR}/source" "whisper.cpp source"
}

download_piper() {
    log "============================================================"
    log "TOOL: Piper TTS (Fast text-to-speech)"
    log "============================================================"

    local PIPER_DIR="${TOOLS_ROOT}/piper"
    local TAG=$(github_latest_tag "rhasspy/piper" "$PIN_PIPER")

    # Linux arm64
    local linux_url="https://github.com/rhasspy/piper/releases/download/${TAG}/piper_linux_aarch64.tar.gz"
    download_and_extract "$linux_url" "${PIPER_DIR}/linux-arm64" "Piper Linux arm64 (${TAG})"

    # Linux x86_64
    local linux_x64_url="https://github.com/rhasspy/piper/releases/download/${TAG}/piper_linux_x86_64.tar.gz"
    download_and_extract "$linux_x64_url" "${PIPER_DIR}/linux-x86_64" "Piper Linux x86_64 (${TAG})"

    # macOS arm64
    local mac_url="https://github.com/rhasspy/piper/releases/download/${TAG}/piper_macos_aarch64.tar.gz"
    download_and_extract "$mac_url" "${PIPER_DIR}/macos-arm64" "Piper macOS arm64 (${TAG})"

    # Windows x64
    local win_url="https://github.com/rhasspy/piper/releases/download/${TAG}/piper_windows_amd64.zip"
    download_and_extract "$win_url" "${PIPER_DIR}/windows-x64" "Piper Windows x64 (${TAG})"
}

download_stable_diffusion_cpp() {
    log "============================================================"
    log "TOOL: stable-diffusion.cpp (Image generation)"
    log "============================================================"

    local SD_DIR="${TOOLS_ROOT}/stable-diffusion.cpp"
    local TAG=$(github_latest_tag "leejet/stable-diffusion.cpp" "$PIN_SD")

    # macOS arm64 - find asset dynamically (name includes OS version)
    local mac_url=$(github_asset_url "leejet/stable-diffusion.cpp" "$TAG" "Darwin.*arm64.zip")
    if [ -n "$mac_url" ]; then
        download_and_extract "$mac_url" "${SD_DIR}/macos-arm64" "sd.cpp macOS arm64 (${TAG})"
    else
        log_warn "Could not find macOS arm64 binary for stable-diffusion.cpp ${TAG}"
    fi

    # Windows x64 AVX2
    local win_url=$(github_asset_url "leejet/stable-diffusion.cpp" "$TAG" "win-avx2-x64.zip")
    if [ -n "$win_url" ]; then
        download_and_extract "$win_url" "${SD_DIR}/windows-x64" "sd.cpp Windows x64 AVX2 (${TAG})"
    fi

    # Windows CUDA variant
    local win_cuda_url=$(github_asset_url "leejet/stable-diffusion.cpp" "$TAG" "win-cuda.*x64.zip")
    if [ -n "$win_cuda_url" ]; then
        download_and_extract "$win_cuda_url" "${SD_DIR}/windows-x64-cuda" "sd.cpp Windows CUDA (${TAG})"
    fi

    # Linux x86_64 - prebuilt binary (name includes Ubuntu version)
    local linux_url=$(github_asset_url "leejet/stable-diffusion.cpp" "$TAG" "bin-Linux-Ubuntu.*x86_64.zip")
    if [ -n "$linux_url" ]; then
        download_and_extract "$linux_url" "${SD_DIR}/linux-x86_64" "sd.cpp Linux x86_64 (${TAG})"
    else
        log_warn "Could not find Linux x86_64 binary for stable-diffusion.cpp ${TAG}"
    fi

    # Linux arm64 - clone source for building (no prebuilt for arm64)
    clone_repo "https://github.com/leejet/stable-diffusion.cpp.git" "$TAG" \
        "${SD_DIR}/source" "stable-diffusion.cpp source"
}

download_onnxruntime() {
    log "============================================================"
    log "TOOL: ONNX Runtime (Kokoro TTS, Moonshine ASR)"
    log "============================================================"

    local ONNX_DIR="${TOOLS_ROOT}/onnxruntime"
    local TAG=$(github_latest_tag "microsoft/onnxruntime" "$PIN_ONNX")
    local VER="${TAG#v}"  # Strip leading 'v'

    # Linux arm64
    local linux_url="https://github.com/microsoft/onnxruntime/releases/download/${TAG}/onnxruntime-linux-aarch64-${VER}.tgz"
    download_and_extract "$linux_url" "${ONNX_DIR}/linux-arm64" "ONNX Runtime Linux arm64 (${VER})"

    # Linux x86_64
    local linux_x64_url="https://github.com/microsoft/onnxruntime/releases/download/${TAG}/onnxruntime-linux-x64-${VER}.tgz"
    download_and_extract "$linux_x64_url" "${ONNX_DIR}/linux-x86_64" "ONNX Runtime Linux x86_64 (${VER})"

    # macOS arm64
    local mac_url="https://github.com/microsoft/onnxruntime/releases/download/${TAG}/onnxruntime-osx-arm64-${VER}.tgz"
    download_and_extract "$mac_url" "${ONNX_DIR}/macos-arm64" "ONNX Runtime macOS arm64 (${VER})"

    # Windows x64
    local win_url="https://github.com/microsoft/onnxruntime/releases/download/${TAG}/onnxruntime-win-x64-${VER}.zip"
    download_and_extract "$win_url" "${ONNX_DIR}/windows-x64" "ONNX Runtime Windows x64 (${VER})"
}

download_ffmpeg() {
    log "============================================================"
    log "TOOL: FFmpeg (Audio/Video processing)"
    log "============================================================"

    local FF_DIR="${TOOLS_ROOT}/ffmpeg"

    # Linux arm64 - BtbN static builds (rolling 'latest' tag, stable URL)
    local linux_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
    download_and_extract "$linux_url" "${FF_DIR}/linux-arm64" "FFmpeg Linux arm64" 1

    # Linux x86_64 - BtbN static builds
    local linux_x64_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
    download_and_extract "$linux_x64_url" "${FF_DIR}/linux-x86_64" "FFmpeg Linux x86_64" 1

    # Windows x64 - BtbN static builds
    local win_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    download_and_extract "$win_url" "${FF_DIR}/windows-x64" "FFmpeg Windows x64"

    # macOS arm64 - evermeet.cx static builds
    local mac_dir="${FF_DIR}/macos-arm64"
    ensure_dir "$mac_dir"

    # Try to get latest version from evermeet
    local mac_ffmpeg_url="https://evermeet.cx/ffmpeg/ffmpeg-7.1.1.zip"
    local mac_ffprobe_url="https://evermeet.cx/ffmpeg/ffprobe-7.1.1.zip"
    download_and_extract "$mac_ffmpeg_url" "$mac_dir" "FFmpeg macOS arm64"
    download_and_extract "$mac_ffprobe_url" "$mac_dir" "FFprobe macOS arm64"
}

download_vosk() {
    log "============================================================"
    log "TOOL: Vosk (Lightweight offline ASR)"
    log "============================================================"

    local VOSK_DIR="${TOOLS_ROOT}/vosk"
    # Pin to 0.3.45: latest release (v0.3.50) has no binary assets
    local TAG="v${PIN_VOSK#v}"
    local VER="${TAG#v}"
    log_info "Vosk version: ${VER} (pinned - latest has no binaries)"

    # Linux arm64
    local linux_url="https://github.com/alphacep/vosk-api/releases/download/${TAG}/vosk-linux-aarch64-${VER}.zip"
    download_and_extract "$linux_url" "${VOSK_DIR}/linux-arm64" "Vosk Linux arm64 (${VER})"

    # Linux x86_64
    local linux_x64_url="https://github.com/alphacep/vosk-api/releases/download/${TAG}/vosk-linux-x86_64-${VER}.zip"
    download_and_extract "$linux_x64_url" "${VOSK_DIR}/linux-x86_64" "Vosk Linux x86_64 (${VER})"

    # Windows x64
    local win_url="https://github.com/alphacep/vosk-api/releases/download/${TAG}/vosk-win64-${VER}.zip"
    download_and_extract "$win_url" "${VOSK_DIR}/windows-x64" "Vosk Windows x64 (${VER})"

    # macOS - no prebuilt binary available
    local mac_dir="${VOSK_DIR}/macos-arm64"
    ensure_dir "$mac_dir"
    if [ ! -f "${mac_dir}/INSTALL.txt" ]; then
        cat > "${mac_dir}/INSTALL.txt" << 'VOSK_EOF'
Vosk for macOS - Installation via pip
======================================

No prebuilt native binary is available for macOS.
Install via Python:

    pip install vosk

Then use the Vosk models in ./models/stt/vosk/
VOSK_EOF
        log_info "Created Vosk macOS install instructions"
    fi
}

download_bitnet() {
    log "============================================================"
    log "TOOL: BitNet.cpp (1-bit LLM inference)"
    log "============================================================"

    local BITNET_DIR="${TOOLS_ROOT}/bitnet"

    # BitNet is source-only (no prebuilt releases) - clone the repo
    clone_repo "https://github.com/microsoft/BitNet.git" "main" \
        "${BITNET_DIR}/source" "BitNet.cpp source"

    # Also clone into the project sources directory for web-ui detection
    local PROJECT_SOURCES="$(dirname "$(dirname "$(realpath "$0")")")/sources"
    if [ -d "$PROJECT_SOURCES" ]; then
        clone_repo "https://github.com/microsoft/BitNet.git" "main" \
            "${PROJECT_SOURCES}/BitNet" "BitNet source (project)"
    fi
}

###############################################################################
# Build Script Generators
###############################################################################

generate_build_scripts() {
    log "============================================================"
    log "Generating build-from-source scripts"
    log "============================================================"

    # --- Jetson CUDA build script ---
    cat > "${TOOLS_ROOT}/build-from-source.sh" << 'BUILD_EOF'
#!/bin/bash
###############################################################################
# Build native CUDA binaries on NVIDIA Jetson
# Prerequisites: cmake, CUDA toolkit, git
# Run this AFTER download-all-tools.sh has cloned the source repos
###############################################################################

set -e

TOOLS_ROOT="/home/uat-admin/models/tools"
CUDA_ARCH="87"  # Jetson Orin = SM 8.7 (Ampere)
NPROC=$(nproc)

echo "Building with CUDA arch SM ${CUDA_ARCH} using ${NPROC} threads..."
echo ""

build_llama_cpp() {
    echo "=== Building llama.cpp ==="
    local SRC="${TOOLS_ROOT}/llama.cpp/source"
    local DEST="${TOOLS_ROOT}/llama.cpp/linux-arm64"

    if [ ! -d "$SRC" ]; then
        echo "ERROR: Source not found at $SRC. Run download-all-tools.sh first."
        return 1
    fi

    mkdir -p "$DEST"
    cd "$SRC"
    rm -rf build 2>/dev/null || true

    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_CURL=OFF

    cmake --build build -j${NPROC}

    # Install key binaries
    cp build/bin/llama-server "$DEST/" 2>/dev/null || true
    cp build/bin/llama-cli "$DEST/" 2>/dev/null || true
    cp build/bin/llama-llava-cli "$DEST/" 2>/dev/null || true
    cp build/bin/llama-quantize "$DEST/" 2>/dev/null || true
    cp build/bin/llama-bench "$DEST/" 2>/dev/null || true

    echo "llama.cpp binaries installed to: $DEST"
    ls -la "$DEST/"
    echo ""
}

build_whisper_cpp() {
    echo "=== Building whisper.cpp ==="
    local SRC="${TOOLS_ROOT}/whisper.cpp/source"
    local DEST="${TOOLS_ROOT}/whisper.cpp/linux-arm64"

    if [ ! -d "$SRC" ]; then
        echo "ERROR: Source not found at $SRC. Run download-all-tools.sh first."
        return 1
    fi

    mkdir -p "$DEST"
    cd "$SRC"
    rm -rf build 2>/dev/null || true

    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_BUILD_TYPE=Release

    cmake --build build -j${NPROC}

    # Install key binaries
    cp build/bin/whisper-cli "$DEST/" 2>/dev/null || true
    cp build/bin/whisper-server "$DEST/" 2>/dev/null || true

    echo "whisper.cpp binaries installed to: $DEST"
    ls -la "$DEST/"
    echo ""
}

build_stable_diffusion_cpp() {
    echo "=== Building stable-diffusion.cpp ==="
    local SRC="${TOOLS_ROOT}/stable-diffusion.cpp/source"
    local DEST="${TOOLS_ROOT}/stable-diffusion.cpp/linux-arm64"

    if [ ! -d "$SRC" ]; then
        echo "ERROR: Source not found at $SRC. Run download-all-tools.sh first."
        return 1
    fi

    mkdir -p "$DEST"
    cd "$SRC"
    rm -rf build 2>/dev/null || true

    cmake -B build \
        -DSD_CUBLAS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_BUILD_TYPE=Release

    cmake --build build -j${NPROC}

    cp build/bin/sd-cli "$DEST/" 2>/dev/null || true
    cp build/bin/sd-server "$DEST/" 2>/dev/null || true
    cp build/bin/sd "$DEST/" 2>/dev/null || true

    echo "stable-diffusion.cpp binaries installed to: $DEST"
    ls -la "$DEST/"
    echo ""
}

echo "================================================================"
echo "  NVIDIA Jetson - CUDA Build Script"
echo "  Building: llama.cpp, whisper.cpp, stable-diffusion.cpp"
echo "================================================================"
echo ""

build_llama_cpp
build_whisper_cpp
build_stable_diffusion_cpp

echo ""
echo "================================================================"
echo "  All builds complete!"
echo "================================================================"
BUILD_EOF

    chmod +x "${TOOLS_ROOT}/build-from-source.sh"
    log_success "Generated: build-from-source.sh (Jetson CUDA)"

    # --- macOS Metal build script ---
    cat > "${TOOLS_ROOT}/build-macos.sh" << 'MACOS_EOF'
#!/bin/bash
###############################################################################
# Build native Metal-accelerated binaries on macOS (Apple Silicon)
# Prerequisites: Xcode command line tools, cmake
# Run this AFTER download-all-tools.sh has cloned the source repos
###############################################################################

set -e

TOOLS_ROOT="$(cd "$(dirname "$0")" && pwd)"
NPROC=$(sysctl -n hw.ncpu)

echo "Building with Metal acceleration using ${NPROC} threads..."
echo ""

build_whisper_cpp() {
    echo "=== Building whisper.cpp (Metal) ==="
    local SRC="${TOOLS_ROOT}/whisper.cpp/source"
    local DEST="${TOOLS_ROOT}/whisper.cpp/macos-arm64"

    if [ ! -d "$SRC" ]; then
        echo "ERROR: Source not found at $SRC. Run download-all-tools.sh first."
        return 1
    fi

    mkdir -p "$DEST"
    cd "$SRC"
    rm -rf build 2>/dev/null || true

    cmake -B build \
        -DGGML_METAL=ON \
        -DCMAKE_BUILD_TYPE=Release

    cmake --build build -j${NPROC}

    cp build/bin/whisper-cli "$DEST/" 2>/dev/null || true
    cp build/bin/whisper-server "$DEST/" 2>/dev/null || true

    echo "whisper.cpp binaries installed to: $DEST"
    ls -la "$DEST/"
    echo ""
}

echo "================================================================"
echo "  macOS Apple Silicon - Metal Build Script"
echo "  Building: whisper.cpp"
echo "================================================================"
echo ""
echo "NOTE: llama.cpp and stable-diffusion.cpp have prebuilt macOS"
echo "      binaries already downloaded. Only whisper.cpp needs building."
echo ""

build_whisper_cpp

echo ""
echo "================================================================"
echo "  Build complete!"
echo "================================================================"
MACOS_EOF

    chmod +x "${TOOLS_ROOT}/build-macos.sh"
    log_success "Generated: build-macos.sh (macOS Metal)"

    # --- Linux x86_64 build script ---
    cat > "${TOOLS_ROOT}/build-linux-x86_64.sh" << 'X86_EOF'
#!/bin/bash
###############################################################################
# Build native binaries on Linux x86_64 (Ubuntu/Debian)
# Auto-detects: CPU flags (AVX2, AVX512), CUDA toolkit
# Prerequisites: cmake, build-essential, git
# Run this AFTER download-all-tools.sh has cloned the source repos
###############################################################################

set -e

TOOLS_ROOT="/home/uat-admin/models/tools"
NPROC=$(nproc)
DEST_BASE="${TOOLS_ROOT}"

# --- CPU Feature Detection ---
detect_cpu_flags() {
    echo "Detecting CPU features..."
    CPU_FLAGS=""
    if grep -q avx512f /proc/cpuinfo 2>/dev/null; then
        echo "  AVX-512: YES"
        CPU_FLAGS="-mavx512f"
    elif grep -q avx2 /proc/cpuinfo 2>/dev/null; then
        echo "  AVX2: YES"
        CPU_FLAGS="-mavx2"
    elif grep -q avx /proc/cpuinfo 2>/dev/null; then
        echo "  AVX: YES"
        CPU_FLAGS="-mavx"
    else
        echo "  AVX: NO (using default)"
    fi
    if grep -q fma /proc/cpuinfo 2>/dev/null; then
        echo "  FMA: YES"
        CPU_FLAGS="${CPU_FLAGS} -mfma"
    fi
    if grep -q f16c /proc/cpuinfo 2>/dev/null; then
        echo "  F16C: YES"
        CPU_FLAGS="${CPU_FLAGS} -mf16c"
    fi
    echo ""
}

# --- CUDA Detection ---
CUDA_AVAILABLE=0
CUDA_ARCH=""
detect_cuda() {
    echo "Detecting CUDA toolkit..."
    if command -v nvcc &>/dev/null; then
        local cuda_ver=$(nvcc --version | grep "release" | sed 's/.*release //' | sed 's/,.*//')
        echo "  CUDA Toolkit: ${cuda_ver}"
        CUDA_AVAILABLE=1

        # Detect GPU compute capability
        if command -v nvidia-smi &>/dev/null; then
            local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
            echo "  GPU: ${gpu_name}"

            # Map common GPUs to SM architectures
            local cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d '.')
            if [ -n "$cc" ]; then
                CUDA_ARCH="$cc"
                echo "  Compute Capability: SM ${CUDA_ARCH}"
            else
                # Fallback: build for common desktop GPUs
                CUDA_ARCH="75;80;86;89;90"
                echo "  Using multi-arch: ${CUDA_ARCH}"
            fi
        else
            CUDA_ARCH="75;80;86;89;90"
            echo "  nvidia-smi not found, using multi-arch: ${CUDA_ARCH}"
        fi
    else
        echo "  CUDA: NOT FOUND (building CPU-only)"
        echo "  Install CUDA toolkit for GPU acceleration"
    fi
    echo ""
}

build_llama_cpp() {
    echo "=== Building llama.cpp (Linux x86_64) ==="
    local SRC="${TOOLS_ROOT}/llama.cpp/source"
    local DEST="${TOOLS_ROOT}/llama.cpp/linux-x86_64"

    if [ ! -d "$SRC" ]; then
        echo "ERROR: Source not found at $SRC. Run download-all-tools.sh first."
        return 1
    fi

    mkdir -p "$DEST"
    cd "$SRC"
    rm -rf build 2>/dev/null || true

    local cmake_args="-DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF"
    if [ "$CUDA_AVAILABLE" -eq 1 ]; then
        cmake_args="${cmake_args} -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}"
        echo "  Building with CUDA (SM ${CUDA_ARCH})"
    else
        echo "  Building CPU-only (AVX2/AVX512 optimized)"
    fi
    if [ -n "$CPU_FLAGS" ]; then
        cmake_args="${cmake_args} -DCMAKE_C_FLAGS='${CPU_FLAGS}' -DCMAKE_CXX_FLAGS='${CPU_FLAGS}'"
    fi

    eval cmake -B build $cmake_args
    cmake --build build -j${NPROC}

    cp build/bin/llama-server "$DEST/" 2>/dev/null || true
    cp build/bin/llama-cli "$DEST/" 2>/dev/null || true
    cp build/bin/llama-llava-cli "$DEST/" 2>/dev/null || true
    cp build/bin/llama-quantize "$DEST/" 2>/dev/null || true
    cp build/bin/llama-bench "$DEST/" 2>/dev/null || true

    echo "llama.cpp binaries installed to: $DEST"
    ls -la "$DEST/"
    echo ""
}

build_whisper_cpp() {
    echo "=== Building whisper.cpp (Linux x86_64) ==="
    local SRC="${TOOLS_ROOT}/whisper.cpp/source"
    local DEST="${TOOLS_ROOT}/whisper.cpp/linux-x86_64"

    if [ ! -d "$SRC" ]; then
        echo "ERROR: Source not found at $SRC. Run download-all-tools.sh first."
        return 1
    fi

    mkdir -p "$DEST"
    cd "$SRC"
    rm -rf build 2>/dev/null || true

    local cmake_args="-DCMAKE_BUILD_TYPE=Release"
    if [ "$CUDA_AVAILABLE" -eq 1 ]; then
        cmake_args="${cmake_args} -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}"
        echo "  Building with CUDA (SM ${CUDA_ARCH})"
    else
        echo "  Building CPU-only"
    fi
    if [ -n "$CPU_FLAGS" ]; then
        cmake_args="${cmake_args} -DCMAKE_C_FLAGS='${CPU_FLAGS}' -DCMAKE_CXX_FLAGS='${CPU_FLAGS}'"
    fi

    eval cmake -B build $cmake_args
    cmake --build build -j${NPROC}

    cp build/bin/whisper-cli "$DEST/" 2>/dev/null || true
    cp build/bin/whisper-server "$DEST/" 2>/dev/null || true

    echo "whisper.cpp binaries installed to: $DEST"
    ls -la "$DEST/"
    echo ""
}

build_stable_diffusion_cpp() {
    echo "=== Building stable-diffusion.cpp (Linux x86_64) ==="
    local SRC="${TOOLS_ROOT}/stable-diffusion.cpp/source"
    local DEST="${TOOLS_ROOT}/stable-diffusion.cpp/linux-x86_64"

    if [ ! -d "$SRC" ]; then
        echo "ERROR: Source not found at $SRC. Run download-all-tools.sh first."
        return 1
    fi

    mkdir -p "$DEST"
    cd "$SRC"
    rm -rf build 2>/dev/null || true

    local cmake_args="-DCMAKE_BUILD_TYPE=Release"
    if [ "$CUDA_AVAILABLE" -eq 1 ]; then
        cmake_args="${cmake_args} -DSD_CUBLAS=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}"
        echo "  Building with CUDA (SM ${CUDA_ARCH})"
    else
        echo "  Building CPU-only"
    fi

    eval cmake -B build $cmake_args
    cmake --build build -j${NPROC}

    cp build/bin/sd-cli "$DEST/" 2>/dev/null || true
    cp build/bin/sd-server "$DEST/" 2>/dev/null || true
    cp build/bin/sd "$DEST/" 2>/dev/null || true

    echo "stable-diffusion.cpp binaries installed to: $DEST"
    ls -la "$DEST/"
    echo ""
}

echo "================================================================"
echo "  Linux x86_64 Build Script"
echo "  Building: llama.cpp, whisper.cpp, stable-diffusion.cpp"
echo "================================================================"
echo ""

detect_cpu_flags
detect_cuda

echo "Building with ${NPROC} threads..."
echo ""

build_llama_cpp
build_whisper_cpp
build_stable_diffusion_cpp

echo ""
echo "================================================================"
echo "  All builds complete!"
if [ "$CUDA_AVAILABLE" -eq 1 ]; then
    echo "  GPU acceleration: ENABLED (CUDA SM ${CUDA_ARCH})"
else
    echo "  GPU acceleration: DISABLED (CPU-only, install CUDA for GPU support)"
fi
echo "================================================================"
X86_EOF

    chmod +x "${TOOLS_ROOT}/build-linux-x86_64.sh"
    log_success "Generated: build-linux-x86_64.sh (Linux x86_64 with CUDA auto-detect)"
}

###############################################################################
# Main
###############################################################################

main() {
    echo ""
    echo "=================================================================="
    echo "  Val Ark - Tool Downloader"
    echo "  Platforms: Linux arm64 (Jetson), Linux x86_64 (Ubuntu),"
    echo "             macOS arm64, Windows x64"
    echo "=================================================================="
    echo ""

    ensure_dir "$TOOLS_ROOT"
    ensure_dir "$LOG_DIR"
    : > "${LOG_DIR}/failed_tool_downloads.txt"

    log "Starting tool download session"
    log "Tools root: ${TOOLS_ROOT}"
    log "Log file: ${LOG_FILE}"

    local avail_gb
    avail_gb=$(df -BG "$TOOLS_ROOT" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//') || avail_gb="unknown"
    log_info "Available disk space: ${avail_gb} GB"

    DOWNLOAD_TOTAL=28  # Approximate total operations (includes linux-x86_64)

    download_llama_cpp
    download_whisper_cpp
    download_piper
    download_stable_diffusion_cpp
    download_onnxruntime
    download_ffmpeg
    download_vosk
    download_bitnet
    generate_build_scripts

    # Final Summary
    echo ""
    log "============================================================"
    log "TOOL DOWNLOAD SESSION COMPLETE"
    log "============================================================"

    local total_size
    total_size=$(du -sh "$TOOLS_ROOT" 2>/dev/null | cut -f1) || total_size="unknown"
    log_info "Total tools size: ${total_size}"
    log_info "Total elapsed: $(elapsed_since $SCRIPT_START)"
    log_info "Results: ${DOWNLOAD_SUCCESS} succeeded | ${DOWNLOAD_FAILED} failed | ${DOWNLOAD_SKIPPED} skipped"

    if [ -s "${LOG_DIR}/failed_tool_downloads.txt" ]; then
        log_warn "Failed downloads logged to: ${LOG_DIR}/failed_tool_downloads.txt"
        while IFS= read -r line; do
            log_warn "  $line"
        done < "${LOG_DIR}/failed_tool_downloads.txt"
    else
        log_success "All tool downloads completed successfully!"
    fi

    echo ""
    log_info "Next steps:"
    log_info "  1. On Jetson:       run ${TOOLS_ROOT}/build-from-source.sh"
    log_info "  2. On Ubuntu x86:   run ${TOOLS_ROOT}/build-linux-x86_64.sh"
    log_info "  3. On macOS:        run ${TOOLS_ROOT}/build-macos.sh"
    log_info "  4. Tools are ready in: ${TOOLS_ROOT}/"
}

###############################################################################
# Validate Mode - check all download URLs with range requests
###############################################################################

validate_url() {
    local url="$1" label="$2"
    local status
    # Use range request (byte 0) since GitHub CDN doesn't support HEAD on downloads
    status=$(curl -sS --connect-timeout 10 --max-time 20 \
        -o /dev/null -w "%{http_code}" -L -r 0-0 \
        "$url" 2>/dev/null || echo "000")
    if [ "$status" = "200" ] || [ "$status" = "206" ] || [ "$status" = "302" ]; then
        echo -e "  ${GREEN}✓${NC} ${label} (HTTP ${status})"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${label} (HTTP ${status})"
        return 1
    fi
}

run_validate() {
    echo ""
    echo "=================================================================="
    echo "  Val Ark Tool Downloader - URL Validation"
    echo "=================================================================="
    echo ""

    ensure_dir "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/validate_$(date +%Y%m%d_%H%M%S).log"

    local pass=0 fail=0

    local LLAMA_TAG=$(github_latest_tag "ggml-org/llama.cpp" "$PIN_LLAMA")
    local WHISPER_TAG=$(github_latest_tag "ggml-org/whisper.cpp" "$PIN_WHISPER")
    local PIPER_TAG="$PIN_PIPER"  # Piper: pin to known release with binaries
    local SD_TAG=$(github_latest_tag "leejet/stable-diffusion.cpp" "$PIN_SD")
    local ONNX_TAG=$(github_latest_tag "microsoft/onnxruntime" "$PIN_ONNX")
    local VOSK_TAG="v${PIN_VOSK#v}"  # Vosk: pin to 0.3.45 (latest has no binaries)
    local ONNX_VER="${ONNX_TAG#v}"
    local VOSK_VER="${VOSK_TAG#v}"

    echo ""
    echo "llama.cpp (${LLAMA_TAG}):"
    validate_url "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-bin-macos-arm64.tar.gz" "macOS arm64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-bin-win-cpu-x64.zip" "Windows x64 CPU" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/ggml-org/llama.cpp.git" "Source repo" && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo "whisper.cpp (${WHISPER_TAG}):"
    validate_url "https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_TAG}/whisper-bin-x64.zip" "Windows x64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/ggml-org/whisper.cpp.git" "Source repo" && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo "piper (${PIPER_TAG}):"
    validate_url "https://github.com/rhasspy/piper/releases/download/${PIPER_TAG}/piper_linux_aarch64.tar.gz" "Linux arm64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/rhasspy/piper/releases/download/${PIPER_TAG}/piper_linux_x86_64.tar.gz" "Linux x86_64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/rhasspy/piper/releases/download/${PIPER_TAG}/piper_macos_aarch64.tar.gz" "macOS arm64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/rhasspy/piper/releases/download/${PIPER_TAG}/piper_windows_amd64.zip" "Windows x64" && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo "stable-diffusion.cpp (${SD_TAG}):"
    validate_url "https://github.com/leejet/stable-diffusion.cpp.git" "Source repo" && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo "onnxruntime (${ONNX_VER}):"
    validate_url "https://github.com/microsoft/onnxruntime/releases/download/${ONNX_TAG}/onnxruntime-linux-aarch64-${ONNX_VER}.tgz" "Linux arm64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/microsoft/onnxruntime/releases/download/${ONNX_TAG}/onnxruntime-linux-x64-${ONNX_VER}.tgz" "Linux x86_64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/microsoft/onnxruntime/releases/download/${ONNX_TAG}/onnxruntime-osx-arm64-${ONNX_VER}.tgz" "macOS arm64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/microsoft/onnxruntime/releases/download/${ONNX_TAG}/onnxruntime-win-x64-${ONNX_VER}.zip" "Windows x64" && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo "ffmpeg:"
    validate_url "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz" "Linux arm64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz" "Linux x86_64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" "Windows x64" && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo "vosk (${VOSK_VER}):"
    validate_url "https://github.com/alphacep/vosk-api/releases/download/${VOSK_TAG}/vosk-linux-aarch64-${VOSK_VER}.zip" "Linux arm64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/alphacep/vosk-api/releases/download/${VOSK_TAG}/vosk-linux-x86_64-${VOSK_VER}.zip" "Linux x86_64" && pass=$((pass+1)) || fail=$((fail+1))
    validate_url "https://github.com/alphacep/vosk-api/releases/download/${VOSK_TAG}/vosk-win64-${VOSK_VER}.zip" "Windows x64" && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo "=================================================================="
    echo -e "  Results: ${GREEN}${pass} passed${NC} | ${RED}${fail} failed${NC}"
    echo "=================================================================="
    return $fail
}

case "${1:-all}" in
    validate)   ensure_dir "$LOG_DIR"; run_validate ;;
    llama)      ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_llama_cpp ;;
    whisper)    ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_whisper_cpp ;;
    piper)      ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_piper ;;
    sd)         ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_stable_diffusion_cpp ;;
    onnx)       ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_onnxruntime ;;
    ffmpeg)     ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_ffmpeg ;;
    vosk)       ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_vosk ;;
    bitnet)     ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; download_bitnet ;;
    build)      ensure_dir "$LOG_DIR"; LOG_FILE="${LOG_DIR}/tools_$(date +%Y%m%d_%H%M%S).log"; generate_build_scripts ;;
    all)        main ;;
    *)
        echo "Usage: $0 [all|validate|llama|whisper|piper|sd|onnx|ffmpeg|vosk|bitnet|build]"
        echo ""
        echo "  all      - Download all tools for all platforms (~3.5GB)"
        echo "  validate - Check all download URLs with HEAD requests"
        echo "  llama    - llama.cpp only"
        echo "  whisper  - whisper.cpp only"
        echo "  piper    - Piper TTS only"
        echo "  sd       - stable-diffusion.cpp only"
        echo "  onnx     - ONNX Runtime only"
        echo "  ffmpeg   - FFmpeg only"
        echo "  vosk     - Vosk only"
        echo "  bitnet   - BitNet.cpp only (1-bit LLM inference)"
        echo "  build    - Generate build-from-source scripts only"
        exit 1
        ;;
esac
