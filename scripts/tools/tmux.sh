#!/bin/bash
# Val Ark - Download tmux
source "$(dirname "$0")/_common.sh"

TOOL_NAME="tmux"
PINNED_VERSION="3.5a"

download_tmux() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"
    local tag="${ver}"
    local source_url="https://github.com/tmux/tmux/releases/download/${tag}/tmux-${ver}.tar.gz"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/tmux"
    ensure_dir "$dest"
    download_and_extract "$source_url" "$dest" "tmux source (linux-arm64)" 1

    cat > "${dest}/BUILD.txt" << BUILDEOF
tmux ${ver} - Build Instructions (linux-arm64)
================================================

Prerequisites:
  sudo apt install -y build-essential libevent-dev libncurses-dev bison

Build:
  cd ${dest}
  ./configure
  make
  cp tmux ${TOOLS_DIR}/linux-arm64/tmux/tmux

Or install via package manager:
  sudo apt install tmux
BUILDEOF

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/tmux"
    ensure_dir "$dest"
    download_and_extract "$source_url" "$dest" "tmux source (linux-x86_64)" 1

    cat > "${dest}/BUILD.txt" << BUILDEOF
tmux ${ver} - Build Instructions (linux-x86_64)
================================================

Prerequisites:
  sudo apt install -y build-essential libevent-dev libncurses-dev bison

Build:
  cd ${dest}
  ./configure
  make
  cp tmux ${TOOLS_DIR}/linux-x86_64/tmux/tmux

Or install via package manager:
  sudo apt install tmux
BUILDEOF

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/tmux"
    write_install_hint "$dest" "tmux (macOS)" "Install tmux on macOS:

brew install tmux

Or build from source:
  brew install libevent ncurses
  curl -LO https://github.com/tmux/tmux/releases/download/${tag}/tmux-${ver}.tar.gz
  tar xzf tmux-${ver}.tar.gz
  cd tmux-${ver}
  ./configure
  make
  sudo make install
"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_tmux
