#!/bin/bash
###############################################################################
# Val Ark - Run Service: Git forge (Gitea, #346)
#
# Runs the mirrored Gitea binary on the Val Ark HOST so the LAN gets git hosting,
# issues, pull requests, wikis and the built-in package registries, reverse-proxied
# by server.js at /app/gitea/.
#
#   gitea.sh start                    # write app.ini, start Gitea (idempotent)
#   gitea.sh stop | restart | status
#   gitea.sh config                   # write/repair app.ini only (prints its path)
#   gitea.sh adduser <name> [pass]    # create a login; the FIRST one is the site admin
#
# POSTURE
#   - Always binds 127.0.0.1, whatever VALARK_BIND says (#317): the LAN reaches it only
#     through the Val Ark proxy, which sandboxes user content (raw files, attachments,
#     release downloads, packages) and applies the read-wall. SSH is off (HTTP clone).
#   - ROOT_URL carries the /app/gitea/ sub-path; the proxy strips that prefix before
#     forwarding (Gitea serves at its root and only prefixes the links it generates).
#   - SQLite under STATE_DIR/services/gitea; no database server.
#   - Self-registration is OFF. Logins are made by the host: `gitea.sh adduser`, which
#     the admin-only POST /api/service/adduser (the Community page's "Create a login"
#     form) also runs. The first login created is the site administrator.
#   - Offline: OFFLINE_MODE (no CDN assets; it also turns Gravatar and federated
#     avatars off, settings that now live in the admin panel, not app.ini), no mailer,
#     no update checker, no federation, Actions off (runners need the internet).
#   - app.ini is regenerated on every start from the settings below plus the secrets in
#     secrets.env (generated once, chmod 600), so the enforced keys can't drift.
#
# Knobs (.env): VALARK_GITEA_PORT (3300), VALARK_GITEA_ROOT_URL (the origin people use,
# e.g. http://ark.example:3000; the /app/gitea/ path is always appended),
# VALARK_GITEA_REQUIRE_SIGNIN (0: anyone on the LAN may browse public repos),
# VALARK_GITEA_EMAIL_DOMAIN (valark.lan: placeholder addresses for adduser).
###############################################################################

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SELF_DIR")")"
if [ -f "${PROJECT_ROOT}/scripts/lib/valark-env.sh" ]; then
    # shellcheck source=../lib/valark-env.sh
    . "${PROJECT_ROOT}/scripts/lib/valark-env.sh"
fi
TOOLS_DIR="${TOOLS_DIR:-${PROJECT_ROOT}/tools}"
STATE_DIR="${STATE_DIR:-${PROJECT_ROOT}/state}"

# --- Configuration ------------------------------------------------------------
GITEA_PORT="${VALARK_GITEA_PORT:-3300}"     # fixed localhost port for the reverse proxy
WEB_BIND="127.0.0.1"                        # loopback only, never VALARK_BIND (#317)
PUBLIC_PATH="/app/gitea/"                   # reverse-proxy mount point (server.js APP_SERVICES)

DATA_DIR="${STATE_DIR}/services/gitea"
INI="${DATA_DIR}/custom/conf/app.ini"
SECRETS="${DATA_DIR}/secrets.env"
PID_FILE="${DATA_DIR}/gitea.pid"
LOG_FILE="${DATA_DIR}/gitea.log"
ADMIN_MARK="${DATA_DIR}/.admin-created"

_log() { echo "[gitea] $*"; }
_err() { echo "[gitea] ERROR: $*" >&2; }
_truthy() { case "${1:-}" in 1|[Tt]rue|[Yy]es|[Oo]n) return 0 ;; esac; return 1; }

# The origin people browse the Ark at (no path). Anything after the host is dropped:
# Gitea must always live at /app/gitea/ because that is where the proxy mounts it.
_root_url() {
    local o="${VALARK_GITEA_ROOT_URL:-http://localhost:${VALARK_WEB_PORT:-3000}}"
    case "$o" in http://*|https://*) ;; *) o="http://${o}" ;; esac
    o=$(printf '%s' "$o" | head -1 | sed -E 's#^(https?://[^/?#]+).*#\1#')
    # Only a plain scheme://host[:port] may reach app.ini (no spaces, no injected lines).
    printf '%s' "$o" | grep -qE '^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?$' \
        || o="http://localhost:${VALARK_WEB_PORT:-3000}"
    printf '%s%s' "$o" "$PUBLIC_PATH"
}
_root_host() { _root_url | sed -E 's#^https?://(\[[^]]*\]|[^:/]+).*#\1#'; }

_gitea_bin() {
    local sub bin="gitea"
    case "$(uname -s)/$(uname -m)" in
        Linux/aarch64|Linux/arm64) sub="linux-arm64" ;;
        Linux/*)                   sub="linux-x86_64" ;;
        Darwin/*)                  sub="macos-arm64" ;;
        *)                         sub="windows-x64"; bin="gitea.exe" ;;
    esac
    echo "${TOOLS_DIR}/${sub}/gitea/${bin}"
}

_rand() {   # _rand N -> N URL-safe random characters
    local n="${1:-32}" s=""
    if command -v openssl >/dev/null 2>&1; then
        s=$(openssl rand -base64 $((n * 2)) 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$n")
    fi
    [ "${#s}" -ge "$n" ] || s=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$n")
    printf '%s' "$s"
}
_jwt_secret() {   # base64url (no padding) of 32 random bytes: the shape Gitea decodes
    if command -v openssl >/dev/null 2>&1; then
        openssl rand 32 2>/dev/null | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '='
    else
        head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
    fi
}

_ensure_secrets() {
    mkdir -p "$DATA_DIR" 2>/dev/null || true
    # shellcheck disable=SC1090
    [ -f "$SECRETS" ] && . "$SECRETS"
    if [ -z "${GITEA_SECRET_KEY:-}" ] || [ -z "${GITEA_INTERNAL_TOKEN:-}" ] \
       || [ -z "${GITEA_JWT_SECRET:-}" ] || [ -z "${GITEA_LFS_JWT_SECRET:-}" ]; then
        GITEA_SECRET_KEY="${GITEA_SECRET_KEY:-$(_rand 64)}"
        GITEA_INTERNAL_TOKEN="${GITEA_INTERNAL_TOKEN:-$(_rand 96)}"
        GITEA_JWT_SECRET="${GITEA_JWT_SECRET:-$(_jwt_secret)}"
        GITEA_LFS_JWT_SECRET="${GITEA_LFS_JWT_SECRET:-$(_jwt_secret)}"
        ( umask 077
          { echo "# Val Ark Gitea secrets - generated $(date). Keep private; never NFS-export."
            echo "GITEA_SECRET_KEY='${GITEA_SECRET_KEY}'"
            echo "GITEA_INTERNAL_TOKEN='${GITEA_INTERNAL_TOKEN}'"
            echo "GITEA_JWT_SECRET='${GITEA_JWT_SECRET}'"
            echo "GITEA_LFS_JWT_SECRET='${GITEA_LFS_JWT_SECRET}'"
          } > "$SECRETS" )
    fi
    chmod 600 "$SECRETS" 2>/dev/null || true
    if [ -n "$(find "$SECRETS" -perm /0077 2>/dev/null)" ]; then
        _log "WARNING: ${SECRETS} is world-accessible (this filesystem ignores chmod - likely NTFS/FUSE). Do NOT NFS-export the state tree."
    fi
}

# Write app.ini (atomically, mode 600: it carries the secrets).
write_config() {
    _ensure_secrets
    mkdir -p "$(dirname "$INI")" "${DATA_DIR}/data" "${DATA_DIR}/repositories" "${DATA_DIR}/log" 2>/dev/null || true
    local signin=false; _truthy "${VALARK_GITEA_REQUIRE_SIGNIN:-0}" && signin=true
    local tmp="${INI}.tmp.$$"
    ( umask 077
      cat > "$tmp" <<EOF
; Generated by scripts/services/gitea.sh on every start - edit the script or .env, not this file.
APP_NAME = Val Ark Git
RUN_USER = $(id -un)
RUN_MODE = prod
WORK_PATH = ${DATA_DIR}

[server]
PROTOCOL = http
HTTP_ADDR = ${WEB_BIND}
HTTP_PORT = ${GITEA_PORT}
ROOT_URL = $(_root_url)
; Absolute links follow the Host the browser used (the proxy passes it through).
PUBLIC_URL_DETECTION = auto
DOMAIN = $(_root_host)
DISABLE_SSH = true
START_SSH_SERVER = false
OFFLINE_MODE = true
APP_DATA_PATH = ${DATA_DIR}/data
LFS_START_SERVER = true
LFS_JWT_SECRET = ${GITEA_LFS_JWT_SECRET}
LANDING_PAGE = explore

[database]
DB_TYPE = sqlite3
PATH = ${DATA_DIR}/data/gitea.db

[repository]
ROOT = ${DATA_DIR}/repositories

[security]
INSTALL_LOCK = true
SECRET_KEY = ${GITEA_SECRET_KEY}
INTERNAL_TOKEN = ${GITEA_INTERNAL_TOKEN}

[oauth2]
JWT_SECRET = ${GITEA_JWT_SECRET}

[service]
DISABLE_REGISTRATION = true
SHOW_REGISTRATION_BUTTON = false
ALLOW_ONLY_EXTERNAL_REGISTRATION = false
REQUIRE_SIGNIN_VIEW = ${signin}
ENABLE_NOTIFY_MAIL = false
DEFAULT_KEEP_EMAIL_PRIVATE = true
NO_REPLY_ADDRESS = noreply.$(_root_host)

[openid]
ENABLE_OPENID_SIGNIN = false
ENABLE_OPENID_SIGNUP = false

[mailer]
ENABLED = false

[cron.update_checker]
ENABLED = false

[federation]
ENABLED = false

[actions]
ENABLED = false

[packages]
ENABLED = true

[log]
MODE = file
LEVEL = Info
ROOT_PATH = ${DATA_DIR}/log
EOF
    ) || { rm -f "$tmp"; _err "could not write ${INI}"; return 1; }
    mv -f "$tmp" "$INI" && chmod 600 "$INI" 2>/dev/null
    return 0
}

_is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_need_bin() {
    BIN="$(_gitea_bin)"
    [ -f "$BIN" ] && [ ! -x "$BIN" ] && chmod +x "$BIN" 2>/dev/null
    if [ ! -x "$BIN" ]; then
        _err "Gitea binary not found/executable: $BIN"
        _err "Mirror it first:  scripts/tools/gitea.sh"
        return 1
    fi
    if [ "$(id -u)" = 0 ]; then
        _err "Gitea refuses to run as root; run Val Ark as its normal user."
        return 1
    fi
}

cmd_start() {
    if _is_running; then _log "already running (pid $(cat "$PID_FILE"))"; return 0; fi
    _need_bin || return 1
    command -v git >/dev/null 2>&1 || { _err "Gitea needs git on the host (apt install git)"; return 1; }
    write_config || return 1
    _log "starting Gitea on ${WEB_BIND}:${GITEA_PORT} (proxy ${PUBLIC_PATH}, ROOT_URL $(_root_url))"
    # 8>&-: never inherit the loop's run_locked loop.lock fd (fd 8) into this detached
    # daemon - a shared fd holds the flock forever and deadlocks every later cycle.
    (
        cd "$DATA_DIR" || exit 1
        GITEA_WORK_DIR="$DATA_DIR" GITEA_CUSTOM="${DATA_DIR}/custom" \
            nohup "$BIN" web --config "$INI" --work-path "$DATA_DIR" >>"$LOG_FILE" 2>&1 8>&- &
        echo $! > "$PID_FILE"
    )
    local i
    for i in $(seq 1 30); do
        _is_running || break
        if ! command -v curl >/dev/null 2>&1 \
           || curl -fsS -o /dev/null --max-time 2 "http://${WEB_BIND}:${GITEA_PORT}/api/healthz" 2>/dev/null; then
            _log "started (pid $(cat "$PID_FILE")) - LAN: ${PUBLIC_PATH} on the Val Ark web port"
            [ -f "$ADMIN_MARK" ] || _log "no admin yet: create the first login (it becomes the site admin): $0 adduser <name>"
            return 0
        fi
        sleep 1
    done
    _err "failed to start; see $LOG_FILE"
    return 1
}

cmd_stop() {
    if ! _is_running; then _log "not running"; rm -f "$PID_FILE"; return 0; fi
    local pid; pid="$(cat "$PID_FILE")"
    _log "stopping (pid $pid)"
    kill "$pid" 2>/dev/null
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    _log "stopped"
}

cmd_status() {
    if _is_running; then
        echo "gitea: running (pid $(cat "$PID_FILE")) on ${WEB_BIND}:${GITEA_PORT} (proxied at ${PUBLIC_PATH})"
        echo "  root url: $(_root_url)"
        echo "  data:     ${DATA_DIR}"
        echo "  log:      ${LOG_FILE}"
        return 0
    fi
    echo "gitea: stopped"
    return 1
}

# adduser NAME [PASSWORD]: the first login created becomes the site admin. With no
# password, one is generated and printed once (the person must change it at first sign-in).
cmd_adduser() {
    local name="${1:-}" pass="${2:-}" must=false admin=() role="user"
    [ -n "$name" ] || { echo "usage: gitea.sh adduser <name> [password]" >&2; return 2; }
    printf '%s' "$name" | grep -qE '^[A-Za-z0-9._-]{1,32}$' || { _err "invalid username"; return 2; }
    _need_bin || return 1
    write_config || return 1
    [ -n "$pass" ] || { pass="$(_rand 20)"; must=true; }
    [ -f "$ADMIN_MARK" ] || { admin=(--admin); role="site admin"; }
    # Create/upgrade the SQLite schema first (idempotent): `admin user create` needs it.
    "$BIN" migrate --config "$INI" --work-path "$DATA_DIR" >>"$LOG_FILE" 2>&1 \
        || { _err "could not initialise the database (see $LOG_FILE)"; return 1; }
    if ! "$BIN" admin user create --config "$INI" --work-path "$DATA_DIR" \
            --username "$name" --password "$pass" \
            --email "${name}@${VALARK_GITEA_EMAIL_DOMAIN:-valark.lan}" \
            --must-change-password="$must" "${admin[@]}" >>"$LOG_FILE" 2>&1; then
        _err "could not create '${name}' (already exists? see $LOG_FILE)"
        return 1
    fi
    [ "$role" = "site admin" ] && : > "$ADMIN_MARK"
    if [ "$must" = true ]; then
        _log "gitea ${role} '${name}' created - temporary password: ${pass} (change it at first sign-in at ${PUBLIC_PATH})"
    else
        _log "gitea ${role} '${name}' created - sign in at ${PUBLIC_PATH}"
    fi
}

case "${1:-status}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status)  cmd_status ;;
    config)  write_config && echo "$INI" ;;
    adduser) shift; cmd_adduser "$@" ;;
    *) echo "Usage: $0 {start|stop|restart|status|config|adduser <name> [pass]}" >&2; exit 2 ;;
esac
