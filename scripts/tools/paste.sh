#!/bin/bash
# Val Ark - Download Files & Pastebin (MicroBin)
#
# MicroBin is a single self-contained Rust binary: pastebin + file upload +
# URL shortener, with SQLite/JSON storage and NO federation or relay. It ships
# prebuilt musl static binaries for aarch64 + x86_64 Linux, Apple Silicon, and
# Windows x64, which makes it an ideal offline single-binary community service.
#
# This script ONLY mirrors binaries into the Val Ark tools tree. It installs
# nothing system-wide. It is idempotent (download_and_extract skips when already
# present) and safe to re-run.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="paste"
PINNED_VERSION="v2.1.0"

download_paste() {
    log "Downloading ${TOOL_NAME} (MicroBin)..."

    local repo="szabodanika/microbin"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    local base="https://github.com/${repo}/releases/download/${tag}"
    local ver="${tag#v}"

    # linux-arm64 (aarch64 musl static) - Jetson Orin/Thor, GB10, OpenWRT
    download_and_extract \
        "${base}/microbin-${tag}-aarch64-unknown-linux-musl.tar.gz" \
        "${TOOLS_DIR}/linux-arm64/paste" "paste (microbin) linux-arm64" 0

    # linux-x86_64 (musl static)
    download_and_extract \
        "${base}/microbin-${tag}-x86_64-unknown-linux-musl.tar.gz" \
        "${TOOLS_DIR}/linux-x86_64/paste" "paste (microbin) linux-x86_64" 0

    # macos-arm64 (Apple Silicon)
    download_and_extract \
        "${base}/microbin-${tag}-aarch64-apple-darwin.tar.gz" \
        "${TOOLS_DIR}/macos-arm64/paste" "paste (microbin) macos-arm64" 0

    # windows-x64
    download_and_extract \
        "${base}/microbin-${tag}-x86_64-pc-windows-msvc.zip" \
        "${TOOLS_DIR}/windows-x64/paste" "paste (microbin) windows-x64" 0

    # Normalize the extracted binary name across platforms so the service script
    # and end users can rely on a stable "microbin" / "microbin.exe" entrypoint.
    local p
    for p in linux-arm64 linux-x86_64 macos-arm64; do
        local d="${TOOLS_DIR}/${p}/paste"
        if [ -f "${d}/microbin" ]; then
            chmod +x "${d}/microbin" 2>/dev/null || true
        fi
    done
    [ -f "${TOOLS_DIR}/windows-x64/paste/microbin.exe" ] || \
        log_info "Windows build extracted (expect microbin.exe in tools/windows-x64/paste)"

    # Usage hint shipped alongside every platform so the offline box is
    # self-documenting. MicroBin needs NO node/redis — it is fully standalone.
    local hint
    hint="Files & Pastebin (MicroBin ${ver})
====================================

Single self-contained binary: pastebin + file upload + URL shortener.
No federation, no relay, no external services required. Fully offline.

Run (Linux/macOS):
  MICROBIN_PORT=8085 MICROBIN_BIND=0.0.0.0 ./microbin

On the Val Ark host, start/stop it via the service supervisor instead:
  scripts/services/paste.sh start | status | stop

Data is stored next to the working dir (MICROBIN_DATA_DIR). Admin login and
basic-auth credentials are configurable via MICROBIN_ADMIN_PASSWORD and
MICROBIN_BASIC_AUTH_USERNAME / MICROBIN_BASIC_AUTH_PASSWORD.

Project: https://microbin.eu  -  Source: https://github.com/szabodanika/microbin
"
    for p in linux-arm64 linux-x86_64 macos-arm64 windows-x64; do
        write_install_hint "${TOOLS_DIR}/${p}/paste" "paste" "$hint"
    done

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_paste
