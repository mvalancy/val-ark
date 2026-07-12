#!/bin/bash
###############################################################################
# Val Ark - Mail service runner (maddy SMTP/IMAP + alps webmail)
#
# Starts LOCAL community email for the Val Ark host to serve on the LAN. It is
# OFFLINE BY DESIGN: maddy is configured with NO outbound relay / NO federation,
# so mail can only move between local mailboxes. Auth is always required (SASL
# for SMTP submission + IMAP login).
#
# Subcommands:
#   start    launch maddy + alps (idempotent; no-op if already running)
#   stop     stop both
#   status   report running state + ports + data dir
#   creds    passthrough to `maddy creds`     (create/list/remove logins)
#   acct     passthrough to `maddy imap-acct` (create/list IMAP mailboxes)
#
# Ports (defaults; LAN-facing maddy ports honor $VALARK_BIND):
#   SMTP submission  587   (STARTTLS-capable; plaintext allowed on LAN)
#   IMAP             143   (mail clients on the LAN)
#   SMTP (MX, local) 25    (local delivery only, bound to 127.0.0.1)
#   alps webmail     127.0.0.1:1323  (FIXED localhost; reverse-proxied at /app/mail/)
#
# Data lives under the Val Ark data tree:
#   $STATE_DIR/services/mail/{maddy.conf, maddy/ (mailboxes+creds db), logs, run}
#
# SECURITY:
#   * No internet relay: there is no `target_remote` / outbound SMTP block.
#   * VALARK_BIND (default 0.0.0.0) sets the LAN bind for maddy's client ports.
#     Set VALARK_BIND=127.0.0.1 to keep everything host-local.
#   * alps ALWAYS binds 127.0.0.1 only; reach it through the Val Ark reverse proxy.
#   * First-run requires creating an admin/postmaster login (see status output).
###############################################################################
# NOTE: no `set -u` — valark-env.sh (and _common.sh) rely on reading unset vars
# in their idempotent source-guards.

# --- locate repo + env --------------------------------------------------------
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SELF")"
PROJECT_ROOT="$(dirname "$SCRIPTS_DIR")"
# shellcheck source=../lib/valark-env.sh
. "${SCRIPTS_DIR}/lib/valark-env.sh"
# shellcheck source=../lib/tls.sh
. "${SCRIPTS_DIR}/lib/tls.sh"

# --- config -------------------------------------------------------------------
MAIL_DOMAIN="${VALARK_MAIL_DOMAIN:-valark.lan}"
VALARK_BIND="${VALARK_BIND:-0.0.0.0}"           # LAN bind for maddy client ports
ALPS_PORT="${VALARK_MAIL_WEB_PORT:-1323}"        # FIXED localhost port for /app/mail/
SMTP_SUBMISSION_PORT="${VALARK_MAIL_SUBMISSION_PORT:-587}"
IMAP_PORT="${VALARK_MAIL_IMAP_PORT:-143}"
# Local-MX (127.0.0.1) port. Port 25 is privileged: only emit the MX endpoint
# when running as root, otherwise maddy can't bind it and aborts. The MX is for
# on-box mail injection only — community mail still flows via submission+IMAP
# without it. Override with VALARK_MAIL_MX_PORT (e.g. 2525) to force it unprivileged.
SMTP_MX_PORT="${VALARK_MAIL_MX_PORT:-25}"

# Val Ark usually runs as a NON-root user (loop/cron), which cannot bind the
# privileged defaults 143/587. Auto-shift those to non-privileged ports
# (143->1143, 587->1587) unless the operator pinned them or we're root, so the
# daemon actually starts. Mail clients just point at the shifted ports.
if [ "$(id -u)" -ne 0 ]; then
    if [ -z "${VALARK_MAIL_IMAP_PORT:-}" ] && [ "$IMAP_PORT" -lt 1024 ]; then IMAP_PORT=$((IMAP_PORT + 1000)); fi
    if [ -z "${VALARK_MAIL_SUBMISSION_PORT:-}" ] && [ "$SMTP_SUBMISSION_PORT" -lt 1024 ]; then SMTP_SUBMISSION_PORT=$((SMTP_SUBMISSION_PORT + 1000)); fi
fi

# Local TLS: ensure the Ark's CA + server cert exist so IMAP/submission can offer
# STARTTLS. The cert (valark.lan + every LAN/Tailscale IP) lets mail clients
# connect encrypted. If openssl is unavailable we fall back to plaintext and say so.
MAIL_TLS="tls off"
if ensure_valark_tls 2>/dev/null; then
    MAIL_TLS="tls file ${VALARK_TLS_CERT} ${VALARK_TLS_KEY}"
fi

MAIL_HOME="${STATE_DIR}/services/mail"
MADDY_STATE="${MAIL_HOME}/maddy"                 # mailboxes + credentials DB
MADDY_CONF="${MAIL_HOME}/maddy.conf"
RUN_DIR="${MAIL_HOME}/run"
LOG_DIR_MAIL="${MAIL_HOME}/logs"
MADDY_PID="${RUN_DIR}/maddy.pid"
ALPS_PID="${RUN_DIR}/alps.pid"

# --- platform / binary resolution --------------------------------------------
detect_platform() {
    local arch; arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64) echo "linux-arm64" ;;
        x86_64|amd64)  echo "linux-x86_64" ;;
        *)             echo "linux-x86_64" ;;
    esac
}
PLATFORM="$(detect_platform)"
MADDY_BIN="${TOOLS_DIR}/${PLATFORM}/mail/maddy"
ALPS_BIN="${TOOLS_DIR}/${PLATFORM}/mail/alps"

log()  { echo "[mail] $*"; }
err()  { echo "[mail] ERROR: $*" >&2; }

is_running() { # is_running <pidfile>
    local pf="$1" pid
    [ -f "$pf" ] || return 1
    pid="$(cat "$pf" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

ensure_layout() {
    mkdir -p "$MADDY_STATE" "$RUN_DIR" "$LOG_DIR_MAIL" 2>/dev/null || true
}

# Generate an OFFLINE maddy config the first time. Key properties:
#   * hostname/domain are the LAN-local domain (no public DNS, no MX lookups).
#   * SMTP submission + IMAP bind to $VALARK_BIND (LAN); MX :25 stays localhost.
#   * Delivery target is local IMAP only (deliver_to &local_mailboxes) — there is
#     deliberately NO target_remote, so mail can never leave the box.
#   * insecure_auth + io_debug are off; plaintext auth is permitted on the LAN
#     (set up TLS certs in maddy.conf if you want STARTTLS).
write_config() {
    # The config is fully generated from env + cert state, so (re)write it every
    # start — that's how an existing plaintext install picks up STARTTLS. Back up
    # any prior config once. Mailboxes/credentials live elsewhere and are untouched.
    if [ -f "$MADDY_CONF" ]; then cp -f "$MADDY_CONF" "${MADDY_CONF}.bak" 2>/dev/null || true; fi
    log "Writing offline config -> ${MADDY_CONF}"

    # Only include the local-MX endpoint when its port is bindable: port 25 is
    # privileged (root-only). Skipping it for non-root runs lets the daemon come
    # up cleanly — submission+IMAP are all community mail needs.
    local mx_block=""
    if [ "$SMTP_MX_PORT" -ge 1024 ] || [ "$(id -u)" -eq 0 ]; then
        mx_block="## --- Local MX (127.0.0.1 only) — accepts on-box generated mail -----------
smtp tcp://127.0.0.1:${SMTP_MX_PORT} {
    tls off
    hostname \$(hostname)
    source \$(local_domains) {
        destination \$(local_domains) {
            deliver_to &local_routing
        }
        default_destination { reject 550 5.1.1 \"User not local\" }
    }
    default_source { reject 550 5.1.8 \"Val Ark Mail accepts local mail only\" }
}"
    else
        log "Skipping local-MX :${SMTP_MX_PORT} (privileged port, not root) — submission+IMAP only"
    fi

    cat > "$MADDY_CONF" <<EOF
## Val Ark Mail - OFFLINE local-community config (generated $(date '+%Y-%m-%d'))
## NO outbound relay, NO federation. Mail moves only between local mailboxes.

\$(hostname) = ${MAIL_DOMAIN}
\$(primary_domain) = ${MAIL_DOMAIN}
\$(local_domains) = \$(primary_domain)

## Storage: messages live in a Maildir-backed bbolt store under MAIL_HOME.
state_dir ${MADDY_STATE}
runtime_dir ${RUN_DIR}

## --- Credentials + mailbox stores (auth is mandatory) ---------------------
storage.imapsql local_mailboxes {
    driver sqlite3
    dsn ${MADDY_STATE}/imapsql.db
}

table.chain local_rewrites {
    optional_step regexp "(.+)\+(.+)@(.+)" "\$1@\$3"
    optional_step static {
        entry postmaster postmaster@\$(primary_domain)
    }
    optional_step file ${MADDY_STATE}/aliases
}

auth.pass_table local_authdb {
    table sql_table {
        driver sqlite3
        dsn ${MADDY_STATE}/credentials.db
        table_name passwords
    }
}

## --- IMAP (LAN clients) ---------------------------------------------------
## TLS via the Val Ark local CA (STARTTLS). With a cert present, maddy refuses
## plaintext AUTH unless the client upgrades to TLS — so credentials are never
## sent in the clear. '${MAIL_TLS}' is 'tls off' only if openssl was unavailable.
imap tcp://${VALARK_BIND}:${IMAP_PORT} {
    ${MAIL_TLS}
    auth &local_authdb
    storage &local_mailboxes
}

## --- SMTP submission (LAN clients send through here, auth required) --------
submission tcp://${VALARK_BIND}:${SMTP_SUBMISSION_PORT} {
    ${MAIL_TLS}
    hostname \$(hostname)
    auth &local_authdb
    source \$(local_domains) {
        destination postmaster \$(local_domains) {
            deliver_to &local_routing
        }
        default_destination {
            ## Reject anything not addressed to a LOCAL domain. This is what
            ## makes the box offline: no remote target exists to relay to.
            reject 501 5.1.8 "Val Ark Mail is offline: only local delivery is allowed"
        }
    }
    default_source { reject 501 5.1.8 "Unknown sender domain" }
}

${mx_block}

## --- Routing: deliver to local IMAP mailboxes (NO remote target) ----------
msgpipeline local_routing {
    hostname \$(hostname)
    destination postmaster \$(local_domains) {
        modify { replace_rcpt &local_rewrites }
        deliver_to &local_mailboxes
    }
    default_destination { reject 550 5.1.1 "User not local" }
}
EOF
}

maddy_cmd() { # run maddy with our config + state
    "$MADDY_BIN" --config "$MADDY_CONF" "$@"
}

start_maddy() {
    if is_running "$MADDY_PID"; then log "maddy already running (pid $(cat "$MADDY_PID"))"; return 0; fi
    if [ ! -x "$MADDY_BIN" ]; then
        err "maddy binary not found at ${MADDY_BIN} — run scripts/tools/mail.sh first"
        return 1
    fi
    write_config
    log "Starting maddy (submission :${SMTP_SUBMISSION_PORT}, imap :${IMAP_PORT}, bind ${VALARK_BIND}) ..."
    nohup "$MADDY_BIN" --config "$MADDY_CONF" run >"${LOG_DIR_MAIL}/maddy.log" 2>&1 &
    echo $! > "$MADDY_PID"
    sleep 1
    if is_running "$MADDY_PID"; then
        log "maddy up (pid $(cat "$MADDY_PID"))"
    else
        err "maddy failed to start — see ${LOG_DIR_MAIL}/maddy.log"
        return 1
    fi
}

start_alps() {
    if is_running "$ALPS_PID"; then log "alps already running (pid $(cat "$ALPS_PID"))"; return 0; fi
    if [ ! -x "$ALPS_BIN" ]; then
        log "alps webmail binary not present (build it from tools/sources/alps); webmail UI disabled."
        log "Mail server (maddy) still works for IMAP/SMTP clients on the LAN."
        return 0
    fi
    # alps ALWAYS binds localhost; the Val Ark server reverse-proxies it at /app/mail/.
    # It connects to the local maddy over plaintext IMAP/SMTP submission (the box
    # is offline/LAN-only, so '+insecure' loopback is fine — no cert needed).
    log "Starting alps webmail on 127.0.0.1:${ALPS_PORT} (proxied at /app/mail/) ..."
    nohup "$ALPS_BIN" \
        -addr "127.0.0.1:${ALPS_PORT}" \
        "imap+insecure://127.0.0.1:${IMAP_PORT}" "smtp+insecure://127.0.0.1:${SMTP_SUBMISSION_PORT}" \
        >"${LOG_DIR_MAIL}/alps.log" 2>&1 &
    echo $! > "$ALPS_PID"
    sleep 1
    if is_running "$ALPS_PID"; then
        log "alps up (pid $(cat "$ALPS_PID"))"
    else
        err "alps failed to start — see ${LOG_DIR_MAIL}/alps.log"
        return 1
    fi
}

stop_pid() { # stop_pid <pidfile> <label>
    local pf="$1" label="$2" pid
    if is_running "$pf"; then
        pid="$(cat "$pf")"
        log "Stopping ${label} (pid ${pid}) ..."
        kill "$pid" 2>/dev/null
        for _ in 1 2 3 4 5; do is_running "$pf" || break; sleep 1; done
        is_running "$pf" && kill -9 "$pid" 2>/dev/null
    else
        log "${label} not running"
    fi
    rm -f "$pf" 2>/dev/null || true
}

cmd_start() {
    ensure_layout
    start_maddy || return 1
    start_alps
    cmd_status
    first_run_hint
}

cmd_stop() {
    stop_pid "$ALPS_PID" "alps"
    stop_pid "$MADDY_PID" "maddy"
}

cmd_status() {
    echo "Val Ark Mail status"
    echo "  domain         ${MAIL_DOMAIN}"
    echo "  data dir       ${MAIL_HOME}"
    echo "  maddy binary   ${MADDY_BIN} $( [ -x "$MADDY_BIN" ] && echo '(present)' || echo '(MISSING)')"
    echo "  alps binary    ${ALPS_BIN} $( [ -x "$ALPS_BIN" ] && echo '(present)' || echo '(not built — IMAP/SMTP only)')"
    if is_running "$MADDY_PID"; then
        echo "  maddy          RUNNING (pid $(cat "$MADDY_PID")) submission ${VALARK_BIND}:${SMTP_SUBMISSION_PORT}, imap ${VALARK_BIND}:${IMAP_PORT}"
    else
        echo "  maddy          stopped"
    fi
    if is_running "$ALPS_PID"; then
        echo "  alps webmail   RUNNING (pid $(cat "$ALPS_PID")) http://127.0.0.1:${ALPS_PORT}  -> proxied at /app/mail/"
    else
        echo "  alps webmail   stopped"
    fi
    echo "  relay/federation: DISABLED (offline; local delivery only)"
}

first_run_hint() {
    # If no credentials exist yet, point the operator at account creation.
    if [ ! -s "${MADDY_STATE}/credentials.db" ]; then
        cat <<EOF

First-run account setup (REQUIRED — auth is mandatory):
  Create the admin/postmaster login and its mailbox:
    scripts/services/mail.sh creds create postmaster@${MAIL_DOMAIN}
    scripts/services/mail.sh acct  create postmaster@${MAIL_DOMAIN}
  Add a community member:
    scripts/services/mail.sh creds create alice@${MAIL_DOMAIN}
    scripts/services/mail.sh acct  create alice@${MAIL_DOMAIN}
  Then sign in at  /app/mail/  (webmail) or point a mail client at
  IMAP ${VALARK_BIND}:${IMAP_PORT} / submission ${VALARK_BIND}:${SMTP_SUBMISSION_PORT}.
EOF
    fi
}

# Create a full mailbox in one step: SASL login (password) + IMAP account. maddy has
# no self-registration (offline, no public signup), so the host provisions logins;
# the UI's Community "Accounts & sign-up" panel points here (localhost/admin only).
cmd_adduser() {
    local name="${1:-}" pass="${2:-}" addr
    [ -n "$name" ] || { echo "usage: mail.sh adduser <name|user@domain> [password]"; return 1; }
    case "$name" in *@*) addr="$name" ;; *) addr="${name}@${MAIL_DOMAIN}" ;; esac
    ensure_layout; write_config
    # 1) SASL credential (password DB). maddy reads the password from stdin when
    #    stdin is not a TTY, so piping it keeps this non-interactive + script-safe.
    if [ -n "$pass" ]; then
        if ! printf '%s\n' "$pass" | maddy_cmd creds create "$addr"; then
            err "could not create login '${addr}' (already exists?)"; return 1
        fi
    else
        if ! maddy_cmd creds create "$addr"; then
            err "could not create login '${addr}'"; return 1
        fi
    fi
    # 2) IMAP mailbox (safe to skip if it already exists).
    maddy_cmd imap-acct create "$addr" >/dev/null 2>&1 || true
    log "mail account '${addr}' created — sign in at /app/mail/ (IMAP ${VALARK_BIND}:${IMAP_PORT})"
}

usage() {
    echo "Usage: $0 {start|stop|status|adduser <name> [pass]|creds ...|acct ...}"
    echo "  adduser <name> [pass]  -> create a full mailbox (login + IMAP account)"
    echo "  creds ...  -> maddy creds <args>     (manage logins)"
    echo "  acct  ...  -> maddy imap-acct <args> (manage mailboxes)"
}

main() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        start)   cmd_start ;;
        stop)    cmd_stop ;;
        restart) cmd_stop; cmd_start ;;
        status)  cmd_status ;;
        adduser) cmd_adduser "$@" ;;
        creds)   ensure_layout; write_config; maddy_cmd creds "$@" ;;
        acct)    ensure_layout; write_config; maddy_cmd imap-acct "$@" ;;
        *)       usage; exit 1 ;;
    esac
}

main "$@"
