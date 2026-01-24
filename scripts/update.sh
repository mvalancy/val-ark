#!/bin/bash
###############################################################################
# Val Ark - Update Script
# Keeps the Val Ark site and its assets up to date.
#
# Features:
# - Downloads latest Ollama installers (append-only, never deletes old versions)
# - Updates tool logos and assets
# - Checks for new tool releases
# - Reports model file locations for each platform
#
# Usage:
#   ./update.sh              # Run full update
#   ./update.sh ollama       # Update Ollama installers only
#   ./update.sh assets       # Update logos/assets only
#   ./update.sh check        # Check for new versions (dry run)
#   ./update.sh paths        # Show model file paths for each platform
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
ASSETS_DIR="${PROJECT_ROOT}/web-ui"
OLLAMA_DIR="${PROJECT_ROOT}/assets/ollama"
LOGOS_DIR="${ASSETS_DIR}/logos"
SAMPLES_DIR="${ASSETS_DIR}/samples"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }
log_ok() { log "${GREEN}OK${NC}: $*"; }
log_info() { log "${BLUE}INFO${NC}: $*"; }
log_warn() { log "${YELLOW}WARN${NC}: $*"; }
log_err() { log "${RED}ERROR${NC}: $*"; }

###############################################################################
# Ollama Installer Updates (append-only)
###############################################################################

update_ollama() {
    log "============================================================"
    log "Updating Ollama Installers (append-only)"
    log "============================================================"

    mkdir -p "${OLLAMA_DIR}"

    # Resolve latest version
    local latest_tag
    latest_tag=$(curl -sS "https://api.github.com/repos/ollama/ollama/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$latest_tag" ]; then
        log_warn "Could not resolve latest Ollama version, using v0.5.4"
        latest_tag="v0.5.4"
    fi
    local ver="${latest_tag#v}"
    log_info "Latest Ollama version: ${latest_tag}"

    # Create version directory (append-only: never removes old versions)
    local ver_dir="${OLLAMA_DIR}/${latest_tag}"
    mkdir -p "$ver_dir"

    # Record this version
    echo "${latest_tag} $(date '+%Y-%m-%d')" >> "${OLLAMA_DIR}/versions.txt"
    sort -u -o "${OLLAMA_DIR}/versions.txt" "${OLLAMA_DIR}/versions.txt"

    # --- Linux x86_64 (tar.zst archive) ---
    local linux_bin="${ver_dir}/ollama-linux-amd64"
    if [ ! -f "$linux_bin" ] || [ $(stat -c%s "$linux_bin" 2>/dev/null || echo 0) -lt 1000 ]; then
        log_info "Downloading Ollama ${latest_tag} for Linux x86_64 (tar.zst)..."
        rm -f "$linux_bin" 2>/dev/null
        curl -L -o /tmp/ollama-linux-amd64.tar.zst \
            "https://github.com/ollama/ollama/releases/download/${latest_tag}/ollama-linux-amd64.tar.zst" 2>/dev/null
        if [ -f /tmp/ollama-linux-amd64.tar.zst ] && [ -s /tmp/ollama-linux-amd64.tar.zst ]; then
            tar --zstd -xf /tmp/ollama-linux-amd64.tar.zst -C /tmp/ bin/ollama 2>/dev/null
            if [ -f /tmp/bin/ollama ]; then
                mv /tmp/bin/ollama "$linux_bin"
                chmod +x "$linux_bin"
                rm -rf /tmp/bin
                log_ok "Linux x86_64: ${linux_bin} ($(du -h "$linux_bin" | cut -f1))"
            else
                log_warn "Could not extract ollama binary from tar.zst"
            fi
            rm -f /tmp/ollama-linux-amd64.tar.zst
        else
            log_err "Failed to download Linux x86_64 tar.zst"
        fi
    else
        log_info "Already have: Linux x86_64 ${latest_tag}"
    fi

    # --- Linux ARM64 (tar.zst archive) ---
    local linux_arm="${ver_dir}/ollama-linux-arm64"
    if [ ! -f "$linux_arm" ] || [ $(stat -c%s "$linux_arm" 2>/dev/null || echo 0) -lt 1000 ]; then
        log_info "Downloading Ollama ${latest_tag} for Linux ARM64 (tar.zst)..."
        rm -f "$linux_arm" 2>/dev/null
        curl -L -o /tmp/ollama-linux-arm64.tar.zst \
            "https://github.com/ollama/ollama/releases/download/${latest_tag}/ollama-linux-arm64.tar.zst" 2>/dev/null
        if [ -f /tmp/ollama-linux-arm64.tar.zst ] && [ -s /tmp/ollama-linux-arm64.tar.zst ]; then
            tar --zstd -xf /tmp/ollama-linux-arm64.tar.zst -C /tmp/ bin/ollama 2>/dev/null
            if [ -f /tmp/bin/ollama ]; then
                mv /tmp/bin/ollama "$linux_arm"
                chmod +x "$linux_arm"
                rm -rf /tmp/bin
                log_ok "Linux ARM64: ${linux_arm} ($(du -h "$linux_arm" | cut -f1))"
            else
                log_err "Could not extract ollama binary from arm64 tar.zst"
            fi
            rm -f /tmp/ollama-linux-arm64.tar.zst
        else
            log_err "Failed to download Linux ARM64 tar.zst"
        fi
    else
        log_info "Already have: Linux ARM64 ${latest_tag}"
    fi

    # --- macOS (universal zip) ---
    local mac_zip="${ver_dir}/Ollama-darwin.zip"
    if [ ! -f "$mac_zip" ] || [ $(stat -c%s "$mac_zip" 2>/dev/null || echo 0) -lt 1000 ]; then
        log_info "Downloading Ollama ${latest_tag} for macOS..."
        curl -L -o "$mac_zip" \
            "https://github.com/ollama/ollama/releases/download/${latest_tag}/Ollama-darwin.zip" 2>/dev/null
        [ -f "$mac_zip" ] && [ -s "$mac_zip" ] && log_ok "macOS: ${mac_zip}" || log_err "Failed: macOS"
    else
        log_info "Already have: macOS ${latest_tag}"
    fi

    # --- Windows (installer) ---
    local win_exe="${ver_dir}/OllamaSetup.exe"
    if [ ! -f "$win_exe" ] || [ $(stat -c%s "$win_exe" 2>/dev/null || echo 0) -lt 1000 ]; then
        log_info "Downloading Ollama ${latest_tag} for Windows..."
        curl -L -o "$win_exe" \
            "https://github.com/ollama/ollama/releases/download/${latest_tag}/OllamaSetup.exe" 2>/dev/null
        [ -f "$win_exe" ] && [ -s "$win_exe" ] && log_ok "Windows: ${win_exe}" || log_err "Failed: Windows"
    else
        log_info "Already have: Windows ${latest_tag}"
    fi

    # Create/update 'latest' symlink for the web server
    rm -f "${OLLAMA_DIR}/latest"
    ln -sf "${latest_tag}" "${OLLAMA_DIR}/latest"
    log_ok "Symlink: assets/ollama/latest -> ${latest_tag}"

    # List all available versions
    echo ""
    log_info "Available Ollama versions:"
    ls -d "${OLLAMA_DIR}"/v* 2>/dev/null | while read d; do
        local v=$(basename "$d")
        local files=$(ls "$d" 2>/dev/null | wc -l)
        echo "    ${v} (${files} installers)"
    done
    echo ""
}

###############################################################################
# Tool Binary Updates (prebuilt binaries for each platform)
###############################################################################

TOOLS_DIR="${PROJECT_ROOT}/tools"

update_tools() {
    log "============================================================"
    log "Updating Tool Binaries (prebuilt downloads)"
    log "============================================================"

    mkdir -p "${TOOLS_DIR}/linux-x86_64" "${TOOLS_DIR}/linux-arm64" \
             "${TOOLS_DIR}/macos-arm64" "${TOOLS_DIR}/windows-x64"

    # --- FFmpeg (BtbN static builds) ---
    log_info "Checking FFmpeg..."
    local ffmpeg_tag
    ffmpeg_tag=$(curl -sS "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -n "$ffmpeg_tag" ]; then
        # Linux x86_64
        if [ ! -f "${TOOLS_DIR}/linux-x86_64/ffmpeg" ]; then
            log_info "Downloading FFmpeg for Linux x86_64..."
            local ff_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/${ffmpeg_tag}/ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz"
            curl -L -o /tmp/ffmpeg-linux64.tar.xz "$ff_url" 2>/dev/null
            if [ -f /tmp/ffmpeg-linux64.tar.xz ]; then
                tar -xJf /tmp/ffmpeg-linux64.tar.xz -C /tmp/ --wildcards '*/bin/ffmpeg' 2>/dev/null
                find /tmp -name 'ffmpeg' -type f -exec mv {} "${TOOLS_DIR}/linux-x86_64/ffmpeg" \; 2>/dev/null
                chmod +x "${TOOLS_DIR}/linux-x86_64/ffmpeg" 2>/dev/null
                rm -f /tmp/ffmpeg-linux64.tar.xz
                [ -f "${TOOLS_DIR}/linux-x86_64/ffmpeg" ] && log_ok "FFmpeg linux-x86_64" || log_warn "FFmpeg linux-x86_64 extract failed"
            fi
        else
            log_info "Already have: FFmpeg linux-x86_64"
        fi

        # Linux ARM64
        if [ ! -f "${TOOLS_DIR}/linux-arm64/ffmpeg" ]; then
            log_info "Downloading FFmpeg for Linux ARM64..."
            local ff_arm_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/${ffmpeg_tag}/ffmpeg-n7.1-latest-linuxarm64-gpl-7.1.tar.xz"
            curl -L -o /tmp/ffmpeg-arm64.tar.xz "$ff_arm_url" 2>/dev/null
            if [ -f /tmp/ffmpeg-arm64.tar.xz ]; then
                tar -xJf /tmp/ffmpeg-arm64.tar.xz -C /tmp/ --wildcards '*/bin/ffmpeg' 2>/dev/null
                find /tmp -name 'ffmpeg' -type f -exec mv {} "${TOOLS_DIR}/linux-arm64/ffmpeg" \; 2>/dev/null
                chmod +x "${TOOLS_DIR}/linux-arm64/ffmpeg" 2>/dev/null
                rm -f /tmp/ffmpeg-arm64.tar.xz
                [ -f "${TOOLS_DIR}/linux-arm64/ffmpeg" ] && log_ok "FFmpeg linux-arm64" || log_warn "FFmpeg linux-arm64 extract failed"
            fi
        else
            log_info "Already have: FFmpeg linux-arm64"
        fi
    else
        log_warn "Could not resolve FFmpeg latest version"
    fi

    # --- Piper TTS ---
    log_info "Checking Piper TTS..."
    local piper_tag
    piper_tag=$(curl -sS "https://api.github.com/repos/rhasspy/piper/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -n "$piper_tag" ]; then
        # Linux x86_64
        if [ ! -f "${TOOLS_DIR}/linux-x86_64/piper/piper" ]; then
            log_info "Downloading Piper ${piper_tag} for Linux x86_64..."
            mkdir -p "${TOOLS_DIR}/linux-x86_64/piper"
            curl -L -o /tmp/piper-linux-x64.tar.gz \
                "https://github.com/rhasspy/piper/releases/download/${piper_tag}/piper_linux_x86_64.tar.gz" 2>/dev/null
            tar -xzf /tmp/piper-linux-x64.tar.gz -C "${TOOLS_DIR}/linux-x86_64/" 2>/dev/null
            rm -f /tmp/piper-linux-x64.tar.gz
            [ -f "${TOOLS_DIR}/linux-x86_64/piper/piper" ] && log_ok "Piper linux-x86_64" || log_warn "Piper linux-x86_64 failed"
        else
            log_info "Already have: Piper linux-x86_64"
        fi

        # Linux ARM64
        if [ ! -f "${TOOLS_DIR}/linux-arm64/piper/piper" ]; then
            log_info "Downloading Piper ${piper_tag} for Linux ARM64..."
            mkdir -p "${TOOLS_DIR}/linux-arm64/piper"
            curl -L -o /tmp/piper-linux-arm64.tar.gz \
                "https://github.com/rhasspy/piper/releases/download/${piper_tag}/piper_linux_aarch64.tar.gz" 2>/dev/null
            tar -xzf /tmp/piper-linux-arm64.tar.gz -C "${TOOLS_DIR}/linux-arm64/" 2>/dev/null
            rm -f /tmp/piper-linux-arm64.tar.gz
            [ -f "${TOOLS_DIR}/linux-arm64/piper/piper" ] && log_ok "Piper linux-arm64" || log_warn "Piper linux-arm64 failed"
        else
            log_info "Already have: Piper linux-arm64"
        fi

        # macOS ARM64
        if [ ! -f "${TOOLS_DIR}/macos-arm64/piper/piper" ]; then
            log_info "Downloading Piper ${piper_tag} for macOS ARM64..."
            mkdir -p "${TOOLS_DIR}/macos-arm64/piper"
            curl -L -o /tmp/piper-macos-arm64.tar.gz \
                "https://github.com/rhasspy/piper/releases/download/${piper_tag}/piper_macos_aarch64.tar.gz" 2>/dev/null
            tar -xzf /tmp/piper-macos-arm64.tar.gz -C "${TOOLS_DIR}/macos-arm64/" 2>/dev/null
            rm -f /tmp/piper-macos-arm64.tar.gz
            [ -f "${TOOLS_DIR}/macos-arm64/piper/piper" ] && log_ok "Piper macos-arm64" || log_warn "Piper macos-arm64 failed"
        else
            log_info "Already have: Piper macos-arm64"
        fi

        # Windows
        if [ ! -f "${TOOLS_DIR}/windows-x64/piper/piper.exe" ]; then
            log_info "Downloading Piper ${piper_tag} for Windows..."
            mkdir -p "${TOOLS_DIR}/windows-x64/piper"
            curl -L -o /tmp/piper-windows.zip \
                "https://github.com/rhasspy/piper/releases/download/${piper_tag}/piper_windows_amd64.zip" 2>/dev/null
            unzip -o -q /tmp/piper-windows.zip -d "${TOOLS_DIR}/windows-x64/" 2>/dev/null
            rm -f /tmp/piper-windows.zip
            [ -f "${TOOLS_DIR}/windows-x64/piper/piper.exe" ] && log_ok "Piper windows-x64" || log_warn "Piper windows failed"
        else
            log_info "Already have: Piper windows-x64"
        fi
    else
        log_warn "Could not resolve Piper latest version"
    fi

    # --- Vosk ---
    log_info "Checking Vosk..."
    if [ ! -d "${TOOLS_DIR}/linux-x86_64/vosk" ]; then
        log_info "Downloading Vosk Python package..."
        mkdir -p "${TOOLS_DIR}/linux-x86_64/vosk"
        pip3 install --target="${TOOLS_DIR}/linux-x86_64/vosk" vosk 2>/dev/null
        [ -d "${TOOLS_DIR}/linux-x86_64/vosk/vosk" ] && log_ok "Vosk linux-x86_64" || log_warn "Vosk install failed (pip3 needed)"
    else
        log_info "Already have: Vosk linux-x86_64"
    fi

    # --- ONNX Runtime ---
    log_info "Checking ONNX Runtime..."
    local ort_tag
    ort_tag=$(curl -sS "https://api.github.com/repos/microsoft/onnxruntime/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -n "$ort_tag" ]; then
        local ort_ver="${ort_tag#v}"
        if [ ! -d "${TOOLS_DIR}/linux-x86_64/onnxruntime" ]; then
            log_info "Downloading ONNX Runtime ${ort_tag} for Linux x86_64..."
            mkdir -p "${TOOLS_DIR}/linux-x86_64/onnxruntime"
            curl -L -o /tmp/ort-linux.tgz \
                "https://github.com/microsoft/onnxruntime/releases/download/${ort_tag}/onnxruntime-linux-x64-${ort_ver}.tgz" 2>/dev/null
            tar -xzf /tmp/ort-linux.tgz -C "${TOOLS_DIR}/linux-x86_64/onnxruntime/" --strip-components=1 2>/dev/null
            rm -f /tmp/ort-linux.tgz
            [ -d "${TOOLS_DIR}/linux-x86_64/onnxruntime/lib" ] && log_ok "ORT linux-x86_64" || log_warn "ORT linux-x86_64 failed"
        else
            log_info "Already have: ORT linux-x86_64"
        fi
    else
        log_warn "Could not resolve ONNX Runtime latest version"
    fi

    # --- llama.cpp, whisper.cpp, stable-diffusion.cpp ---
    # These are build-from-source on most platforms.
    # The build scripts are generated by download-all-tools.sh
    log_info "llama.cpp, whisper.cpp, sd.cpp: build from source (see download-all-tools.sh)"
    log_info "Pre-compiled binaries for macOS/Windows available from GitHub Releases."

    echo ""
    log_info "Tool binaries status:"
    for platform_dir in "${TOOLS_DIR}"/*/; do
        local plat=$(basename "$platform_dir")
        local count=$(find "$platform_dir" -type f 2>/dev/null | wc -l)
        echo "    ${plat}: ${count} files"
    done
    echo ""
}

###############################################################################
# Source Repos (clone/pull for build-from-source tools)
###############################################################################

SOURCES_DIR="${PROJECT_ROOT}/sources"

clone_sources() {
    log "============================================================"
    log "Updating Source Repos (build-from-source tools)"
    log "============================================================"

    mkdir -p "${SOURCES_DIR}"

    clone_or_pull() {
        local repo_url="$1" dir_name="$2"
        local dest="${SOURCES_DIR}/${dir_name}"
        if [ -d "$dest/.git" ]; then
            log_info "Pulling latest: ${dir_name}..."
            git -C "$dest" pull --ff-only 2>/dev/null
            local tag=$(git -C "$dest" describe --tags --abbrev=0 2>/dev/null || echo "HEAD")
            log_ok "${dir_name}: ${tag}"
        else
            log_info "Cloning: ${dir_name}..."
            rm -rf "$dest" 2>/dev/null
            git clone --depth 1 "$repo_url" "$dest" 2>/dev/null
            if [ -d "$dest/.git" ]; then
                local tag=$(git -C "$dest" describe --tags --abbrev=0 2>/dev/null || echo "HEAD")
                log_ok "Cloned ${dir_name}: ${tag}"
            else
                log_err "Failed to clone ${dir_name}"
            fi
        fi
    }

    clone_or_pull "https://github.com/ggml-org/llama.cpp.git" "llama.cpp"
    clone_or_pull "https://github.com/ggml-org/whisper.cpp.git" "whisper.cpp"
    clone_or_pull "https://github.com/leejet/stable-diffusion.cpp.git" "stable-diffusion.cpp"

    echo ""
    log_info "Source repos status:"
    for repo_dir in "${SOURCES_DIR}"/*/; do
        local name=$(basename "$repo_dir")
        if [ -d "$repo_dir/.git" ]; then
            local tag=$(git -C "$repo_dir" describe --tags --abbrev=0 2>/dev/null || echo "unknown")
            echo "    ${name}: ${tag}"
        fi
    done

    echo ""
    log_info "Build instructions:"
    echo "    cd sources/llama.cpp && cmake -B build -DGGML_CUDA=ON && cmake --build build -j"
    echo "    cd sources/whisper.cpp && cmake -B build -DGGML_CUDA=ON && cmake --build build -j"
    echo "    cd sources/stable-diffusion.cpp && cmake -B build -DGGML_CUDA=ON && cmake --build build -j"
    echo ""
    echo "    After building, copy binaries to tools/ directories:"
    echo "    cp sources/llama.cpp/build/bin/llama-server tools/linux-arm64/"
    echo "    cp sources/whisper.cpp/build/bin/whisper-cli tools/linux-arm64/"
    echo "    cp sources/stable-diffusion.cpp/build/bin/sd tools/linux-arm64/sd-cli"
    echo ""
}

###############################################################################
# Disk Space Check (200GB buffer enforcement)
###############################################################################

DISK_BUFFER_GB=60

check_disk_space() {
    local avail_kb=$(df --output=avail "${PROJECT_ROOT}" 2>/dev/null | tail -1)
    local avail_gb=$((avail_kb / 1024 / 1024))
    local budget_gb=$((avail_gb - DISK_BUFFER_GB))
    echo "$budget_gb"
}

DISK_HARD_MIN_GB=50  # Absolute minimum: never go below this

require_disk_space() {
    local needed_mb="$1"
    local label="$2"
    local avail_kb=$(df --output=avail "${PROJECT_ROOT}" 2>/dev/null | tail -1)
    local avail_mb=$((avail_kb / 1024))
    local hard_min_mb=$((DISK_HARD_MIN_GB * 1024))

    # Hard minimum: never go below 50GB free
    if [ $((avail_mb - needed_mb)) -lt "$hard_min_mb" ]; then
        log_warn "SKIP ${label}: needs ${needed_mb}MB but only $((avail_mb - hard_min_mb))MB safe budget (${DISK_HARD_MIN_GB}GB hard minimum)"
        return 1
    fi

    # Soft buffer: warn but allow small downloads (<500MB) even past the buffer
    local buffer_mb=$((DISK_BUFFER_GB * 1024))
    local budget_mb=$((avail_mb - buffer_mb))
    if [ "$budget_mb" -lt "$needed_mb" ] && [ "$needed_mb" -gt 500 ]; then
        log_warn "SKIP ${label}: needs ${needed_mb}MB, exceeds ${DISK_BUFFER_GB}GB soft buffer (use --force to override)"
        return 1
    fi

    if [ "$budget_mb" -lt 0 ] && [ "$needed_mb" -le 500 ]; then
        log_info "(past ${DISK_BUFFER_GB}GB buffer, but ${label} is only ${needed_mb}MB - proceeding)"
    fi
    return 0
}

###############################################################################
# App Downloads (creative, infrastructure, dev tools)
###############################################################################

download_gh_binary() {
    local repo="$1" pattern="$2" dest="$3" label="$4"
    if [ -f "$dest" ] && [ $(stat -c%s "$dest" 2>/dev/null || echo 0) -gt 1000 ]; then
        log_info "Already have: ${label}"
        return 0
    fi
    local url
    url=$(curl -sS "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep "browser_download_url.*${pattern}" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
    if [ -z "$url" ]; then
        log_warn "No release URL found for ${label} (pattern: ${pattern})"
        return 1
    fi
    log_info "Downloading ${label}..."
    mkdir -p "$(dirname "$dest")"
    curl -L -o "$dest" "$url" 2>/dev/null
    if [ -f "$dest" ] && [ $(stat -c%s "$dest" 2>/dev/null || echo 0) -gt 1000 ]; then
        chmod +x "$dest" 2>/dev/null
        log_ok "${label}: $(du -h "$dest" | cut -f1)"
    else
        log_err "Failed: ${label}"
        rm -f "$dest" 2>/dev/null
        return 1
    fi
}

update_apps() {
    # Accept optional platform override: linux-arm64, linux-x86_64, macos-arm64, windows-x64
    local target_platform="${1:-}"

    local arch=$(uname -m)
    local arm64=false
    local is_native=true
    local can_compile=true

    if [ -n "$target_platform" ]; then
        # Use specified platform
        case "$target_platform" in
            linux-arm64)  arm64=true;  is_native=false ;;
            linux-x86_64) arm64=false; is_native=false ;;
            macos-arm64)  arm64=true;  is_native=false; can_compile=false ;;
            windows-x64)  arm64=false; is_native=false; can_compile=false ;;
        esac
        # Check if target matches native platform
        if { [ "$target_platform" = "linux-arm64" ] && { [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; }; } ||
           { [ "$target_platform" = "linux-x86_64" ] && [ "$arch" = "x86_64" ]; }; then
            is_native=true
        fi
    else
        # Auto-detect
        [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ] && arm64=true
        target_platform="linux-arm64"
        [ "$arm64" != true ] && target_platform="linux-x86_64"
    fi

    local plat_dir="${TOOLS_DIR}/${target_platform}"
    local arch_label="${target_platform}"

    log "============================================================"
    log "Updating Apps & Dev Tools (${arch_label})"
    log "============================================================"

    mkdir -p "$plat_dir"

    # --- Syncthing (~10MB) ---
    require_disk_space 15 "Syncthing" && {
        local sync_dir="${plat_dir}/syncthing"
        if [ ! -f "${sync_dir}/syncthing" ]; then
            local sync_arch="linux-arm64"
            [ "$arm64" != true ] && sync_arch="linux-amd64"
            local sync_url
            sync_url=$(curl -sS "https://api.github.com/repos/syncthing/syncthing/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*${sync_arch}.*tar.gz\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$sync_url" ]; then
                log_info "Downloading Syncthing (${arch_label})..."
                curl -L -o /tmp/syncthing.tar.gz "$sync_url" 2>/dev/null
                mkdir -p "${sync_dir}"
                tar -xzf /tmp/syncthing.tar.gz -C /tmp/ 2>/dev/null
                find /tmp -name 'syncthing' -type f -perm /111 -exec mv {} "${sync_dir}/syncthing" \; 2>/dev/null
                rm -f /tmp/syncthing.tar.gz
                rm -rf /tmp/syncthing-*
                [ -f "${sync_dir}/syncthing" ] && log_ok "Syncthing: $(du -h "${sync_dir}/syncthing" | cut -f1)" || log_err "Syncthing extract failed"
            else
                log_warn "Could not find Syncthing release URL"
            fi
        else
            log_info "Already have: Syncthing"
        fi
    }

    # --- btop (~2MB static binary) ---
    require_disk_space 5 "btop" && {
        local btop_dir="${plat_dir}/btop"
        if [ ! -f "${btop_dir}/bin/btop" ]; then
            local btop_arch="aarch64"
            [ "$arm64" != true ] && btop_arch="x86_64"
            local btop_url
            btop_url=$(curl -sS "https://api.github.com/repos/aristocratos/btop/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*btop-${btop_arch}-unknown-linux-musl" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$btop_url" ]; then
                log_info "Downloading btop (${arch_label})..."
                curl -L -o /tmp/btop.tbz "$btop_url" 2>/dev/null
                rm -rf "${btop_dir}"
                tar -xjf /tmp/btop.tbz -C "${plat_dir}/" 2>/dev/null
                rm -f /tmp/btop.tbz
                [ -f "${btop_dir}/bin/btop" ] && log_ok "btop: $(du -h "${btop_dir}/bin/btop" | cut -f1)" || log_err "btop extract failed"
            else
                log_warn "Could not find btop release URL"
            fi
        else
            log_info "Already have: btop"
        fi
    }

    # --- tmux (~2MB from tmux-builds) ---
    require_disk_space 5 "tmux" && {
        local tmux_dir="${plat_dir}/tmux"
        if [ ! -f "${tmux_dir}/tmux" ]; then
            local tmux_arch="linux-arm64"
            [ "$arm64" != true ] && tmux_arch="linux-x86_64"
            local tmux_url
            tmux_url=$(curl -sS "https://api.github.com/repos/tmux/tmux-builds/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*${tmux_arch}.*tar.gz" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$tmux_url" ]; then
                log_info "Downloading tmux (${arch_label})..."
                curl -L -o /tmp/tmux.tar.gz "$tmux_url" 2>/dev/null
                mkdir -p "${tmux_dir}"
                tar -xzf /tmp/tmux.tar.gz -C /tmp/ 2>/dev/null
                find /tmp -name 'tmux' -type f -perm /111 -exec mv {} "${tmux_dir}/tmux" \; 2>/dev/null
                rm -f /tmp/tmux.tar.gz
                rm -rf /tmp/tmux-*
                [ -f "${tmux_dir}/tmux" ] && log_ok "tmux: $(du -h "${tmux_dir}/tmux" | cut -f1)" || log_err "tmux extract failed"
            else
                log_warn "Could not find tmux-builds release URL"
            fi
        else
            log_info "Already have: tmux"
        fi
    }

    # --- Dev CLI Tools Bundle ---
    require_disk_space 30 "Dev CLI Bundle" && {
        local dev_dir="${plat_dir}/dev-cli"
        mkdir -p "${dev_dir}"

        # ripgrep (note: no musl build for aarch64, use gnu)
        if [ ! -f "${dev_dir}/rg" ]; then
            local rg_arch="aarch64-unknown-linux-gnu"
            [ "$arm64" != true ] && rg_arch="x86_64-unknown-linux-musl"
            download_gh_binary "BurntSushi/ripgrep" "${rg_arch}.*tar.gz" "/tmp/rg.tar.gz" "ripgrep" && {
                tar -xzf /tmp/rg.tar.gz -C /tmp/ 2>/dev/null
                find /tmp -name 'rg' -type f -exec mv {} "${dev_dir}/rg" \; 2>/dev/null
                chmod +x "${dev_dir}/rg"
                rm -f /tmp/rg.tar.gz && rm -rf /tmp/ripgrep-*
            }
        fi

        # fd
        if [ ! -f "${dev_dir}/fd" ]; then
            local fd_arch="aarch64-unknown-linux-musl"
            [ "$arm64" != true ] && fd_arch="x86_64-unknown-linux-musl"
            download_gh_binary "sharkdp/fd" "${fd_arch}.*tar.gz" "/tmp/fd.tar.gz" "fd" && {
                tar -xzf /tmp/fd.tar.gz -C /tmp/ 2>/dev/null
                find /tmp -name 'fd' -type f -exec mv {} "${dev_dir}/fd" \; 2>/dev/null
                chmod +x "${dev_dir}/fd"
                rm -f /tmp/fd.tar.gz && rm -rf /tmp/fd-*
            }
        fi

        # bat
        if [ ! -f "${dev_dir}/bat" ]; then
            local bat_arch="aarch64-unknown-linux-musl"
            [ "$arm64" != true ] && bat_arch="x86_64-unknown-linux-musl"
            download_gh_binary "sharkdp/bat" "${bat_arch}.*tar.gz" "/tmp/bat.tar.gz" "bat" && {
                tar -xzf /tmp/bat.tar.gz -C /tmp/ 2>/dev/null
                find /tmp -name 'bat' -type f -exec mv {} "${dev_dir}/bat" \; 2>/dev/null
                chmod +x "${dev_dir}/bat"
                rm -f /tmp/bat.tar.gz && rm -rf /tmp/bat-*
            }
        fi

        # jq
        if [ ! -f "${dev_dir}/jq" ]; then
            local jq_name="jq-linux-arm64"
            [ "$arm64" != true ] && jq_name="jq-linux-amd64"
            download_gh_binary "jqlang/jq" "${jq_name}\"" "${dev_dir}/jq" "jq"
        fi

        # fzf
        if [ ! -f "${dev_dir}/fzf" ]; then
            local fzf_arch="linux_arm64"
            [ "$arm64" != true ] && fzf_arch="linux_amd64"
            download_gh_binary "junegunn/fzf" "${fzf_arch}.*tar.gz" "/tmp/fzf.tar.gz" "fzf" && {
                tar -xzf /tmp/fzf.tar.gz -C "${dev_dir}/" fzf 2>/dev/null
                chmod +x "${dev_dir}/fzf"
                rm -f /tmp/fzf.tar.gz
            }
        fi

        # lazygit
        if [ ! -f "${dev_dir}/lazygit" ]; then
            local lg_arch="linux_arm64"
            [ "$arm64" != true ] && lg_arch="linux_x86_64"
            download_gh_binary "jesseduffield/lazygit" "${lg_arch}.*tar.gz" "/tmp/lazygit.tar.gz" "lazygit" && {
                tar -xzf /tmp/lazygit.tar.gz -C "${dev_dir}/" lazygit 2>/dev/null
                chmod +x "${dev_dir}/lazygit"
                rm -f /tmp/lazygit.tar.gz
            }
        fi

        local count=$(ls "${dev_dir}" 2>/dev/null | wc -l)
        log_ok "Dev CLI bundle: ${count} tools in ${dev_dir}"
    }

    # --- Godot Engine (~50MB) ---
    require_disk_space 60 "Godot" && {
        local godot_dir="${plat_dir}/godot"
        if [ ! -f "${godot_dir}/"Godot_* ]; then
            local godot_ver="4.5.1"
            local godot_arch="linux.arm64"
            [ "$arm64" != true ] && godot_arch="linux.x86_64"
            local godot_url="https://github.com/godotengine/godot/releases/download/${godot_ver}-stable/Godot_v${godot_ver}-stable_${godot_arch}.zip"
            log_info "Downloading Godot ${godot_ver} (${arch_label})..."
            mkdir -p "${godot_dir}"
            curl -L -o /tmp/godot.zip "$godot_url" 2>/dev/null
            if [ -f /tmp/godot.zip ] && [ $(stat -c%s /tmp/godot.zip) -gt 1000 ]; then
                unzip -o /tmp/godot.zip -d "${godot_dir}/" 2>/dev/null
                chmod +x "${godot_dir}/"Godot_* 2>/dev/null
                rm -f /tmp/godot.zip
                log_ok "Godot ${godot_ver}: $(du -sh "${godot_dir}" | cut -f1)"
            else
                log_err "Godot download failed"
                rm -f /tmp/godot.zip
            fi
        else
            log_info "Already have: Godot"
        fi
    }

    # --- InfluxDB 2.x (~100MB) ---
    require_disk_space 120 "InfluxDB" && {
        local influx_dir="${plat_dir}/influxdb"
        if [ ! -f "${influx_dir}/influxd" ]; then
            local influx_ver="2.7.11"
            local influx_arch="linux_arm64"
            [ "$arm64" != true ] && influx_arch="linux_amd64"
            local influx_url="https://dl.influxdata.com/influxdb/releases/influxdb2-${influx_ver}_${influx_arch}.tar.gz"
            log_info "Downloading InfluxDB ${influx_ver} (${arch_label})..."
            mkdir -p "${influx_dir}"
            curl -L -o /tmp/influxdb.tar.gz "$influx_url" 2>/dev/null
            if [ -f /tmp/influxdb.tar.gz ] && [ $(stat -c%s /tmp/influxdb.tar.gz) -gt 1000 ]; then
                tar -xzf /tmp/influxdb.tar.gz -C /tmp/ 2>/dev/null
                find /tmp -name 'influxd' -type f -exec mv {} "${influx_dir}/influxd" \; 2>/dev/null
                find /tmp -name 'influx' -type f ! -name 'influxd' -exec mv {} "${influx_dir}/influx" \; 2>/dev/null
                chmod +x "${influx_dir}/"* 2>/dev/null
                rm -f /tmp/influxdb.tar.gz
                rm -rf /tmp/influxdb2-*
                [ -f "${influx_dir}/influxd" ] && log_ok "InfluxDB: $(du -h "${influx_dir}/influxd" | cut -f1)" || log_err "InfluxDB extract failed"
            else
                log_err "InfluxDB download failed"
                rm -f /tmp/influxdb.tar.gz
            fi
        else
            log_info "Already have: InfluxDB"
        fi
    }

    # --- Tailscale (~20MB) --- downloads from pkgs.tailscale.com (no GitHub release assets)
    require_disk_space 25 "Tailscale" && {
        local ts_dir="${plat_dir}/tailscale"
        if [ ! -f "${ts_dir}/tailscale" ]; then
            local ts_arch="arm64"
            [ "$arm64" != true ] && ts_arch="amd64"
            # Get latest version from GitHub tag, download from pkgs.tailscale.com
            local ts_ver
            ts_ver=$(curl -sS "https://api.github.com/repos/tailscale/tailscale/releases/latest" 2>/dev/null \
                | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
            if [ -n "$ts_ver" ]; then
                local ts_url="https://pkgs.tailscale.com/stable/tailscale_${ts_ver}_${ts_arch}.tgz"
                log_info "Downloading Tailscale ${ts_ver} (${arch_label})..."
                curl -L -o /tmp/tailscale.tgz "$ts_url" 2>/dev/null
                if [ -f /tmp/tailscale.tgz ] && [ $(stat -c%s /tmp/tailscale.tgz 2>/dev/null || echo 0) -gt 1000 ]; then
                    mkdir -p "${ts_dir}"
                    tar -xzf /tmp/tailscale.tgz -C /tmp/ 2>/dev/null
                    find /tmp -name 'tailscale' -type f -perm /111 -exec mv {} "${ts_dir}/tailscale" \; 2>/dev/null
                    find /tmp -name 'tailscaled' -type f -perm /111 -exec mv {} "${ts_dir}/tailscaled" \; 2>/dev/null
                    rm -f /tmp/tailscale.tgz
                    rm -rf /tmp/tailscale_*
                    [ -f "${ts_dir}/tailscale" ] && log_ok "Tailscale ${ts_ver}: $(du -h "${ts_dir}/tailscale" | cut -f1)" || log_err "Tailscale extract failed"
                else
                    log_err "Tailscale download failed from ${ts_url}"
                    rm -f /tmp/tailscale.tgz
                fi
            else
                log_warn "Could not determine Tailscale version"
            fi
        else
            log_info "Already have: Tailscale"
        fi
    }

    # --- Mosquitto (~5MB, compile from source) --- requires native platform
    [ "$is_native" != true ] && log_info "Skipping Mosquitto (requires native compile)"
    [ "$is_native" = true ] && require_disk_space 10 "Mosquitto" && {
        local mosq_dir="${plat_dir}/mosquitto"
        if [ ! -f "${mosq_dir}/mosquitto" ]; then
            log_info "Downloading Mosquitto source..."
            local mosq_ver
            # Use tags endpoint (Mosquitto doesn't use GitHub Releases)
            mosq_ver=$(curl -sS "https://api.github.com/repos/eclipse-mosquitto/mosquitto/tags" 2>/dev/null \
                | grep '"name"' | grep -v 'rc\|alpha\|beta' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
            if [ -n "$mosq_ver" ]; then
                local mosq_url="https://mosquitto.org/files/source/mosquitto-${mosq_ver}.tar.gz"
                curl -L -o /tmp/mosquitto.tar.gz "$mosq_url" 2>/dev/null
                if [ -f /tmp/mosquitto.tar.gz ] && [ $(stat -c%s /tmp/mosquitto.tar.gz 2>/dev/null || echo 0) -gt 1000 ]; then
                    mkdir -p /tmp/mosquitto-build
                    tar -xzf /tmp/mosquitto.tar.gz -C /tmp/mosquitto-build --strip-components=1 2>/dev/null
                    if command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
                        (cd /tmp/mosquitto-build && make WITH_TLS=no WITH_CJSON=no WITH_DOCS=no -j$(nproc) 2>/dev/null)
                        mkdir -p "${mosq_dir}"
                        [ -f /tmp/mosquitto-build/src/mosquitto ] && mv /tmp/mosquitto-build/src/mosquitto "${mosq_dir}/mosquitto"
                        [ -f /tmp/mosquitto-build/client/mosquitto_pub ] && mv /tmp/mosquitto-build/client/mosquitto_pub "${mosq_dir}/mosquitto_pub"
                        [ -f /tmp/mosquitto-build/client/mosquitto_sub ] && mv /tmp/mosquitto-build/client/mosquitto_sub "${mosq_dir}/mosquitto_sub"
                        chmod +x "${mosq_dir}/"* 2>/dev/null
                        [ -f "${mosq_dir}/mosquitto" ] && log_ok "Mosquitto ${mosq_ver}: $(du -h "${mosq_dir}/mosquitto" | cut -f1)" || log_err "Mosquitto build failed"
                    else
                        log_warn "Mosquitto: gcc/make not found, skipping build (source saved)"
                        mkdir -p "${mosq_dir}"
                        mv /tmp/mosquitto-build "${mosq_dir}/source"
                    fi
                else
                    log_err "Mosquitto download failed"
                fi
                rm -f /tmp/mosquitto.tar.gz
                rm -rf /tmp/mosquitto-build
            else
                log_warn "Could not determine Mosquitto version"
            fi
        else
            log_info "Already have: Mosquitto"
        fi
    }

    # --- MQTT Explorer (~100MB, x86_64 AppImage — always download for the ark) ---
    require_disk_space 110 "MQTT Explorer" && {
        local mqtt_dir="${TOOLS_DIR}/linux-x86_64/mqtt-explorer"
        if [ ! -f "${mqtt_dir}/MQTT-Explorer.AppImage" ]; then
            local mqtt_url
            mqtt_url=$(curl -sS "https://api.github.com/repos/thomasnordquist/MQTT-Explorer/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*AppImage\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$mqtt_url" ]; then
                log_info "Downloading MQTT Explorer (x86_64 AppImage)..."
                mkdir -p "${mqtt_dir}"
                curl -L -o "${mqtt_dir}/MQTT-Explorer.AppImage" "$mqtt_url" 2>/dev/null
                chmod +x "${mqtt_dir}/MQTT-Explorer.AppImage"
                [ -s "${mqtt_dir}/MQTT-Explorer.AppImage" ] && log_ok "MQTT Explorer: $(du -h "${mqtt_dir}/MQTT-Explorer.AppImage" | cut -f1)" || log_err "MQTT Explorer download failed"
            else
                log_warn "Could not find MQTT Explorer release URL"
            fi
        else
            log_info "Already have: MQTT Explorer"
        fi
    }

    # --- SQLite CLI (~2MB) ---
    require_disk_space 5 "SQLite" && {
        local sqlite_dir="${plat_dir}/sqlite"
        if [ ! -f "${sqlite_dir}/sqlite3" ]; then
            mkdir -p "${sqlite_dir}"
            if [ "$arm64" != true ]; then
                # Prebuilt CLI available for x86_64
                local sqlite_url="https://www.sqlite.org/2024/sqlite-tools-linux-x64-3470200.zip"
                log_info "Downloading SQLite CLI (x86_64)..."
                curl -L -o /tmp/sqlite.zip "$sqlite_url" 2>/dev/null
                if [ -f /tmp/sqlite.zip ] && [ $(stat -c%s /tmp/sqlite.zip 2>/dev/null || echo 0) -gt 1000 ]; then
                    unzip -o /tmp/sqlite.zip -d /tmp/sqlite-tmp 2>/dev/null
                    find /tmp/sqlite-tmp -name 'sqlite3' -type f -exec mv {} "${sqlite_dir}/sqlite3" \; 2>/dev/null
                    chmod +x "${sqlite_dir}/sqlite3" 2>/dev/null
                fi
                rm -f /tmp/sqlite.zip
                rm -rf /tmp/sqlite-tmp
            else
                # Compile amalgamation for arm64 (only on native platform)
                if [ "$is_native" = true ]; then
                    log_info "Downloading SQLite amalgamation (arm64, will compile)..."
                    local sqlite_amal_url="https://www.sqlite.org/2024/sqlite-amalgamation-3470200.zip"
                    curl -L -o /tmp/sqlite-amal.zip "$sqlite_amal_url" 2>/dev/null
                    if [ -f /tmp/sqlite-amal.zip ] && command -v gcc >/dev/null 2>&1; then
                        unzip -o /tmp/sqlite-amal.zip -d /tmp/sqlite-amal 2>/dev/null
                        local amal_dir=$(find /tmp/sqlite-amal -name 'shell.c' -printf '%h\n' 2>/dev/null | head -1)
                        if [ -n "$amal_dir" ]; then
                            gcc -O2 -o "${sqlite_dir}/sqlite3" "${amal_dir}/shell.c" "${amal_dir}/sqlite3.c" -lpthread -ldl -lm 2>/dev/null
                        fi
                    fi
                    rm -f /tmp/sqlite-amal.zip
                    rm -rf /tmp/sqlite-amal
                else
                    log_info "SQLite: skipping ARM64 compile (not on native platform)"
                fi
            fi
            [ -f "${sqlite_dir}/sqlite3" ] && log_ok "SQLite: $(du -h "${sqlite_dir}/sqlite3" | cut -f1)" || log_err "SQLite install failed"
        else
            log_info "Already have: SQLite"
        fi
    }

    # --- Redis (~5MB, compile from source) --- requires native platform
    [ "$is_native" != true ] && log_info "Skipping Redis (requires native compile)"
    [ "$is_native" = true ] && require_disk_space 10 "Redis" && {
        local redis_dir="${plat_dir}/redis"
        if [ ! -f "${redis_dir}/redis-server" ]; then
            local redis_ver
            redis_ver=$(curl -sS "https://api.github.com/repos/redis/redis/releases/latest" 2>/dev/null \
                | grep '"tag_name"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
            if [ -n "$redis_ver" ]; then
                local redis_url="https://github.com/redis/redis/archive/refs/tags/${redis_ver}.tar.gz"
                log_info "Downloading Redis ${redis_ver} source..."
                curl -L -o /tmp/redis.tar.gz "$redis_url" 2>/dev/null
                if [ -f /tmp/redis.tar.gz ] && command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
                    mkdir -p /tmp/redis-build
                    tar -xzf /tmp/redis.tar.gz -C /tmp/redis-build --strip-components=1 2>/dev/null
                    log_info "Compiling Redis (this may take a moment)..."
                    (cd /tmp/redis-build && make -j$(nproc) MALLOC=libc 2>/dev/null)
                    mkdir -p "${redis_dir}"
                    for bin in redis-server redis-cli redis-benchmark; do
                        [ -f "/tmp/redis-build/src/${bin}" ] && mv "/tmp/redis-build/src/${bin}" "${redis_dir}/${bin}"
                    done
                    chmod +x "${redis_dir}/"* 2>/dev/null
                    [ -f "${redis_dir}/redis-server" ] && log_ok "Redis ${redis_ver}: $(du -h "${redis_dir}/redis-server" | cut -f1)" || log_err "Redis build failed"
                else
                    log_warn "Redis: gcc/make not found or download failed"
                fi
                rm -f /tmp/redis.tar.gz
                rm -rf /tmp/redis-build
            else
                log_warn "Could not determine Redis version"
            fi
        else
            log_info "Already have: Redis"
        fi
    }

    # --- PostgreSQL (~50MB, compile from source) --- requires native platform
    [ "$is_native" != true ] && log_info "Skipping PostgreSQL (requires native compile)"
    [ "$is_native" = true ] && require_disk_space 60 "PostgreSQL" && {
        local pg_dir="${plat_dir}/postgresql"
        if [ ! -f "${pg_dir}/bin/postgres" ]; then
            local pg_ver="17.2"
            if [ "$is_native" = true ] && command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
                log_info "Downloading PostgreSQL ${pg_ver} source..."
                curl -L -o /tmp/postgresql.tar.gz "https://ftp.postgresql.org/pub/source/v${pg_ver}/postgresql-${pg_ver}.tar.gz" 2>/dev/null
                if [ -f /tmp/postgresql.tar.gz ] && [ $(stat -c%s /tmp/postgresql.tar.gz 2>/dev/null || echo 0) -gt 1000 ]; then
                    mkdir -p /tmp/pg-build
                    tar -xzf /tmp/postgresql.tar.gz -C /tmp/pg-build --strip-components=1 2>/dev/null
                    log_info "Compiling PostgreSQL ${pg_ver} (this may take a moment)..."
                    (cd /tmp/pg-build && ./configure --prefix="${pg_dir}" --without-icu --without-readline 2>/dev/null && make -j$(nproc) 2>/dev/null && make install 2>/dev/null)
                    [ -f "${pg_dir}/bin/postgres" ] && log_ok "PostgreSQL ${pg_ver}: $(du -sh "${pg_dir}" | cut -f1)" || log_err "PostgreSQL compile failed"
                else
                    log_err "PostgreSQL source download failed"
                fi
                rm -f /tmp/postgresql.tar.gz
                rm -rf /tmp/pg-build
            else
                mkdir -p "${pg_dir}"
                log_info "PostgreSQL: saving INSTALL instructions (compile on target)"
                cat > "${pg_dir}/INSTALL.txt" << 'PGEOF'
PostgreSQL - Install from package manager or compile:

  # Debian/Ubuntu:
  sudo apt-get install postgresql postgresql-client

  # Or compile from source:
  curl -L https://ftp.postgresql.org/pub/source/v17.2/postgresql-17.2.tar.gz | tar xz
  cd postgresql-17.2
  ./configure --prefix=$HOME/postgresql
  make -j$(nproc) && make install
PGEOF
                log_info "PostgreSQL: INSTALL.txt created in ${pg_dir}"
            fi
        else
            log_info "Already have: PostgreSQL"
        fi
    }

    # --- Helix Editor (~15MB) ---
    require_disk_space 20 "Helix" && {
        local hx_dir="${plat_dir}/helix"
        if [ ! -f "${hx_dir}/hx" ]; then
            local hx_arch="aarch64"
            [ "$arm64" != true ] && hx_arch="x86_64"
            local hx_url
            hx_url=$(curl -sS "https://api.github.com/repos/helix-editor/helix/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*${hx_arch}.*linux.*tar.xz\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$hx_url" ]; then
                log_info "Downloading Helix (${arch_label})..."
                curl -L -o /tmp/helix.tar.xz "$hx_url" 2>/dev/null
                mkdir -p "${hx_dir}"
                tar -xJf /tmp/helix.tar.xz -C /tmp/ 2>/dev/null
                find /tmp -name 'hx' -type f -perm /111 -exec mv {} "${hx_dir}/hx" \; 2>/dev/null
                # Also grab runtime directory if present
                local hx_runtime=$(find /tmp -type d -name 'runtime' -path '*/helix*' 2>/dev/null | head -1)
                [ -d "$hx_runtime" ] && cp -r "$hx_runtime" "${hx_dir}/runtime"
                rm -f /tmp/helix.tar.xz
                rm -rf /tmp/helix-*
                [ -f "${hx_dir}/hx" ] && log_ok "Helix: $(du -h "${hx_dir}/hx" | cut -f1)" || log_err "Helix extract failed"
            else
                log_warn "Could not find Helix release URL"
            fi
        else
            log_info "Already have: Helix"
        fi
    }

    # --- VSCodium (~100MB) ---
    require_disk_space 120 "VSCodium" && {
        local vsc_dir="${plat_dir}/vscodium"
        if [ ! -f "${vsc_dir}/bin/codium" ]; then
            local vsc_arch="arm64"
            [ "$arm64" != true ] && vsc_arch="x64"
            local vsc_url
            vsc_url=$(curl -sS "https://api.github.com/repos/VSCodium/vscodium/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*VSCodium-linux-${vsc_arch}.*tar.gz\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$vsc_url" ]; then
                log_info "Downloading VSCodium (${arch_label})..."
                curl -L -o /tmp/vscodium.tar.gz "$vsc_url" 2>/dev/null
                if [ -f /tmp/vscodium.tar.gz ] && [ $(stat -c%s /tmp/vscodium.tar.gz 2>/dev/null || echo 0) -gt 1000 ]; then
                    mkdir -p "${vsc_dir}"
                    tar -xzf /tmp/vscodium.tar.gz -C "${vsc_dir}/" 2>/dev/null
                    [ -f "${vsc_dir}/bin/codium" ] && log_ok "VSCodium: $(du -sh "${vsc_dir}" | cut -f1)" || log_err "VSCodium extract failed"
                else
                    log_err "VSCodium download failed"
                fi
                rm -f /tmp/vscodium.tar.gz
            else
                log_warn "Could not find VSCodium release URL"
            fi
        else
            log_info "Already have: VSCodium"
        fi
    }

    # --- Miniforge (~80MB, .sh installer) ---
    require_disk_space 100 "Miniforge" && {
        local mf_dir="${plat_dir}/miniforge"
        local mf_arch="aarch64"
        [ "$arm64" != true ] && mf_arch="x86_64"
        if [ ! -f "${mf_dir}/bin/conda" ] && [ ! -f "${mf_dir}/Miniforge3-Linux-${mf_arch}.sh" ]; then
            local mf_url
            mf_url=$(curl -sS "https://api.github.com/repos/conda-forge/miniforge/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*Miniforge3-Linux-${mf_arch}\.sh\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$mf_url" ]; then
                log_info "Downloading Miniforge installer (${arch_label})..."
                curl -L -o /tmp/miniforge.sh "$mf_url" 2>/dev/null
                if [ -f /tmp/miniforge.sh ] && [ $(stat -c%s /tmp/miniforge.sh 2>/dev/null || echo 0) -gt 1000 ]; then
                    if [ "$is_native" = true ]; then
                        # Run installer on native platform
                        bash /tmp/miniforge.sh -b -p "${mf_dir}" 2>/dev/null
                        [ -f "${mf_dir}/bin/conda" ] && log_ok "Miniforge: $(du -sh "${mf_dir}" | cut -f1)" || log_err "Miniforge install failed"
                    else
                        # Cross-platform: save installer for target machine
                        mkdir -p "${mf_dir}"
                        mv /tmp/miniforge.sh "${mf_dir}/Miniforge3-Linux-${mf_arch}.sh"
                        chmod +x "${mf_dir}/Miniforge3-Linux-${mf_arch}.sh"
                        log_ok "Miniforge installer saved (run on target platform to install)"
                    fi
                else
                    log_err "Miniforge download failed"
                fi
                rm -f /tmp/miniforge.sh 2>/dev/null
            else
                log_warn "Could not find Miniforge release URL"
            fi
        else
            log_info "Already have: Miniforge"
        fi
    }

    # --- python-build-standalone (~30MB) --- repo: astral-sh/python-build-standalone
    require_disk_space 40 "python-build-standalone" && {
        local pbs_dir="${plat_dir}/python-standalone"
        if [ ! -f "${pbs_dir}/bin/python3" ]; then
            local pbs_arch="aarch64"
            [ "$arm64" != true ] && pbs_arch="x86_64"
            local pbs_url
            # Pattern: cpython-3.12.X+DATE-ARCH-unknown-linux-gnu-install_only_stripped.tar.gz
            pbs_url=$(curl -sS -L "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*3\.12.*${pbs_arch}.*linux-gnu.*install_only_stripped.*tar.gz\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$pbs_url" ]; then
                log_info "Downloading python-build-standalone (${arch_label})..."
                curl -L -o /tmp/python-standalone.tar.gz "$pbs_url" 2>/dev/null
                if [ -f /tmp/python-standalone.tar.gz ] && [ $(stat -c%s /tmp/python-standalone.tar.gz 2>/dev/null || echo 0) -gt 1000 ]; then
                    mkdir -p "${pbs_dir}"
                    tar -xzf /tmp/python-standalone.tar.gz -C "${pbs_dir}/" --strip-components=1 2>/dev/null
                    [ -f "${pbs_dir}/bin/python3" ] && log_ok "Python standalone: $(du -sh "${pbs_dir}" | cut -f1)" || log_err "python-build-standalone extract failed"
                else
                    log_err "python-build-standalone download failed"
                fi
                rm -f /tmp/python-standalone.tar.gz
            else
                log_warn "Could not find python-build-standalone release URL"
            fi
        else
            log_info "Already have: python-build-standalone"
        fi
    }

    # --- Blender (~300MB, x86_64 binary — always download for the ark) ---
    require_disk_space 350 "Blender" && {
        local blender_dir="${TOOLS_DIR}/linux-x86_64/blender"
        if [ ! -f "${blender_dir}/blender" ]; then
            local blender_ver="4.4.0"
            local blender_url="https://download.blender.org/release/Blender${blender_ver%.*}/blender-${blender_ver}-linux-x64.tar.xz"
            log_info "Downloading Blender ${blender_ver} (linux-x86_64)..."
            mkdir -p "${blender_dir}"
            curl -L -o /tmp/blender.tar.xz "$blender_url" 2>/dev/null
            if [ -f /tmp/blender.tar.xz ] && [ $(stat -c%s /tmp/blender.tar.xz 2>/dev/null || echo 0) -gt 10000 ]; then
                tar -xJf /tmp/blender.tar.xz -C /tmp/ 2>/dev/null
                local bdir=$(find /tmp -maxdepth 1 -name "blender-*-linux*" -type d | head -1)
                if [ -n "$bdir" ] && [ -f "${bdir}/blender" ]; then
                    mv "${bdir}"/* "${blender_dir}/" 2>/dev/null
                    rm -rf "${bdir}"
                    chmod +x "${blender_dir}/blender" 2>/dev/null
                    log_ok "Blender ${blender_ver}: $(du -sh "${blender_dir}" | cut -f1)"
                else
                    log_err "Blender extraction failed"
                fi
                rm -f /tmp/blender.tar.xz
            else
                log_err "Blender download failed"
                rm -f /tmp/blender.tar.xz
            fi
        else
            log_info "Already have: Blender"
        fi
    }

    # --- FreeCAD (~700MB AppImage, x86_64 binary — always download for the ark) ---
    require_disk_space 750 "FreeCAD" && {
        local freecad_dir="${TOOLS_DIR}/linux-x86_64/FreeCAD"
        if [ ! -f "${freecad_dir}/bin/FreeCADCmd" ] && [ ! -f "${freecad_dir}/FreeCAD.AppImage" ]; then
            log_info "Downloading FreeCAD AppImage (linux-x86_64)..."
            mkdir -p "${freecad_dir}/bin"
            local freecad_url
            freecad_url=$(curl -sS "https://api.github.com/repos/FreeCAD/FreeCAD-Bundle/releases/latest" 2>/dev/null \
                | grep "browser_download_url.*Linux-x86_64.*AppImage\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
            if [ -n "$freecad_url" ]; then
                curl -L -o "${freecad_dir}/FreeCAD.AppImage" "$freecad_url" 2>/dev/null
                if [ -f "${freecad_dir}/FreeCAD.AppImage" ] && [ $(stat -c%s "${freecad_dir}/FreeCAD.AppImage" 2>/dev/null || echo 0) -gt 10000 ]; then
                    chmod +x "${freecad_dir}/FreeCAD.AppImage"
                    ln -sf ../FreeCAD.AppImage "${freecad_dir}/bin/FreeCADCmd" 2>/dev/null
                    log_ok "FreeCAD: $(du -sh "${freecad_dir}/FreeCAD.AppImage" | cut -f1)"
                else
                    log_err "FreeCAD download failed (file too small)"
                    rm -f "${freecad_dir}/FreeCAD.AppImage"
                fi
            else
                log_err "FreeCAD: could not resolve download URL from GitHub"
            fi
        else
            log_info "Already have: FreeCAD"
        fi
    }

    # --- KiCad (~200MB AppImage, x86_64 — always download for the ark) ---
    require_disk_space 250 "KiCad" && {
        local kicad_dir="${TOOLS_DIR}/linux-x86_64/kicad"
        if [ ! -f "${kicad_dir}/KiCad.AppImage" ]; then
            local kicad_ver="8.0.9"
            local kicad_url="https://sourceforge.net/projects/kicad-appimage/files/v8/KiCad-${kicad_ver}.glibc2.29-x86_64.AppImage/download"
            log_info "Downloading KiCad ${kicad_ver} AppImage (linux-x86_64)..."
            mkdir -p "${kicad_dir}"
            curl -L -o "${kicad_dir}/KiCad.AppImage" "$kicad_url" 2>/dev/null
            if [ -f "${kicad_dir}/KiCad.AppImage" ] && [ $(stat -c%s "${kicad_dir}/KiCad.AppImage" 2>/dev/null || echo 0) -gt 10000 ]; then
                chmod +x "${kicad_dir}/KiCad.AppImage"
                log_ok "KiCad ${kicad_ver}: $(du -h "${kicad_dir}/KiCad.AppImage" | cut -f1)"
            else
                log_err "KiCad download failed (file too small or missing)"
                rm -f "${kicad_dir}/KiCad.AppImage"
            fi
        else
            log_info "Already have: KiCad"
        fi
    }

    # --- Disk space summary ---
    echo ""
    local budget=$(check_disk_space)
    if [ "$budget" -gt 0 ]; then
        log_info "Disk budget remaining: ${budget}GB (after ${DISK_BUFFER_GB}GB buffer)"
    else
        log_warn "Disk budget EXCEEDED: ${budget}GB past ${DISK_BUFFER_GB}GB buffer!"
    fi
}

###############################################################################
# Asset Updates (logos, samples)
###############################################################################

update_assets() {
    log "============================================================"
    log "Updating Tool Logos & Assets"
    log "============================================================"

    mkdir -p "$LOGOS_DIR" "$SAMPLES_DIR"

    # Download GitHub avatar/logos for each project (small PNGs)
    download_logo() {
        local org="$1" repo="$2" filename="$3"
        local dest="${LOGOS_DIR}/${filename}"
        if [ -f "$dest" ]; then
            log_info "Already have: ${filename}"
            return
        fi
        # Use GitHub's opengraph image or org avatar
        local url="https://github.com/${org}.png?size=128"
        curl -sS -L -o "$dest" "$url" 2>/dev/null
        if [ -f "$dest" ] && [ -s "$dest" ]; then
            log_ok "Logo: ${filename}"
        else
            rm -f "$dest" 2>/dev/null
            log_warn "Could not download: ${filename}"
        fi
    }

    download_logo "ggml-org" "llama.cpp" "llama-cpp.png"
    download_logo "ggml-org" "whisper.cpp" "whisper-cpp.png"
    download_logo "rhasspy" "piper" "piper.png"
    download_logo "leejet" "stable-diffusion.cpp" "sd-cpp.png"
    download_logo "microsoft" "onnxruntime" "onnxruntime.png"
    download_logo "FFmpeg" "FFmpeg" "ffmpeg.png"
    download_logo "alphacep" "vosk-api" "vosk.png"
    download_logo "ollama" "ollama" "ollama.png"
    download_logo "meta-llama" "" "meta.png"
    download_logo "QwenLM" "" "qwen.png"
    download_logo "deepseek-ai" "" "deepseek.png"
    download_logo "microsoft" "" "microsoft.png"
    download_logo "google" "" "google.png"
    download_logo "NVIDIA" "" "nvidia.png"
    download_logo "mistralai" "" "mistral.png"

    # Create a sample TTS text file for demos
    if [ ! -f "${SAMPLES_DIR}/sample-text.txt" ]; then
        cat > "${SAMPLES_DIR}/sample-text.txt" << 'EOF'
Welcome to Val Ark, the complete offline AI toolkit.
This is a sample text for testing text-to-speech engines.
Piper TTS can synthesize this at 10 to 20 times faster than real-time.
Try different voices and languages for your applications.
EOF
        log_ok "Created: samples/sample-text.txt"
    fi

    # Create sample prompts for image generation
    if [ ! -f "${SAMPLES_DIR}/image-prompts.txt" ]; then
        cat > "${SAMPLES_DIR}/image-prompts.txt" << 'EOF'
a serene mountain landscape at golden hour, photorealistic, 8k
cyberpunk city street at night with neon signs, rain reflections
a cute robot reading a book in a cozy library, digital art
abstract fluid art with vibrant blue and purple gradients
a medieval castle on a cliff overlooking the ocean, fantasy art
EOF
        log_ok "Created: samples/image-prompts.txt"
    fi

    echo ""
}

###############################################################################
# Version Check (dry run)
###############################################################################

check_versions() {
    log "============================================================"
    log "Checking Latest Versions"
    log "============================================================"

    check_repo() {
        local repo="$1" label="$2"
        local tag=$(curl -sS "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
        if [ -n "$tag" ]; then
            echo -e "  ${GREEN}${label}${NC}: ${tag}"
        else
            echo -e "  ${YELLOW}${label}${NC}: could not resolve"
        fi
    }

    check_repo "ollama/ollama" "Ollama"
    check_repo "ggml-org/llama.cpp" "llama.cpp"
    check_repo "ggml-org/whisper.cpp" "whisper.cpp"
    check_repo "rhasspy/piper" "Piper TTS"
    check_repo "leejet/stable-diffusion.cpp" "stable-diffusion.cpp"
    check_repo "microsoft/onnxruntime" "ONNX Runtime"
    check_repo "alphacep/vosk-api" "Vosk"

    echo ""
}

###############################################################################
# Model File Paths Reference
###############################################################################

show_model_paths() {
    echo ""
    echo "=================================================================="
    echo "  Model File Locations by Platform & Tool"
    echo "=================================================================="
    echo ""

    echo -e "${CYAN}=== Ollama ===${NC}"
    echo "  Linux:   ~/.ollama/models/"
    echo "  macOS:   ~/.ollama/models/"
    echo "  Windows: C:\\Users\\<user>\\.ollama\\models\\"
    echo "  Custom:  Set OLLAMA_MODELS environment variable"
    echo ""

    echo -e "${CYAN}=== llama.cpp (GGUF models) ===${NC}"
    echo "  All platforms: Pass model path directly with -m flag"
    echo "  Recommended structure:"
    echo "    ./models/llm/<family>/<model>.gguf"
    echo "  Examples:"
    echo "    ./models/llm/qwen2.5-32b/Qwen2.5-32B-Instruct-Q4_K_M.gguf"
    echo "    ./models/llm/llama-3.1-8b/Llama-3.1-8B-Instruct-Q8_0.gguf"
    echo ""

    echo -e "${CYAN}=== whisper.cpp (GGML models) ===${NC}"
    echo "  All platforms: Pass model path directly with -m flag"
    echo "  Recommended structure:"
    echo "    ./models/stt/whisper-ggml/ggml-<model>.bin"
    echo "  Examples:"
    echo "    ./models/stt/whisper-ggml/ggml-large-v3-turbo-q5_0.bin"
    echo "    ./models/stt/whisper-ggml/ggml-base.bin"
    echo ""

    echo -e "${CYAN}=== Piper TTS (ONNX models) ===${NC}"
    echo "  All platforms: Pass model path with --model flag"
    echo "  Each voice needs TWO files: .onnx + .onnx.json"
    echo "  Recommended structure:"
    echo "    ./models/tts/piper/<voice>.onnx"
    echo "    ./models/tts/piper/<voice>.onnx.json"
    echo "  Download voices from: https://github.com/rhasspy/piper/blob/master/VOICES.md"
    echo ""

    echo -e "${CYAN}=== stable-diffusion.cpp (SafeTensors/GGUF) ===${NC}"
    echo "  All platforms: Pass model path with -m flag"
    echo "  Recommended structure:"
    echo "    ./models/image/<family>/<model>.safetensors"
    echo "  LoRA adapters: --lora path/to/lora.safetensors"
    echo "  VAE (optional): --vae path/to/vae.safetensors"
    echo ""

    echo -e "${CYAN}=== ONNX Runtime (Kokoro, Moonshine, etc.) ===${NC}"
    echo "  All platforms: Models loaded via Python/C++ API"
    echo "  Recommended structure:"
    echo "    ./models/tts/kokoro/kokoro-v0.19.onnx"
    echo "    ./models/stt/moonshine/"
    echo ""

    echo -e "${CYAN}=== Vosk (Kaldi models) ===${NC}"
    echo "  All platforms: Pass model directory path"
    echo "  Recommended structure:"
    echo "    ./models/stt/vosk/vosk-model-en-us-0.22/"
    echo "    ./models/stt/vosk/vosk-model-small-en-us-0.15/"
    echo ""

    echo -e "${CYAN}=== Environment Variables ===${NC}"
    echo "  OLLAMA_MODELS     - Ollama model storage path"
    echo "  LLAMA_CACHE       - llama.cpp model cache (if using HF download)"
    echo "  HF_HOME           - Hugging Face cache (~/.cache/huggingface)"
    echo "  XDG_DATA_HOME     - Linux data directory standard"
    echo ""
}

###############################################################################
# Link AI engine binaries from models tools into project tools + web-ui symlinks
###############################################################################

MODELS_TOOLS="/home/uat-admin/models/tools"

link_tools() {
    log "============================================================"
    log "Linking AI engine binaries & web-ui paths"
    log "============================================================"

    # Link AI engine binaries from models/tools into project tools
    local arm64_dir="${TOOLS_DIR}/linux-arm64"
    local x86_dir="${TOOLS_DIR}/linux-x86_64"
    local mac_dir="${TOOLS_DIR}/macos-arm64"
    local win_dir="${TOOLS_DIR}/windows-x64"
    mkdir -p "$arm64_dir" "$x86_dir" "$mac_dir" "$win_dir"

    # llama.cpp
    [ -f "${MODELS_TOOLS}/llama.cpp/linux-arm64/llama-server" ] && \
        ln -sf "${MODELS_TOOLS}/llama.cpp/linux-arm64/llama-server" "${arm64_dir}/llama-server" 2>/dev/null
    [ -f "${MODELS_TOOLS}/llama.cpp/linux-x86_64/llama-server" ] && \
        ln -sf "${MODELS_TOOLS}/llama.cpp/linux-x86_64/llama-server" "${x86_dir}/llama-server" 2>/dev/null
    [ -f "${MODELS_TOOLS}/llama.cpp/macos-arm64/llama-server" ] && \
        ln -sf "${MODELS_TOOLS}/llama.cpp/macos-arm64/llama-server" "${mac_dir}/llama-server" 2>/dev/null
    [ -f "${MODELS_TOOLS}/llama.cpp/windows-x64/llama-server.exe" ] && \
        ln -sf "${MODELS_TOOLS}/llama.cpp/windows-x64/llama-server.exe" "${win_dir}/llama-server.exe" 2>/dev/null

    # whisper.cpp (no linux prebuilt — source-only; Windows has prebuilt)
    [ -f "${MODELS_TOOLS}/whisper.cpp/linux-arm64/whisper-cli" ] && \
        ln -sf "${MODELS_TOOLS}/whisper.cpp/linux-arm64/whisper-cli" "${arm64_dir}/whisper-cli" 2>/dev/null
    [ -f "${MODELS_TOOLS}/whisper.cpp/linux-x86_64/whisper-cli" ] && \
        ln -sf "${MODELS_TOOLS}/whisper.cpp/linux-x86_64/whisper-cli" "${x86_dir}/whisper-cli" 2>/dev/null
    [ -f "${MODELS_TOOLS}/whisper.cpp/windows-x64/whisper-cli.exe" ] && \
        ln -sf "${MODELS_TOOLS}/whisper.cpp/windows-x64/whisper-cli.exe" "${win_dir}/whisper-cli.exe" 2>/dev/null

    # stable-diffusion.cpp
    [ -f "${MODELS_TOOLS}/stable-diffusion.cpp/linux-arm64/sd-cli" ] && \
        ln -sf "${MODELS_TOOLS}/stable-diffusion.cpp/linux-arm64/sd-cli" "${arm64_dir}/sd-cli" 2>/dev/null
    [ -f "${MODELS_TOOLS}/stable-diffusion.cpp/linux-x86_64/sd-cli" ] && \
        ln -sf "${MODELS_TOOLS}/stable-diffusion.cpp/linux-x86_64/sd-cli" "${x86_dir}/sd-cli" 2>/dev/null
    [ -f "${MODELS_TOOLS}/stable-diffusion.cpp/macos-arm64/sd-cli" ] && \
        ln -sf "${MODELS_TOOLS}/stable-diffusion.cpp/macos-arm64/sd-cli" "${mac_dir}/sd-cli" 2>/dev/null
    [ -f "${MODELS_TOOLS}/stable-diffusion.cpp/windows-x64/sd-cli.exe" ] && \
        ln -sf "${MODELS_TOOLS}/stable-diffusion.cpp/windows-x64/sd-cli.exe" "${win_dir}/sd-cli.exe" 2>/dev/null

    # onnxruntime
    [ -d "${MODELS_TOOLS}/onnxruntime/linux-arm64" ] && \
        ln -sfn "${MODELS_TOOLS}/onnxruntime/linux-arm64" "${arm64_dir}/onnxruntime" 2>/dev/null
    [ -d "${MODELS_TOOLS}/onnxruntime/linux-x86_64" ] && \
        ln -sfn "${MODELS_TOOLS}/onnxruntime/linux-x86_64" "${x86_dir}/onnxruntime" 2>/dev/null
    [ -d "${MODELS_TOOLS}/onnxruntime/macos-arm64" ] && \
        ln -sfn "${MODELS_TOOLS}/onnxruntime/macos-arm64" "${mac_dir}/onnxruntime" 2>/dev/null
    [ -d "${MODELS_TOOLS}/onnxruntime/windows-x64" ] && \
        ln -sfn "${MODELS_TOOLS}/onnxruntime/windows-x64" "${win_dir}/onnxruntime" 2>/dev/null

    # vosk
    [ -d "${MODELS_TOOLS}/vosk/linux-arm64" ] && \
        ln -sfn "${MODELS_TOOLS}/vosk/linux-arm64" "${arm64_dir}/vosk" 2>/dev/null
    [ -d "${MODELS_TOOLS}/vosk/linux-x86_64" ] && \
        ln -sfn "${MODELS_TOOLS}/vosk/linux-x86_64" "${x86_dir}/vosk" 2>/dev/null
    [ -d "${MODELS_TOOLS}/vosk/windows-x64" ] && \
        ln -sfn "${MODELS_TOOLS}/vosk/windows-x64" "${win_dir}/vosk" 2>/dev/null

    # bitnet
    [ -d "${MODELS_TOOLS}/bitnet/source" ] && \
        ln -sfn "${MODELS_TOOLS}/bitnet/source" "${arm64_dir}/bitnet" 2>/dev/null

    # Web-UI symlinks (for the dev server to serve tools/sources/assets)
    local webui="${PROJECT_ROOT}/web-ui"
    [ -d "$webui" ] && {
        ln -sfn ../tools "$webui/tools" 2>/dev/null
        ln -sfn ../sources "$webui/sources" 2>/dev/null
        ln -sfn ../assets "$webui/assets" 2>/dev/null
    }

    log_ok "Tool symlinks updated"
}

###############################################################################
# Main
###############################################################################

case "${1:-all}" in
    ollama)  update_ollama ;;
    tools)   update_tools ;;
    apps)    update_apps ;;
    apps-all)
        # Download apps for all supported Linux platforms
        update_apps "linux-arm64"
        update_apps "linux-x86_64"
        ;;
    sources) clone_sources ;;
    assets)  update_assets ;;
    check)   check_versions ;;
    paths)   show_model_paths ;;
    disk)
        budget=$(check_disk_space)
        avail_kb=$(df --output=avail "${PROJECT_ROOT}" 2>/dev/null | tail -1)
        avail_gb=$((avail_kb / 1024 / 1024))
        echo "Available: ${avail_gb}GB | Buffer: ${DISK_BUFFER_GB}GB | Budget: ${budget}GB"
        du -sh "${PROJECT_ROOT}"/*/
        ;;
    cron)
        # Install weekly cron job
        CRON_LINE="0 3 * * 0 cd ${PROJECT_ROOT} && ./start.sh update >> /var/log/val-ark-update.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "val-ark-update"; echo "$CRON_LINE") | crontab -
        log_ok "Weekly cron job installed (Sundays at 3 AM)"
        echo "    ${CRON_LINE}"
        ;;
    links)   link_tools ;;
    all)
        update_ollama
        update_tools
        update_apps
        clone_sources
        update_assets
        link_tools
        check_versions
        show_model_paths
        echo ""
        log_ok "Update complete!"
        ;;
    *)
        echo "Usage: $0 [all|ollama|tools|apps|apps-all|sources|assets|links|check|paths|disk|cron]"
        echo ""
        echo "  all      - Run full update (Ollama + tools + apps + sources + assets + links)"
        echo "  ollama   - Download latest Ollama installers (append-only)"
        echo "  tools    - Download latest tool binaries (FFmpeg, Piper, Vosk, ONNX Runtime)"
        echo "  apps     - Download apps & dev tools for current platform"
        echo "  apps-all - Download apps for all Linux platforms (arm64 + x86_64)"
        echo "  sources  - Clone/pull llama.cpp, whisper.cpp, sd.cpp source repos"
        echo "  assets   - Update tool logos and sample files"
        echo "  links    - Create symlinks (AI engine binaries + web-ui paths)"
        echo "  check    - Check for new tool versions (dry run)"
        echo "  paths    - Show model file paths for each platform/tool"
        echo "  cron     - Install weekly cron job (Sundays 3 AM)"
        exit 1
        ;;
esac
