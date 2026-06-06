#!/bin/bash
###############################################################################
# Val Ark - Mirror Message Boards (NodeBB)
#
# NodeBB is a Node.js forum platform distributed as SOURCE (no prebuilt portable
# binaries). We mirror the source so the Val Ark box can stand it up fully
# offline, backed by the Redis that Val Ark already mirrors (no Mongo needed).
#
# This script ONLY mirrors into the tools tree. It never installs anything
# system-wide and never runs `npm install` (that happens on the serving host via
# scripts/services/forum.sh, which can use a local/offline npm cache).
###############################################################################
source "$(dirname "$0")/_common.sh"

TOOL_NAME="forum"
DISPLAY_NAME="Message Boards (NodeBB)"
# Pin a known-good v4 release; fall back to live latest if reachable.
PINNED_VERSION="v4.12.0"
REPO="NodeBB/NodeBB"

download_forum() {
    log "Downloading ${DISPLAY_NAME}..."

    local tag
    tag=$(github_latest_tag "$REPO" "$PINNED_VERSION")
    local ver="${tag#v}"

    # NodeBB has no portable per-arch binary. The same Node source runs on every
    # platform, so we mirror ONE source tree and produce a downloadable tarball,
    # then drop a platform-appropriate install hint into each tools dir.
    local src_url="https://github.com/${REPO}/archive/refs/tags/${tag}.tar.gz"

    # Mirror source into the architecture-neutral linux-x86_64 slot and tar it.
    local src_dest="${TOOLS_DIR}/linux-x86_64/forum/nodebb-${ver}"
    download_and_extract "$src_url" "$src_dest" "NodeBB source ${tag}" 1
    if [ -d "$src_dest" ]; then
        create_source_tarball "$src_dest" "nodebb-${ver}" "$tag"
    fi

    # Per-platform install hints. NodeBB is identical source on all platforms; the
    # only platform-specific concern is how Node.js itself is obtained. Val Ark
    # already mirrors a standalone Python; Node is documented as a runtime dep.
    local hint
    hint=$(_forum_install_hint "$tag" "$ver" "$src_url")

    # linux-arm64 (Jetson Orin/Thor, GB10, OpenWRT) - same source tree
    local arm_dest="${TOOLS_DIR}/linux-arm64/forum"
    ensure_dir "$arm_dest"
    write_install_hint "$arm_dest" "${TOOL_NAME} (linux-arm64)" "$hint"
    # Make the mirrored source available to ARM hosts too without a second copy:
    # point a relative pointer file at the shared tarball.
    _forum_source_pointer "$arm_dest" "$ver"

    # linux-x86_64 - source lives here; just add the hint alongside it
    write_install_hint "${TOOLS_DIR}/linux-x86_64/forum" "${TOOL_NAME} (linux-x86_64)" "$hint"

    # macos-arm64
    local mac_dest="${TOOLS_DIR}/macos-arm64/forum"
    ensure_dir "$mac_dest"
    write_install_hint "$mac_dest" "${TOOL_NAME} (macos-arm64)" "$hint"
    _forum_source_pointer "$mac_dest" "$ver"

    # windows-x64
    local win_dest="${TOOLS_DIR}/windows-x64/forum"
    ensure_dir "$win_dest"
    write_install_hint "$win_dest" "${TOOL_NAME} (windows-x64)" "$hint"
    _forum_source_pointer "$win_dest" "$ver"

    log_success "${DISPLAY_NAME} mirror complete."
}

# Write a small pointer so every platform dir tells the user/host where the
# single shared source tarball lives (avoids mirroring the tree 4x).
_forum_source_pointer() {
    local dir="$1" ver="$2"
    ensure_dir "$dir"
    if [ ! -f "${dir}/SOURCE.txt" ]; then
        cat > "${dir}/SOURCE.txt" <<EOF
NodeBB source is mirrored once (architecture-neutral Node.js source) at:
  tools/linux-x86_64/forum/nodebb-${ver}/
  tools/linux-x86_64/forum/nodebb-${ver}.tar.gz   (downloadable archive)

Run it with: scripts/services/forum.sh start
EOF
    fi
}

_forum_install_hint() {
    local tag="$1" ver="$2" src_url="$3"
    cat <<EOF
Message Boards - NodeBB ${tag}
==============================================

NodeBB is an async forum / message-board platform (threads, categories,
announcements, Q&A). It is a Node.js application and is mirrored here as SOURCE
(no standalone binary exists). Val Ark runs it offline using the Redis it
already mirrors -- no MongoDB required.

RUNTIME REQUIREMENTS
  - Node.js 20+  (NodeBB ${tag} targets Node 20/22 LTS).
      Val Ark does not bundle Node; install it on the serving host, e.g.
      mirror a Node tarball into tools/<platform>/node/ or use the system Node.
  - Redis        (use the Val Ark-mirrored redis: tools/<platform>/redis/).
      NodeBB stores everything in Redis -- no separate Mongo instance.

OFFLINE STAND-UP (handled for you by Val Ark)
  scripts/services/forum.sh start     # starts Redis if needed, then NodeBB
  scripts/services/forum.sh status
  scripts/services/forum.sh stop

  The web UI listens on 127.0.0.1:4567 and Val Ark reverse-proxies it at
  http://<val-ark>/app/forum/. First run prompts you to create the admin
  account (or set VALARK_FORUM_ADMIN_* env vars -- see the service script).

MANUAL INSTALL (if you are NOT using the Val Ark service supervisor)
  1. Extract the mirrored source:
       tar -xzf nodebb-${ver}.tar.gz && cd nodebb-${ver}
  2. Install dependencies (needs an npm registry OR an offline npm cache):
       npm install --omit=dev
  3. Point it at Redis and set up the admin user:
       ./nodebb setup
       (choose "redis" as the database; host 127.0.0.1, port 6379)
  4. Start it:
       ./nodebb start          # serves on http://127.0.0.1:4567

Source archive: ${src_url}
Project:        https://github.com/${REPO}
Docs:           https://docs.nodebb.org/

NOTE: Federation / social-login / outbound webhooks must stay DISABLED for an
offline box. The Val Ark service script never enables them.
EOF
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_forum
