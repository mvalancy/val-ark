#!/bin/bash
###############################################################################
# Val Ark — link DHCP + DNS for a directly connected laptop (issue #148).
#
# When a laptop is plugged straight into the Ark's ethernet port and NOTHING else
# on that link hands out addresses, the Ark serves a tiny DHCP + DNS service on
# THAT ONE INTERFACE so the laptop can reach the web UI with no router.
#
# Rules (the whole point is to never fight a real router):
#   * Opt-in: VALARK_LINK_DHCP=1 in .env. Off = never serves (and stops if serving).
#   * Before serving, probe the link for a DHCP server for a short window
#     (VALARK_LINK_DHCP_PROBE_SECS, default 4). Serve only if NONE answers.
#   * A probe that cannot run (no root, socket error) is "unknown" -> fail closed:
#     never start, and stop if serving.
#   * While serving, re-probe on every carrier change and every
#     VALARK_LINK_DHCP_RECHECK_SECS (default 60); stop the moment a real server
#     (any server id other than our own address) answers. Link down -> stop.
#   * dnsmasq is bound with --interface=<iface> --bind-interfaces, no router
#     option (the laptop keeps its own default route), --no-resolv, and DNS
#     answers the box's name with its link address.
#   * Needs root (or passwordless `sudo -n`) and dnsmasq; without either it logs
#     one clear line and does nothing.
#
# Usage:
#   link-dhcp.sh check     one decision now (serve / don't / stop)
#   link-dhcp.sh ensure    what the loop calls: check, then keep the watcher up
#   link-dhcp.sh watch     long-running carrier/recheck watcher (single, flock'd)
#   link-dhcp.sh stop      stop serving now (and the watcher)
#   link-dhcp.sh status    print state/link-dhcp.json
#
# Test seams (offline tests; never needed on a real box):
#   VALARK_LINK_DHCP_PROBE_CMD  probe command, run as `<cmd> IFACE SECS`; prints
#                               one server IP per line; exit !=0 = unknown
#                               (default: python3 scripts/lib/dhcp_probe.py)
#   VALARK_LINK_DHCP_DNSMASQ    dnsmasq binary      VALARK_LINK_DHCP_IP    ip binary
#   VALARK_LINK_DHCP_SUDO       sudo binary         VALARK_LINK_DHCP_SYSFS /sys/class/net
###############################################################################
set -o pipefail
_LD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LD_SELF="${_LD_DIR}/link-dhcp.sh"
# shellcheck source=./valark-env.sh
. "${_LD_DIR}/valark-env.sh" 2>/dev/null || true
export PATH="/usr/sbin:/sbin:$PATH"   # dnsmasq/ip live in sbin; cron PATH lacks it

LD_STATE="${STATE_DIR}/link-dhcp"
LD_JSON="${STATE_DIR}/link-dhcp.json"
LD_PIDFILE="${LD_STATE}/dnsmasq.pid"
LD_IFFILE="${LD_STATE}/iface"
LD_WATCH_LOCK="${LD_STATE}/watch.lock"
LD_CHECK_LOCK="${LD_STATE}/check.lock"
LD_WATCH_PID="${LD_STATE}/watch.pid"

LD_NET="${VALARK_LINK_DHCP_NET:-10.254.77}"           # /24 prefix (3 octets)
LD_SELF_IP="${LD_NET}.1"
LD_RANGE="${LD_NET}.${VALARK_LINK_DHCP_RANGE_START:-10},${LD_NET}.${VALARK_LINK_DHCP_RANGE_END:-60},255.255.255.0,${VALARK_LINK_DHCP_LEASE:-1h}"
LD_PROBE_SECS="${VALARK_LINK_DHCP_PROBE_SECS:-4}"
LD_WATCH_SECS="${VALARK_LINK_DHCP_WATCH_SECS:-10}"
LD_RECHECK_SECS="${VALARK_LINK_DHCP_RECHECK_SECS:-60}"
LD_SYSFS="${VALARK_LINK_DHCP_SYSFS:-/sys/class/net}"
LD_IPBIN="${VALARK_LINK_DHCP_IP:-ip}"
LD_SUDO="${VALARK_LINK_DHCP_SUDO:-sudo}"

log(){ printf '[%s] link-dhcp: %s\n' "$(date '+%F %T')" "$*"; }
_enabled(){ [ "${VALARK_LINK_DHCP:-0}" = "1" ]; }

_json_state(){   # mode iface detail
    mkdir -p "$STATE_DIR" 2>/dev/null
    local d="$3"; d=${d//\\/\\\\}; d=${d//\"/\\\"}
    printf '{"ts":"%s","mode":"%s","iface":"%s","address":"%s","detail":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$LD_SELF_IP" "$d" > "${LD_JSON}.tmp" 2>/dev/null \
        && mv -f "${LD_JSON}.tmp" "$LD_JSON" 2>/dev/null
}

# The wired interface: VALARK_LINK_DHCP_IFACE, else the ONE physical non-wireless
# ethernet device. Two or more candidates -> refuse (name it in .env).
_iface(){
    local want="${VALARK_LINK_DHCP_IFACE:-}" d n c=()
    if [ -n "$want" ]; then
        [ -e "${LD_SYSFS}/${want}" ] || { echo "ERR:interface ${want} not found"; return 1; }
        echo "$want"; return 0
    fi
    for d in "${LD_SYSFS}"/*; do
        n="${d##*/}"
        case "$n" in eth*|en*) ;; *) continue ;; esac
        [ -e "$d/device" ] || continue          # physical only (no veth/bridge)
        [ -e "$d/wireless" ] && continue
        [ -e "$d/phy80211" ] && continue
        c+=("$n")
    done
    case "${#c[@]}" in
        1) echo "${c[0]}" ;;
        0) echo "ERR:no wired ethernet interface found (set VALARK_LINK_DHCP_IFACE)"; return 1 ;;
        *) echo "ERR:several wired interfaces (${c[*]}); set VALARK_LINK_DHCP_IFACE"; return 1 ;;
    esac
}
_carrier(){ [ "$(cat "${LD_SYSFS}/$1/carrier" 2>/dev/null)" = "1" ]; }

# Privilege prefix: root -> none; else passwordless sudo -n; else fail.
PRIV=()
_priv(){
    if [ "$(id -u)" = "0" ]; then PRIV=(); return 0; fi
    if command -v "$LD_SUDO" >/dev/null 2>&1 && "$LD_SUDO" -n true >/dev/null 2>&1; then
        PRIV=("$LD_SUDO" -n); return 0
    fi
    return 1
}
_dnsmasq(){
    local b="${VALARK_LINK_DHCP_DNSMASQ:-dnsmasq}"
    command -v "$b" 2>/dev/null
}

# Serving = our pidfile names a live process whose argv carries OUR pid-file path
# (guards against a reused pid after a reboot; we must never kill a stranger).
_serving_pid(){
    local pid; pid=$(cat "$LD_PIDFILE" 2>/dev/null | tr -dc 0-9)
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "--pid-file=${LD_PIDFILE}" || return 1
    echo "$pid"
}

_probe(){   # iface -> prints server ids; rc = probe rc
    if [ -n "${VALARK_LINK_DHCP_PROBE_CMD:-}" ]; then
        # shellcheck disable=SC2086
        ${VALARK_LINK_DHCP_PROBE_CMD} "$1" "$LD_PROBE_SECS"
    else
        command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; return 2; }
        "${PRIV[@]}" python3 "${_LD_DIR}/dhcp_probe.py" "$1" "$LD_PROBE_SECS"
    fi
}

_names(){   # DNS names that resolve to our link address
    local h; h=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
    printf '%s\n' ${h:+"$h"} valark ${VALARK_LINK_DHCP_NAMES:-} | awk 'NF && !s[$0]++'
}

ld_start(){   # iface
    local ifc="$1" dm pid n args=()
    dm=$(_dnsmasq) || { log "dnsmasq not found — cannot serve DHCP on ${ifc} (install dnsmasq)"; _json_state unavailable "$ifc" "dnsmasq not installed"; return 1; }
    mkdir -p "$LD_STATE" 2>/dev/null
    if ! "${PRIV[@]}" "$LD_IPBIN" -4 addr show dev "$ifc" 2>/dev/null | grep -qF " ${LD_SELF_IP}/"; then
        "${PRIV[@]}" "$LD_IPBIN" addr add "${LD_SELF_IP}/24" dev "$ifc" \
            || { log "could not add ${LD_SELF_IP}/24 to ${ifc}"; return 1; }
    fi
    args=(--conf-file=/dev/null --interface="$ifc" --bind-interfaces --except-interface=lo
          --listen-address="$LD_SELF_IP" --dhcp-range="$LD_RANGE" --dhcp-option=3
          --no-resolv --no-hosts --domain-needed --bogus-priv
          --dhcp-leasefile="${LD_STATE}/leases" --pid-file="$LD_PIDFILE"
          --log-facility="${LD_STATE}/dnsmasq.log")
    while IFS= read -r n; do args+=(--host-record="${n},${LD_SELF_IP}"); done < <(_names)
    rm -f "$LD_PIDFILE"
    # 6>&- 7>&- 8>&- : never let the daemon inherit the check/watcher/loop locks
    # (a daemon holding a flock'd fd keeps that lock forever; see gotchas.md).
    "${PRIV[@]}" "$dm" "${args[@]}" </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- \
        || { log "dnsmasq failed to start on ${ifc} (see ${LD_STATE}/dnsmasq.log)"; "${PRIV[@]}" "$LD_IPBIN" addr del "${LD_SELF_IP}/24" dev "$ifc" 2>/dev/null; return 1; }
    local i=0; while [ $i -lt 20 ] && ! pid=$(_serving_pid); do sleep 0.1; i=$((i+1)); done
    [ -n "$pid" ] || { log "dnsmasq did not come up on ${ifc}"; return 1; }
    echo "$ifc" > "$LD_IFFILE"
    log "started serving DHCP+DNS on ${ifc} only (${LD_SELF_IP}, range ${LD_RANGE%%,255*}, pid ${pid})"
    _json_state serving "$ifc" "no other DHCP server on the link"
}

ld_stop(){   # reason
    local pid ifc; ifc=$(cat "$LD_IFFILE" 2>/dev/null)
    if pid=$(_serving_pid); then
        "${PRIV[@]}" kill "$pid" 2>/dev/null
        local i=0; while [ $i -lt 30 ] && [ -d "/proc/$pid" ]; do sleep 0.1; i=$((i+1)); done
        [ -n "$ifc" ] && "${PRIV[@]}" "$LD_IPBIN" addr del "${LD_SELF_IP}/24" dev "$ifc" 2>/dev/null
        log "stopped serving DHCP+DNS on ${ifc:-?}: $1"
    fi
    rm -f "$LD_PIDFILE" "$LD_IFFILE" 2>/dev/null
    return 0
}

ld_check(){
    mkdir -p "$LD_STATE" 2>/dev/null
    exec 6>"$LD_CHECK_LOCK"; flock -w 60 6 2>/dev/null || true
    local ifc out rc servers s
    if ! _enabled; then
        _priv; ld_stop "VALARK_LINK_DHCP is off"
        _json_state off "" "VALARK_LINK_DHCP is not 1"; log "off (set VALARK_LINK_DHCP=1 to serve a direct-connect laptop)"; return 0
    fi
    ifc=$(_iface) || { log "${ifc#ERR:}"; _json_state error "" "${ifc#ERR:}"; return 0; }
    if ! _priv; then
        log "needs root (or passwordless sudo) to probe/serve on ${ifc} — not serving"
        _json_state unavailable "$ifc" "needs root"; return 0
    fi
    if ! _carrier "$ifc"; then
        ld_stop "link down"; log "${ifc} link down — idle"; _json_state idle "$ifc" "link down"; return 0
    fi
    local serving=0; _serving_pid >/dev/null && serving=1
    out=$(_probe "$ifc" 2>/dev/null); rc=$?
    if [ "$rc" != 0 ]; then
        ld_stop "DHCP probe failed (fail closed)"
        log "DHCP probe on ${ifc} could not run (rc ${rc}) — not serving (fail closed)"
        _json_state unavailable "$ifc" "probe failed"; return 0
    fi
    servers=""
    for s in $out; do
        [ "$serving" = 1 ] && [ "$s" = "$LD_SELF_IP" ] && continue   # our own answer
        servers="${servers}${servers:+ }${s}"
    done
    if [ -n "$servers" ]; then
        [ "$serving" = 1 ] && ld_stop "a real DHCP server appeared (${servers})"
        log "DHCP server present on ${ifc} (${servers}) — not serving"
        _json_state present "$ifc" "DHCP server present: ${servers}"; return 0
    fi
    if [ "$serving" = 1 ]; then
        log "still the only DHCP server on ${ifc} — serving"; _json_state serving "$ifc" "no other DHCP server on the link"; return 0
    fi
    ld_start "$ifc" || true
    return 0
}

ld_watch(){
    mkdir -p "$LD_STATE" 2>/dev/null
    exec 7>"$LD_WATCH_LOCK"
    flock -n 7 || { log "watcher already running"; return 0; }
    echo $$ > "$LD_WATCH_PID"
    local last="" now ifc c due=0
    while :; do
        [ -f "${STATE_DIR}/STOP" ] && break
        # Fresh shell per decision: re-reads .env, so turning the knob off takes effect.
        ifc=$(_iface 2>/dev/null) || ifc=""
        c=0; [ -n "$ifc" ] && _carrier "$ifc" && c=1
        now=$(date +%s)
        if [ "${ifc}:${c}" != "$last" ] || [ "$now" -ge "$due" ]; then
            [ -n "$last" ] && [ "${ifc}:${c}" != "$last" ] && log "link change on ${ifc:-?} (carrier ${c})"
            last="${ifc}:${c}"; due=$((now + LD_RECHECK_SECS))
            bash "$_LD_SELF" check 7>&- 8>&-
            grep -q '"mode":"off"' "$LD_JSON" 2>/dev/null && { log "disabled — watcher exiting"; break; }
        fi
        sleep "$LD_WATCH_SECS"
    done
    rm -f "$LD_WATCH_PID"
}

_watch_running(){ ( exec 7>"$LD_WATCH_LOCK"; ! flock -n 7 ) 2>/dev/null; }

ld_ensure(){
    mkdir -p "$LD_STATE" 2>/dev/null
    ld_check
    _enabled || { _stop_watch; return 0; }
    # Can't ever serve here (no root/sudo, no dnsmasq, no usable iface)? Don't park
    # a watcher that would log the same line every minute; the next loop cycle retries.
    if grep -qE '"mode":"error"|needs root|dnsmasq not installed' "$LD_JSON" 2>/dev/null; then
        _stop_watch; return 0
    fi
    if ! _watch_running; then
        setsid nohup bash "$_LD_SELF" watch >>"${LD_STATE}/watch.log" 2>&1 </dev/null 6>&- 7>&- 8>&- & disown
        log "watcher started (re-probes on link change, every ${LD_RECHECK_SECS}s)"
    fi
}
_stop_watch(){
    local p; p=$(cat "$LD_WATCH_PID" 2>/dev/null | tr -dc 0-9)
    [ -n "$p" ] && [ -r "/proc/$p/cmdline" ] && tr '\0' ' ' < "/proc/$p/cmdline" | grep -qF "link-dhcp.sh watch" && kill "$p" 2>/dev/null
    rm -f "$LD_WATCH_PID" 2>/dev/null
}

case "${1:-}" in
    check)  ld_check ;;
    ensure) ld_ensure ;;
    watch)  ld_watch ;;
    stop)   _stop_watch; _priv; ld_stop "stopped by request"; _json_state idle "" "stopped by request" ;;
    status) cat "$LD_JSON" 2>/dev/null || echo '{"mode":"unknown"}' ;;
    *) echo "usage: link-dhcp.sh {check|ensure|watch|stop|status}" >&2; exit 64 ;;
esac
