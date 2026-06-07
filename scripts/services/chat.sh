#!/bin/bash
###############################################################################
# Val Ark - IRC Chat service (ngIRCd + The Lounge)
#
# Runs Val Ark's offline, federation-free real-time chat on the LAN:
#   - ngIRCd      : tiny C IRC daemon  (the protocol/server, port 6667)
#   - The Lounge  : Node web IRC client with persistent history, bound to a
#                   FIXED localhost port (9000) so Val Ark's web server can
#                   reverse-proxy it at  /app/chat/.
#
# Subcommands:  start | stop | status
#
# Security / offline posture:
#   * NO server-to-server links, NO internet relay, NO federation. ngIRCd is
#     configured with zero [Server] blocks and the web client is single-org.
#   * Everything binds to ${VALARK_BIND} (default 0.0.0.0 = whole LAN; set
#     VALARK_BIND=127.0.0.1 in .env to keep it host-only). It never reaches out.
#   * The web client (The Lounge) listens ONLY on 127.0.0.1 — it is reachable
#     from the LAN solely through the Val Ark reverse proxy, which can enforce
#     its own access control. The Lounge itself requires per-user login; a
#     first-run admin account is created automatically (see ADMIN setup below).
#
# Data lives under the Val Ark data tree:
#   ${STATE_DIR}/services/chat/{ngircd,thelounge,logs,run}
# Nothing is installed system-wide; binaries are built in-place from the mirror.
###############################################################################
# --- Resolve environment / data layout ----------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SELF_DIR")")"
# valark-env.sh expects nounset OFF (it reads optional, possibly-unset vars).
# shellcheck source=../lib/valark-env.sh
. "${PROJECT_ROOT}/scripts/lib/valark-env.sh"
set -u

# --- Service constants ---------------------------------------------------------
IRC_PORT="${VALARK_CHAT_IRC_PORT:-6667}"     # ngIRCd listen port (LAN)
WEB_PORT="${VALARK_CHAT_WEB_PORT:-9000}"     # The Lounge web UI (localhost only; reverse-proxied at /app/chat/)
# ngIRCd binds loopback by default (The Lounge connects via 127.0.0.1; the web
# UI is the supported entry point). Set VALARK_BIND=0.0.0.0 to also let native IRC
# clients on the LAN connect — if you do, set a connect Password (ngIRCd has none
# by default, so a LAN bind would accept unauthenticated connections).
BIND="${VALARK_BIND:-127.0.0.1}"             # IRC bind address; honour VALARK_BIND
NETWORK_NAME="${VALARK_CHAT_NETWORK:-Val Ark}"

CHAT_HOME="${STATE_DIR}/services/chat"
NGIRCD_HOME="${CHAT_HOME}/ngircd"
THELOUNGE_HOME="${CHAT_HOME}/thelounge"      # The Lounge data/config dir (THELOUNGE_HOME)
RUN_DIR="${CHAT_HOME}/run"
LOG_DIR_CHAT="${CHAT_HOME}/logs"

NGIRCD_PID="${RUN_DIR}/ngircd.pid"
THELOUNGE_PID="${RUN_DIR}/thelounge.pid"
NGIRCD_CONF="${NGIRCD_HOME}/ngircd.conf"

# Platform tools dir holding the mirrored source (from scripts/tools/chat.sh)
_arch="$(uname -m)"
case "$_arch" in
    aarch64|arm64) PLATFORM="linux-arm64" ;;
    x86_64|amd64)  PLATFORM="linux-x86_64" ;;
    *)             PLATFORM="linux-x86_64" ;;
esac
case "$(uname -s)" in Darwin) PLATFORM="macos-arm64" ;; esac
SRC_DIR="${TOOLS_DIR}/${PLATFORM}/chat"
NGIRCD_SRC="${SRC_DIR}/ngircd"
THELOUNGE_SRC="${SRC_DIR}/thelounge"

# --- Logging -------------------------------------------------------------------
log()  { echo "[chat] $*"; }
err()  { echo "[chat] ERROR: $*" >&2; }
warn() { echo "[chat] WARN: $*" >&2; }

# --- Node resolution (same scheme as loop.sh) ----------------------------------
_chat_node() {
    local n="$HOME/.nvm/versions/node/v20.20.2/bin/node"
    [ -x "$n" ] || n="$(command -v node 2>/dev/null)"
    echo "$n"
}

_is_running() {  # _is_running <pidfile>
    local pf="$1" pid
    [ -f "$pf" ] || return 1
    pid="$(cat "$pf" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

###############################################################################
# Build (in-place, idempotent) -- only runs when a binary/build is missing.
###############################################################################
_ngircd_bin() {
    # Prefer an installed/built binary; search the usual autotools output paths.
    local b
    for b in "${NGIRCD_HOME}/_install/sbin/ngircd" "${NGIRCD_SRC}/src/ngircd/ngircd"; do
        [ -x "$b" ] && { echo "$b"; return 0; }
    done
    return 1
}

_build_ngircd() {
    _ngircd_bin >/dev/null 2>&1 && return 0
    [ -d "$NGIRCD_SRC" ] || { err "ngIRCd source missing at ${NGIRCD_SRC} (run scripts/tools/chat.sh)"; return 1; }
    command -v make >/dev/null 2>&1 || { err "make not found; cannot build ngIRCd"; return 1; }

    log "Building ngIRCd from ${NGIRCD_SRC} (one-time)..."
    mkdir -p "${NGIRCD_HOME}/_install"
    ( cd "$NGIRCD_SRC" \
        && { [ -x ./configure ] || ./autogen.sh >/dev/null 2>&1 || true; } \
        && ./configure --prefix="${NGIRCD_HOME}/_install" --without-tls >"${LOG_DIR_CHAT}/ngircd-build.log" 2>&1 \
        && make -j"$(nproc 2>/dev/null || echo 2)" >>"${LOG_DIR_CHAT}/ngircd-build.log" 2>&1 \
        && make install >>"${LOG_DIR_CHAT}/ngircd-build.log" 2>&1 )

    if _ngircd_bin >/dev/null 2>&1; then
        log "ngIRCd built: $(_ngircd_bin)"
    else
        err "ngIRCd build failed; see ${LOG_DIR_CHAT}/ngircd-build.log"
        return 1
    fi
}

_build_thelounge() {
    [ -f "${THELOUNGE_SRC}/index.js" ] || [ -f "${THELOUNGE_SRC}/package.json" ] \
        || { err "The Lounge source missing at ${THELOUNGE_SRC} (run scripts/tools/chat.sh)"; return 1; }
    # Already built? dist/ (or public/) present means yarn build ran.
    [ -d "${THELOUNGE_SRC}/public" ] && [ -d "${THELOUNGE_SRC}/node_modules" ] && return 0

    local node; node="$(_chat_node)"
    [ -n "$node" ] || { err "node not found; The Lounge needs Node 18+"; return 1; }
    local nodedir; nodedir="$(dirname "$node")"

    log "Building The Lounge from ${THELOUNGE_SRC} (one-time; needs network the FIRST time only)..."
    if PATH="${nodedir}:$PATH" sh -c 'command -v yarn >/dev/null 2>&1'; then
        ( cd "$THELOUNGE_SRC" && PATH="${nodedir}:$PATH" yarn install >"${LOG_DIR_CHAT}/thelounge-build.log" 2>&1 \
            && PATH="${nodedir}:$PATH" yarn build >>"${LOG_DIR_CHAT}/thelounge-build.log" 2>&1 )
    else
        # --legacy-peer-deps: The Lounge has an internal peer-dep mismatch
        # (@textcomplete/core) that strict npm (v7+) refuses; yarn and older npm
        # tolerated it. This accepts the upstream-intended resolution.
        ( cd "$THELOUNGE_SRC" && PATH="${nodedir}:$PATH" npm install --legacy-peer-deps >"${LOG_DIR_CHAT}/thelounge-build.log" 2>&1 \
            && PATH="${nodedir}:$PATH" npm run build >>"${LOG_DIR_CHAT}/thelounge-build.log" 2>&1 )
    fi
    if [ -d "${THELOUNGE_SRC}/public" ]; then
        log "The Lounge built."
    else
        warn "The Lounge build incomplete; see ${LOG_DIR_CHAT}/thelounge-build.log"
        return 1
    fi
}

###############################################################################
# Config generation (idempotent) -- federation OFF, LAN-only, auth required.
###############################################################################
_write_ngircd_conf() {
    # Regenerate EVERY start so a stale config can never persist — in particular
    # an older LAN-exposed `Listen = 0.0.0.0` (which left IRC open to the whole
    # LAN with no password). Back up any prior file once.
    if [ -f "$NGIRCD_CONF" ]; then cp -f "$NGIRCD_CONF" "${NGIRCD_CONF}.bak" 2>/dev/null || true; fi
    log "Writing ngIRCd config (federation-free, bind ${BIND})..."
    # This ngIRCd build has no TLS. Chat is kept encrypted by binding ngIRCd to
    # loopback (the plaintext IRC hop never leaves the box — only The Lounge talks
    # to it over 127.0.0.1) and serving The Lounge to users through the Ark's
    # HTTPS reverse proxy at /app/chat/. If an operator LAN-exposes ngIRCd
    # (VALARK_BIND=0.0.0.0), native IRC on :${IRC_PORT} would be PLAINTEXT — warn.
    if [ "$BIND" != "127.0.0.1" ] && [ "$BIND" != "::1" ] && [ "$BIND" != "localhost" ]; then
        log "WARNING: ngIRCd is LAN-exposed (bind ${BIND}) and this build has no TLS — native IRC on :${IRC_PORT} is PLAINTEXT and unauthenticated. Prefer VALARK_BIND=127.0.0.1 and reach chat via The Lounge over the Ark's HTTPS proxy."
    fi
    # NOTE: deliberately NO [Server] blocks => no server-to-server links / relay.
    cat > "$NGIRCD_CONF" <<EOF
# Val Ark IRC server - offline, federation-free. Generated by services/chat.sh.
[Global]
    Name = valark.irc.local
    Info = Val Ark offline IRC
    Network = ${NETWORK_NAME}
    # Bind to the LAN (or 127.0.0.1 if VALARK_BIND is set). NO uplinks defined.
    Listen = ${BIND}
    Ports = ${IRC_PORT}
    MotdText = Welcome to the Val Ark offline IRC server. Be excellent to each other.
    PidFile = ${NGIRCD_PID}

[Limits]
    MaxConnections = 0
    MaxConnectionsIP = 0
    MaxJoins = 0

[Options]
    # No DNS / Ident lookups (offline box; keeps connects instant).
    DNS = no
    Ident = no
    PAM = no
    # Connections never relay outward: there are intentionally no [Server] sections.
    AllowRemoteOper = no

[Channel]
    Name = #valark
    Topic = Val Ark community channel
    Modes = tn
EOF
}

# The Lounge: private mode (login required), bound to localhost for the proxy.
_write_thelounge_conf() {
    local cfg="${THELOUNGE_HOME}/config.js"
    [ -f "$cfg" ] && return 0
    mkdir -p "$THELOUNGE_HOME"
    log "Writing The Lounge config (private/login-required, localhost:${WEB_PORT}, reverse-proxy /app/chat/)..."
    cat > "$cfg" <<EOF
"use strict";
// Val Ark - The Lounge config. Generated by services/chat.sh.
module.exports = {
    // Listen on localhost ONLY; Val Ark reverse-proxies this at /app/chat/.
    host: "127.0.0.1",
    port: ${WEB_PORT},
    bind: "127.0.0.1",
    reverseProxy: true,
    public: false,            // private mode => every user must log in (auth required)
    prefetch: false,          // offline box: never fetch link previews from the internet
    disableMediaPreview: true,
    lockNetwork: true,        // users cannot add arbitrary (internet) IRC networks
    leaveMessage: "Val Ark offline IRC",
    defaults: {
        name: "${NETWORK_NAME}",
        host: "127.0.0.1",    // local ngIRCd only
        port: ${IRC_PORT},
        tls: false,
        rejectUnauthorized: false,
        nick: "valark-user",
        username: "valark",
        realname: "Val Ark user",
        join: "#valark"
    },
    // Persistent history (the whole point of The Lounge): keep messages on disk.
    messageStorage: ["sqlite", "text"],
    maxHistory: 10000
};
EOF
}

###############################################################################
# Admin / first-run account
###############################################################################
_ensure_admin() {
    # The Lounge stores users under ${THELOUNGE_HOME}/users/*.json. If none exist,
    # create an "admin" with a generated password (printed once) so the operator
    # has a working login on first start. Override creds via env if desired.
    local users_dir="${THELOUNGE_HOME}/users"
    if [ -d "$users_dir" ] && [ -n "$(ls -A "$users_dir" 2>/dev/null)" ]; then
        return 0
    fi
    local node nodedir admin pass
    node="$(_chat_node)"; [ -n "$node" ] || return 0
    nodedir="$(dirname "$node")"
    admin="${VALARK_CHAT_ADMIN_USER:-admin}"
    pass="${VALARK_CHAT_ADMIN_PASS:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)}"
    [ -n "$pass" ] || pass="valark-change-me"

    log "Creating first-run admin account '${admin}'..."
    ( cd "$THELOUNGE_SRC" \
        && THELOUNGE_HOME="$THELOUNGE_HOME" PATH="${nodedir}:$PATH" \
           "$node" index.js add "$admin" --password "$pass" >/dev/null 2>&1 ) || {
        warn "Automatic admin creation failed; create one manually:"
        warn "  THELOUNGE_HOME='${THELOUNGE_HOME}' '${node}' '${THELOUNGE_SRC}/index.js' add ${admin}"
        return 0
    }
    # Persist the generated credential to a 600 file instead of printing it to
    # stdout (which lands in logs that may be world-readable / NFS-exported).
    local cred="${THELOUNGE_HOME}/admin-credentials.txt"
    umask 077
    { echo "CHAT_ADMIN_USER='${admin}'"; echo "CHAT_ADMIN_PASS='${pass}'"; } > "$cred"
    chmod 600 "$cred" 2>/dev/null || true
    if [ -n "$(find "$cred" -perm /0077 2>/dev/null)" ]; then
        warn "${cred} is world-accessible (filesystem ignores chmod — likely NTFS/FUSE). Do NOT NFS-export the state tree; relocate secrets to an ext4 path for real 600."
    fi
    log "First-run admin '${admin}' created; credential saved to ${cred} (chmod 600). Change it after first login, or pin VALARK_CHAT_ADMIN_USER/_PASS in .env."
}

###############################################################################
# start / stop / status
###############################################################################
cmd_start() {
    valark_ensure_layout 2>/dev/null || true
    mkdir -p "$NGIRCD_HOME" "$THELOUNGE_HOME" "$RUN_DIR" "$LOG_DIR_CHAT"

    # --- ngIRCd ---------------------------------------------------------------
    if _is_running "$NGIRCD_PID"; then
        log "ngIRCd already running (pid $(cat "$NGIRCD_PID"))."
    else
        _build_ngircd || return 1
        _write_ngircd_conf
        local bin; bin="$(_ngircd_bin)"
        log "Starting ngIRCd on ${BIND}:${IRC_PORT} (federation-free)..."
        # -n = no fork (we background it ourselves and own the pidfile);
        # -f = config file. ngIRCd also writes PidFile from the config.
        setsid nohup "$bin" -n -f "$NGIRCD_CONF" >"${LOG_DIR_CHAT}/ngircd.out" 2>&1 </dev/null &
        echo $! > "$NGIRCD_PID"
        disown 2>/dev/null || true
    fi

    # --- The Lounge (web UI) --------------------------------------------------
    if _is_running "$THELOUNGE_PID"; then
        log "The Lounge already running (pid $(cat "$THELOUNGE_PID"))."
    else
        _build_thelounge || { warn "The Lounge not started (build needed)."; return 1; }
        _write_thelounge_conf
        _ensure_admin
        local node nodedir; node="$(_chat_node)"
        [ -n "$node" ] || { err "node not found; cannot start The Lounge"; return 1; }
        nodedir="$(dirname "$node")"
        log "Starting The Lounge web UI on 127.0.0.1:${WEB_PORT} (proxy at /app/chat/)..."
        ( cd "$THELOUNGE_SRC" \
            && THELOUNGE_HOME="$THELOUNGE_HOME" PATH="${nodedir}:$PATH" \
               setsid nohup "$node" index.js start >"${LOG_DIR_CHAT}/thelounge.out" 2>&1 </dev/null &
            echo $! > "$THELOUNGE_PID" )
        disown 2>/dev/null || true
    fi

    sleep 1
    cmd_status
}

cmd_stop() {
    local pf pid stopped=0
    for pf in "$THELOUNGE_PID" "$NGIRCD_PID"; do
        if _is_running "$pf"; then
            pid="$(cat "$pf")"
            log "Stopping pid ${pid} ($(basename "$pf" .pid))..."
            kill "$pid" 2>/dev/null
            stopped=1
        fi
        rm -f "$pf" 2>/dev/null
    done
    # Backstop: free the ports if the pidfiles were stale.
    command -v fuser >/dev/null 2>&1 && { fuser -k "${IRC_PORT}/tcp" 2>/dev/null; fuser -k "${WEB_PORT}/tcp" 2>/dev/null; }
    [ "$stopped" -eq 1 ] && log "Stopped." || log "Nothing running."
}

cmd_status() {
    local ng_state tl_state
    if _is_running "$NGIRCD_PID"; then ng_state="running (pid $(cat "$NGIRCD_PID"))"; else ng_state="stopped"; fi
    if _is_running "$THELOUNGE_PID"; then tl_state="running (pid $(cat "$THELOUNGE_PID"))"; else tl_state="stopped"; fi
    cat <<EOF
Val Ark IRC Chat
  ngIRCd (server)    : ${ng_state}   ${BIND}:${IRC_PORT}  (federation-free)
  The Lounge (web)   : ${tl_state}   127.0.0.1:${WEB_PORT}  (proxy: /app/chat/)
  data               : ${CHAT_HOME}
  source             : ${SRC_DIR}
EOF
    # Liveness probe on the web UI for orchestrators/verify.
    if curl -fsS --max-time 4 "http://127.0.0.1:${WEB_PORT}/" >/dev/null 2>&1; then
        echo "  web probe          : OK (http://127.0.0.1:${WEB_PORT}/)"
    else
        echo "  web probe          : not responding yet"
    fi
}

case "${1:-status}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    restart) cmd_stop; sleep 1; cmd_start ;;
    status) cmd_status ;;
    *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
