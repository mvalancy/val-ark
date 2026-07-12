#!/bin/bash
# Val Ark - Download Audacity
source "$(dirname "$0")/_common.sh"

TOOL_NAME="audacity"
PINNED_VERSION="3.7.8"

download_audacity() {
    log "Downloading ${TOOL_NAME}..."

    local repo="audacity/audacity"
    local tag
    tag=$(github_latest_tag "$repo" "Audacity-${PINNED_VERSION}")

    # linux-x86_64: AppImage. Upstream ships one AppImage per Ubuntu base
    # (e.g. -20.04 and -22.04); prefer the newest base deterministically
    # instead of taking whichever the API lists first.
    local dest="${TOOLS_DIR}/linux-x86_64/audacity"
    ensure_dir "$dest"
    local url=""
    local base
    for base in "26.04" "24.04" "22.04" "20.04"; do
        url=$(github_asset_url "$repo" "$tag" "audacity.*linux.*x64.*${base}.*AppImage")
        [ -n "$url" ] && break
    done
    [ -z "$url" ] && url=$(github_asset_url "$repo" "$tag" "audacity.*linux.*x64.*AppImage")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        if download_file "$url" "${dest}/Audacity.AppImage" "audacity linux-x86_64"; then
            chmod +x "${dest}/Audacity.AppImage" 2>/dev/null
            rm -f "${dest}/INSTALL.txt" 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find Audacity x86_64 AppImage"
    fi

    # linux-arm64: no official ARM64 AppImage, provide install hint
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
        version_gate "$dest" "$tag"
        if download_file "$url" "${dest}/Audacity.dmg" "audacity macos-arm64"; then
            rm -f "${dest}/INSTALL.txt" 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
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
        version_gate "$dest" "$tag"
        if download_file "$url" "${dest}/Audacity-Setup.exe" "audacity windows-x64"; then
            rm -f "${dest}/INSTALL.txt" 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
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
