#!/bin/bash
# Val Ark - Download Bambu Studio (3D-printing slicer; AGPL-3.0)
#
# cad-agent slices with Bambu Studio's command line for real filament grams and
# print time (`cad-agent slice`), so the mirror carries it beside cad-agent.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="bambu-studio"
PINNED_VERSION="v02.08.02.61"

# Mirror one asset into a platform dir under a stable name.
_bambu_fetch() {   # $1 platform  $2 asset grep pattern  $3 file name  $4 tag  $5 repo
    local plat="$1" pattern="$2" name="$3" tag="$4" repo="$5" dest url
    dest="${TOOLS_DIR}/${plat}/bambu-studio"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "$pattern")
    if [ -z "$url" ]; then
        log_error "Could not find Bambu Studio ${plat} asset (${pattern}) in ${tag}"
        return 1
    fi
    version_gate "$dest" "$tag"
    if download_file "$url" "${dest}/${name}" "bambu-studio ${plat}"; then
        case "$name" in *.AppImage) chmod +x "${dest}/${name}" 2>/dev/null ;; esac
        rm -f "${dest:?}/INSTALL.txt" 2>/dev/null
        version_stamp "$dest" "$tag"
    fi
}

download_bambu_studio() {
    log "Downloading ${TOOL_NAME}..."

    local repo="bambulab/BambuStudio"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")

    # linux-x86_64: AppImage. Upstream ships one per Ubuntu base; the older
    # base runs on more distros (glibc forward-compatibility), so prefer it.
    local base found=0
    for base in "22.04" "24.04"; do
        if [ -n "$(github_asset_url "$repo" "$tag" "ubuntu${base}.*AppImage")" ]; then
            _bambu_fetch linux-x86_64 "ubuntu${base}.*AppImage" "BambuStudio.AppImage" "$tag" "$repo" && found=1
            break
        fi
    done
    [ "$found" = 1 ] || log_error "Could not mirror the Bambu Studio Linux AppImage"

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
    _bambu_fetch macos-arm64 "mac.*\.dmg" "BambuStudio.dmg" "$tag" "$repo"

    # windows-x64: installer
    _bambu_fetch windows-x64 "win.*\.exe" "BambuStudio-Setup.exe" "$tag" "$repo"

    log_success "${TOOL_NAME} download complete."
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_bambu_studio
