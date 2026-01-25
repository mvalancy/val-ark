#!/bin/bash
# Val Ark - Download Dev CLI Tools Bundle
source "$(dirname "$0")/_common.sh"

TOOL_NAME="dev-cli"

# Pinned versions
FD_VERSION="v10.2.0"
RG_VERSION="14.1.1"
BAT_VERSION="v0.25.0"
FZF_VERSION="v0.57.0"
JQ_VERSION="jq-1.7.1"
LAZYGIT_VERSION="v0.44.1"

download_dev_cli() {
    log "Downloading ${TOOL_NAME} bundle..."

    download_fd
    download_rg
    download_bat
    download_fzf
    download_jq
    download_lazygit
}

download_fd() {
    local repo="sharkdp/fd"
    local tag="${FD_VERSION}"
    local url

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*linux-gnu.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fd linux-arm64" 1
        find "$tmp_dir" -name "fd" -type f -exec cp {} "${dest}/fd" \; 2>/dev/null
        chmod +x "${dest}/fd" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fd aarch64-linux asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "x86_64.*linux-gnu.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fd linux-x86_64" 1
        find "$tmp_dir" -name "fd" -type f -exec cp {} "${dest}/fd" \; 2>/dev/null
        chmod +x "${dest}/fd" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fd x86_64-linux asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*apple-darwin.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fd macos-arm64" 1
        find "$tmp_dir" -name "fd" -type f -exec cp {} "${dest}/fd" \; 2>/dev/null
        chmod +x "${dest}/fd" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fd aarch64-apple-darwin asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "x86_64.*windows.*zip")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fd windows-x64" 0
        find "$tmp_dir" -name "fd.exe" -type f -exec cp {} "${dest}/fd.exe" \; 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fd x86_64-windows asset"
    fi
}

download_rg() {
    local repo="BurntSushi/ripgrep"
    local tag="${RG_VERSION}"
    local url

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*linux-gnu.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "ripgrep linux-arm64" 1
        find "$tmp_dir" -name "rg" -type f -exec cp {} "${dest}/rg" \; 2>/dev/null
        chmod +x "${dest}/rg" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find ripgrep aarch64-linux asset"
    fi

    # linux-x86_64 (ripgrep uses musl, not gnu, for x86_64)
    dest="${TOOLS_DIR}/linux-x86_64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "x86_64.*linux-musl.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "ripgrep linux-x86_64" 1
        find "$tmp_dir" -name "rg" -type f -exec cp {} "${dest}/rg" \; 2>/dev/null
        chmod +x "${dest}/rg" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find ripgrep x86_64-linux asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*apple-darwin.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "ripgrep macos-arm64" 1
        find "$tmp_dir" -name "rg" -type f -exec cp {} "${dest}/rg" \; 2>/dev/null
        chmod +x "${dest}/rg" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find ripgrep aarch64-apple-darwin asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "x86_64.*windows.*zip")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "ripgrep windows-x64" 0
        find "$tmp_dir" -name "rg.exe" -type f -exec cp {} "${dest}/rg.exe" \; 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find ripgrep x86_64-windows asset"
    fi
}

download_bat() {
    local repo="sharkdp/bat"
    local tag="${BAT_VERSION}"
    local url

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*linux-gnu.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "bat linux-arm64" 1
        find "$tmp_dir" -name "bat" -type f -exec cp {} "${dest}/bat" \; 2>/dev/null
        chmod +x "${dest}/bat" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find bat aarch64-linux asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "x86_64.*linux-gnu.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "bat linux-x86_64" 1
        find "$tmp_dir" -name "bat" -type f -exec cp {} "${dest}/bat" \; 2>/dev/null
        chmod +x "${dest}/bat" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find bat x86_64-linux asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "aarch64.*apple-darwin.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "bat macos-arm64" 1
        find "$tmp_dir" -name "bat" -type f -exec cp {} "${dest}/bat" \; 2>/dev/null
        chmod +x "${dest}/bat" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find bat aarch64-apple-darwin asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "x86_64.*windows.*zip")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "bat windows-x64" 0
        find "$tmp_dir" -name "bat.exe" -type f -exec cp {} "${dest}/bat.exe" \; 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find bat x86_64-windows asset"
    fi
}

download_fzf() {
    local repo="junegunn/fzf"
    local tag="${FZF_VERSION}"
    local url

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "linux_arm64.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fzf linux-arm64" 0
        find "$tmp_dir" -name "fzf" -type f -exec cp {} "${dest}/fzf" \; 2>/dev/null
        chmod +x "${dest}/fzf" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fzf linux_arm64 asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "linux_amd64.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fzf linux-x86_64" 0
        find "$tmp_dir" -name "fzf" -type f -exec cp {} "${dest}/fzf" \; 2>/dev/null
        chmod +x "${dest}/fzf" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fzf linux_amd64 asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "darwin_arm64.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fzf macos-arm64" 0
        find "$tmp_dir" -name "fzf" -type f -exec cp {} "${dest}/fzf" \; 2>/dev/null
        chmod +x "${dest}/fzf" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fzf darwin_arm64 asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "windows_amd64.*zip")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "fzf windows-x64" 0
        find "$tmp_dir" -name "fzf.exe" -type f -exec cp {} "${dest}/fzf.exe" \; 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find fzf windows_amd64 asset"
    fi
}

download_jq() {
    local repo="jqlang/jq"
    local tag="${JQ_VERSION}"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/dev-cli"
    ensure_dir "$dest"
    local url="https://github.com/jqlang/jq/releases/download/${tag}/jq-linux-arm64"
    download_file "$url" "${dest}/jq" "jq linux-arm64"
    chmod +x "${dest}/jq" 2>/dev/null

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/dev-cli"
    ensure_dir "$dest"
    url="https://github.com/jqlang/jq/releases/download/${tag}/jq-linux-amd64"
    download_file "$url" "${dest}/jq" "jq linux-x86_64"
    chmod +x "${dest}/jq" 2>/dev/null

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/dev-cli"
    ensure_dir "$dest"
    url="https://github.com/jqlang/jq/releases/download/${tag}/jq-macos-arm64"
    download_file "$url" "${dest}/jq" "jq macos-arm64"
    chmod +x "${dest}/jq" 2>/dev/null

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/dev-cli"
    ensure_dir "$dest"
    url="https://github.com/jqlang/jq/releases/download/${tag}/jq-windows-amd64.exe"
    download_file "$url" "${dest}/jq.exe" "jq windows-x64"
}

download_lazygit() {
    local repo="jesseduffield/lazygit"
    local tag="${LAZYGIT_VERSION}"
    local url

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "Linux_arm64.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "lazygit linux-arm64" 0
        find "$tmp_dir" -name "lazygit" -type f -exec cp {} "${dest}/lazygit" \; 2>/dev/null
        chmod +x "${dest}/lazygit" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find lazygit Linux_arm64 asset"
    fi

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "Linux_x86_64.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "lazygit linux-x86_64" 0
        find "$tmp_dir" -name "lazygit" -type f -exec cp {} "${dest}/lazygit" \; 2>/dev/null
        chmod +x "${dest}/lazygit" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find lazygit Linux_x86_64 asset"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "Darwin_arm64.*tar.gz")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "lazygit macos-arm64" 0
        find "$tmp_dir" -name "lazygit" -type f -exec cp {} "${dest}/lazygit" \; 2>/dev/null
        chmod +x "${dest}/lazygit" 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find lazygit Darwin_arm64 asset"
    fi

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/dev-cli"
    ensure_dir "$dest"
    url=$(github_asset_url "$repo" "$tag" "Windows_x86_64.*zip")
    if [ -n "$url" ]; then
        local tmp_dir=$(mktemp -d)
        download_and_extract "$url" "$tmp_dir" "lazygit windows-x64" 0
        find "$tmp_dir" -name "lazygit.exe" -type f -exec cp {} "${dest}/lazygit.exe" \; 2>/dev/null
        rm -rf "$tmp_dir"
    else
        log_error "Could not find lazygit Windows_x86_64 asset"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_dev_cli
