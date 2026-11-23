#!/bin/bash
# Val Ark - Download Audacity
source "$(dirname "$0")/_common.sh"

TOOL_NAME="audacity"
PINNED_VERSION="4.0.2"

download_audacity() {
    log "Downloading ${TOOL_NAME}..."

    local repo="audacity/audacity"
    local tag
    tag=$(github_latest_tag "$repo" "Audacity-${PINNED_VERSION}")

    local ver="${tag#Audacity-}" url dest

    # linux-x86_64 / linux-arm64: AppImages. 3.x shipped one per Ubuntu base (…-x64-22.04…,
    # newest base preferred); 4.x ships audacity-linux-<v>-x86_64 / -aarch64.AppImage.
    local plat pat base
    for plat in linux-x86_64 linux-arm64; do
        dest="${TOOLS_DIR}/${plat}/audacity"
        ensure_dir "$dest"
        url=""
        if [ "$plat" = linux-x86_64 ]; then
            for base in "26.04" "24.04" "22.04" "20.04"; do
                url=$(github_asset_url "$repo" "$tag" "audacity.*linux.*\(x64\|x86_64\).*${base}.*AppImage")
                [ -n "$url" ] && break
            done
            pat="audacity.*linux.*\(x64\|x86_64\).*AppImage"
        else
            pat="audacity.*linux.*\(aarch64\|arm64\).*AppImage"
        fi
        [ -z "$url" ] && url=$(github_asset_url "$repo" "$tag" "$pat")
        if [ -n "$url" ]; then
            version_gate "$dest" "$tag"
            if download_file "$url" "${dest}/Audacity.AppImage" "audacity ${plat}"; then
                chmod +x "${dest}/Audacity.AppImage" 2>/dev/null
                rm -f "${dest}/INSTALL.txt" 2>/dev/null
                version_stamp "$dest" "$tag"
            fi
        elif [ "$plat" = linux-x86_64 ]; then
            log_error "Could not find the Audacity ${plat} AppImage"
        else
            # No binary for this platform: mirror upstream's release source (fetched only
            # here, so a run where every platform has a binary downloads no source).
            local src_path=""
            src_path=$(mirror_source_tarball audacity "${tag#Audacity-}" \
                "$(github_asset_url "$repo" "$tag" "audacity-sources.*tar")") || src_path=""
            build_from_source_hint audacity "Audacity" "$plat" audacity audacity "$src_path" audacity/audacity \
"  cmake -B build -DCMAKE_BUILD_TYPE=Release -Daudacity_conan_enabled=Off
  cmake --build build --parallel
  (https://github.com/audacity/audacity/blob/master/BUILDING.md; system libraries come from the
   desktop-src build-deps, so Conan - which needs internet - stays off)"
        fi
    done

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
        log_error "Could not find the Audacity macOS arm64 DMG"
    fi

    # windows-x64: 3.x shipped audacity-win-<v>-64bit.exe, 4.x ships audacity-win-<v>-x86_64.msi.
    dest="${TOOLS_DIR}/windows-x64/audacity"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "audacity.*win.*\(x86_64\|64bit\).*\(msi\|exe\)")
    if [ -n "$url" ]; then
        version_gate "$dest" "$tag"
        if download_file "$url" "${dest}/$(basename "$url")" "audacity windows-x64"; then
            rm -f "${dest}/INSTALL.txt" "${dest}/Audacity-Setup.exe" 2>/dev/null
            version_stamp "$dest" "$tag"
        fi
    else
        log_error "Could not find the Audacity windows-x64 installer"
    fi

    log_success "Audacity download complete"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_audacity
