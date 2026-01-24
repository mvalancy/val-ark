#!/bin/bash
###############################################################################
# Test: Critical download URLs are reachable
# Uses HEAD/range requests to avoid downloading full files
###############################################################################

PASS=0
FAIL=0

check_url() {
    local url="$1" label="$2"
    local status
    status=$(curl -sS --connect-timeout 10 --max-time 15 \
        -o /dev/null -w "%{http_code}" -L -r 0-0 \
        "$url" 2>/dev/null || echo "000")

    if [ "$status" = "200" ] || [ "$status" = "206" ] || [ "$status" = "302" ] || [ "$status" = "301" ]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL ($status): $label" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Check a sampling of critical URLs
check_url "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q8_0.bin" "whisper tiny"
check_url "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz" "ffmpeg arm64"
check_url "https://github.com/rhasspy/piper/releases" "piper releases"
check_url "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF" "llama-3.2-1b"

[ $FAIL -eq 0 ] && exit 0 || exit 1
