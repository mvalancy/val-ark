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

    # Redis ships NO prebuilt Linux binaries — the only way to a binary is `make`,
    # which builds for the BUILD HOST's architecture. So compile ONLY for the platform
    # that matches this host; for the other Linux arch, mirror the source + a build hint
    # and DELETE any binary. Otherwise mirroring on an x86_64 host drops an x86 binary
    # into linux-arm64/redis/bin (and vice-versa) → "Exec format error" on the target,
    # which the Health page flags as "tool present but won't run".
    local host_plat
    case "$(uname -m)" in
        aarch64|arm64) host_plat="linux-arm64" ;;
        x86_64|amd64)  host_plat="linux-x86_64" ;;
        *)             host_plat="" ;;
    esac

    local plat dest
    for plat in linux-arm64 linux-x86_64; do
        dest="${TOOLS_DIR}/${plat}/redis"
        ensure_dir "$dest"
        download_and_extract "$source_url" "$dest" "redis source ${plat}" 1

        if [ "$plat" = "$host_plat" ] && [ -f "${dest}/Makefile" ]; then
            log_info "Compiling redis for ${plat} (native build host)..."
            if (cd "$dest" && make -j"$(nproc)" 2>/dev/null); then
                ensure_dir "${dest}/bin"
                for bin in redis-server redis-cli redis-benchmark; do
                    if [ -f "${dest}/src/${bin}" ]; then
                        cp "${dest}/src/${bin}" "${dest}/bin/"
                        chmod +x "${dest}/bin/${bin}"
                    fi
                done
                log_success "Redis compiled for ${plat} (binaries in ${dest}/bin/)"
            else
                log_warn "redis compile failed for ${plat}"
            fi
        else
            # Non-native arch: never leave a wrong-arch binary. Scrub any stale ones from
            # an older (buggy) mirror — both bin/ and the ones make left in src/ (verify.sh
            # finds by name anywhere under the tool dir); keep source + a build-on-target hint.
            rm -rf "${dest}/bin" 2>/dev/null
            rm -f "${dest}/src/redis-server" "${dest}/src/redis-cli" "${dest}/src/redis-benchmark" 2>/dev/null
            write_install_hint "$dest" "redis" \
"Redis for ${plat}
=================
Redis ships no prebuilt Linux binaries, and cross-compiling from a $(uname -m) host
would produce a wrong-arch binary. The source is mirrored here; build it natively on
the ${plat} box:
  cd \"\$(dirname \"\$0\")\" && make -j\$(nproc) && cp src/redis-server src/redis-cli bin/
Or use the system package: apt install redis-server  (the forum service auto-falls
back to a system redis when no matching mirrored binary is present)."
        fi
    done

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
