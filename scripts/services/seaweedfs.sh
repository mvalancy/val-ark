#!/bin/bash
###############################################################################
# Val Ark - SeaweedFS launcher
#
# Starts the mirrored `weed` binary as an all-in-one node (master + volume +
# filer + S3 gateway), using the data dir and ports resolved from the Val Ark
# environment (.env / valark-env.sh). Everything is overridable:
#
#   VALARK_SEAWEED_DIR          data dir (default <VALARK_HOME>/seaweedfs;
#                               pinned to a 2nd disk via .env on multi-NVMe boxes)
#   VALARK_SEAWEED_MASTER_PORT  default 9333
#   VALARK_SEAWEED_VOLUME_PORT  default 8085  (NOT 8080 — collides with some NAS
#                                              web stacks, e.g. openresty on UT2)
#   VALARK_SEAWEED_FILER_PORT   default 8889
#   VALARK_SEAWEED_S3_PORT      default 8333
#
# Usage:
#   scripts/services/seaweedfs.sh [start]   # run in foreground (default)
#   scripts/services/seaweedfs.sh status    # show listening ports / health
###############################################################################

set -o pipefail
_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$(dirname "$_DIR")/lib/valark-env.sh"

# --- Resolve the weed binary for this platform --------------------------------
case "$(uname -s)-$(uname -m)" in
    Linux-aarch64|Linux-arm64)   _plat="linux-arm64" ;;
    Linux-x86_64|Linux-amd64)    _plat="linux-x86_64" ;;
    Darwin-arm64)                _plat="macos-arm64" ;;
    *)                           _plat="linux-$(uname -m)" ;;
esac
WEED="${TOOLS_DIR}/${_plat}/seaweedfs/weed"
BIND_IP="${VALARK_SEAWEED_IP:-127.0.0.1}"

_status() {
    echo "SeaweedFS:"
    echo "  binary : $WEED $( [ -x "$WEED" ] && echo '(ok)' || echo '(MISSING — run: scripts/tools/seaweedfs.sh)')"
    echo "  data   : $SEAWEED_DIR ($(df -h "$SEAWEED_DIR" 2>/dev/null | awk 'NR==2{print $4" free"}'))"
    local p code
    for p in "master:$SEAWEED_MASTER_PORT" "volume:$SEAWEED_VOLUME_PORT" \
             "filer:$SEAWEED_FILER_PORT" "s3:$SEAWEED_S3_PORT"; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${BIND_IP}:${p##*:}/" 2>/dev/null)
        case "$code" in ''|000) code="down" ;; esac
        printf "  %-7s :%s -> %s\n" "${p%%:*}" "${p##*:}" "$code"
    done
}

case "${1:-start}" in
    status) _status ;;
    start)
        if [ ! -x "$WEED" ]; then
            echo "SeaweedFS binary not found: $WEED" >&2
            echo "Download it first: scripts/tools/seaweedfs.sh" >&2
            exit 1
        fi
        mkdir -p "$SEAWEED_DIR"
        echo "Starting SeaweedFS (all-in-one) on ${BIND_IP}"
        echo "  data=$SEAWEED_DIR  master=$SEAWEED_MASTER_PORT volume=$SEAWEED_VOLUME_PORT filer=$SEAWEED_FILER_PORT s3=$SEAWEED_S3_PORT"
        exec "$WEED" server \
            -dir="$SEAWEED_DIR" -ip="$BIND_IP" \
            -master.port="$SEAWEED_MASTER_PORT" \
            -volume.port="$SEAWEED_VOLUME_PORT" \
            -filer -filer.port="$SEAWEED_FILER_PORT" \
            -s3 -s3.port="$SEAWEED_S3_PORT"
        ;;
    *) echo "Usage: $0 [start|status]" >&2; exit 2 ;;
esac
