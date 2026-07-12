#!/bin/bash
# Val Ark - Download yt-dlp
source "$(dirname "$0")/_common.sh"

TOOL_NAME="yt-dlp"
PINNED_VERSION="2026.07.04"

# Fetch one platform's binary, refreshing when upstream moved on.
# Dest filenames are versionless (yt-dlp / yt-dlp.exe) and download_file skips
# existing files, so the shared version_gate/version_stamp helpers keep the
# cached binary in step with the resolved tag.
fetch_yt_dlp_binary() {
    local tag="$1"
    local url="$2"
    local platform="$3"
    local bin_name="$4"
    local dest="${TOOLS_DIR}/${platform}/yt-dlp"

    ensure_dir "$dest"
    version_gate "$dest" "$tag"

    if download_file "$url" "${dest}/${bin_name}" "yt-dlp ${platform}"; then
        case "$bin_name" in
            *.exe) : ;;
            *) chmod +x "${dest}/${bin_name}" 2>/dev/null ;;
        esac
        version_stamp "$dest" "$tag"
        return 0
    fi
    return 1
}

download_yt_dlp() {
    log "Downloading ${TOOL_NAME}..."

    local repo="yt-dlp/yt-dlp"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")
    local base_url="https://github.com/${repo}/releases/download/${tag}"

    local failed=0

    # linux-x86_64: standalone binary
    fetch_yt_dlp_binary "$tag" "${base_url}/yt-dlp_linux" "linux-x86_64" "yt-dlp" || failed=$((failed + 1))

    # linux-arm64: standalone binary
    fetch_yt_dlp_binary "$tag" "${base_url}/yt-dlp_linux_aarch64" "linux-arm64" "yt-dlp" || failed=$((failed + 1))

    # macos-arm64: universal binary
    fetch_yt_dlp_binary "$tag" "${base_url}/yt-dlp_macos" "macos-arm64" "yt-dlp" || failed=$((failed + 1))

    # windows-x64: exe
    fetch_yt_dlp_binary "$tag" "${base_url}/yt-dlp.exe" "windows-x64" "yt-dlp.exe" || failed=$((failed + 1))

    if [ "$failed" -gt 0 ]; then
        log_error "yt-dlp: ${failed} platform download(s) failed"
        return 1
    fi

    log_success "yt-dlp download complete"
    # Explicit success: log()'s trailing `[ -n "$LOG_FILE" ] && ...` returns 1
    # when LOG_FILE is unset (run_tool spawns a fresh bash without exporting it),
    # which used to leak out as a phantom "exited with code 1" on success.
    return 0
}

# Run if called directly (if-form so sourcing this file returns 0, not 1)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    download_yt_dlp
fi
