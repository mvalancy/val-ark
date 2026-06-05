#!/bin/bash
###############################################################################
# Test: Critical download URLs are reachable
# Uses HEAD/range requests to avoid downloading full files
###############################################################################

PASS=0
FAIL=0

# Probe a URL once: HEAD with redirect-follow; fall back to a single-byte GET
# (some CDNs/hosts answer HEAD poorly but accept a ranged GET).
probe_once() {
    local url="$1" status
    status=$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w "%{http_code}" -IL "$url" 2>/dev/null)
    case "$status" in 200|206|301|302|307|308) echo "$status"; return 0 ;; esac
    status=$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w "%{http_code}" -L -r 0-0 "$url" 2>/dev/null)
    echo "${status:-000}"
}

# Reachable check with retry/backoff. Public mirrors (esp. GitHub) rate-limit
# rapid unauthenticated requests and return curl code 000 / HTTP 429 / 403 —
# those are RETRYABLE, not "dead". Only a stable 4xx/5xx (non-rate-limit) fails.
check_url() {
    local url="$1" label="$2" status="" attempt
    for attempt in 1 2 3 4; do
        status=$(probe_once "$url")
        case "$status" in
            200|206|301|302|307|308) PASS=$((PASS + 1)); return 0 ;;
            000|429|403|408|425|500|502|503|504) sleep $((attempt * 3)) ;;  # transient/rate-limited
            *) break ;;  # definitive failure (e.g. 404, 410)
        esac
    done
    echo "FAIL ($status): $label" >&2
    FAIL=$((FAIL + 1))
}

# Check a sampling of critical URLs
check_url "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q8_0.bin" "whisper tiny"
check_url "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz" "ffmpeg arm64"
check_url "https://github.com/rhasspy/piper/releases" "piper releases"
check_url "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF" "llama-3.2-1b"

[ $FAIL -eq 0 ] && exit 0 || exit 1
