#!/bin/bash
# Val Ark - Download PostgreSQL
source "$(dirname "$0")/_common.sh"

TOOL_NAME="postgresql"
PINNED_VERSION="16.6"

download_postgresql() {
    log "Downloading ${TOOL_NAME}..."

    local ver="${PINNED_VERSION}"
    local source_url="https://ftp.postgresql.org/pub/source/v${ver}/postgresql-${ver}.tar.gz"
    local build_instructions="PostgreSQL ${ver} Build Instructions
=========================================

Prerequisites:
  - gcc/g++ or clang
  - make
  - readline development headers (libreadline-dev / readline-devel)
  - zlib development headers (zlib1g-dev / zlib-devel)
  - flex, bison (for building from source)
  - Optional: libssl-dev for SSL support
  - Optional: libxml2-dev for XML support

Build steps:
  cd postgresql-source
  ./configure --prefix=\$(pwd)/install
  make -j\$(nproc)
  make install

The binaries will be in install/bin/:
  - postgres       (database server)
  - psql           (interactive terminal)
  - pg_dump        (backup utility)
  - pg_restore     (restore utility)
  - initdb         (initialize database cluster)
  - pg_ctl         (control server)

Quick start after build:
  export PATH=\$(pwd)/install/bin:\$PATH
  initdb -D ./data
  pg_ctl -D ./data -l logfile start
  createdb mydb
  psql mydb
"

    local platforms="linux-arm64 linux-x86_64 macos-arm64 windows-x64"
    for platform in $platforms; do
        local dest="${TOOLS_DIR}/${platform}/postgresql"
        ensure_dir "$dest"

        # Download and extract source tarball
        download_and_extract "$source_url" "$dest" "postgresql ${ver} (${platform})" 1

        # Write BUILD.txt
        if [ ! -f "${dest}/BUILD.txt" ]; then
            echo "$build_instructions" > "${dest}/BUILD.txt"
            log_info "Created BUILD.txt for postgresql (${platform})"
        fi
    done

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_postgresql
