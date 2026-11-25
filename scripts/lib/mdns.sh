#!/bin/bash
###############################################################################
# Val Ark — publish the box's name as <name>.local over mDNS, when it can (#306).
#
# The setup wizard names the box; this makes http://<name>.local/ actually answer.
# It never installs anything and never needs root:
#   - the system hostname already equals the name and an mDNS responder runs
#     (avahi-daemon, or macOS mDNSResponder)            -> "native" (nothing to do)
#   - avahi-daemon runs and avahi-publish is installed  -> keep ONE
#     `avahi-publish -a -R <name>.local <ip>` child up   -> "published"
#     (avahi-publish talks to the daemon over D-Bus as any user; -R skips the
#      reverse PTR, which belongs to the real hostname)
#   - otherwise                                          -> "unavailable" + reason
# When it's unavailable, the web UI shows the box's LAN IP address instead and
# says .local is unavailable (server.js boxAddress()).
#
# The name comes from <state>/settings.json (never from argv or a request), turned
# into a DNS label by the same rule as commission.js mdnsLabel(): lower case,
# spaces/underscores -> '-', anything else outside [a-z0-9-] dropped, at most 63.
#
# Usage:
#   mdns.sh check  STATE_DIR   can this box publish? (no changes) -> JSON
#   mdns.sh ensure STATE_DIR   publish / keep the publisher up, write
#                              STATE_DIR/mdns.json                 -> JSON
#   mdns.sh stop   STATE_DIR   stop our publisher (if any)
#
# JSON: {"ts","name","label","host","state":"native|published|available|unavailable",
#        "canPublish":bool,"hostLabel","ip","reason"}
#   check reports "available" where ensure would publish.
#
# The publisher is detached (setsid/nohup) with fd 8 CLOSED: loop.sh runs this
# under its cycle lock (loop.lock on fd 8), and a child holding that fd would keep
# the lock forever (scripts/AGENTS.md). Its pid is kept in STATE_DIR/mdns.pid and is
# only trusted while `ps` shows our exact argv for it (no pid-reuse kills).
#
# Test seams (all optional):
#   VALARK_MDNS_PUBLISH     the avahi-publish to run; "none" = not installed
#   VALARK_MDNS_DAEMON_CMD  command whose exit status says "avahi-daemon is running";
#                           "none" = no daemon
#   VALARK_MDNS_HOSTNAME    stands in for the system hostname
#   VALARK_MDNS_IP          the IPv4 address to publish
#   VALARK_MDNS_SETTLE      seconds to wait before checking the publisher stayed up (1)
#   VALARK_MDNS_OS          stands in for `uname -s`
# (lan_ip reads `ip`/`ifconfig` from PATH; tests put stubs first.)
#
# Safety: with a state dir under the system temp dir (a test's), only a publisher
# that is itself under the temp dir (a stub) is ever started. `ensure`/`stop` hold
# STATE_DIR/mdns.lock (flock -n on fd 7) so two runs never race.
#
# "published" means our publisher is up and announcing; it does not prove every
# client on the network resolves .local (some don't), so the UI also shows the IP.
###############################################################################
set -u

MODE="${1:-}"; SD="${2:-}"
case "$MODE" in check|ensure|stop) ;; *) echo "usage: mdns.sh {check|ensure|stop} STATE_DIR" >&2; exit 64 ;; esac
[ -n "$SD" ] || { echo "usage: mdns.sh {check|ensure|stop} STATE_DIR" >&2; exit 64; }

PIDF="${SD}/mdns.pid"
OUT="${SD}/mdns.json"
OS="${VALARK_MDNS_OS:-$(uname -s 2>/dev/null)}"

js() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=$(printf '%s' "$s" | tr -d '\000-\037'); printf '"%s"' "$s"; }

# DNS label from a free-text name (mirror of commission.js mdnsLabel).
to_label() {
    local l
    l=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ' _' '--' | tr -cd 'a-z0-9-' | tr -s '-' | sed -e 's/^-*//' -e 's/-*$//' | cut -c1-63)
    l=${l%-}
    printf '%s' "${l:-valark}"
}

# The box name from settings.json (JSON.stringify output; the name is limited to
# [A-Za-z0-9 _-] by commission.js, so no escapes to undo).
box_name() {
    local f="${SD}/settings.json" n=""
    [ -r "$f" ] && n=$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
    printf '%s' "${n:-valark}"
}

find_publisher() {
    local c="${VALARK_MDNS_PUBLISH:-}"
    if [ "$c" = none ]; then return 1; fi
    if [ -n "$c" ]; then [ -x "$c" ] && { printf '%s' "$c"; return 0; }; return 1; fi
    c=$(command -v avahi-publish 2>/dev/null) && { printf '%s' "$c"; return 0; }
    c=$(command -v avahi-publish-address 2>/dev/null) && { printf '%s' "$c"; return 0; }
    return 1
}

daemon_running() {
    local c="${VALARK_MDNS_DAEMON_CMD:-}"
    if [ "$c" = none ]; then return 1; fi
    if [ -n "$c" ]; then "$c" >/dev/null 2>&1; return; fi
    if command -v avahi-daemon >/dev/null 2>&1 && avahi-daemon --check >/dev/null 2>&1; then return 0; fi
    command -v pgrep >/dev/null 2>&1 && pgrep -x avahi-daemon >/dev/null 2>&1
}

host_label() {
    local h="${VALARK_MDNS_HOSTNAME:-}"
    if [ -z "$h" ]; then
        if [ "$OS" = Darwin ] && command -v scutil >/dev/null 2>&1; then h=$(scutil --get LocalHostName 2>/dev/null)
        else h=$(hostname 2>/dev/null); fi
    fi
    h=${h%%.*}
    [ -n "$h" ] && to_label "$h"
}

is_private4() { printf '%s' "$1" | grep -qE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; }
is_ipv4() { printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

# Interfaces whose address is never "the LAN address": VPNs/tunnels, containers,
# bridges, loopback. SAME list as server.js lanIp() (_SKIP_IFACE); keep them in step.
SKIP_IFACE_RE='^(tailscale|ts|utun|wg|tun|zt|docker|br-|veth|virbr|lo)'
skip_iface() { printf '%s' "$1" | grep -qE "$SKIP_IFACE_RE"; }

# The LAN IPv4 to publish: the default route's source address when that route leaves
# through a LAN interface (not a tunnel/VPN/container one), else the first private
# address on a LAN interface. Never loopback, never Tailscale/WireGuard/ZeroTier/docker.
lan_ip() {
    local ip="${VALARK_MDNS_IP:-}" a dev line
    if [ -n "$ip" ]; then is_ipv4 "$ip" && printf '%s' "$ip"; return; fi
    if command -v ip >/dev/null 2>&1; then
        line=$(ip -4 route get 192.0.2.1 2>/dev/null | head -1)
        dev=$(printf '%s' "$line" | grep -oE 'dev [^ ]+' | head -1 | cut -d' ' -f2)
        ip=$(printf '%s' "$line" | grep -oE 'src [0-9.]+' | head -1 | cut -d' ' -f2)
        if [ -n "$ip" ] && [ -n "$dev" ] && ! skip_iface "$dev" && is_private4 "$ip"; then printf '%s' "$ip"; return; fi
        # "2: eth0    inet 10.0.0.5/24 brd ... scope global eth0" -> "eth0 10.0.0.5"
        while read -r dev a; do
            skip_iface "${dev%@*}" && continue
            is_private4 "$a" && { printf '%s' "$a"; return; }
        done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $2, $4}')
    elif command -v ifconfig >/dev/null 2>&1; then
        # BSD/macOS: "en0: flags=..." header lines, then "inet A.B.C.D ..." lines.
        while read -r dev a; do
            skip_iface "$dev" && continue
            is_private4 "$a" && { printf '%s' "$a"; return; }
        done < <(ifconfig 2>/dev/null | awk '/^[^ \t]/{d=$1; sub(/:$/, "", d)} $1=="inet"{a=$2; sub(/^addr:/, "", a); print d, a}')
    fi
}

# A throwaway state dir (the system temp dir) is a test's: there, only a publisher
# that itself lives in the temp dir (a stub) may be started, never the real
# avahi-publish, so a test can't leave a real <name>.local announcing on the LAN.
in_tmp() {
    local d="$1" t
    for t in "${TMPDIR:-/tmp}" /tmp /var/tmp; do
        t="${t%/}"; [ -n "$t" ] || continue
        case "$d/" in "$t"/*) return 0 ;; esac
    done
    return 1
}
real_path() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# Our publisher's pid: alive AND `ps` still shows the argv recorded when we started
# it (line 2 of mdns.pid), so a recycled pid is never mistaken for ours.
any_our_pid() {
    local pid args
    [ -r "$PIDF" ] || return 1
    pid=$(head -1 "$PIDF" 2>/dev/null | tr -cd '0-9')
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    args=$(ps -p "$pid" -o args= 2>/dev/null)
    [ "$args" = "$(sed -n 2p "$PIDF" 2>/dev/null)" ] || return 1
    printf '%s' "$pid"
}

stop_ours() {
    local pid
    pid=$(any_our_pid) && kill "$pid" 2>/dev/null
    rm -f "$PIDF" 2>/dev/null
}

emit() {   # state reason
    local name label
    name=$(box_name); label=$(to_label "$name")
    printf '{"ts":"%s","name":%s,"label":%s,"host":%s,"state":%s,"canPublish":%s,"hostLabel":%s,"ip":%s,"reason":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(js "$name")" "$(js "$label")" "$(js "${label}.local")" "$(js "$1")" \
        "${CAN:-false}" "$(js "${HOSTL:-}")" "$(js "${IP:-}")" "$(js "${2:-}")"
}

write_out() {   # JSON line -> OUT atomically (ensure only)
    [ "$MODE" = ensure ] || return 0
    mkdir -p "$SD" 2>/dev/null
    printf '%s' "$1" > "${OUT}.tmp" 2>/dev/null && mv -f "${OUT}.tmp" "$OUT" 2>/dev/null
}

# One ensure/stop at a time per state dir (the server every 10 min and loop step 2h
# can overlap). fd 7, NOT 8: fd 8 is loop.lock, held by the loop cycle that may be
# running us. Busy -> report the last result and leave it to the run in progress.
if [ "$MODE" != check ] && command -v flock >/dev/null 2>&1; then
    mkdir -p "$SD" 2>/dev/null
    exec 7>"${SD}/mdns.lock"
    if ! flock -n 7; then
        [ -s "$OUT" ] && cat "$OUT" || printf '{"state":"busy","reason":"another mdns.sh run holds the lock"}'
        exit 0
    fi
fi

if [ "$MODE" = stop ]; then stop_ours; exit 0; fi

NAME=$(box_name); LABEL=$(to_label "$NAME")
IP=$(lan_ip)
PUB=$(find_publisher) || PUB=""
SD_REAL=$(real_path "$SD")
if [ -n "$PUB" ] && { in_tmp "$SD" || in_tmp "$SD_REAL"; } && ! in_tmp "$PUB" && ! in_tmp "$(real_path "$(dirname "$PUB")")"; then
    PUB=""; TMP_GUARD=1
fi
RUNNING=0; daemon_running && RUNNING=1
HOSTL=""; CAN=false
if [ "$OS" = Darwin ]; then HOSTL=$(host_label)          # mDNSResponder always runs on macOS
elif [ "$RUNNING" = 1 ]; then HOSTL=$(host_label); fi
[ "$RUNNING" = 1 ] && [ -n "$PUB" ] && [ -n "$IP" ] && CAN=true

if [ -n "$HOSTL" ] && [ "$HOSTL" = "$LABEL" ]; then
    # The responder already answers for <hostname>.local, which is our name.
    [ "$MODE" = ensure ] && stop_ours
    j=$(emit native "the box's hostname is ${LABEL}"); write_out "$j"; printf '%s' "$j"; exit 0
fi

reason=""
if [ "$OS" = Darwin ]; then reason="macOS publishes only its Local Hostname; set it to ${LABEL} in System Settings > Sharing"
elif [ "$RUNNING" != 1 ]; then
    if command -v avahi-daemon >/dev/null 2>&1 || [ -n "$PUB" ]; then reason="avahi-daemon is not running"
    else reason="avahi (mDNS) is not installed"; fi
elif [ "${TMP_GUARD:-0}" = 1 ]; then reason="a temporary (test) state dir never starts the real avahi-publish"
elif [ -z "$PUB" ]; then reason="avahi-publish is not installed (package avahi-utils)"
elif [ -z "$IP" ]; then reason="no LAN IPv4 address to publish"
fi
if [ -n "$reason" ]; then
    [ "$MODE" = ensure ] && stop_ours
    j=$(emit unavailable "$reason"); write_out "$j"; printf '%s' "$j"; exit 0
fi

if [ "$MODE" = check ]; then emit available ""; exit 0; fi

# ensure: keep exactly one publisher for ${LABEL}.local -> ${IP}.
args=(-a -R "${LABEL}.local" "$IP")
case "$(basename "$PUB")" in avahi-publish-address) args=(-R "${LABEL}.local" "$IP") ;; esac
want="${LABEL}.local ${IP}"
pid=$(any_our_pid) || pid=""
if [ -n "$pid" ] && [ "$(sed -n 3p "$PIDF" 2>/dev/null)" = "$want" ]; then
    j=$(emit published ""); write_out "$j"; printf '%s' "$j"; exit 0
fi
[ -n "$pid" ] && { kill "$pid" 2>/dev/null; sleep 0.2; }
rm -f "$PIDF" 2>/dev/null
mkdir -p "$SD" 2>/dev/null
log="${SD}/mdns-publish.log"
# 8>&- : never hand loop.lock to a long-lived child (see header); 7>&- : nor our
# own mdns.lock, or every later ensure would find it busy forever.
if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$PUB" "${args[@]}" >"$log" 2>&1 </dev/null 7>&- 8>&- &
else
    nohup "$PUB" "${args[@]}" >"$log" 2>&1 </dev/null 7>&- 8>&- &
fi
npid=$!
sleep "${VALARK_MDNS_SETTLE:-1}"
if kill -0 "$npid" 2>/dev/null; then
    printf '%s\n%s\n%s\n' "$npid" "$(ps -p "$npid" -o args= 2>/dev/null)" "$want" > "$PIDF" 2>/dev/null
    j=$(emit published ""); write_out "$j"; printf '%s' "$j"; exit 0
fi
err=$(tail -n 1 "$log" 2>/dev/null | cut -c1-160)
j=$(emit unavailable "avahi-publish stopped: ${err:-no output}"); write_out "$j"; printf '%s' "$j"; exit 0
