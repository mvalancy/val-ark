#!/bin/bash
###############################################################################
# Val Ark - Comprehensive AI Model Download Script
# Target: ~500GB of models across LLMs, TTS, STT, Vision, Image Generation
#
# Features:
# - NEVER aborts on errors - continues downloading remaining models
# - Resume-capable downloads (uses wget -c)
# - Retry logic with exponential backoff
# - Detailed logging with timestamps and counters
# - URL pre-validation pass (--validate flag)
# - Per-download and total elapsed time tracking
# - Failed downloads tracked for later retry
###############################################################################

# Only fail on pipe errors, NOT on individual command failures
set -o pipefail

# Configuration
MODEL_ROOT="/home/uat-admin/models"
LOG_DIR="${MODEL_ROOT}/logs"
LOG_FILE="${LOG_DIR}/download_$(date +%Y%m%d_%H%M%S).log"
MAX_RETRIES=5
RETRY_DELAY=30
HF_CLI="/home/uat-admin/.local/bin/hf"
SCRIPT_START=$(date +%s)

# Counters
DOWNLOAD_SUCCESS=0
DOWNLOAD_FAILED=0
DOWNLOAD_SKIPPED=0
DOWNLOAD_TOTAL=0
VALIDATE_OK=0
VALIDATE_FAIL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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
log_detail() { log "${CYAN}DETAIL${NC}: $*"; }

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

# Download a single file from HuggingFace with retries
# NEVER returns non-zero to caller - tracks failures internally
hf_download_file() {
    local repo="$1"
    local filename="$2"
    local dest_dir="$3"
    local attempt=1
    local dl_start=$(date +%s)

    ensure_dir "$dest_dir"

    local dest_file="${dest_dir}/${filename##*/}"

    # Check if file already exists and has non-zero size
    if [ -f "$dest_file" ] && [ -s "$dest_file" ]; then
        log_info "Already exists: ${filename} ($(du -h "$dest_file" 2>/dev/null | cut -f1)) - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        return 0
    fi

    # Remove empty/partial files from previous failed attempts
    if [ -f "$dest_file" ] && [ ! -s "$dest_file" ]; then
        rm -f "$dest_file" 2>/dev/null || true
        log_detail "Removed empty partial file: $dest_file"
    fi

    local url="https://huggingface.co/${repo}/resolve/main/${filename}"

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading ${repo}/${filename} (attempt ${attempt}/${MAX_RETRIES})"

        local wget_output
        wget_output=$(wget -c --progress=dot:giga --timeout=60 --tries=1 \
            "$url" \
            -O "$dest_file" 2>&1)
        local wget_status=$?

        # Log wget output
        echo "$wget_output" | tail -5 >> "$LOG_FILE" 2>/dev/null || true

        if [ $wget_status -eq 0 ] && [ -f "$dest_file" ] && [ -s "$dest_file" ]; then
            local size=$(du -h "$dest_file" 2>/dev/null | cut -f1)
            log_success "Downloaded: ${filename} (${size}) in $(elapsed_since $dl_start)"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            print_progress
            return 0
        else
            log_warn "Attempt ${attempt} failed for ${filename} (wget exit code: ${wget_status})"
            # Check for HTTP errors in wget output
            if echo "$wget_output" | grep -qi "404\|not found"; then
                log_error "HTTP 404 - File not found: ${repo}/${filename}"
                break  # Don't retry 404s
            fi
            if echo "$wget_output" | grep -qi "401\|403\|unauthorized\|forbidden"; then
                log_error "HTTP 401/403 - Access denied: ${repo}/${filename} (may require login)"
                break  # Don't retry auth errors
            fi
            attempt=$((attempt + 1))
            if [ $attempt -le $MAX_RETRIES ]; then
                local delay=$((RETRY_DELAY * (attempt - 1)))  # Linear backoff
                log_info "Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done

    log_error "FAILED after all attempts: ${repo}/${filename}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${repo}/${filename}" >> "${LOG_DIR}/failed_downloads.txt"
    DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    print_progress
    return 0  # Always return 0 so script continues
}

# Download an entire HuggingFace repo using hf CLI
# NEVER returns non-zero to caller
hf_download_repo() {
    local repo="$1"
    local dest_dir="$2"
    local include_pattern="${3:-}"
    local attempt=1
    local dl_start=$(date +%s)

    ensure_dir "$dest_dir"

    # Check if directory already has content
    local existing_files=$(find "$dest_dir" -type f 2>/dev/null | wc -l)
    if [ "$existing_files" -gt 2 ]; then
        local existing_size=$(du -sh "$dest_dir" 2>/dev/null | cut -f1)
        log_info "Repo already has ${existing_files} files (${existing_size}): ${repo} - attempting resume/update"
    fi

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading repo ${repo} (attempt ${attempt}/${MAX_RETRIES})"

        local cmd_output
        if [ -n "$include_pattern" ]; then
            cmd_output=$($HF_CLI download "$repo" --local-dir "$dest_dir" --include "$include_pattern" 2>&1)
        else
            cmd_output=$($HF_CLI download "$repo" --local-dir "$dest_dir" 2>&1)
        fi
        local cmd_status=$?

        # Log output
        echo "$cmd_output" | tail -10 >> "$LOG_FILE" 2>/dev/null || true

        if [ $cmd_status -eq 0 ]; then
            local size=$(du -sh "$dest_dir" 2>/dev/null | cut -f1)
            log_success "Downloaded repo: ${repo} (${size}) in $(elapsed_since $dl_start)"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            print_progress
            return 0
        else
            log_warn "Attempt ${attempt} failed for repo ${repo} (exit code: ${cmd_status})"
            # Check for common errors
            if echo "$cmd_output" | grep -qi "401\|403\|gated\|access"; then
                log_error "Access denied for repo: ${repo} (may require HF login or model agreement)"
                break
            fi
            if echo "$cmd_output" | grep -qi "404\|not found\|does not exist"; then
                log_error "Repo not found: ${repo}"
                break
            fi
            attempt=$((attempt + 1))
            if [ $attempt -le $MAX_RETRIES ]; then
                local delay=$((RETRY_DELAY * (attempt - 1)))
                log_info "Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done

    log_error "FAILED repo download: ${repo}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] REPO: ${repo}" >> "${LOG_DIR}/failed_downloads.txt"
    DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    print_progress
    return 0  # Always return 0 so script continues
}

# Download a file from a direct URL with retries
# NEVER returns non-zero to caller
download_url() {
    local url="$1"
    local dest_path="$2"
    local attempt=1
    local dl_start=$(date +%s)

    ensure_dir "$(dirname "$dest_path")"

    if [ -f "$dest_path" ] && [ -s "$dest_path" ]; then
        log_info "Already exists: $(basename "$dest_path") ($(du -h "$dest_path" 2>/dev/null | cut -f1)) - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1))
        return 0
    fi

    # Remove empty files
    if [ -f "$dest_path" ] && [ ! -s "$dest_path" ]; then
        rm -f "$dest_path" 2>/dev/null || true
    fi

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading $(basename "$dest_path") (attempt ${attempt}/${MAX_RETRIES})"

        local wget_output
        wget_output=$(wget -c --progress=dot:giga --timeout=60 --tries=1 \
            "$url" -O "$dest_path" 2>&1)
        local wget_status=$?

        echo "$wget_output" | tail -5 >> "$LOG_FILE" 2>/dev/null || true

        if [ $wget_status -eq 0 ] && [ -f "$dest_path" ] && [ -s "$dest_path" ]; then
            local size=$(du -h "$dest_path" 2>/dev/null | cut -f1)
            log_success "Downloaded: $(basename "$dest_path") (${size}) in $(elapsed_since $dl_start)"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            print_progress
            return 0
        else
            log_warn "Attempt ${attempt} failed for $(basename "$dest_path") (exit: ${wget_status})"
            if echo "$wget_output" | grep -qi "404\|not found"; then
                log_error "HTTP 404: $url"
                break
            fi
            if echo "$wget_output" | grep -qi "401\|403"; then
                log_error "HTTP 401/403: $url"
                break
            fi
            attempt=$((attempt + 1))
            if [ $attempt -le $MAX_RETRIES ]; then
                local delay=$((RETRY_DELAY * (attempt - 1)))
                log_info "Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done

    log_error "FAILED: $url"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $url" >> "${LOG_DIR}/failed_downloads.txt"
    DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    print_progress
    return 0  # Always return 0 so script continues
}

###############################################################################
# URL Pre-Validation
###############################################################################

validate_single_url() {
    local url="$1"
    local label="$2"

    local http_code
    http_code=$(wget --spider --timeout=10 --tries=1 -S "$url" 2>&1 | grep "HTTP/" | tail -1 | awk '{print $2}')

    if [ -z "$http_code" ]; then
        # Try curl as fallback
        http_code=$(curl -sI --max-time 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    fi

    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "301" ] || [ "$http_code" = "307" ]; then
        echo -e "  ${GREEN}OK${NC} ($http_code): $label"
        VALIDATE_OK=$((VALIDATE_OK + 1))
        return 0
    else
        echo -e "  ${RED}FAIL${NC} ($http_code): $label"
        echo "  VALIDATE_FAIL: $label -> HTTP $http_code" >> "$LOG_FILE"
        VALIDATE_FAIL=$((VALIDATE_FAIL + 1))
        return 1
    fi
}

validate_all_urls() {
    echo ""
    echo "=================================================================="
    echo "  URL Pre-Validation Pass"
    echo "  Checking all download URLs with HEAD requests..."
    echo "=================================================================="
    echo ""

    VALIDATE_OK=0
    VALIDATE_FAIL=0
    local val_start=$(date +%s)

    # --- LLM GGUF files (HuggingFace) ---
    echo "=== LLM Models (HuggingFace GGUF) ==="
    local hf_files=(
        "unsloth/Nemotron-3-Nano-30B-A3B-GGUF|Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf"
        "unsloth/Nemotron-3-Nano-30B-A3B-GGUF|Nemotron-3-Nano-30B-A3B-Q8_0.gguf"
        "bartowski/nvidia_NVIDIA-Nemotron-Nano-12B-v2-GGUF|nvidia_NVIDIA-Nemotron-Nano-12B-v2-Q8_0.gguf"
        "bartowski/nvidia_NVIDIA-Nemotron-Nano-9B-v2-GGUF|nvidia_NVIDIA-Nemotron-Nano-9B-v2-Q8_0.gguf"
        "bartowski/Nemotron-Mini-4B-Instruct-GGUF|Nemotron-Mini-4B-Instruct-Q8_0.gguf"
        "bartowski/Qwen2.5-32B-Instruct-GGUF|Qwen2.5-32B-Instruct-Q4_K_M.gguf"
        "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF|Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf"
        "bartowski/Qwen2.5-14B-Instruct-GGUF|Qwen2.5-14B-Instruct-Q8_0.gguf"
        "bartowski/Qwen2.5-14B-Instruct-GGUF|Qwen2.5-14B-Instruct-Q6_K.gguf"
        "bartowski/Qwen_QwQ-32B-GGUF|Qwen_QwQ-32B-Q4_K_M.gguf"
        "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
        "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF|DeepSeek-R1-Distill-Qwen-14B-Q8_0.gguf"
        "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF|DeepSeek-R1-Distill-Qwen-14B-Q6_K.gguf"
        "bartowski/phi-4-GGUF|phi-4-Q8_0.gguf"
        "bartowski/microsoft_Phi-4-reasoning-GGUF|microsoft_Phi-4-reasoning-Q8_0.gguf"
        "bartowski/microsoft_Phi-4-reasoning-plus-GGUF|microsoft_Phi-4-reasoning-plus-Q8_0.gguf"
        "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"
        "bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q8_0.gguf"
        "bartowski/Llama-3.2-1B-Instruct-GGUF|Llama-3.2-1B-Instruct-Q8_0.gguf"
        "bartowski/Mistral-Nemo-Instruct-2407-GGUF|Mistral-Nemo-Instruct-2407-Q8_0.gguf"
        "bartowski/Mistral-Nemo-Instruct-2407-GGUF|Mistral-Nemo-Instruct-2407-Q6_K.gguf"
        "bartowski/gemma-2-27b-it-GGUF|gemma-2-27b-it-Q4_K_M.gguf"
        "bartowski/gemma-2-9b-it-GGUF|gemma-2-9b-it-Q8_0.gguf"
        "bartowski/Llama-3.1-Nemotron-70B-Instruct-HF-GGUF|Llama-3.1-Nemotron-70B-Instruct-HF-IQ2_XXS.gguf"
        "bartowski/nvidia_Llama-3_3-Nemotron-Super-49B-v1_5-GGUF|nvidia_Llama-3_3-Nemotron-Super-49B-v1_5-IQ3_XXS.gguf"
        "bartowski/google_gemma-3-27b-it-GGUF|google_gemma-3-27b-it-Q4_K_M.gguf"
        "bartowski/Qwen2.5-32B-Instruct-GGUF|Qwen2.5-32B-Instruct-Q5_K_M.gguf"
        "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q5_K_M.gguf"
        "bartowski/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-IQ2_XXS.gguf"
    )

    for entry in "${hf_files[@]}"; do
        local repo="${entry%%|*}"
        local file="${entry##*|}"
        local url="https://huggingface.co/${repo}/resolve/main/${file}"
        validate_single_url "$url" "${repo}/${file}" || true
    done

    # --- Whisper GGML files ---
    echo ""
    echo "=== Whisper.cpp Models (GGML) ==="
    local WHISPER_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    local whisper_files=(
        "ggml-tiny.en-q8_0.bin"
        "ggml-base.en-q8_0.bin"
        "ggml-small.en-q8_0.bin"
        "ggml-small-q8_0.bin"
        "ggml-medium-q5_0.bin"
        "ggml-medium.en-q5_0.bin"
        "ggml-medium-q8_0.bin"
        "ggml-large-v2-q5_0.bin"
        "ggml-large-v3-q5_0.bin"
        "ggml-large-v3-turbo.bin"
        "ggml-large-v3-turbo-q5_0.bin"
        "ggml-large-v3-turbo-q8_0.bin"
        "ggml-large-v2.bin"
        "ggml-large-v3.bin"
    )

    for model in "${whisper_files[@]}"; do
        validate_single_url "${WHISPER_BASE}/${model}" "whisper.cpp/${model}" || true
    done

    # --- Vosk models ---
    echo ""
    echo "=== Vosk Models ==="
    validate_single_url "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip" "vosk-small" || true
    validate_single_url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.22.zip" "vosk-0.22" || true
    validate_single_url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.22-lgraph.zip" "vosk-lgraph" || true

    # --- HuggingFace repos (check repo existence) ---
    echo ""
    echo "=== HuggingFace Repos (checking existence) ==="
    local hf_repos=(
        "hexgrad/Kokoro-82M"
        "onnx-community/Kokoro-82M-v1.0-ONNX"
        "OuteAI/OuteTTS-1.0-0.6B-GGUF"
        "rhasspy/piper-voices"
        "coqui/XTTS-v2"
        "parler-tts/parler-tts-mini-v1.1"
        "yl4579/StyleTTS2-LibriTTS"
        "suno/bark-small"
        "distil-whisper/distil-large-v3.5-ggml"
        "distil-whisper/distil-large-v3-ggml"
        "UsefulSensors/moonshine"
        "Systran/faster-whisper-large-v3"
        "deepdml/faster-whisper-large-v3-turbo-ct2"
        "nvidia/parakeet-tdt-0.6b-v2"
        "cjpais/llava-1.6-mistral-7b-gguf"
        "vikhyatk/moondream2"
        "nvidia/Llama-3.1-Nemotron-Nano-VL-8B-V1"
        "bartowski/Qwen2-VL-7B-Instruct-GGUF"
        "stabilityai/sdxl-turbo"
        "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS"
        "stabilityai/stable-diffusion-xl-base-1.0"
        "nvidia/Audio2Face-3D-v3.0"
        "nvidia/canary-1b"
        "nvidia/Cosmos-0.1-Tokenizer-CI8x8"
        "nvidia/Cosmos-Reason1-7B"
    )

    for repo in "${hf_repos[@]}"; do
        validate_single_url "https://huggingface.co/${repo}" "$repo" || true
    done

    # --- VLM specific files ---
    echo ""
    echo "=== VLM Specific Files ==="
    validate_single_url "https://huggingface.co/cjpais/llava-1.6-mistral-7b-gguf/resolve/main/llava-v1.6-mistral-7b.Q4_K_M.gguf" "llava-v1.6-mistral-7b.Q4_K_M.gguf" || true
    validate_single_url "https://huggingface.co/cjpais/llava-1.6-mistral-7b-gguf/resolve/main/mmproj-model-f16.gguf" "llava mmproj-model-f16.gguf" || true
    validate_single_url "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" "sdxl-base safetensors" || true

    # --- Distil-Whisper specific files ---
    echo ""
    echo "=== Distil-Whisper Specific Files ==="
    validate_single_url "https://huggingface.co/distil-whisper/distil-large-v3.5-ggml/resolve/main/ggml-model.bin" "distil-whisper-v3.5 ggml" || true
    validate_single_url "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/ggml-distil-large-v3.bin" "distil-whisper-v3 ggml" || true

    echo ""
    echo "=================================================================="
    echo "  Validation Complete"
    echo "  OK: ${VALIDATE_OK} | FAILED: ${VALIDATE_FAIL} | Time: $(elapsed_since $val_start)"
    echo "=================================================================="
    echo ""

    if [ $VALIDATE_FAIL -gt 0 ]; then
        echo -e "${YELLOW}WARNING:${NC} ${VALIDATE_FAIL} URLs failed validation."
        echo "Failed URLs are logged. The download script will skip these and continue."
        echo "Some may be gated models requiring HuggingFace login."
    else
        echo -e "${GREEN}All URLs validated successfully!${NC}"
    fi
}

###############################################################################
# Category 1: LLM Models (GGUF for llama.cpp) - ~300GB
###############################################################################

download_llm_models() {
    log "============================================================"
    log "CATEGORY 1: LLM Models (GGUF)"
    log "============================================================"

    local LLM_DIR="${MODEL_ROOT}/llm"
    ensure_dir "$LLM_DIR"

    # --- NVIDIA Nemotron Family ---
    log_info "=== NVIDIA Nemotron Models ==="

    # Nemotron-3-Nano-30B-A3B Q4_K_M (~24.6 GB) - MoE, only 3B active params
    hf_download_file "unsloth/Nemotron-3-Nano-30B-A3B-GGUF" \
        "Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf" \
        "${LLM_DIR}/nemotron-3-nano-30b"

    # Nemotron-3-Nano-30B-A3B Q8_0 (~33.6 GB) - higher quality
    hf_download_file "unsloth/Nemotron-3-Nano-30B-A3B-GGUF" \
        "Nemotron-3-Nano-30B-A3B-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-3-nano-30b"

    # Nemotron-Nano-12B-v2 Q8_0
    hf_download_file "bartowski/nvidia_NVIDIA-Nemotron-Nano-12B-v2-GGUF" \
        "nvidia_NVIDIA-Nemotron-Nano-12B-v2-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-nano-12b-v2"

    # Nemotron-Nano-9B-v2 Q8_0
    hf_download_file "bartowski/nvidia_NVIDIA-Nemotron-Nano-9B-v2-GGUF" \
        "nvidia_NVIDIA-Nemotron-Nano-9B-v2-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-nano-9b-v2"

    # Nemotron-Mini-4B Q8_0
    hf_download_file "bartowski/Nemotron-Mini-4B-Instruct-GGUF" \
        "Nemotron-Mini-4B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-mini-4b"

    # --- Qwen 2.5 Family ---
    log_info "=== Qwen 2.5 Models ==="

    # Qwen2.5-32B-Instruct Q4_K_M (~19.9 GB)
    hf_download_file "bartowski/Qwen2.5-32B-Instruct-GGUF" \
        "Qwen2.5-32B-Instruct-Q4_K_M.gguf" \
        "${LLM_DIR}/qwen2.5-32b"

    # Qwen2.5-Coder-32B-Instruct Q4_K_M (~19.9 GB)
    hf_download_file "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF" \
        "Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf" \
        "${LLM_DIR}/qwen2.5-coder-32b"

    # Qwen2.5-14B-Instruct Q8_0 (~15.7 GB)
    hf_download_file "bartowski/Qwen2.5-14B-Instruct-GGUF" \
        "Qwen2.5-14B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/qwen2.5-14b"

    # Qwen2.5-14B-Instruct Q6_K
    hf_download_file "bartowski/Qwen2.5-14B-Instruct-GGUF" \
        "Qwen2.5-14B-Instruct-Q6_K.gguf" \
        "${LLM_DIR}/qwen2.5-14b"

    # QwQ-32B Q4_K_M (~19.9 GB) - Reasoning model
    hf_download_file "bartowski/Qwen_QwQ-32B-GGUF" \
        "Qwen_QwQ-32B-Q4_K_M.gguf" \
        "${LLM_DIR}/qwq-32b"

    # --- DeepSeek R1 Distilled ---
    log_info "=== DeepSeek R1 Models ==="

    # DeepSeek-R1-Distill-Qwen-32B Q4_K_M (~19.9 GB)
    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf" \
        "${LLM_DIR}/deepseek-r1-32b"

    # DeepSeek-R1-Distill-Qwen-14B Q8_0 (~15.7 GB)
    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-14B-Q8_0.gguf" \
        "${LLM_DIR}/deepseek-r1-14b"

    # DeepSeek-R1-Distill-Qwen-14B Q6_K (~12.1 GB)
    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-14B-Q6_K.gguf" \
        "${LLM_DIR}/deepseek-r1-14b"

    # --- Microsoft Phi-4 ---
    log_info "=== Microsoft Phi-4 Models ==="

    # Phi-4 Q8_0 (~16 GB)
    hf_download_file "bartowski/phi-4-GGUF" \
        "phi-4-Q8_0.gguf" \
        "${LLM_DIR}/phi-4"

    # Phi-4-reasoning Q8_0 (~15.6 GB)
    hf_download_file "bartowski/microsoft_Phi-4-reasoning-GGUF" \
        "microsoft_Phi-4-reasoning-Q8_0.gguf" \
        "${LLM_DIR}/phi-4-reasoning"

    # Phi-4-reasoning-plus Q8_0
    hf_download_file "bartowski/microsoft_Phi-4-reasoning-plus-GGUF" \
        "microsoft_Phi-4-reasoning-plus-Q8_0.gguf" \
        "${LLM_DIR}/phi-4-reasoning-plus"

    # --- Meta Llama 3.x ---
    log_info "=== Meta Llama Models ==="

    # Llama-3.1-8B-Instruct Q8_0 (~8.5 GB)
    hf_download_file "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF" \
        "Meta-Llama-3.1-8B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/llama-3.1-8b"

    # Llama-3.2-3B-Instruct Q8_0 (~3.4 GB)
    hf_download_file "bartowski/Llama-3.2-3B-Instruct-GGUF" \
        "Llama-3.2-3B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/llama-3.2-3b"

    # Llama-3.2-1B-Instruct Q8_0 (~1.3 GB)
    hf_download_file "bartowski/Llama-3.2-1B-Instruct-GGUF" \
        "Llama-3.2-1B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/llama-3.2-1b"

    # --- Mistral ---
    log_info "=== Mistral Models ==="

    # Mistral-Nemo-12B Q8_0 (~13 GB)
    hf_download_file "bartowski/Mistral-Nemo-Instruct-2407-GGUF" \
        "Mistral-Nemo-Instruct-2407-Q8_0.gguf" \
        "${LLM_DIR}/mistral-nemo-12b"

    # Mistral-Nemo-12B Q6_K (~10.1 GB)
    hf_download_file "bartowski/Mistral-Nemo-Instruct-2407-GGUF" \
        "Mistral-Nemo-Instruct-2407-Q6_K.gguf" \
        "${LLM_DIR}/mistral-nemo-12b"

    # --- Google Gemma ---
    log_info "=== Google Gemma Models ==="

    # Gemma-2-27B-IT Q4_K_M (~16.6 GB)
    hf_download_file "bartowski/gemma-2-27b-it-GGUF" \
        "gemma-2-27b-it-Q4_K_M.gguf" \
        "${LLM_DIR}/gemma-2-27b"

    # Gemma-2-9B-IT Q8_0
    hf_download_file "bartowski/gemma-2-9b-it-GGUF" \
        "gemma-2-9b-it-Q8_0.gguf" \
        "${LLM_DIR}/gemma-2-9b"

    # --- BitNet 1-bit Models (I2_S GGUF) ---
    log_info "=== BitNet 1-bit Models ==="

    # BitNet b1.58-2B-4T (~1.19 GB) - Official Microsoft model
    hf_download_file "microsoft/bitnet-b1.58-2B-4T-gguf" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/bitnet-2b-4t"

    # Falcon3-1B-Instruct-1.58bit (~400 MB)
    hf_download_file "tiiuae/Falcon3-1B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-1b-1.58bit"

    # Falcon3-3B-Instruct-1.58bit (~1.2 GB)
    hf_download_file "tiiuae/Falcon3-3B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-3b-1.58bit"

    # Falcon3-7B-Instruct-1.58bit (~2.5 GB)
    hf_download_file "tiiuae/Falcon3-7B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-7b-1.58bit"

    # Falcon3-10B-Instruct-1.58bit (~3.5 GB)
    hf_download_file "tiiuae/Falcon3-10B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-10b-1.58bit"

    log_success "LLM models category complete (${DOWNLOAD_SUCCESS} ok, ${DOWNLOAD_FAILED} failed)"
}

###############################################################################
# Category 2: TTS Models - ~15GB
###############################################################################

download_tts_models() {
    log "============================================================"
    log "CATEGORY 2: Text-to-Speech Models"
    log "============================================================"

    local TTS_DIR="${MODEL_ROOT}/tts"
    ensure_dir "$TTS_DIR"

    # --- Kokoro TTS (82M, best quality/size ratio) ---
    log_info "=== Kokoro TTS ==="
    hf_download_repo "hexgrad/Kokoro-82M" "${TTS_DIR}/kokoro-82m"
    hf_download_repo "onnx-community/Kokoro-82M-v1.0-ONNX" "${TTS_DIR}/kokoro-82m-onnx"

    # --- OuteTTS 1.0 (GGUF, runs on llama.cpp) ---
    log_info "=== OuteTTS ==="
    hf_download_repo "OuteAI/OuteTTS-1.0-0.6B-GGUF" "${TTS_DIR}/outetts-1.0-gguf"

    # --- Piper TTS (ultra-fast ONNX) ---
    log_info "=== Piper TTS Voices ==="
    local PIPER_DIR="${TTS_DIR}/piper-voices"
    ensure_dir "$PIPER_DIR"

    # Piper voices use LFS - must use hf CLI instead of direct wget
    local dl_start=$(date +%s)
    log_info "Downloading Piper voices via hf CLI (5 voices)"
    local cmd_output
    cmd_output=$($HF_CLI download "rhasspy/piper-voices" --local-dir "$PIPER_DIR" \
        --include "v2/en/en_US/lessac/high/*" \
        --include "v2/en/en_US/lessac/medium/*" \
        --include "v2/en/en_US/amy/medium/*" \
        --include "v2/en/en_US/ljspeech/high/*" \
        --include "v2/en/en_GB/alba/medium/*" 2>&1)
    local cmd_status=$?
    echo "$cmd_output" | tail -10 >> "$LOG_FILE" 2>/dev/null || true
    if [ $cmd_status -eq 0 ]; then
        local size=$(du -sh "$PIPER_DIR" 2>/dev/null | cut -f1)
        log_success "Downloaded Piper voices (${size}) in $(elapsed_since $dl_start)"
        DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
    else
        log_error "FAILED: Piper voices download"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] REPO: rhasspy/piper-voices (selected voices)" >> "${LOG_DIR}/failed_downloads.txt"
        DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    fi
    print_progress

    # --- Coqui XTTS v2 (voice cloning) ---
    log_info "=== Coqui XTTS v2 ==="
    hf_download_repo "coqui/XTTS-v2" "${TTS_DIR}/xtts-v2"

    # --- Parler TTS Mini (natural language voice control) ---
    log_info "=== Parler TTS Mini ==="
    hf_download_repo "parler-tts/parler-tts-mini-v1.1" "${TTS_DIR}/parler-tts-mini"

    # --- StyleTTS 2 ---
    log_info "=== StyleTTS 2 ==="
    hf_download_repo "yl4579/StyleTTS2-LibriTTS" "${TTS_DIR}/styletts2-libritts"

    # --- Bark (text-to-audio, includes music) ---
    log_info "=== Bark (Suno) ==="
    hf_download_repo "suno/bark-small" "${TTS_DIR}/bark-small"

    log_success "TTS models category complete"
}

###############################################################################
# Category 3: STT / ASR Models - ~20GB
###############################################################################

download_stt_models() {
    log "============================================================"
    log "CATEGORY 3: Speech-to-Text / ASR Models"
    log "============================================================"

    local STT_DIR="${MODEL_ROOT}/stt"
    ensure_dir "$STT_DIR"

    # --- Whisper.cpp GGML models ---
    log_info "=== Whisper.cpp Models (GGML) ==="
    local WHISPER_DIR="${STT_DIR}/whisper-ggml"
    ensure_dir "$WHISPER_DIR"

    local WHISPER_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    # All quantized models (best for Jetson)
    for model in \
        "ggml-tiny.en-q8_0.bin" \
        "ggml-base.en-q8_0.bin" \
        "ggml-small.en-q8_0.bin" \
        "ggml-small-q8_0.bin" \
        "ggml-medium-q5_0.bin" \
        "ggml-medium.en-q5_0.bin" \
        "ggml-medium-q8_0.bin" \
        "ggml-large-v2-q5_0.bin" \
        "ggml-large-v3-q5_0.bin" \
        "ggml-large-v3-turbo.bin" \
        "ggml-large-v3-turbo-q5_0.bin" \
        "ggml-large-v3-turbo-q8_0.bin"; do
        download_url "${WHISPER_BASE}/${model}" "${WHISPER_DIR}/${model}"
    done

    # Full precision large models
    for model in \
        "ggml-large-v2.bin" \
        "ggml-large-v3.bin"; do
        download_url "${WHISPER_BASE}/${model}" "${WHISPER_DIR}/${model}"
    done

    # --- Distil-Whisper GGML ---
    log_info "=== Distil-Whisper ==="
    hf_download_file "distil-whisper/distil-large-v3.5-ggml" \
        "ggml-model.bin" \
        "${STT_DIR}/distil-whisper-v3.5"

    hf_download_file "distil-whisper/distil-large-v3-ggml" \
        "ggml-distil-large-v3.bin" \
        "${STT_DIR}/distil-whisper-v3"

    # --- Moonshine ONNX (ultra-fast edge ASR) ---
    log_info "=== Moonshine (Useful Sensors) ==="
    hf_download_repo "UsefulSensors/moonshine" "${STT_DIR}/moonshine" "onnx/**"

    # --- Vosk (offline, ultra-lightweight) ---
    log_info "=== Vosk Models ==="
    local VOSK_DIR="${STT_DIR}/vosk"
    ensure_dir "$VOSK_DIR"

    download_url "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip" \
        "${VOSK_DIR}/vosk-model-small-en-us-0.15.zip"
    download_url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.22.zip" \
        "${VOSK_DIR}/vosk-model-en-us-0.22.zip"
    download_url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.22-lgraph.zip" \
        "${VOSK_DIR}/vosk-model-en-us-0.22-lgraph.zip"

    # --- Faster-Whisper CTranslate2 ---
    log_info "=== Faster-Whisper (CTranslate2) ==="
    hf_download_repo "Systran/faster-whisper-large-v3" "${STT_DIR}/faster-whisper-large-v3"
    hf_download_repo "deepdml/faster-whisper-large-v3-turbo-ct2" "${STT_DIR}/faster-whisper-large-v3-turbo"

    # --- NVIDIA Parakeet (state-of-the-art English ASR) ---
    log_info "=== NVIDIA Parakeet ==="
    hf_download_repo "nvidia/parakeet-tdt-0.6b-v2" "${STT_DIR}/parakeet-tdt-0.6b-v2"

    log_success "STT models category complete"
}

###############################################################################
# Category 4: Vision Language Models - ~40GB
###############################################################################

download_vision_models() {
    log "============================================================"
    log "CATEGORY 4: Vision Language Models"
    log "============================================================"

    local VLM_DIR="${MODEL_ROOT}/vlm"
    ensure_dir "$VLM_DIR"

    # --- LLaVA 1.6 (Mistral 7B backbone) ---
    log_info "=== LLaVA 1.6 ==="
    hf_download_file "cjpais/llava-1.6-mistral-7b-gguf" \
        "llava-v1.6-mistral-7b.Q4_K_M.gguf" \
        "${VLM_DIR}/llava-1.6-mistral"
    hf_download_file "cjpais/llava-1.6-mistral-7b-gguf" \
        "mmproj-model-f16.gguf" \
        "${VLM_DIR}/llava-1.6-mistral"

    # --- Moondream 2 (tiny but capable VLM) ---
    log_info "=== Moondream 2 ==="
    hf_download_repo "vikhyatk/moondream2" "${VLM_DIR}/moondream2"

    # --- NVIDIA Nemotron Nano VL (8B, OCR champion) ---
    log_info "=== NVIDIA Nemotron Nano VL ==="
    hf_download_repo "nvidia/Llama-3.1-Nemotron-Nano-VL-8B-V1" "${VLM_DIR}/nemotron-nano-vl-8b"

    # --- Qwen2-VL 7B ---
    log_info "=== Qwen2-VL 7B ==="
    hf_download_file "bartowski/Qwen2-VL-7B-Instruct-GGUF" \
        "Qwen2-VL-7B-Instruct-Q4_K_M.gguf" \
        "${VLM_DIR}/qwen2-vl-7b"

    log_success "Vision models category complete"
}

###############################################################################
# Category 5: Image Generation Models - ~40GB
###############################################################################

download_image_gen_models() {
    log "============================================================"
    log "CATEGORY 5: Image Generation Models"
    log "============================================================"

    local IMG_DIR="${MODEL_ROOT}/image-gen"
    ensure_dir "$IMG_DIR"

    # --- SDXL Turbo (1-step generation) ---
    log_info "=== SDXL Turbo ==="
    hf_download_repo "stabilityai/sdxl-turbo" "${IMG_DIR}/sdxl-turbo"

    # --- PixArt-Sigma (0.6B params, 4K capable) ---
    log_info "=== PixArt-Sigma ==="
    hf_download_repo "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS" "${IMG_DIR}/pixart-sigma-1024"

    # --- Stable Diffusion XL Base ---
    log_info "=== SDXL Base ==="
    hf_download_file "stabilityai/stable-diffusion-xl-base-1.0" \
        "sd_xl_base_1.0.safetensors" \
        "${IMG_DIR}/sdxl-base"

    log_success "Image generation models category complete"
}

###############################################################################
# Category 6: NVIDIA Special Models - ~10GB
###############################################################################

download_nvidia_special() {
    log "============================================================"
    log "CATEGORY 6: NVIDIA Special Models"
    log "============================================================"

    local NV_DIR="${MODEL_ROOT}/nvidia-special"
    ensure_dir "$NV_DIR"

    # --- Audio2Face 3D v3.0 ---
    log_info "=== Audio2Face 3D ==="
    hf_download_repo "nvidia/Audio2Face-3D-v3.0" "${NV_DIR}/audio2face-3d-v3"

    # --- NVIDIA Canary (multilingual ASR + translation) ---
    log_info "=== NVIDIA Canary 1B ==="
    hf_download_repo "nvidia/canary-1b" "${NV_DIR}/canary-1b"

    # --- NVIDIA Cosmos Tokenizer ---
    log_info "=== NVIDIA Cosmos Tokenizer ==="
    hf_download_repo "nvidia/Cosmos-0.1-Tokenizer-CI8x8" "${NV_DIR}/cosmos-tokenizer"

    # --- NVIDIA Cosmos Reason ---
    log_info "=== NVIDIA Cosmos Reason ==="
    hf_download_repo "nvidia/Cosmos-Reason1-7B" "${NV_DIR}/cosmos-reason1-7b"

    log_success "NVIDIA special models category complete"
}

###############################################################################
# Category 7: Additional Models to reach 500GB target
###############################################################################

download_extra_models() {
    log "============================================================"
    log "CATEGORY 7: Additional Quality Models"
    log "============================================================"

    local EXTRA_DIR="${MODEL_ROOT}/llm"

    # --- Nemotron 70B (aggressive quant, still usable) ---
    log_info "=== Llama-3.1-Nemotron-70B IQ2_XXS ==="
    hf_download_file "bartowski/Llama-3.1-Nemotron-70B-Instruct-HF-GGUF" \
        "Llama-3.1-Nemotron-70B-Instruct-HF-IQ2_XXS.gguf" \
        "${EXTRA_DIR}/nemotron-70b"

    # --- Llama-3.3-Nemotron-Super-49B IQ3_XXS ---
    log_info "=== Nemotron-Super-49B ==="
    hf_download_file "bartowski/nvidia_Llama-3_3-Nemotron-Super-49B-v1_5-GGUF" \
        "nvidia_Llama-3_3-Nemotron-Super-49B-v1_5-IQ3_XXS.gguf" \
        "${EXTRA_DIR}/nemotron-super-49b"

    # --- Gemma 3 27B ---
    log_info "=== Gemma 3 27B ==="
    hf_download_file "bartowski/google_gemma-3-27b-it-GGUF" \
        "google_gemma-3-27b-it-Q4_K_M.gguf" \
        "${EXTRA_DIR}/gemma-3-27b"

    # --- Qwen2.5-32B-Instruct Q5_K_M (higher quality) ---
    hf_download_file "bartowski/Qwen2.5-32B-Instruct-GGUF" \
        "Qwen2.5-32B-Instruct-Q5_K_M.gguf" \
        "${EXTRA_DIR}/qwen2.5-32b"

    # --- DeepSeek-R1-Distill-Qwen-32B Q5_K_M ---
    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-32B-Q5_K_M.gguf" \
        "${EXTRA_DIR}/deepseek-r1-32b"

    # --- Llama-3.3-70B-Instruct IQ2_XXS ---
    hf_download_file "bartowski/Llama-3.3-70B-Instruct-GGUF" \
        "Llama-3.3-70B-Instruct-IQ2_XXS.gguf" \
        "${EXTRA_DIR}/llama-3.3-70b"

    log_success "Extra models category complete"
}

###############################################################################
# Priority Tier Downloads
###############################################################################

# Tier 1: Phone/tablet/edge models - small, fast, go everywhere (~15GB)
download_tier1() {
    log "============================================================"
    log "TIER 1: Edge/Mobile Models (small, fast)"
    log "============================================================"

    local LLM_DIR="${MODEL_ROOT}/llm"
    local STT_DIR="${MODEL_ROOT}/stt"
    local TTS_DIR="${MODEL_ROOT}/tts"
    local VLM_DIR="${MODEL_ROOT}/vlm"
    ensure_dir "$LLM_DIR" "$STT_DIR" "$TTS_DIR" "$VLM_DIR"

    # --- Small LLMs ---
    log_info "=== Small LLMs (edge-friendly) ==="

    # Llama-3.2-1B Q8_0 (~1.3 GB)
    hf_download_file "bartowski/Llama-3.2-1B-Instruct-GGUF" \
        "Llama-3.2-1B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/llama-3.2-1b"

    # Llama-3.2-3B Q8_0 (~3.4 GB)
    hf_download_file "bartowski/Llama-3.2-3B-Instruct-GGUF" \
        "Llama-3.2-3B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/llama-3.2-3b"

    # Nemotron-Mini-4B Q8_0
    hf_download_file "bartowski/Nemotron-Mini-4B-Instruct-GGUF" \
        "Nemotron-Mini-4B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-mini-4b"

    # --- BitNet 1-bit Models (ultra-efficient CPU inference) ---
    log_info "=== BitNet 1-bit Edge Models ==="

    # BitNet b1.58-2B-4T (~1.19 GB) - Official Microsoft
    hf_download_file "microsoft/bitnet-b1.58-2B-4T-gguf" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/bitnet-2b-4t"

    # Falcon3-1B-1.58bit (~400 MB) - Ultra-fast edge
    hf_download_file "tiiuae/Falcon3-1B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-1b-1.58bit"

    # --- Small Whisper models ---
    log_info "=== Whisper (tiny/base/small) ==="
    local WHISPER_DIR="${STT_DIR}/whisper-ggml"
    ensure_dir "$WHISPER_DIR"
    local WHISPER_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    download_url "${WHISPER_BASE}/ggml-tiny.en-q8_0.bin" "${WHISPER_DIR}/ggml-tiny.en-q8_0.bin"
    download_url "${WHISPER_BASE}/ggml-base.en-q8_0.bin" "${WHISPER_DIR}/ggml-base.en-q8_0.bin"
    download_url "${WHISPER_BASE}/ggml-small.en-q8_0.bin" "${WHISPER_DIR}/ggml-small.en-q8_0.bin"
    download_url "${WHISPER_BASE}/ggml-small-q8_0.bin" "${WHISPER_DIR}/ggml-small-q8_0.bin"

    # --- Piper TTS voices ---
    log_info "=== Piper TTS Voices ==="
    local PIPER_DIR="${TTS_DIR}/piper-voices"
    ensure_dir "$PIPER_DIR"

    local dl_start=$(date +%s)
    log_info "Downloading Piper voices via hf CLI (5 voices)"
    local cmd_output
    cmd_output=$($HF_CLI download "rhasspy/piper-voices" --local-dir "$PIPER_DIR" \
        --include "v2/en/en_US/lessac/high/*" \
        --include "v2/en/en_US/lessac/medium/*" \
        --include "v2/en/en_US/amy/medium/*" \
        --include "v2/en/en_US/ljspeech/high/*" \
        --include "v2/en/en_GB/alba/medium/*" 2>&1)
    local cmd_status=$?
    echo "$cmd_output" | tail -10 >> "$LOG_FILE" 2>/dev/null || true
    if [ $cmd_status -eq 0 ]; then
        local size=$(du -sh "$PIPER_DIR" 2>/dev/null | cut -f1)
        log_success "Downloaded Piper voices (${size}) in $(elapsed_since $dl_start)"
        DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
    else
        log_error "FAILED: Piper voices download"
        DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
    fi
    print_progress

    # --- Moondream 2 (tiny VLM) ---
    log_info "=== Moondream 2 (edge VLM) ==="
    hf_download_repo "vikhyatk/moondream2" "${VLM_DIR}/moondream2"

    # --- Vosk (ultra-lightweight offline ASR) ---
    log_info "=== Vosk (offline ASR) ==="
    local VOSK_DIR="${STT_DIR}/vosk"
    ensure_dir "$VOSK_DIR"
    download_url "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip" \
        "${VOSK_DIR}/vosk-model-small-en-us-0.15.zip"

    log_success "Tier 1 (edge/mobile) complete"
}

# Tier 2: Balanced workstation models (~150GB)
download_tier2() {
    log "============================================================"
    log "TIER 2: Balanced Workstation Models"
    log "============================================================"

    local LLM_DIR="${MODEL_ROOT}/llm"
    local STT_DIR="${MODEL_ROOT}/stt"
    local TTS_DIR="${MODEL_ROOT}/tts"
    local IMG_DIR="${MODEL_ROOT}/image-gen"
    local VLM_DIR="${MODEL_ROOT}/vlm"
    ensure_dir "$LLM_DIR" "$STT_DIR" "$TTS_DIR" "$IMG_DIR" "$VLM_DIR"

    # --- Medium LLMs ---
    log_info "=== Medium LLMs ==="

    # Llama-3.1-8B Q8_0 (~8.5 GB)
    hf_download_file "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF" \
        "Meta-Llama-3.1-8B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/llama-3.1-8b"

    # Gemma-2-9B Q8_0
    hf_download_file "bartowski/gemma-2-9b-it-GGUF" \
        "gemma-2-9b-it-Q8_0.gguf" \
        "${LLM_DIR}/gemma-2-9b"

    # Qwen2.5-14B Q8_0 (~15.7 GB)
    hf_download_file "bartowski/Qwen2.5-14B-Instruct-GGUF" \
        "Qwen2.5-14B-Instruct-Q8_0.gguf" \
        "${LLM_DIR}/qwen2.5-14b"

    # Qwen2.5-14B Q6_K
    hf_download_file "bartowski/Qwen2.5-14B-Instruct-GGUF" \
        "Qwen2.5-14B-Instruct-Q6_K.gguf" \
        "${LLM_DIR}/qwen2.5-14b"

    # Mistral-Nemo-12B Q8_0
    hf_download_file "bartowski/Mistral-Nemo-Instruct-2407-GGUF" \
        "Mistral-Nemo-Instruct-2407-Q8_0.gguf" \
        "${LLM_DIR}/mistral-nemo-12b"

    # Mistral-Nemo-12B Q6_K
    hf_download_file "bartowski/Mistral-Nemo-Instruct-2407-GGUF" \
        "Mistral-Nemo-Instruct-2407-Q6_K.gguf" \
        "${LLM_DIR}/mistral-nemo-12b"

    # DeepSeek-R1-14B Q8_0
    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-14B-Q8_0.gguf" \
        "${LLM_DIR}/deepseek-r1-14b"

    # DeepSeek-R1-14B Q6_K
    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-14B-Q6_K.gguf" \
        "${LLM_DIR}/deepseek-r1-14b"

    # Phi-4 Q8_0
    hf_download_file "bartowski/phi-4-GGUF" \
        "phi-4-Q8_0.gguf" \
        "${LLM_DIR}/phi-4"

    # Phi-4-reasoning Q8_0
    hf_download_file "bartowski/microsoft_Phi-4-reasoning-GGUF" \
        "microsoft_Phi-4-reasoning-Q8_0.gguf" \
        "${LLM_DIR}/phi-4-reasoning"

    # Phi-4-reasoning-plus Q8_0
    hf_download_file "bartowski/microsoft_Phi-4-reasoning-plus-GGUF" \
        "microsoft_Phi-4-reasoning-plus-Q8_0.gguf" \
        "${LLM_DIR}/phi-4-reasoning-plus"

    # Nemotron-Nano-9B-v2 Q8_0
    hf_download_file "bartowski/nvidia_NVIDIA-Nemotron-Nano-9B-v2-GGUF" \
        "nvidia_NVIDIA-Nemotron-Nano-9B-v2-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-nano-9b-v2"

    # Nemotron-Nano-12B-v2 Q8_0
    hf_download_file "bartowski/nvidia_NVIDIA-Nemotron-Nano-12B-v2-GGUF" \
        "nvidia_NVIDIA-Nemotron-Nano-12B-v2-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-nano-12b-v2"

    # --- BitNet 1-bit Medium Models ---
    log_info "=== BitNet 1-bit Models (3B-10B) ==="
    hf_download_file "tiiuae/Falcon3-3B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-3b-1.58bit"

    hf_download_file "tiiuae/Falcon3-7B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-7b-1.58bit"

    hf_download_file "tiiuae/Falcon3-10B-Instruct-1.58bit-GGUF" \
        "ggml-model-i2_s.gguf" \
        "${LLM_DIR}/falcon3-10b-1.58bit"

    # --- Whisper medium/large-turbo ---
    log_info "=== Whisper (medium/large-turbo) ==="
    local WHISPER_DIR="${STT_DIR}/whisper-ggml"
    ensure_dir "$WHISPER_DIR"
    local WHISPER_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    download_url "${WHISPER_BASE}/ggml-medium-q5_0.bin" "${WHISPER_DIR}/ggml-medium-q5_0.bin"
    download_url "${WHISPER_BASE}/ggml-medium.en-q5_0.bin" "${WHISPER_DIR}/ggml-medium.en-q5_0.bin"
    download_url "${WHISPER_BASE}/ggml-medium-q8_0.bin" "${WHISPER_DIR}/ggml-medium-q8_0.bin"
    download_url "${WHISPER_BASE}/ggml-large-v3-turbo.bin" "${WHISPER_DIR}/ggml-large-v3-turbo.bin"
    download_url "${WHISPER_BASE}/ggml-large-v3-turbo-q5_0.bin" "${WHISPER_DIR}/ggml-large-v3-turbo-q5_0.bin"
    download_url "${WHISPER_BASE}/ggml-large-v3-turbo-q8_0.bin" "${WHISPER_DIR}/ggml-large-v3-turbo-q8_0.bin"

    # --- Distil-Whisper ---
    log_info "=== Distil-Whisper ==="
    hf_download_file "distil-whisper/distil-large-v3.5-ggml" \
        "ggml-model.bin" \
        "${STT_DIR}/distil-whisper-v3.5"
    hf_download_file "distil-whisper/distil-large-v3-ggml" \
        "ggml-distil-large-v3.bin" \
        "${STT_DIR}/distil-whisper-v3"

    # --- Kokoro TTS ---
    log_info "=== Kokoro TTS ==="
    hf_download_repo "hexgrad/Kokoro-82M" "${TTS_DIR}/kokoro-82m"
    hf_download_repo "onnx-community/Kokoro-82M-v1.0-ONNX" "${TTS_DIR}/kokoro-82m-onnx"

    # --- OuteTTS ---
    log_info "=== OuteTTS ==="
    hf_download_repo "OuteAI/OuteTTS-1.0-0.6B-GGUF" "${TTS_DIR}/outetts-1.0-gguf"

    # --- SDXL Turbo ---
    log_info "=== SDXL Turbo ==="
    hf_download_repo "stabilityai/sdxl-turbo" "${IMG_DIR}/sdxl-turbo"

    # --- VLMs ---
    log_info "=== Vision Language Models ==="
    hf_download_file "cjpais/llava-1.6-mistral-7b-gguf" \
        "llava-v1.6-mistral-7b.Q4_K_M.gguf" \
        "${VLM_DIR}/llava-1.6-mistral"
    hf_download_file "cjpais/llava-1.6-mistral-7b-gguf" \
        "mmproj-model-f16.gguf" \
        "${VLM_DIR}/llava-1.6-mistral"
    hf_download_file "bartowski/Qwen2-VL-7B-Instruct-GGUF" \
        "Qwen2-VL-7B-Instruct-Q4_K_M.gguf" \
        "${VLM_DIR}/qwen2-vl-7b"

    log_success "Tier 2 (workstation) complete"
}

# Tier 3: Large models - as space allows (~300GB+)
download_tier3() {
    log "============================================================"
    log "TIER 3: Large Models (space permitting)"
    log "============================================================"

    local LLM_DIR="${MODEL_ROOT}/llm"
    local STT_DIR="${MODEL_ROOT}/stt"
    local TTS_DIR="${MODEL_ROOT}/tts"
    local IMG_DIR="${MODEL_ROOT}/image-gen"
    local VLM_DIR="${MODEL_ROOT}/vlm"
    local NV_DIR="${MODEL_ROOT}/nvidia-special"
    ensure_dir "$LLM_DIR" "$STT_DIR" "$TTS_DIR" "$IMG_DIR" "$VLM_DIR" "$NV_DIR"

    # --- 32B Models ---
    log_info "=== 32B Models ==="

    hf_download_file "bartowski/Qwen2.5-32B-Instruct-GGUF" \
        "Qwen2.5-32B-Instruct-Q4_K_M.gguf" \
        "${LLM_DIR}/qwen2.5-32b"

    hf_download_file "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF" \
        "Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf" \
        "${LLM_DIR}/qwen2.5-coder-32b"

    hf_download_file "bartowski/Qwen_QwQ-32B-GGUF" \
        "Qwen_QwQ-32B-Q4_K_M.gguf" \
        "${LLM_DIR}/qwq-32b"

    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf" \
        "${LLM_DIR}/deepseek-r1-32b"

    # --- 27B-30B Models ---
    log_info "=== 27B-30B Models ==="

    hf_download_file "bartowski/gemma-2-27b-it-GGUF" \
        "gemma-2-27b-it-Q4_K_M.gguf" \
        "${LLM_DIR}/gemma-2-27b"

    hf_download_file "bartowski/google_gemma-3-27b-it-GGUF" \
        "google_gemma-3-27b-it-Q4_K_M.gguf" \
        "${LLM_DIR}/gemma-3-27b"

    hf_download_file "unsloth/Nemotron-3-Nano-30B-A3B-GGUF" \
        "Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf" \
        "${LLM_DIR}/nemotron-3-nano-30b"

    hf_download_file "unsloth/Nemotron-3-Nano-30B-A3B-GGUF" \
        "Nemotron-3-Nano-30B-A3B-Q8_0.gguf" \
        "${LLM_DIR}/nemotron-3-nano-30b"

    # --- Higher quant 32B models ---
    log_info "=== Higher quality quants ==="

    hf_download_file "bartowski/Qwen2.5-32B-Instruct-GGUF" \
        "Qwen2.5-32B-Instruct-Q5_K_M.gguf" \
        "${LLM_DIR}/qwen2.5-32b"

    hf_download_file "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF" \
        "DeepSeek-R1-Distill-Qwen-32B-Q5_K_M.gguf" \
        "${LLM_DIR}/deepseek-r1-32b"

    # --- 70B IQ2 variants ---
    log_info "=== 70B Models (aggressive quants) ==="

    hf_download_file "bartowski/Llama-3.1-Nemotron-70B-Instruct-HF-GGUF" \
        "Llama-3.1-Nemotron-70B-Instruct-HF-IQ2_XXS.gguf" \
        "${LLM_DIR}/nemotron-70b"

    hf_download_file "bartowski/nvidia_Llama-3_3-Nemotron-Super-49B-v1_5-GGUF" \
        "nvidia_Llama-3_3-Nemotron-Super-49B-v1_5-IQ3_XXS.gguf" \
        "${LLM_DIR}/nemotron-super-49b"

    hf_download_file "bartowski/Llama-3.3-70B-Instruct-GGUF" \
        "Llama-3.3-70B-Instruct-IQ2_XXS.gguf" \
        "${LLM_DIR}/llama-3.3-70b"

    # --- Full Whisper large models ---
    log_info "=== Whisper large (full precision) ==="
    local WHISPER_DIR="${STT_DIR}/whisper-ggml"
    ensure_dir "$WHISPER_DIR"
    local WHISPER_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    download_url "${WHISPER_BASE}/ggml-large-v2-q5_0.bin" "${WHISPER_DIR}/ggml-large-v2-q5_0.bin"
    download_url "${WHISPER_BASE}/ggml-large-v3-q5_0.bin" "${WHISPER_DIR}/ggml-large-v3-q5_0.bin"
    download_url "${WHISPER_BASE}/ggml-large-v2.bin" "${WHISPER_DIR}/ggml-large-v2.bin"
    download_url "${WHISPER_BASE}/ggml-large-v3.bin" "${WHISPER_DIR}/ggml-large-v3.bin"

    # --- Full TTS suite ---
    log_info "=== Full TTS suite ==="
    hf_download_repo "coqui/XTTS-v2" "${TTS_DIR}/xtts-v2"
    hf_download_repo "parler-tts/parler-tts-mini-v1.1" "${TTS_DIR}/parler-tts-mini"
    hf_download_repo "yl4579/StyleTTS2-LibriTTS" "${TTS_DIR}/styletts2-libritts"
    hf_download_repo "suno/bark-small" "${TTS_DIR}/bark-small"

    # --- Full image generation ---
    log_info "=== Full image generation ==="
    hf_download_repo "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS" "${IMG_DIR}/pixart-sigma-1024"
    hf_download_file "stabilityai/stable-diffusion-xl-base-1.0" \
        "sd_xl_base_1.0.safetensors" \
        "${IMG_DIR}/sdxl-base"

    # --- Faster-Whisper CTranslate2 ---
    log_info "=== Faster-Whisper ==="
    hf_download_repo "Systran/faster-whisper-large-v3" "${STT_DIR}/faster-whisper-large-v3"
    hf_download_repo "deepdml/faster-whisper-large-v3-turbo-ct2" "${STT_DIR}/faster-whisper-large-v3-turbo"

    # --- Vosk full models ---
    log_info "=== Vosk (full models) ==="
    local VOSK_DIR="${STT_DIR}/vosk"
    ensure_dir "$VOSK_DIR"
    download_url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.22.zip" \
        "${VOSK_DIR}/vosk-model-en-us-0.22.zip"
    download_url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.22-lgraph.zip" \
        "${VOSK_DIR}/vosk-model-en-us-0.22-lgraph.zip"

    # --- Moonshine ONNX ---
    log_info "=== Moonshine (edge ASR) ==="
    hf_download_repo "UsefulSensors/moonshine" "${STT_DIR}/moonshine" "onnx/**"

    # --- NVIDIA Parakeet ---
    log_info "=== NVIDIA Parakeet ==="
    hf_download_repo "nvidia/parakeet-tdt-0.6b-v2" "${STT_DIR}/parakeet-tdt-0.6b-v2"

    # --- NVIDIA Special ---
    log_info "=== NVIDIA Special Models ==="
    hf_download_repo "nvidia/Audio2Face-3D-v3.0" "${NV_DIR}/audio2face-3d-v3"
    hf_download_repo "nvidia/canary-1b" "${NV_DIR}/canary-1b"
    hf_download_repo "nvidia/Cosmos-0.1-Tokenizer-CI8x8" "${NV_DIR}/cosmos-tokenizer"
    hf_download_repo "nvidia/Cosmos-Reason1-7B" "${NV_DIR}/cosmos-reason1-7b"

    # --- VLMs (remaining) ---
    log_info "=== Additional VLMs ==="
    hf_download_repo "nvidia/Llama-3.1-Nemotron-Nano-VL-8B-V1" "${VLM_DIR}/nemotron-nano-vl-8b"

    log_success "Tier 3 (large) complete"
}

###############################################################################
# Main Execution
###############################################################################

run_session() {
    local tier_label="$1"
    shift

    echo ""
    echo "=================================================================="
    echo "  Val Ark - AI Model Download Suite"
    echo "  Mode: ${tier_label}"
    echo "=================================================================="
    echo ""

    # Setup
    ensure_dir "$MODEL_ROOT"
    ensure_dir "$LOG_DIR"
    : > "${LOG_DIR}/failed_downloads.txt"

    log "Starting download session (${tier_label})"
    log "Model root: ${MODEL_ROOT}"
    log "Log file: ${LOG_FILE}"

    # Check disk space
    local avail_gb
    avail_gb=$(df -BG "$MODEL_ROOT" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//') || avail_gb="unknown"
    log_info "Available disk space: ${avail_gb} GB"

    # Run requested tier functions
    for tier_fn in "$@"; do
        "$tier_fn"
    done

    # Final Summary
    echo ""
    log "============================================================"
    log "DOWNLOAD SESSION COMPLETE"
    log "============================================================"

    local total_size
    total_size=$(du -sh "$MODEL_ROOT" 2>/dev/null | cut -f1) || total_size="unknown"
    log_info "Total downloaded: ${total_size}"
    log_info "Total elapsed: $(elapsed_since $SCRIPT_START)"
    log_info "Results: ${DOWNLOAD_SUCCESS} succeeded | ${DOWNLOAD_FAILED} failed | ${DOWNLOAD_SKIPPED} skipped"

    if [ -s "${LOG_DIR}/failed_downloads.txt" ]; then
        log_warn "Failed downloads logged to: ${LOG_DIR}/failed_downloads.txt"
        log_warn "Contents:"
        while IFS= read -r line; do
            log_warn "  $line"
        done < "${LOG_DIR}/failed_downloads.txt"
        log_info "Re-run this script to retry (it skips already-downloaded files)."
    else
        log_success "All downloads completed successfully!"
    fi

    log_info "Models are stored in: ${MODEL_ROOT}"
}

# Allow running by tier, individual category, or validation
ensure_dir "$LOG_DIR"
LOG_FILE="${LOG_DIR}/download_$(date +%Y%m%d_%H%M%S).log"

case "${1:-all}" in
    tier1)      run_session "Tier 1 (edge/mobile)" download_tier1 ;;
    tier2)      run_session "Tier 2 (workstation)" download_tier2 ;;
    tier3)      run_session "Tier 3 (large)" download_tier3 ;;
    all)        run_session "All tiers" download_tier1 download_tier2 download_tier3 ;;
    llm)        download_llm_models ;;
    tts)        download_tts_models ;;
    stt)        download_stt_models ;;
    vision)     download_vision_models ;;
    image)      download_image_gen_models ;;
    nvidia)     download_nvidia_special ;;
    extra)      download_extra_models ;;
    bitnet)
        LLM_DIR="${MODEL_ROOT}/llm"
        ensure_dir "$LLM_DIR"
        log_info "=== BitNet 1-bit Models (all) ==="
        hf_download_file "microsoft/bitnet-b1.58-2B-4T-gguf" "ggml-model-i2_s.gguf" "${LLM_DIR}/bitnet-2b-4t"
        hf_download_file "tiiuae/Falcon3-1B-Instruct-1.58bit-GGUF" "ggml-model-i2_s.gguf" "${LLM_DIR}/falcon3-1b-1.58bit"
        hf_download_file "tiiuae/Falcon3-3B-Instruct-1.58bit-GGUF" "ggml-model-i2_s.gguf" "${LLM_DIR}/falcon3-3b-1.58bit"
        hf_download_file "tiiuae/Falcon3-7B-Instruct-1.58bit-GGUF" "ggml-model-i2_s.gguf" "${LLM_DIR}/falcon3-7b-1.58bit"
        hf_download_file "tiiuae/Falcon3-10B-Instruct-1.58bit-GGUF" "ggml-model-i2_s.gguf" "${LLM_DIR}/falcon3-10b-1.58bit"
        ;;
    validate)   LOG_FILE="${LOG_DIR}/validate_$(date +%Y%m%d_%H%M%S).log"; validate_all_urls ;;
    *)
        echo "Usage: $0 [tier1|tier2|tier3|all|llm|tts|stt|vision|image|nvidia|extra|bitnet|validate]"
        echo ""
        echo "  Priority tiers (recommended):"
        echo "    tier1     - Edge/mobile models (~15GB) - small, fast"
        echo "    tier2     - Workstation models (~150GB) - balanced quality/speed"
        echo "    tier3     - Large models (~300GB+) - highest quality"
        echo "    all       - Download all tiers (~500GB)"
        echo ""
        echo "  By category:"
        echo "    llm       - LLM models only (~300GB)"
        echo "    tts       - Text-to-Speech models (~15GB)"
        echo "    stt       - Speech-to-Text models (~20GB)"
        echo "    vision    - Vision Language Models (~40GB)"
        echo "    image     - Image Generation (~40GB)"
        echo "    nvidia    - NVIDIA Special models (~10GB)"
        echo "    extra     - Additional quality models (~75GB)"
        echo "    bitnet    - BitNet 1-bit models only (~14GB)"
        echo ""
        echo "  validate    - Pre-check all URLs without downloading"
        exit 1
        ;;
esac
