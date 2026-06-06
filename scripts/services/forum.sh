#!/bin/bash
###############################################################################
# Val Ark - Run Service: Message Boards (NodeBB)
#
# Starts the mirrored NodeBB forum on the Val Ark HOST so it can be served on the
# LAN and reverse-proxied by server.js at /app/forum/.
#
#   forum.sh start    # ensure Redis, generate config, start NodeBB
#   forum.sh stop     # stop NodeBB (leaves the shared Redis running)
#   forum.sh status   # report Redis + NodeBB state and the listen URL
#
# SECURITY / OFFLINE POSTURE
#   - The web UI binds to a FIXED localhost port (FORUM_PORT, default 4567) so
#     Val Ark can same-origin reverse-proxy it. NodeBB itself listens on
#     127.0.0.1 by default; set VALARK_BIND=0.0.0.0 to expose it directly on the
#     LAN (the box is offline anyway). It NEVER reaches the internet at runtime.
#   - Federation / ActivityPub / social login / outbound webhooks are left
#     DISABLED -- this script writes a config that does not enable them.
#   - Auth is mandatory: first run creates an admin account (interactive, or via
#     VALARK_FORUM_ADMIN_USERNAME / _PASSWORD / _EMAIL for unattended setup).
#   - All data lives under the Val Ark data tree (STATE_DIR/services/forum).
###############################################################################

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/services/forum.sh -> repo root is two levels up.
PROJECT_ROOT="$(dirname "$(dirname "$SELF_DIR")")"
# shellcheck source=../lib/valark-env.sh
if [ -f "${PROJECT_ROOT}/scripts/lib/valark-env.sh" ]; then
    . "${PROJECT_ROOT}/scripts/lib/valark-env.sh"
fi
TOOLS_DIR="${TOOLS_DIR:-${PROJECT_ROOT}/tools}"
STATE_DIR="${STATE_DIR:-${PROJECT_ROOT}/state}"

# --- Config -------------------------------------------------------------------
FORUM_PORT="${VALARK_FORUM_PORT:-4567}"        # fixed localhost port (proxied at /app/forum/)
BIND="${VALARK_BIND:-127.0.0.1}"               # LAN intent; 0.0.0.0 allowed, never relayed
REDIS_PORT="${VALARK_FORUM_REDIS_PORT:-6379}"
REDIS_HOST="127.0.0.1"
REDIS_DB="${VALARK_FORUM_REDIS_DB:-0}"
URL_ROOT="/app/forum"                          # NodeBB relative_path -> matches reverse proxy

FORUM_STATE="${STATE_DIR}/services/forum"
PID_FILE="${FORUM_STATE}/nodebb.pid"
LOG_FILE="${FORUM_STATE}/nodebb.log"
CONFIG_FILE="${FORUM_STATE}/config.json"
REDIS_PID_FILE="${FORUM_STATE}/redis.pid"
REDIS_LOG="${FORUM_STATE}/redis.log"
REDIS_DATA="${FORUM_STATE}/redis-data"

# --- Platform / path detection ------------------------------------------------
detect_platform() {
    local arch; arch="$(uname -m)"
    local os; os="$(uname -s)"
    case "$os" in
        Darwin) echo "macos-arm64" ;;
        Linux)
            case "$arch" in
                aarch64|arm64) echo "linux-arm64" ;;
                *)             echo "linux-x86_64" ;;
            esac ;;
        *) echo "linux-x86_64" ;;
    esac
}
PLATFORM="$(detect_platform)"

# Prefer Val Ark's mirrored Node runtime (NodeBB v4 needs Node >=22; many hosts
# ship older). Falls back to system node. Returns the bin DIR to prepend to PATH.
valark_node_dir() {
    local d="${TOOLS_DIR}/${PLATFORM}/node/bin"
    [ -x "${d}/node" ] && { echo "$d"; return 0; }
    d="${TOOLS_DIR}/linux-x86_64/node/bin"
    [ -x "${d}/node" ] && { echo "$d"; return 0; }
    command -v node >/dev/null 2>&1 && { dirname "$(command -v node)"; return 0; }
    return 1
}

# Locate the mirrored NodeBB source (it lives once, under linux-x86_64).
find_nodebb_dir() {
    local base="${TOOLS_DIR}/linux-x86_64/forum"
    local d
    d=$(find "$base" -maxdepth 1 -type d -name 'nodebb-*' 2>/dev/null | sort -V | tail -1)
    [ -n "$d" ] && { echo "$d"; return 0; }
    return 1
}

# Locate a usable Redis (prefer the Val Ark-mirrored build, else system redis).
find_redis_server() {
    local cand="${TOOLS_DIR}/${PLATFORM}/redis/bin/redis-server"
    [ -x "$cand" ] && { echo "$cand"; return 0; }
    cand="${TOOLS_DIR}/${PLATFORM}/redis/src/redis-server"
    [ -x "$cand" ] && { echo "$cand"; return 0; }
    command -v redis-server >/dev/null 2>&1 && { command -v redis-server; return 0; }
    return 1
}
find_redis_cli() {
    local cand="${TOOLS_DIR}/${PLATFORM}/redis/bin/redis-cli"
    [ -x "$cand" ] && { echo "$cand"; return 0; }
    cand="${TOOLS_DIR}/${PLATFORM}/redis/src/redis-cli"
    [ -x "$cand" ] && { echo "$cand"; return 0; }
    command -v redis-cli >/dev/null 2>&1 && { command -v redis-cli; return 0; }
    return 1
}

log()  { echo "[forum] $*"; }
err()  { echo "[forum] ERROR: $*" >&2; }

# Random URL-safe secret (offline; no extra deps).
_gen_secret() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24
    elif [ -r /dev/urandom ]; then LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24
    else echo "valark$$"; fi
}

# --- Process helpers ----------------------------------------------------------
pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

read_pid() { [ -f "$1" ] && cat "$1" 2>/dev/null || echo ""; }

redis_responding() {
    local cli; cli="$(find_redis_cli)" || return 1
    [ "$("$cli" -h "$REDIS_HOST" -p "$REDIS_PORT" ping 2>/dev/null)" = "PONG" ]
}

# --- Redis lifecycle ----------------------------------------------------------
ensure_redis() {
    if redis_responding; then
        log "Redis already responding on ${REDIS_HOST}:${REDIS_PORT}"
        return 0
    fi
    local server; server="$(find_redis_server)" || {
        err "No redis-server found. Mirror it first: scripts/tools/redis.sh"
        return 1
    }
    mkdir -p "$REDIS_DATA"
    log "Starting Redis (${server}) on ${REDIS_HOST}:${REDIS_PORT}"
    # Bind localhost only; this Redis is an internal datastore, not a LAN service.
    "$server" \
        --bind 127.0.0.1 \
        --port "$REDIS_PORT" \
        --dir "$REDIS_DATA" \
        --daemonize no \
        --save 60 1 \
        --appendonly yes \
        >"$REDIS_LOG" 2>&1 &
    echo $! > "$REDIS_PID_FILE"
    # Wait for it to come up.
    local i
    for i in $(seq 1 30); do
        redis_responding && { log "Redis up."; return 0; }
        sleep 0.5
    done
    err "Redis did not come up; see $REDIS_LOG"
    return 1
}

# --- NodeBB config (offline, Redis-backed, no Mongo, no federation) -----------
write_config() {
    mkdir -p "$FORUM_STATE"
    # Public URL is what users hit through the reverse proxy. Keep it relative-path
    # aware so NodeBB generates correct links under /app/forum/.
    local public_url="http://${BIND}${URL_ROOT}"
    [ "$BIND" = "127.0.0.1" ] && public_url="http://localhost${URL_ROOT}"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
{
    "url": "${public_url}",
    "secret": "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')",
    "database": "redis",
    "redis": {
        "host": "${REDIS_HOST}",
        "port": ${REDIS_PORT},
        "password": "",
        "database": ${REDIS_DB}
    },
    "port": ${FORUM_PORT},
    "bind_address": "${BIND}",
    "isCluster": false,
    "activitypub": false,
    "federation": false
}
EOF
        log "Wrote offline config: $CONFIG_FILE (database=redis, federation=off)"
    fi
}

# --- NodeBB lifecycle ---------------------------------------------------------
nodebb_cmd() {
    # NodeBB is driven via ./nodebb in its source dir; --config points at ours.
    # Run with Val Ark's Node (>=22) on PATH so NodeBB v4's deps (undici) work.
    local dir; dir="$(find_nodebb_dir)" || return 1
    local nd; nd="$(valark_node_dir)"
    ( cd "$dir" && PATH="${nd}:$PATH" "$@" )
}

deps_installed() {
    local dir; dir="$(find_nodebb_dir)" || return 1
    [ -d "${dir}/node_modules" ] && [ -f "${dir}/node_modules/.package-lock.json" -o -d "${dir}/node_modules/ioredis" ]
}

do_start() {
    if ! valark_node_dir >/dev/null 2>&1; then
        err "Node.js runtime not found. NodeBB v4 needs Node >=22."
        err "Mirror it: scripts/tools/node.sh (into tools/${PLATFORM}/node/), or install system Node 22+."
        return 1
    fi
    local dir
    dir="$(find_nodebb_dir)" || { err "NodeBB source not mirrored. Run: scripts/tools/forum.sh"; return 1; }

    local existing; existing="$(read_pid "$PID_FILE")"
    if pid_alive "$existing"; then
        log "Already running (pid $existing) at http://${BIND}:${FORUM_PORT}${URL_ROOT}/"
        return 0
    fi

    ensure_redis || return 1
    write_config

    if ! deps_installed; then
        if ! command -v npm >/dev/null 2>&1; then
            err "npm not found; NodeBB needs Node 20+/npm. Install on host, then re-run."
            return 1
        fi
        # NodeBB ships its manifest as install/package.json; the root package.json
        # is created during bootstrap. Copy it so npm has a manifest to install from.
        if [ ! -f "${dir}/package.json" ] && [ -f "${dir}/install/package.json" ]; then
            cp "${dir}/install/package.json" "${dir}/package.json"
            log "Bootstrapped package.json from install/package.json"
        fi
        # Auto-install on first run (one-time; needs an online or cached registry).
        # --legacy-peer-deps: NodeBB's tree has peer-dep mismatches strict npm rejects.
        log "Installing NodeBB dependencies (one-time; this takes a while)..."
        if ! nodebb_cmd npm install --omit=dev --legacy-peer-deps >"${FORUM_STATE}/npm-install.log" 2>&1; then
            err "npm install failed; see ${FORUM_STATE}/npm-install.log"
            return 1
        fi
        log "NodeBB dependencies installed."
    fi

    # First-run admin: NodeBB setup is interactive unless given the answers as a
    # JSON string. Take the admin login from VALARK_FORUM_ADMIN_* or generate one,
    # persist it (chmod 600), and run setup unattended. Idempotent on reruns.
    local cred="${FORUM_STATE}/admin-credentials.txt"
    [ -f "$cred" ] && . "$cred"
    local admin_user admin_pass admin_email
    admin_user="${VALARK_FORUM_ADMIN_USERNAME:-${FORUM_ADMIN_USER:-admin}}"
    admin_pass="${VALARK_FORUM_ADMIN_PASSWORD:-${FORUM_ADMIN_PASS:-$(_gen_secret)}}"
    admin_email="${VALARK_FORUM_ADMIN_EMAIL:-${FORUM_ADMIN_EMAIL:-admin@valark.lan}}"
    umask 077
    { echo "FORUM_ADMIN_USER='${admin_user}'"; echo "FORUM_ADMIN_PASS='${admin_pass}'"; echo "FORUM_ADMIN_EMAIL='${admin_email}'"; } > "$cred"
    chmod 600 "$cred" 2>/dev/null || true
    if [ -n "$(find "$cred" -perm /0077 2>/dev/null)" ]; then
        log "WARNING: ${cred} is world-accessible (filesystem ignores chmod — likely NTFS/FUSE). Do NOT NFS-export the state tree; relocate secrets to an ext4 path for real 600."
    fi
    nodebb_cmd ./nodebb setup --config="$CONFIG_FILE" \
        "{\"admin:username\":\"${admin_user}\",\"admin:password\":\"${admin_pass}\",\"admin:password:confirm\":\"${admin_pass}\",\"admin:email\":\"${admin_email}\"}" \
        >"${FORUM_STATE}/setup.log" 2>&1 || log "setup returned non-zero (benign if already set up; see ${FORUM_STATE}/setup.log)"

    log "Starting NodeBB on ${BIND}:${FORUM_PORT} (proxied at ${URL_ROOT}/)"
    # ./nodebb start forks a managed loader; we capture its pid for stop/status.
    nodebb_cmd env \
        NODE_ENV=production \
        nodebb_config="$CONFIG_FILE" \
        ./nodebb start --config="$CONFIG_FILE" >"$LOG_FILE" 2>&1
    # NodeBB writes its own pidfile; mirror it into our state for consistency.
    local nb_pid
    nb_pid="$(cat "${dir}/pidfile" 2>/dev/null || echo "")"
    [ -n "$nb_pid" ] && echo "$nb_pid" > "$PID_FILE"
    sleep 1
    if [ -n "$nb_pid" ] && pid_alive "$nb_pid"; then
        log "NodeBB started (pid $nb_pid). UI: http://${BIND}:${FORUM_PORT}${URL_ROOT}/  (proxied: /app/forum/)"
        return 0
    fi
    err "NodeBB did not start; see $LOG_FILE"
    return 1
}

do_stop() {
    local dir; dir="$(find_nodebb_dir)" || true
    if [ -n "${dir:-}" ] && [ -d "$dir" ]; then
        ( cd "$dir" && ./nodebb stop --config="$CONFIG_FILE" >/dev/null 2>&1 ) || true
    fi
    local pid; pid="$(read_pid "$PID_FILE")"
    if pid_alive "$pid"; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    log "NodeBB stopped. (Shared Redis left running.)"
}

do_status() {
    local rc=0
    if redis_responding; then
        echo "redis:  UP   (${REDIS_HOST}:${REDIS_PORT})"
    else
        echo "redis:  DOWN (${REDIS_HOST}:${REDIS_PORT})"; rc=1
    fi
    local dir; dir="$(find_nodebb_dir 2>/dev/null)" || dir=""
    if [ -z "$dir" ]; then
        echo "forum:  NOT MIRRORED (run scripts/tools/forum.sh)"; return 1
    fi
    local pid; pid="$(read_pid "$PID_FILE")"
    if pid_alive "$pid"; then
        echo "forum:  UP   pid=$pid  http://${BIND}:${FORUM_PORT}${URL_ROOT}/  (proxied: /app/forum/)"
    else
        echo "forum:  DOWN (source: $dir)"; rc=1
    fi
    return $rc
}

case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    restart) do_stop; do_start ;;
    *) echo "Usage: $0 {start|stop|status|restart}"; exit 2 ;;
esac
