#!/bin/bash
# Val Ark - Download btop
source "$(dirname "$0")/_common.sh"

TOOL_NAME="btop"
PINNED_VERSION="v1.4.0"

download_btop() {
    log "Downloading ${TOOL_NAME}..."

    local repo="aristocratos/btop"
    local tag="${PINNED_VERSION}"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/btop"
    local url
    url=$(github_asset_url "$repo" "$tag" "aarch64-linux-musl.*tbz")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        local tmp_file="${dest}/.tmp_btop.tbz"
        download_file "$url" "$tmp_file" "btop linux-arm64"
        if [ -f "$tmp_file" ] && [ -s "$tmp_file" ]; then
            log_info "Extracting btop linux-arm64..."
            tar -xjf "$tmp_file" -C "$dest" --strip-components=1 2>/dev/null
            log_success "Extracted btop linux-arm64"
            rm -f "$tmp_file" 2>/dev/null
        fi
    else
        log_error "Could not find btop aarch64-linux-musl asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/btop"
    url=$(github_asset_url "$repo" "$tag" "x86_64-linux-musl.*tbz")
    if [ -n "$url" ]; then
        ensure_dir "$dest"
        local tmp_file="${dest}/.tmp_btop.tbz"
        download_file "$url" "$tmp_file" "btop linux-x86_64"
        if [ -f "$tmp_file" ] && [ -s "$tmp_file" ]; then
            log_info "Extracting btop linux-x86_64..."
            tar -xjf "$tmp_file" -C "$dest" --strip-components=1 2>/dev/null
            log_success "Extracted btop linux-x86_64"
            rm -f "$tmp_file" 2>/dev/null
        fi
    else
        log_error "Could not find btop x86_64-linux-musl asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/btop"
    local src_path=""
    src_path=$(mirror_source_tarball btop "${tag#v}" \
        "https://github.com/aristocratos/btop/archive/refs/tags/${tag}.tar.gz") || src_path=""
    write_install_hint "$dest" "btop (macOS)" "btop - macos-arm64
==================

Upstream ships no macOS binary. Build it offline from the mirrored source (GitHub's tag
archive; btop has no git submodules and no third-party library dependencies, it needs only
Xcode's command line tools with a C++20 compiler):
  ${src_path:-tools/sources/btop-${tag#v}-src/${tag}.tar.gz}   (full history: aristocratos/btop git bundle)
  tar xzf ${tag}.tar.gz && cd btop-${tag#v} && gmake   (or: make) && sudo make install

Online: brew install btop"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_btop
