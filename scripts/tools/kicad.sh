#!/bin/bash
# Val Ark - Download KiCad
source "$(dirname "$0")/_common.sh"

TOOL_NAME="kicad"
PINNED_VERSION="10.0.4"

download_kicad() {
    log "Downloading ${TOOL_NAME}..."

    # KiCad development lives on GitLab, but the GitHub mirror tags every
    # release, so it works for version resolution. The installers themselves
    # are served from downloads.kicad.org, which fronts the CERN S3 bucket.
    local repo="KiCad/kicad-source-mirror"
    local tag
    tag=$(github_latest_tag "$repo" "$PINNED_VERSION")
    local ver="${tag#v}"

    # Linux has no portable upstream binary (PPA / distro packages / flatpak).
    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/kicad"
    local src_path=""
    src_path=$(mirror_source_tarball kicad "$ver" \
        "https://gitlab.com/kicad/code/kicad/-/archive/${ver}/kicad-${ver}.tar.gz") || src_path=""
    local kicad_steps="  tar xf kicad-${ver}.tar.gz && cd kicad-${ver}
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DKICAD_USE_EGL=ON && cmake --build build --parallel
  sudo cmake --install build      (https://dev-docs.kicad.org/en/build/linux/)"
    build_from_source_hint kicad "KiCad" linux-arm64 "kicad kicad-symbols kicad-footprints" kicad "$src_path" KiCad/kicad-source-mirror \
"$kicad_steps" archive

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/kicad"
    build_from_source_hint kicad "KiCad" linux-x86_64 "kicad kicad-symbols kicad-footprints" kicad "$src_path" KiCad/kicad-source-mirror \
"$kicad_steps" archive

    # macos-arm64 - since 10.0, macOS ships a single universal (arm64+x86_64) dmg
    dest="${TOOLS_DIR}/macos-arm64/kicad"
    local url="https://kicad-downloads.s3.cern.ch/osx/stable/kicad-unified-universal-${ver}.dmg"
    version_gate "$dest" "$ver"
    ensure_dir "$dest"
    if download_file "$url" "${dest}/kicad-unified-universal-${ver}.dmg" "kicad macos-arm64"; then
        rm -f "${dest}/INSTALL.txt"
        version_stamp "$dest" "$ver"
    fi

    # windows-x64 - official NSIS installer
    dest="${TOOLS_DIR}/windows-x64/kicad"
    url="https://kicad-downloads.s3.cern.ch/windows/stable/kicad-${ver}-x86_64.exe"
    version_gate "$dest" "$ver"
    ensure_dir "$dest"
    if download_file "$url" "${dest}/kicad-${ver}-x86_64.exe" "kicad windows-x64"; then
        rm -f "${dest}/INSTALL.txt"
        version_stamp "$dest" "$ver"
    fi

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_kicad
