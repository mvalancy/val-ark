#!/bin/bash
# Val Ark - Download Audacity
source "$(dirname "$0")/_common.sh"

TOOL_NAME="audacity"
PINNED_VERSION="3.7.3"

download_audacity() {
    log "Downloading ${TOOL_NAME}..."

    local repo="audacity/audacity"
    local tag="Audacity-${PINNED_VERSION}"

    # linux-x86_64: AppImage
    local dest="${TOOLS_DIR}/linux-x86_64/audacity"
    ensure_dir "$dest"
    local url
    url=$(github_asset_url "$repo" "$tag" "audacity.*linux.*x64.*AppImage")
    if [ -n "$url" ]; then
        download_file "$url" "${dest}/Audacity.AppImage" "audacity linux-x86_64"
        chmod +x "${dest}/Audacity.AppImage" 2>/dev/null
    else
        log_error "Could not find Audacity x86_64 AppImage"
    fi

    # linux-arm64: no official AppImage, provide install hint
    dest="${TOOLS_DIR}/linux-arm64/audacity"
    ensure_dir "$dest"
    write_install_hint "$dest" "audacity (linux-arm64)" "Audacity - linux-arm64
=====================

No official ARM64 AppImage is available. Install via package manager:

  sudo apt install audacity

Or build from source:
  git clone https://github.com/audacity/audacity.git
  cd audacity
  cmake -B build -DCMAKE_BUILD_TYPE=Release
  cmake --build build --parallel

For more info: https://github.com/audacity/audacity/blob/master/BUILDING.md
"

    # macos-arm64: DMG
    dest="${TOOLS_DIR}/macos-arm64/audacity"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "audacity.*macOS.*arm64.*dmg")
    if [ -n "$url" ]; then
        download_file "$url" "${dest}/Audacity.dmg" "audacity macos-arm64"
    else
        log_warn "Could not find Audacity macOS ARM64 DMG"
        write_install_hint "$dest" "audacity (macos-arm64)" "Audacity - macOS ARM64
=====================

  brew install --cask audacity

Or download from: https://www.audacityteam.org/download/
"
    fi

    # windows-x64: installer
    dest="${TOOLS_DIR}/windows-x64/audacity"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "audacity.*win.*64bit.*exe")
    if [ -n "$url" ]; then
        download_file "$url" "${dest}/Audacity-Setup.exe" "audacity windows-x64"
    else
        log_warn "Could not find Audacity Windows installer"
        write_install_hint "$dest" "audacity (windows-x64)" "Audacity - Windows x64
=====================

Download from: https://www.audacityteam.org/download/
"
    fi

    log_success "Audacity download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_audacity
