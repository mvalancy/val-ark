#!/bin/bash
# Val Ark - Mirror IRC Chat stack (ngIRCd server + The Lounge web client)
#
# "chat" is Val Ark's offline, federation-free real-time messaging service:
#   - ngIRCd  : a tiny, portable C IRC daemon (the protocol/server)
#   - The Lounge : a self-hosted Node web IRC client with persistent history
#                  (the framed web UI, reverse-proxied at /app/chat/)
#
# Neither component ships portable per-platform release binaries:
#   * ngIRCd is distributed as a source tarball (compiles cleanly with a C
#     toolchain on every aarch64 / x86_64 / macOS target).
#   * The Lounge is distributed as an npm package / git source (runs on the same
#     Node that already powers Val Ark's server.js).
# So we MIRROR the source (release tarball / git clone -> .tar.gz) into the tools
# tree for every platform, plus a build/install hint. This script only mirrors —
# it never installs anything system-wide.
source "$(dirname "$0")/_common.sh"

TOOL_NAME="chat"

# ngIRCd: latest GitHub release is the "rel-NN" tag carrying a ngircd-NN.tar.gz
# release asset (autotools source). Pin the known-good tag, fall back to live.
NGIRCD_REPO="ngircd/ngircd"
NGIRCD_PINNED_TAG="rel-27"
NGIRCD_PINNED_VER="27"          # tarball is ngircd-${VER}.tar.gz

# The Lounge: pure Node web client, no release binaries -> mirror source.
# v4.4.3 requires Node >=18 (runs on the common 18/20 baselines, incl. older ARM);
# v4.5.0 bumped to Node >=22, which many offline hosts won't have yet.
THELOUNGE_REPO="thelounge/thelounge"
THELOUNGE_PINNED_TAG="v4.4.3"

PLATFORMS="linux-arm64 linux-x86_64 macos-arm64 windows-x64"

_chat_build_hint() {
    local platform="$1"
    cat <<EOF
Val Ark - IRC Chat (ngIRCd + The Lounge)  [${platform}]
=======================================================

This directory mirrors the SOURCE for Val Ark's offline IRC chat service.
Nothing here is installed system-wide; the Val Ark host builds/runs it in place
via  scripts/services/chat.sh start.

Components
----------
  ngircd/        ngIRCd ${NGIRCD_PINNED_VER} source (release tarball, autotools)
  thelounge/     The Lounge ${THELOUNGE_PINNED_TAG} source (Node web IRC client)

Build ngIRCd (server) -- C toolchain required (gcc/clang + make):
  cd ngircd
  ./configure --prefix="\$PWD/_install" --without-tls   # add --with-openssl for TLS
  make -j\$(nproc) && make install
  # binary: _install/sbin/ngircd  (also picked up from src/ngircd/ngircd)

Build The Lounge (web client) -- Node 18+ and Yarn/npm required:
  cd thelounge
  yarn install && yarn build        # or: npm install && npm run build
  # run with: node index.js start   (config + data via THELOUNGE_HOME)

The Val Ark service wrapper (scripts/services/chat.sh) automates the above on
first start, binds the web UI to a fixed localhost port for the reverse proxy,
disables all server-to-server / internet relay (federation-free), and creates a
first-run admin account. See that script for details.

Windows note: build under WSL2, or use the upstream packages:
  ngIRCd  -> https://ngircd.barton.de/   (or build under MSYS2/Cygwin)
  The Lounge -> npm install -g thelounge ; thelounge start
EOF
}

download_chat() {
    log "Mirroring ${TOOL_NAME} (ngIRCd + The Lounge)..."

    # ---------------------------------------------------------------------
    # 1) ngIRCd server source (release tarball; same source serves every arch)
    # ---------------------------------------------------------------------
    local ng_tag ng_ver ng_url
    ng_tag=$(github_latest_tag "$NGIRCD_REPO" "$NGIRCD_PINNED_TAG")
    # Derive the numeric version from the tag (rel-27 -> 27); fall back to pin.
    ng_ver="${ng_tag#rel-}"
    case "$ng_ver" in ''|*[!0-9.]*) ng_ver="$NGIRCD_PINNED_VER" ;; esac

    # Prefer the release asset; if the live tag has no matching asset, fall back
    # to the pinned release URL (verified reachable).
    ng_url=$(github_asset_url "$NGIRCD_REPO" "$ng_tag" "ngircd-.*\.tar\.gz$")
    if [ -z "$ng_url" ]; then
        ng_url="https://github.com/${NGIRCD_REPO}/releases/download/${NGIRCD_PINNED_TAG}/ngircd-${NGIRCD_PINNED_VER}.tar.gz"
        log_warn "ngIRCd: no live asset for ${ng_tag}; using pinned ${ng_url}"
    fi

    # ---------------------------------------------------------------------
    # 2) The Lounge web client source (git clone -> .tar.gz for offline use)
    # ---------------------------------------------------------------------
    # Pin The Lounge to THELOUNGE_PINNED_TAG directly (do NOT follow upstream
    # latest): newer releases require Node >=22, which many offline/ARM hosts
    # won't have. v4.4.3 runs on Node >=18.
    local tl_tag="$THELOUNGE_PINNED_TAG"

    local platform dest
    for platform in $PLATFORMS; do
        dest="${TOOLS_DIR}/${platform}/chat"
        ensure_dir "$dest"

        # ngIRCd source (extracted, strip the ngircd-NN/ top dir)
        download_and_extract "$ng_url" "${dest}/ngircd" "ngircd ${ng_ver} source (${platform})" 1

        # The Lounge source (shallow clone of the pinned tag + offline tarball).
        # clone_repo also writes ${dest}/thelounge.tar.gz via create_source_tarball.
        if command -v git >/dev/null 2>&1; then
            clone_repo "https://github.com/${THELOUNGE_REPO}.git" "$tl_tag" \
                "${dest}/thelounge" "thelounge ${tl_tag} (${platform})"
        else
            log_warn "git not available; mirroring The Lounge source tarball via archive"
            download_and_extract \
                "https://github.com/${THELOUNGE_REPO}/archive/refs/tags/${tl_tag}.tar.gz" \
                "${dest}/thelounge" "thelounge ${tl_tag} archive (${platform})" 1
        fi

        write_install_hint "$dest" "chat (${platform})" "$(_chat_build_hint "$platform")"
    done

    log_success "${TOOL_NAME} mirror complete (ngIRCd ${ng_ver} + The Lounge ${tl_tag})."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_chat
