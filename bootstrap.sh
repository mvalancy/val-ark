#!/bin/bash
###############################################################################
# Val Ark - OFFLINE bootstrap.
#
# Stand up a new Val Ark node by pulling the whole system from a trusted Ark host
# already on your LAN — no internet required (power outage, air-gapped mesh, dead
# uplink). The source Ark serves its own code + a bootstrap at /bootstrap.sh.
#
# Easiest (host is baked in when fetched from a live Ark):
#     curl -fsSL http://<ark-host>:3000/bootstrap.sh | bash
#
# Or run the file directly, naming the host:
#     ./bootstrap.sh <ark-host>[:port] [target-dir]
#     VALARK_HOST=ark.local VALARK_DIR=~/val-ark ./bootstrap.sh
#
# It clones Val Ark's git bundle (full history) when git is available, else pulls
# the source tarball, then runs setup. After that, point VAL_ARK_DATA at your disk
# in .env and run ./start.sh — then pull whatever tools/models/content you want
# from the same host through the web UI.
###############################################################################
set -e

HOST="${1:-${VALARK_HOST:-__VALARK_HOST__}}"
DIR="${2:-${VALARK_DIR:-$HOME/Code/val-ark}}"

if [ "$HOST" = "__VALARK_HOST__" ] || [ -z "$HOST" ]; then
    echo "Val Ark bootstrap"
    echo "Usage: bootstrap.sh <ark-host>[:port] [target-dir]   (or set VALARK_HOST)"
    echo "   e.g. bootstrap.sh 192.168.1.50:3000"
    exit 1
fi

case "$HOST" in
    http://*|https://*) BASE="$HOST" ;;
    *:*)                BASE="http://$HOST" ;;
    *)                  BASE="http://$HOST:3000" ;;
esac
BASE="${BASE%/}"

echo "==> Val Ark bootstrap from ${BASE} into ${DIR}"

need() { command -v "$1" >/dev/null 2>&1; }
need curl || { echo "ERROR: curl is required"; exit 1; }

if [ -e "$DIR/.git" ] || [ -e "$DIR/scripts/setup.sh" ]; then
    echo "==> ${DIR} already looks like a Val Ark checkout — updating in place"
    if [ -d "$DIR/.git" ] && need git; then ( cd "$DIR" && git pull --ff-only 2>/dev/null || true ); fi
else
    mkdir -p "$(dirname "$DIR")"
    if need git && curl -fsI "${BASE}/sources/val-ark/val-ark.bundle" >/dev/null 2>&1; then
        echo "==> cloning from the offline git bundle (full history)"
        tmp="$(mktemp -d)"
        curl -fSL "${BASE}/sources/val-ark/val-ark.bundle" -o "${tmp}/val-ark.bundle"
        git clone -q "${tmp}/val-ark.bundle" "$DIR"
        rm -rf "$tmp"
        # Re-point origin at the LAN host so future pulls stay offline-friendly.
        ( cd "$DIR" && git remote set-url origin "${BASE}/sources/val-ark/val-ark.bundle" 2>/dev/null || true )
    else
        echo "==> fetching the source tarball"
        tmp="$(mktemp -d)"
        curl -fSL "${BASE}/sources/val-ark/val-ark-latest.tar.gz" -o "${tmp}/val-ark.tgz"
        mkdir -p "$DIR"
        # tarball has a val-ark/ prefix; strip it into DIR
        tar -xzf "${tmp}/val-ark.tgz" -C "$DIR" --strip-components=1
        rm -rf "$tmp"
    fi
fi

cd "$DIR"
echo "==> running setup (scripts/setup.sh)"
if [ -x scripts/setup.sh ] || [ -f scripts/setup.sh ]; then
    bash scripts/setup.sh || echo "   (setup reported issues — review its output; you can still ./start.sh)"
fi

cat <<EOF

==> Val Ark bootstrapped into ${DIR}
    Next:
      1. Point VAL_ARK_DATA at your disk in ${DIR}/.env   (see .env.example)
      2. ./start.sh                                        (starts the web UI)
      3. Open the UI and pull tools / models / library content from ${BASE}
EOF
