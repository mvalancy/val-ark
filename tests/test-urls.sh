#!/bin/bash
###############################################################################
# Test: Critical download URLs are reachable
# Uses HEAD/range requests to avoid downloading full files
###############################################################################

PASS=0
FAIL=0
WARN=0

# Probe a URL once: HEAD with redirect-follow; fall back to a single-byte GET
# (some CDNs/hosts answer HEAD poorly but accept a ranged GET). A HEAD answer
# of 429/403 is a definitive rate-limit/refusal — a second request would only
# amplify the throttling — so return it without the GET fallback.
probe_once() {
    local url="$1" status
    status=$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w "%{http_code}" -IL "$url" 2>/dev/null)
    case "$status" in
        200|206|301|302|307|308|429|403) echo "$status"; return 0 ;;
    esac
    status=$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w "%{http_code}" -L -r 0-0 "$url" 2>/dev/null)
    echo "${status:-000}"
}

# Reachable check with retry/backoff. Public mirrors (esp. GitHub) rate-limit
# rapid unauthenticated requests and return curl code 000 / HTTP 429 / 403 —
# those are RETRYABLE, not "dead". Only a stable non-retryable status (e.g.
# 404/410) is a definitive dead URL and hard-FAILs everywhere. A *sustained*
# retryable status:
#   * under CI (CI=true / GITHUB_ACTIONS): WARN, not FAIL — shared-runner
#     egress IPs get throttled by public mirrors and must not red the gate;
#   * locally: FAIL — persistent unreachability should surface to a human.
check_url() {
    local url="$1" label="$2" status="" attempt
    for attempt in 1 2 3 4; do
        status=$(probe_once "$url")
        case "$status" in
            200|206|301|302|307|308) PASS=$((PASS + 1)); return 0 ;;
            000|429|403|408|425|500|502|503|504)  # transient/rate-limited
                [ "$attempt" -lt 4 ] && sleep $((attempt * 3)) ;;
            *) break ;;  # definitive failure (e.g. 404, 410)
        esac
    done
    case "$status" in
        000|429|403|408|425|500|502|503|504)
            if [ "${CI:-}" = "true" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
                echo "WARN (sustained $status): $label" >&2
                WARN=$((WARN + 1))
                return 0
            fi ;;
    esac
    echo "FAIL ($status): $label" >&2
    FAIL=$((FAIL + 1))
}

# Check a sampling of critical URLs — only when executed directly, so a test
# harness can source the functions above and drive them with a stubbed curl.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    check_url "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q8_0.bin" "whisper tiny"
    check_url "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz" "ffmpeg arm64"
    check_url "https://github.com/rhasspy/piper/releases" "piper releases"
    check_url "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF" "llama-3.2-1b"

    [ $FAIL -eq 0 ] && exit 0 || exit 1
fi
