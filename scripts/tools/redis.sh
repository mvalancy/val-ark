#!/bin/bash
# Val Ark - Download Redis
source "$(dirname "$0")/_common.sh"

TOOL_NAME="redis"
PINNED_VERSION="7.4.2"

download_redis() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"
    local tag="${ver}"
    local source_url="https://github.com/redis/redis/archive/refs/tags/${tag}.tar.gz"

    # linux-arm64: download source and compile
    local dest="${TOOLS_DIR}/linux-arm64/redis"
    ensure_dir "$dest"
    download_and_extract "$source_url" "$dest" "redis source linux-arm64" 1

    if [ -f "${dest}/Makefile" ]; then
        log_info "Compiling redis for linux-arm64..."
        if (cd "$dest" && make -j"$(nproc)" 2>/dev/null); then
            log_success "Redis compiled for linux-arm64"
            # Copy key binaries to a bin/ subdirectory for convenience
            ensure_dir "${dest}/bin"
            for bin in redis-server redis-cli redis-benchmark; do
                if [ -f "${dest}/src/${bin}" ]; then
                    cp "${dest}/src/${bin}" "${dest}/bin/"
                    chmod +x "${dest}/bin/${bin}"
                fi
            done
            log_info "Binaries placed in ${dest}/bin/"
        else
            log_warn "Compilation failed for linux-arm64 (may need cross-compile tools)"
        fi
    fi

    # linux-x86_64: download source and compile
    dest="${TOOLS_DIR}/linux-x86_64/redis"
    ensure_dir "$dest"
    download_and_extract "$source_url" "$dest" "redis source linux-x86_64" 1

    if [ -f "${dest}/Makefile" ]; then
        log_info "Compiling redis for linux-x86_64..."
        if (cd "$dest" && make -j"$(nproc)" 2>/dev/null); then
            log_success "Redis compiled for linux-x86_64"
            ensure_dir "${dest}/bin"
            for bin in redis-server redis-cli redis-benchmark; do
                if [ -f "${dest}/src/${bin}" ]; then
                    cp "${dest}/src/${bin}" "${dest}/bin/"
                    chmod +x "${dest}/bin/${bin}"
                fi
            done
            log_info "Binaries placed in ${dest}/bin/"
        else
            log_warn "Compilation failed for linux-x86_64 (may need native build environment)"
        fi
    fi

    # macos-arm64
    write_install_hint "${TOOLS_DIR}/macos-arm64/redis" "redis" \
"Redis for macOS
=================

Redis does not provide prebuilt macOS binaries.

Install via Homebrew:
  brew install redis

Or build from source:
  Download: https://github.com/redis/redis/archive/refs/tags/${tag}.tar.gz
  Extract and run: make
  Binaries will be in src/ (redis-server, redis-cli, redis-benchmark)
"

    # windows-x64
    write_install_hint "${TOOLS_DIR}/windows-x64/redis" "redis" \
"Redis for Windows
===================

Redis does not officially support Windows.

Options:
1. Use WSL2 (recommended):
   Install Redis inside Windows Subsystem for Linux

2. Memurai (Redis-compatible for Windows):
   https://www.memurai.com/

3. Microsoft archive (older versions):
   https://github.com/microsoftarchive/redis/releases

4. Docker:
   docker run -p 6379:6379 redis:${ver}
"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_redis
