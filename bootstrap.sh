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
# the source tarball, then runs setup. Setup autodetects your storage disk, so
# there is usually nothing to edit — just run ./start.sh serve and open the box
# in a browser to finish setup (the hand-off below prints the exact command +
# URL). Then pull whatever tools/models/content you want through the web UI.
###############################################################################
set -e

###############################################################################
# Reusable, unit-testable hand-off helpers.
#
# `VALARK_BOOTSTRAP_LIB=1 . bootstrap.sh` loads ONLY these functions and stops
# (the sentinel below returns before the installer runs) so tests can assert the
# post-setup guidance offline — no network, no real setup, no server started.
# Production `curl … | bash` leaves the var unset and runs normally.
###############################################################################

# Read the web-UI port the owner configured (VALARK_WEB_PORT in .env), else the
# 3000 default. PURE: takes an .env path, echoes a port; ignores comments/junk.
bootstrap_port_from_env() {
    local envfile="$1" p=""
    if [ -f "$envfile" ]; then
        p="$(sed -n 's/^[[:space:]]*VALARK_WEB_PORT[[:space:]]*=[[:space:]]*//p' "$envfile" | tr -d "\"' " | head -1)"
    fi
    case "$p" in ''|*[!0-9]*) echo 3000 ;; *) echo "$p" ;; esac
}

# Verdict: would Val Ark's data land on the OS/boot volume (fill the system disk)
# instead of a real data disk? Mirrors scripts/setup.sh's check. PURE. Args:
#   1=DATA_ROOT 2=PROJECT_ROOT 3=df-source(DATA_ROOT) 4=df-source(/)
# Echoes 1 (system disk — the owner should point VAL_ARK_DATA at real storage)
# or 0 (a distinct data disk autodetected — no .env editing needed).
bootstrap_on_os_vol() {
    local data_root="$1" project_root="$2" data_src="$3" root_src="$4"
    if [ "$data_root" = "$project_root" ] || { [ -n "$data_src" ] && [ "$data_src" = "$root_src" ]; }; then
        echo 1
    else
        echo 0
    fi
}

# Compose the post-install "your box is ready — finish setup in a browser" block.
# PURE: no filesystem, no network. Args:
#   1=DIR  2=PORT  3=ON_OS_VOL(1=data would use the system disk)  4=HOST
# When ON_OS_VOL=0 we deliberately DO NOT tell the owner to hand-edit .env — the
# data disk autodetected, so that step is noise. And we print the CORRECT start
# command (`./start.sh serve` — plain `./start.sh` opens an interactive menu, not
# the web server) plus the exact URL of the first-boot wizard. (Epic #90.)
bootstrap_handoff() {
    local dir="$1" port="$2" on_os_vol="${3:-0}" host="${4:-localhost}"
    echo ""
    echo "=================================================================="
    echo "  Val Ark is installed.  One quick step to finish."
    echo "=================================================================="
    echo ""
    if [ "$on_os_vol" = "1" ]; then
        echo "  Heads up: no separate storage disk was found, so Val Ark would"
        echo "  use this machine's system disk. If you have a bigger disk, add"
        echo "  this one line to ${dir}/.env before starting (see .env.example):"
        echo ""
        echo "       VAL_ARK_DATA=/path/to/your/disk"
        echo ""
    else
        echo "  Your storage disk was detected automatically — nothing to edit."
        echo ""
    fi
    echo "  1) Start Val Ark:"
    echo ""
    echo "       cd ${dir} && ./start.sh serve"
    echo ""
    echo "  2) Open it in a web browser to finish setup:"
    echo ""
    echo "       http://${host}:${port}"
    echo ""
    echo "     Use that address on this machine; from a phone or laptop on the"
    echo "     same network, replace '${host}' with this box's IP address"
    echo "     ('hostname -I' shows it)."
    echo ""
    echo "  Tip: re-run bootstrap with VALARK_START=1 to start the server for you."
    echo "=================================================================="
}

# Resolve the real port + data-disk reality for the checkout at DIR, then print
# the hand-off. Kept separate from the pure formatter above. Sources valark-env
# in a subshell so bootstrap's own environment is never mutated.
bootstrap_print_handoff() {
    local dir="$1" base="${2:-}"
    local port; port="$(bootstrap_port_from_env "${dir}/.env")"
    local on_os_vol=0
    if [ -f "${dir}/scripts/lib/valark-env.sh" ]; then
        on_os_vol="$(
            cd "$dir" 2>/dev/null || { echo 0; exit 0; }
            # shellcheck disable=SC1091
            . scripts/lib/valark-env.sh 2>/dev/null || { echo 0; exit 0; }
            _r="$(df -P "${DATA_ROOT:-/}" 2>/dev/null | awk 'NR==2{print $1}')"
            _o="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
            bootstrap_on_os_vol "${DATA_ROOT:-}" "${PROJECT_ROOT:-x}" "$_r" "$_o"
        )"
        case "$on_os_vol" in 1) : ;; *) on_os_vol=0 ;; esac
    fi
    bootstrap_handoff "$dir" "$port" "$on_os_vol" "localhost"
    if [ -n "$base" ]; then
        echo ""
        echo "  Tools, models and the offline library are pulled from the web UI"
        echo "  (it mirrors from ${base})."
    fi
}

# Test hook: stop here when sourced as a library (see the block header above).
if [ -n "${VALARK_BOOTSTRAP_LIB:-}" ]; then return 0 2>/dev/null || exit 0; fi

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
    # Headless (VALARK_YES) and point setup at THIS Ark so it fetches the Node
    # runtime + deps from the LAN, not the internet — the offline promise.
    VALARK_YES="${VALARK_YES:-1}" VALARK_HOST="$BASE" bash scripts/setup.sh \
        || echo "   (setup reported issues — review its output; you can still run ./start.sh serve)"
fi

echo ""
echo "==> Val Ark bootstrapped into ${DIR}"
bootstrap_print_handoff "$DIR" "$BASE"

# Opt-in convenience: VALARK_START=1 launches the web server now (foreground).
# Off by default — a piped `curl … | bash` must never silently start a daemon.
# start.sh serve just binds the port, so a re-run is harmless (fails loudly if
# something already holds it); no data is touched.
if [ "${VALARK_START:-0}" = "1" ] && [ -f "${DIR}/start.sh" ]; then
    echo ""
    echo "==> VALARK_START=1 — starting the web server now (Ctrl-C to stop)…"
    exec bash "${DIR}/start.sh" serve
fi
