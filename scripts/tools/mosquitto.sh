#!/bin/bash
# Val Ark - Download Mosquitto
source "$(dirname "$0")/_common.sh"

TOOL_NAME="mosquitto"
PINNED_VERSION="v2.0.20"

download_mosquitto() {
    log "Downloading ${TOOL_NAME}..."

    local repo_url="https://github.com/eclipse-mosquitto/mosquitto.git"
    local tag="${PINNED_VERSION}"
    local build_instructions="Mosquitto Build Instructions
==============================

Prerequisites:
  - cmake (>= 3.0)
  - make
  - gcc/g++ or clang
  - openssl development headers (libssl-dev / openssl-devel)
  - cJSON development headers (libcjson-dev) [optional]

Build steps:
  cd mosquitto
  mkdir build && cd build
  cmake .. -DCMAKE_INSTALL_PREFIX=\$(pwd)/install
  make -j\$(nproc)
  make install

The binaries will be in build/install/bin/ and build/install/sbin/

Key binaries:
  - mosquitto        (MQTT broker)
  - mosquitto_pub    (publish client)
  - mosquitto_sub    (subscribe client)
"

    local platforms="linux-arm64 linux-x86_64 macos-arm64 windows-x64"
    for platform in $platforms; do
        local dest="${TOOLS_DIR}/${platform}/mosquitto"
        clone_repo "$repo_url" "$tag" "$dest" "mosquitto ${platform}"

        # Write BUILD.txt
        ensure_dir "$dest"
        if [ ! -f "${dest}/BUILD.txt" ]; then
            echo "$build_instructions" > "${dest}/BUILD.txt"
            log_info "Created BUILD.txt for mosquitto (${platform})"
        fi
    done

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_mosquitto
