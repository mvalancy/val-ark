#!/bin/bash
###############################################################################
# Val Ark - Files & Pastebin service (MicroBin)
#
# Runs the mirrored MicroBin binary so the Val Ark HOST serves a pastebin +
# file-upload + URL-shortener to the LAN, reverse-proxied by server.js at
# /app/paste/. Subcommands: start | stop | status | restart.
#
#   - LAN-only by intent. Binds VALARK_BIND (default 127.0.0.1 so only the
#     local reverse proxy reaches it; set VALARK_BIND=0.0.0.0 to expose direct).
#   - Web UI listens on a FIXED localhost port (PASTE_PORT, default 8085) so the
#     Val Ark web server can reverse-proxy it at /app/paste/.
#   - NEVER enables internet relay/federation: MicroBin has none, and we also
#     disable its telemetry + update-check so it makes zero outbound calls.
#   - Auth is REQUIRED: instance is gated by HTTP Basic auth (browse/read), and
#     admin actions need the admin password. Credentials are generated on first
#     run and written to <data>/credentials.txt (chmod 600). Override via env:
#       PASTE_ADMIN_PASSWORD, PASTE_AUTH_USER, PASTE_AUTH_PASSWORD.
#   - Dependency-light: MicroBin is a single static binary. No node, no redis.
#   - Data lives under the Val Ark data tree (STATE_DIR/services/paste).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Resolve the unified data-root layout (TOOLS_DIR, STATE_DIR, DATA_ROOT, ...).
if [ -f "${PROJECT_ROOT}/scripts/lib/valark-env.sh" ]; then
    # shellcheck source=../lib/valark-env.sh
    . "${PROJECT_ROOT}/scripts/lib/valark-env.sh"
fi
TOOLS_DIR="${TOOLS_DIR:-${PROJECT_ROOT}/tools}"
STATE_DIR="${STATE_DIR:-${PROJECT_ROOT}/state}"

# --- Configuration ------------------------------------------------------------
PASTE_PORT="${PASTE_PORT:-8085}"           # fixed localhost port for reverse proxy
VALARK_BIND="${VALARK_BIND:-127.0.0.1}"    # LAN-only intent; 0.0.0.0 to expose
PUBLIC_PATH="${PASTE_PUBLIC_PATH:-/app/paste/}"  # reverse-proxy mount point

DATA_DIR="${PASTE_DATA_DIR:-${STATE_DIR}/services/paste}"
PID_FILE="${DATA_DIR}/paste.pid"
LOG_FILE="${DATA_DIR}/paste.log"
CRED_FILE="${DATA_DIR}/credentials.txt"

# --- Helpers ------------------------------------------------------------------
_log()  { echo "[paste] $*"; }
_err()  { echo "[paste] ERROR: $*" >&2; }

# Pick the right mirrored binary for this host's OS/arch.
_paste_bin() {
    local os arch sub bin
    os="$(uname -s)"; arch="$(uname -m)"
    case "$os" in
        Linux)
            case "$arch" in
                aarch64|arm64) sub="linux-arm64" ;;
                x86_64|amd64)  sub="linux-x86_64" ;;
                *) sub="linux-x86_64" ;;
            esac
            bin="microbin"
            ;;
        Darwin) sub="macos-arm64"; bin="microbin" ;;
        *)      sub="windows-x64"; bin="microbin.exe" ;;
    esac
    echo "${TOOLS_DIR}/${sub}/paste/${bin}"
}

# Generate a random URL-safe token (no internet, no extra deps).
_gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24
    elif [ -r /dev/urandom ]; then
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24
    else
        echo "valark$(date +%s)$$"
    fi
}

# Create/read persistent credentials so auth is enforced on first run.
_ensure_credentials() {
    mkdir -p "$DATA_DIR" 2>/dev/null || true
    if [ -f "$CRED_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CRED_FILE"
    fi
    PASTE_AUTH_USER="${PASTE_AUTH_USER:-${PASTE_AUTH_USER_SAVED:-valark}}"
    PASTE_AUTH_PASSWORD="${PASTE_AUTH_PASSWORD:-${PASTE_AUTH_PASSWORD_SAVED:-$(_gen_secret)}}"
    PASTE_ADMIN_PASSWORD="${PASTE_ADMIN_PASSWORD:-${PASTE_ADMIN_PASSWORD_SAVED:-$(_gen_secret)}}"
    # Persist so credentials are stable across restarts.
    umask 077
    {
        echo "# Val Ark Files & Pastebin (MicroBin) credentials - generated $(date)"
        echo "# Browse/read is gated by HTTP Basic auth; admin actions need the admin password."
        echo "PASTE_AUTH_USER_SAVED='${PASTE_AUTH_USER}'"
        echo "PASTE_AUTH_PASSWORD_SAVED='${PASTE_AUTH_PASSWORD}'"
        echo "PASTE_ADMIN_PASSWORD_SAVED='${PASTE_ADMIN_PASSWORD}'"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE" 2>/dev/null || true
    # NTFS/exFAT/FUSE data disks silently ignore chmod and force world-readable
    # perms. Warn loudly if so — secrets here must NOT be NFS-exported.
    if [ -n "$(find "$CRED_FILE" -perm /0077 2>/dev/null)" ]; then
        _log "WARNING: ${CRED_FILE} is world-accessible (this filesystem ignores chmod — likely NTFS/FUSE). Do NOT NFS-export the state tree; relocate secrets to an ext4/POSIX path for real 600 perms."
    fi
}

_is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# --- Subcommands --------------------------------------------------------------
cmd_start() {
    if _is_running; then
        _log "already running (pid $(cat "$PID_FILE"))"
        return 0
    fi

    local bin; bin="$(_paste_bin)"
    if [ ! -x "$bin" ]; then
        if [ -f "$bin" ]; then
            chmod +x "$bin" 2>/dev/null || true
        fi
        if [ ! -x "$bin" ]; then
            _err "MicroBin binary not found/executable: $bin"
            _err "Mirror it first:  scripts/tools/paste.sh"
            return 1
        fi
    fi

    mkdir -p "$DATA_DIR" 2>/dev/null || true
    _ensure_credentials

    _log "starting MicroBin on ${VALARK_BIND}:${PASTE_PORT} (proxy ${PUBLIC_PATH})"

    # MicroBin reads config from MICROBIN_* env vars. Run from DATA_DIR so the
    # SQLite DB + uploaded files live under the Val Ark data tree.
    #   - PRIVATE=true        : pastas are unlisted/private by default
    #   - DISABLE_TELEMETRY   : no outbound analytics (offline box)
    #   - DISABLE_UPDATE_CHECKING : no GitHub version pings (offline box)
    #   - BASIC_AUTH_*        : gate the whole instance behind a login
    #   - ADMIN_PASSWORD      : protect destructive admin actions
    (
        cd "$DATA_DIR" || exit 1
        MICROBIN_PORT="$PASTE_PORT" \
        MICROBIN_BIND="$VALARK_BIND" \
        MICROBIN_PUBLIC_PATH="$PUBLIC_PATH" \
        MICROBIN_DATA_DIR="$DATA_DIR" \
        MICROBIN_PRIVATE="true" \
        MICROBIN_EDITABLE="true" \
        MICROBIN_ENABLE_BURN_AFTER="true" \
        MICROBIN_DISABLE_TELEMETRY="true" \
        MICROBIN_DISABLE_UPDATE_CHECKING="true" \
        MICROBIN_TITLE="Val Ark Files & Pastebin" \
        MICROBIN_ADMIN_USERNAME="admin" \
        MICROBIN_ADMIN_PASSWORD="$PASTE_ADMIN_PASSWORD" \
        MICROBIN_BASIC_AUTH_USERNAME="$PASTE_AUTH_USER" \
        MICROBIN_BASIC_AUTH_PASSWORD="$PASTE_AUTH_PASSWORD" \
        nohup "$bin" >>"$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
    )

    # Brief liveness check.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if _is_running; then
            if command -v curl >/dev/null 2>&1; then
                if curl -fsS -o /dev/null --max-time 2 \
                    -u "${PASTE_AUTH_USER}:${PASTE_AUTH_PASSWORD}" \
                    "http://127.0.0.1:${PASTE_PORT}${PUBLIC_PATH}" 2>/dev/null; then
                    break
                fi
            else
                break
            fi
        fi
        sleep 1
    done

    if _is_running; then
        _log "started (pid $(cat "$PID_FILE"))"
        _log "web UI:   http://${VALARK_BIND}:${PASTE_PORT}${PUBLIC_PATH}"
        _log "login:    user='${PASTE_AUTH_USER}'  (password in ${CRED_FILE})"
        _log "admin:    user='admin'  (password in ${CRED_FILE})"
        return 0
    fi

    _err "failed to start; see $LOG_FILE"
    return 1
}

cmd_stop() {
    if ! _is_running; then
        _log "not running"
        rm -f "$PID_FILE" 2>/dev/null || true
        return 0
    fi
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
    _log "stopping (pid $pid)"
    kill "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE" 2>/dev/null || true
    _log "stopped"
}

cmd_status() {
    if _is_running; then
        echo "paste: running (pid $(cat "$PID_FILE")) on ${VALARK_BIND}:${PASTE_PORT}${PUBLIC_PATH}"
        echo "  data:        ${DATA_DIR}"
        echo "  credentials: ${CRED_FILE}"
        echo "  log:         ${LOG_FILE}"
        return 0
    fi
    echo "paste: stopped"
    return 1
}

# MicroBin has no per-user accounts — it's one shared instance behind HTTP Basic
# auth. There is nothing to "sign up" for; the host shares this one access code.
# Print it so the operator (or the UI's Accounts panel, localhost-only) can hand it out.
cmd_creds() {
    _ensure_credentials
    echo "paste: shared access (no per-user signup — one gated instance)"
    echo "  url:      ${PUBLIC_PATH}"
    echo "  username: ${PASTE_AUTH_USER}"
    echo "  password: ${PASTE_AUTH_PASSWORD}"
    echo "  (admin password is in ${CRED_FILE})"
}

case "${1:-status}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status)  cmd_status ;;
    creds)   cmd_creds ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|creds}" >&2
        exit 2
        ;;
esac
