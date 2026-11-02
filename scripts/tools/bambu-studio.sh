#!/bin/bash
# Val Ark - Download Bambu Studio (3D-printing slicer; AGPL-3.0)
#
# cad-agent slices with Bambu Studio's command line for real filament grams and
# print time (`cad-agent slice`), so the mirror carries it beside cad-agent.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="bambu-studio"
PINNED_VERSION="v02.08.02.61"
BAMBU_REPO="bambulab/BambuStudio"
# Asset names carry a build stamp, so the pinned release's assets are listed for
# when the GitHub API is unreachable or rate-limited (the API is the only way to
# discover a newer release's names).
BAMBU_PINNED_BASE="https://github.com/${BAMBU_REPO}/releases/download/${PINNED_VERSION}"
BAMBU_PINNED_LINUX="BambuStudio_ubuntu22.04-v02.08.02.61-20260820225108.AppImage"
BAMBU_PINNED_MAC="Bambu_Studio_mac-v02.08.02.61-20260820225108.dmg"
BAMBU_PINNED_WIN="Bambu_Studio_win-v02.08.02.61-20260820225108.exe"

# Asset URL for a release: the API listing, else the pinned name for the pin.
_bambu_url() {   # $1 tag  $2 grep pattern  $3 pinned asset name
    local url
    url=$(github_asset_url "$BAMBU_REPO" "$1" "$2")
    if [ -z "$url" ] && [ "$1" = "$PINNED_VERSION" ]; then url="${BAMBU_PINNED_BASE}/$3"; fi
    echo "$url"
}

# Mirror one asset into a platform dir under a stable name.
_bambu_fetch() {   # $1 platform  $2 url  $3 file name  $4 tag
    local plat="$1" url="$2" name="$3" tag="$4" dest
    dest="${TOOLS_DIR}/${plat}/bambu-studio"
    if [ -z "$url" ]; then
        log_error "Could not find the Bambu Studio ${plat} asset in ${tag}"
        return 1
    fi
    ensure_dir "$dest"
    version_gate "$dest" "$tag"
    if download_file "$url" "${dest}/${name}" "bambu-studio ${plat}"; then
        case "$name" in *.AppImage) chmod +x "${dest}/${name}" 2>/dev/null ;; esac
        rm -f "${dest:?}/INSTALL.txt" 2>/dev/null
        version_stamp "$dest" "$tag"
        return 0
    fi
    return 1
}

download_bambu_studio() {
    log "Downloading ${TOOL_NAME}..."

    local tag failed=0
    tag=$(github_latest_tag "$BAMBU_REPO" "$PINNED_VERSION")

    # linux-x86_64: AppImage. Upstream ships one per Ubuntu base; the older
    # base runs on more distros (glibc forward-compatibility), so prefer it.
    local url
    url=$(_bambu_url "$tag" "ubuntu22.04.*AppImage" "$BAMBU_PINNED_LINUX")
    [ -n "$url" ] || url=$(_bambu_url "$tag" "ubuntu24.04.*AppImage" "$BAMBU_PINNED_LINUX")
    _bambu_fetch linux-x86_64 "$url" "BambuStudio.AppImage" "$tag" || failed=1

    # linux-arm64: Bambu Lab publishes no aarch64 build.
    write_install_hint "${TOOLS_DIR}/linux-arm64/bambu-studio" "bambu-studio (linux-arm64)" "Bambu Studio - linux-arm64
==========================

Bambu Lab publishes no Linux aarch64 build (releases: x86_64 AppImage, macOS,
Windows). On an aarch64 host, either slice on an x86_64 machine with the
mirrored AppImage (tools/linux-x86_64/bambu-studio/BambuStudio.AppImage), or
build from source:

  https://github.com/bambulab/BambuStudio/blob/master/BuildLinux.sh

OrcaSlicer (same CLI lineage) ships official linux-arm64 builds:
  https://github.com/OrcaSlicer/OrcaSlicer/releases
"

    # macos-arm64: universal dmg
    _bambu_fetch macos-arm64 "$(_bambu_url "$tag" "mac.*\.dmg" "$BAMBU_PINNED_MAC")" "BambuStudio.dmg" "$tag" || failed=1

    # windows-x64: installer
    _bambu_fetch windows-x64 "$(_bambu_url "$tag" "win.*\.exe" "$BAMBU_PINNED_WIN")" "BambuStudio-Setup.exe" "$tag" || failed=1

    if [ "$failed" = 0 ]; then log_success "${TOOL_NAME} download complete."
    else log_error "${TOOL_NAME}: some platforms failed (re-run resumes)"; fi
    return $failed
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_bambu_studio
