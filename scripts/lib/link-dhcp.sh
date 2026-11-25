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
#   * Probe the link first (scripts/lib/dhcp_probe.py: up to 4 DISCOVERs at
#     0/2/4/8 s, then VALARK_LINK_DHCP_PROBE_SECS more). Serve only after TWO
#     empty probes at least VALARK_LINK_DHCP_CONFIRM_SECS (30) apart on the same
#     link epoch (a switch port in STP learning drops frames for ~30 s after
#     link-up). The first VALARK_LINK_DHCP_EARLY_SECS (600) of serving hand out
#     short leases (VALARK_LINK_DHCP_EARLY_LEASE, 5m) so a late-found router wins fast.
#   * EVERY outcome other than "serving" stops dnsmasq and removes our address:
#     a server answered, link down, probe could not run (fail closed), bad
#     config, interface ambiguous, no root, no dnsmasq, knob off, watcher exit.
#   * While serving, a watcher re-probes on every carrier change (carrier_changes
#     counter, polled every VALARK_LINK_DHCP_WATCH_SECS) and every
#     VALARK_LINK_DHCP_RECHECK_SECS (60).
#   * dnsmasq is bound with --interface=<iface> --bind-interfaces, no router
#     option, and DNS per VALARK_LINK_DHCP_DNS (local | forward | off).
#   * Runtime files (pid, locks, leases, logs) live on tmpfs in
#     VALARK_LINK_DHCP_RUN (/run/valark-link-dhcp), never on the data disk; only
#     the small state/link-dhcp.json status goes to state/ (and only if it exists).
#   * Needs root (or passwordless `sudo -n`) and dnsmasq; fails soft otherwise.
#
# Usage:
#   link-dhcp.sh check     one decision now (serve / don't / stop)
#   link-dhcp.sh ensure    what the loop calls: check, then keep the watcher up
#   link-dhcp.sh watch     long-running carrier/recheck watcher (single, flock'd)
#   link-dhcp.sh stop      stop serving now (and the watcher)
#   link-dhcp.sh status    print state/link-dhcp.json
#
# The watcher re-reads the VALARK_LINK_DHCP* knobs from .env before each check,
# so editing or removing a line takes effect without a restart.
#
# Test seams (offline tests; never needed on a real box):
#   VALARK_LINK_DHCP_PROBE_CMD  probe command, run as `<cmd> IFACE SECS`; prints
#                               server IPs; exit !=0 = unknown
#   VALARK_LINK_DHCP_DNSMASQ / _IP / _SUDO / _ID   binaries (dnsmasq, ip, sudo, id)
#   VALARK_LINK_DHCP_SYSFS      /sys/class/net      VALARK_LINK_DHCP_RUN  runtime dir
###############################################################################
set -o pipefail
_LD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LD_SELF="${_LD_DIR}/link-dhcp.sh"
# shellcheck source=./valark-env.sh
. "${_LD_DIR}/valark-env.sh" 2>/dev/null || true
export PATH="/usr/sbin:/sbin:$PATH"   # dnsmasq/ip live in sbin; cron PATH lacks it

log(){ printf '[%s] link-dhcp: %s\n' "$(date '+%F %T')" "$*"; }
_int(){ [[ $1 =~ ^[0-9]+$ ]]; }
_num(){ [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

_ld_config(){
    LD_RUN="${VALARK_LINK_DHCP_RUN:-/run/valark-link-dhcp}"
    LD_PIDFILE="${LD_RUN}/dnsmasq.pid"; LD_IFFILE="${LD_RUN}/iface"
    LD_CONFIRM="${LD_RUN}/confirm";     LD_LEASEFILE="${LD_RUN}/lease"
    LD_STARTED="${LD_RUN}/started"
    LD_WATCH_LOCK="${LD_RUN}/watch.lock"; LD_CHECK_LOCK="${LD_RUN}/check.lock"
    LD_WATCH_PID="${LD_RUN}/watch.pid"
    LD_JSON="${STATE_DIR}/link-dhcp.json"
    LD_NET="${VALARK_LINK_DHCP_NET:-10.254.77}"
    LD_SELF_IP="${LD_NET}.1"
    LD_RS="${VALARK_LINK_DHCP_RANGE_START:-10}"; LD_RE="${VALARK_LINK_DHCP_RANGE_END:-60}"
    LD_LEASE="${VALARK_LINK_DHCP_LEASE:-1h}"
    LD_EARLY_LEASE="${VALARK_LINK_DHCP_EARLY_LEASE:-5m}"
    LD_EARLY_SECS="${VALARK_LINK_DHCP_EARLY_SECS:-600}"
    LD_PROBE_SECS="${VALARK_LINK_DHCP_PROBE_SECS:-4}"
    LD_CONFIRM_SECS="${VALARK_LINK_DHCP_CONFIRM_SECS:-30}"
    LD_WATCH_SECS="${VALARK_LINK_DHCP_WATCH_SECS:-2}"
    LD_RECHECK_SECS="${VALARK_LINK_DHCP_RECHECK_SECS:-60}"
    LD_LOCK_WAIT="${VALARK_LINK_DHCP_LOCK_WAIT:-60}"
    LD_DNS="${VALARK_LINK_DHCP_DNS:-local}"
    LD_SYSFS="${VALARK_LINK_DHCP_SYSFS:-/sys/class/net}"
    LD_IPBIN="${VALARK_LINK_DHCP_IP:-ip}"
    LD_SUDO="${VALARK_LINK_DHCP_SUDO:-sudo}"
    LD_ID="${VALARK_LINK_DHCP_ID:-id}"
    LD_DOMAIN="home.arpa"                               # RFC 8375 local-only domain
    LD_CFG_ERR=""
    local o1 o2 o3 v
    if [[ $LD_NET =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        o1=$((10#${BASH_REMATCH[1]})); o2=$((10#${BASH_REMATCH[2]})); o3=$((10#${BASH_REMATCH[3]}))
        if [ "$o1" -gt 255 ] || [ "$o2" -gt 255 ] || [ "$o3" -gt 255 ]; then
            LD_CFG_ERR="VALARK_LINK_DHCP_NET=${LD_NET} has an octet over 255"
        elif ! { [ "$o1" = 10 ] || { [ "$o1" = 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; } || { [ "$o1" = 192 ] && [ "$o2" = 168 ]; }; }; then
            LD_CFG_ERR="VALARK_LINK_DHCP_NET=${LD_NET} is not a private (RFC 1918) /24"
        fi
    else
        LD_CFG_ERR="VALARK_LINK_DHCP_NET must be three octets like 10.254.77 (got '${LD_NET}')"
    fi
    if [ -z "$LD_CFG_ERR" ]; then
        if ! _int "$LD_RS" || ! _int "$LD_RE" || [ "$((10#$LD_RS))" -lt 2 ] || [ "$((10#$LD_RE))" -gt 254 ] || [ "$((10#$LD_RS))" -gt "$((10#$LD_RE))" ]; then
            LD_CFG_ERR="VALARK_LINK_DHCP_RANGE_START/END must be integers with 2 <= start <= end <= 254"
        else
            LD_RS=$((10#$LD_RS)); LD_RE=$((10#$LD_RE))
        fi
    fi
    for v in "$LD_LEASE" "$LD_EARLY_LEASE"; do
        [[ $v =~ ^[0-9]+[mh]?$ ]] || LD_CFG_ERR="${LD_CFG_ERR:-lease '${v}' must match [0-9]+[mh]?}"
    done
    case "$LD_DNS" in local|forward|off) ;; *) LD_CFG_ERR="${LD_CFG_ERR:-VALARK_LINK_DHCP_DNS must be local, forward or off}" ;; esac
    for v in "$LD_EARLY_SECS" "$LD_CONFIRM_SECS" "$LD_RECHECK_SECS" "$LD_LOCK_WAIT"; do
        _int "$v" || LD_CFG_ERR="${LD_CFG_ERR:-timer value '${v}' must be a whole number of seconds}"
    done
    for v in "$LD_PROBE_SECS" "$LD_WATCH_SECS"; do
        _num "$v" || LD_CFG_ERR="${LD_CFG_ERR:-timer value '${v}' must be a number of seconds}"
    done
}
_ld_config

# Re-read the knobs from .env: drop every VALARK_LINK_DHCP* first, because
# valark-env.sh sources .env with `set -a`, so a line REMOVED from .env would
# otherwise live on in the exported environment.
_reload(){
    local v
    for v in "${!VALARK_LINK_DHCP@}"; do unset "$v"; done
    unset _VALARK_ENV_LOADED          # valark-env.sh is include-guarded; force a re-read
    . "${_LD_DIR}/valark-env.sh" 2>/dev/null
    _ld_config
}

_enabled(){ [ "${VALARK_LINK_DHCP:-0}" = "1" ]; }

_json_state(){   # mode iface detail — status only; never creates state/ (#58)
    [ -d "$STATE_DIR" ] || return 0
    local d="$3"; d=${d//\\/\\\\}; d=${d//\"/\\\"}
    printf '{"ts":"%s","mode":"%s","iface":"%s","address":"%s","dns":"%s","detail":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$LD_SELF_IP" "$LD_DNS" "$d" > "${LD_JSON}.tmp" 2>/dev/null \
        && mv -f "${LD_JSON}.tmp" "$LD_JSON" 2>/dev/null
}

# The wired interface: VALARK_LINK_DHCP_IFACE, else the ONE physical non-wireless
# ethernet device. Two or more candidates -> refuse (name it in .env).
_iface(){
    local want="${VALARK_LINK_DHCP_IFACE:-}" d n c=()
    if [ -n "$want" ]; then
        [[ $want =~ ^[A-Za-z0-9._-]{1,15}$ ]] || { echo "ERR:VALARK_LINK_DHCP_IFACE '${want}' is not an interface name"; return 1; }
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
# Link epoch: changes on every carrier transition (even a quick down/up between
# two polls, via the kernel's carrier_changes counter).
_epoch(){ printf '%s:%s:%s' "$1" "$(cat "${LD_SYSFS}/$1/carrier_changes" 2>/dev/null)" "$(cat "${LD_SYSFS}/$1/carrier" 2>/dev/null)"; }

# Privilege prefix: root -> none; else passwordless sudo -n; else fail.
# Cached for the life of this process (the watcher runs checks in-process).
PRIV=(); _LD_PRIV_CACHE=""
_priv(){
    case "$_LD_PRIV_CACHE" in root) PRIV=(); return 0 ;; sudo) PRIV=("$LD_SUDO" -n); return 0 ;; esac
    if [ "$("$LD_ID" -u 2>/dev/null)" = "0" ]; then PRIV=(); _LD_PRIV_CACHE=root; return 0; fi
    if command -v "$LD_SUDO" >/dev/null 2>&1 && "$LD_SUDO" -n true >/dev/null 2>&1; then
        PRIV=("$LD_SUDO" -n); _LD_PRIV_CACHE=sudo; return 0
    fi
    PRIV=(); return 1
}
_dnsmasq(){ command -v "${VALARK_LINK_DHCP_DNSMASQ:-dnsmasq}" 2>/dev/null; }

# Runtime dir on tmpfs, owned by the loop's user so it can take the locks; root
# (dnsmasq) can still write its pid/leases there.
_run_dir(){
    [ -d "$LD_RUN" ] && [ -w "$LD_RUN" ] && return 0
    "${PRIV[@]}" install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "$LD_RUN" 2>/dev/null
    [ -d "$LD_RUN" ] && [ -w "$LD_RUN" ]
}

# Ours = argv carries --conf-file=/dev/null AND our --pid-file (a reused pid
# after a reboot is never ours; we must never kill a stranger). Pidfile first,
# then a cmdline scan in case the pidfile is gone.
_is_ours(){
    local c; c=$({ tr '\0' '\n' < "/proc/$1/cmdline"; } 2>/dev/null) || return 1
    grep -qxF -- "--pid-file=${LD_PIDFILE}" <<<"$c" && grep -qxF -- "--conf-file=/dev/null" <<<"$c"
}
_serving_pid(){
    local pid f
    pid=$({ tr -dc 0-9 < "$LD_PIDFILE"; } 2>/dev/null)
    if [ -n "$pid" ] && _is_ours "$pid"; then echo "$pid"; return 0; fi
    for f in $(grep -lzF -- "--pid-file=${LD_PIDFILE}" /proc/[0-9]*/cmdline 2>/dev/null); do
        pid=${f#/proc/}; pid=${pid%/cmdline}
        [ "$pid" != "$$" ] && _is_ours "$pid" && { echo "$pid"; return 0; }
    done
    return 1
}

_probe(){   # iface -> prints server ids; rc = probe rc
    if [ -n "${VALARK_LINK_DHCP_PROBE_CMD:-}" ]; then
        # shellcheck disable=SC2086
        ${VALARK_LINK_DHCP_PROBE_CMD} "$1" "$LD_PROBE_SECS"
    else
        command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; return 2; }
        "${PRIV[@]}" python3 -I "${_LD_DIR}/dhcp_probe.py" "$1" "$LD_PROBE_SECS"
    fi
}

_names(){   # DNS names for our link address: hostname, valark, VALARK_LINK_DHCP_NAMES
    local -a raw=(); local n h
    h=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
    set -f
    read -r -a raw <<< "${h} valark ${VALARK_LINK_DHCP_NAMES:-}"
    set +f
    for n in "${raw[@]}"; do
        [[ $n =~ ^[A-Za-z0-9-]{1,63}$ ]] && printf '%s\n' "$n"
    done | awk '!s[$0]++'
}

_addr_present(){ "$LD_IPBIN" -4 addr show dev "$1" 2>/dev/null | grep -qF " ${LD_SELF_IP}/"; }
_addr_ensure(){   # rc 0 present, 2 re-added, 1 failed
    _addr_present "$1" && return 0
    "${PRIV[@]}" "$LD_IPBIN" addr add "${LD_SELF_IP}/24" dev "$1" 2>/dev/null || return 1
    return 2
}

# NET must not already be reachable via another interface (VPN, LAN, second
# NIC). `ip route get NET.1` always answers via the default route, so look at
# the specific routes covering NET.1 (default excluded) and at addresses.
_net_conflict(){   # iface -> prints the conflict, rc 0 if there is one
    local line dev
    while IFS= read -r line; do
        case "$line" in ""|default*) continue ;; esac
        dev=$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$line")
        [ -n "$dev" ] && [ "$dev" != "$1" ] && [ "$dev" != lo ] && { echo "route '${line}'"; return 0; }
    done < <("$LD_IPBIN" -4 route show match "$LD_SELF_IP" 2>/dev/null)
    while IFS= read -r line; do
        dev=$(awk '{print $2}' <<<"$line"); dev=${dev%:}
        [ -n "$dev" ] && [ "$dev" != "$1" ] && { echo "address on ${dev}"; return 0; }
    done < <("$LD_IPBIN" -4 -o addr show 2>/dev/null | grep -F " inet ${LD_NET}.")
    return 1
}

_dnsmasq_kill(){   # stop our dnsmasq if running; rc 0 if one was stopped
    local pid i=0
    pid=$(_serving_pid) || return 1
    "${PRIV[@]}" kill "$pid" 2>/dev/null
    while [ $i -lt 30 ] && [ -d "/proc/$pid" ]; do sleep 0.1; i=$((i+1)); done
    [ -d "/proc/$pid" ] && "${PRIV[@]}" kill -9 "$pid" 2>/dev/null && sleep 0.2
    if [ -d "/proc/$pid" ] && _is_ours "$pid"; then
        log "could not stop dnsmasq (pid ${pid}) — needs root or passwordless sudo"; return 1
    fi
    rm -f "$LD_PIDFILE" 2>/dev/null
    return 0
}

ld_stop(){   # reason — idempotent; always removes our address if present
    local did=0 ifc seen=" "
    _dnsmasq_kill && did=1
    for ifc in $(cat "$LD_IFFILE" 2>/dev/null) ${LD_IFC:-}; do
        case "$seen" in *" $ifc "*) continue ;; esac; seen="${seen}${ifc} "
        [ -e "${LD_SYSFS}/${ifc}" ] || continue
        if _addr_present "$ifc"; then
            "${PRIV[@]}" "$LD_IPBIN" addr del "${LD_SELF_IP}/24" dev "$ifc" 2>/dev/null \
                || log "could not remove ${LD_SELF_IP}/24 from ${ifc}"
            did=1
        fi
    done
    seen=${seen# }; seen=${seen% }
    [ "$did" = 1 ] && log "stopped serving DHCP+DNS on ${seen:-?}: $1"
    rm -f "$LD_IFFILE" "$LD_LEASEFILE" "$LD_STARTED" 2>/dev/null
    return 0
}

ld_start(){   # iface lease
    local ifc="$1" lease="$2" pid n args=() i=0 rc
    _addr_ensure "$ifc"; rc=$?
    [ "$rc" = 1 ] && { log "could not add ${LD_SELF_IP}/24 to ${ifc}"; return 1; }
    echo "$ifc" > "$LD_IFFILE"
    args=(--conf-file=/dev/null --interface="$ifc" --bind-interfaces --except-interface=lo
          --listen-address="$LD_SELF_IP"
          --dhcp-range="${LD_NET}.${LD_RS},${LD_NET}.${LD_RE},255.255.255.0,${lease}"
          --dhcp-option=3 --no-hosts
          --dhcp-leasefile="${LD_RUN}/leases" --pid-file="$LD_PIDFILE"
          --log-facility="${LD_RUN}/dnsmasq.log")
    "$LD_ID" dnsmasq >/dev/null 2>&1 || args+=(--user=nobody)   # dnsmasq-base may lack the user
    case "$LD_DNS" in
        off) args+=(--port=0 --dhcp-option=6) ;;
        *)   args+=(--domain-needed --bogus-priv --domain="$LD_DOMAIN" --local="/${LD_DOMAIN}/"
                    --dhcp-option=option:domain-search,"$LD_DOMAIN")
             [ "$LD_DNS" = local ] && args+=(--no-resolv)
             while IFS= read -r n; do args+=(--host-record="${n},${n}.${LD_DOMAIN},${LD_SELF_IP}"); done < <(_names) ;;
    esac
    rm -f "$LD_PIDFILE"
    # 6>&- 7>&- 8>&- : never let the daemon inherit the check/watcher/loop locks
    # (a daemon holding a flock'd fd keeps that lock forever; see gotchas.md).
    if ! "${PRIV[@]}" "$(_dnsmasq)" "${args[@]}" </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&-; then
        log "dnsmasq failed to start on ${ifc} (port 53/67 in use? see ${LD_RUN}/dnsmasq.log)"
        ld_stop "dnsmasq failed to start"; return 1
    fi
    while [ $i -lt 20 ] && ! pid=$(_serving_pid); do sleep 0.1; i=$((i+1)); done
    if [ -z "$pid" ]; then
        log "dnsmasq did not come up on ${ifc}"; ld_stop "dnsmasq did not come up"; return 1
    fi
    echo "$lease" > "$LD_LEASEFILE"; date +%s > "$LD_STARTED"
    log "started serving DHCP+DNS on ${ifc} only (${LD_SELF_IP}, ${LD_NET}.${LD_RS}-${LD_RE}, lease ${lease}, dns ${LD_DNS}, pid ${pid})"
}

# One decision. Sets MODE (off|idle|probing|present|serving|unavailable|error),
# DETAIL and LD_IFC. Serving is the ONLY outcome the caller leaves running.
_decide(){
    local r out rc now ce ct serving=0 ep
    [ -n "$LD_CFG_ERR" ] && { MODE=error; DETAIL="$LD_CFG_ERR"; return; }
    r=$(_iface) || { MODE=error; DETAIL="${r#ERR:}"; return; }
    LD_IFC="$r"
    if ! _dnsmasq >/dev/null; then
        MODE=unavailable; DETAIL="dnsmasq not installed"
        log "dnsmasq not found — cannot serve DHCP on ${LD_IFC} (apt install dnsmasq-base)"; return
    fi
    if r=$(_net_conflict "$LD_IFC"); then
        MODE=error; DETAIL="${LD_NET}.0/24 is already in use (${r}); set VALARK_LINK_DHCP_NET"; return
    fi
    if ! _carrier "$LD_IFC"; then rm -f "$LD_CONFIRM"; MODE=idle; DETAIL="link down"; return; fi
    _serving_pid >/dev/null && serving=1
    if [ "$serving" = 1 ] && [ "$(cat "$LD_IFFILE" 2>/dev/null)" != "$LD_IFC" ]; then
        ld_stop "interface changed to ${LD_IFC}"; serving=0
    fi
    out=$(_probe "$LD_IFC" 2>/dev/null); rc=$?
    if [ "$rc" != 0 ]; then
        rm -f "$LD_CONFIRM"; MODE=unavailable; DETAIL="DHCP probe could not run (rc ${rc}); fail closed"; return
    fi
    out=${out//$'\n'/ }; out=${out%% }   # one line, space separated (no globbing)
    if [ -n "$out" ]; then
        rm -f "$LD_CONFIRM"; MODE=present; DETAIL="DHCP server present: ${out}"; return
    fi
    now=$(date +%s)
    if [ "$serving" = 1 ]; then
        _addr_ensure "$LD_IFC"; rc=$?
        [ "$rc" = 2 ] && log "re-added ${LD_SELF_IP}/24 on ${LD_IFC} (something removed it)"
        [ "$rc" = 1 ] && { MODE=error; DETAIL="lost ${LD_SELF_IP}/24 on ${LD_IFC} and could not re-add it"; return; }
        local st; st=$({ tr -dc 0-9 < "$LD_STARTED"; } 2>/dev/null); st=${st:-0}
        if [ "$(cat "$LD_LEASEFILE" 2>/dev/null)" != "$LD_LEASE" ] && [ $(( now - st )) -ge "$LD_EARLY_SECS" ]; then
            log "settled: switching lease ${LD_EARLY_LEASE} -> ${LD_LEASE}"
            _dnsmasq_kill
            ld_start "$LD_IFC" "$LD_LEASE" || { MODE=error; DETAIL="dnsmasq failed to restart"; return; }
        fi
        MODE=serving; DETAIL="no other DHCP server on the link"; return
    fi
    # Not serving yet: need two empty probes >= CONFIRM_SECS apart on this link epoch.
    ep=$(_epoch "$LD_IFC")
    ce=""; ct=""; { read -r ce ct < "$LD_CONFIRM"; } 2>/dev/null
    if [ "$ce" != "$ep" ] || ! _int "${ct:-x}"; then
        echo "$ep $now" > "$LD_CONFIRM"
        MODE=probing; DETAIL="no DHCP server answered; confirming in ${LD_CONFIRM_SECS}s"; return
    fi
    if [ $(( now - ct )) -lt "$LD_CONFIRM_SECS" ]; then
        MODE=probing; DETAIL="no DHCP server answered; confirming in $(( LD_CONFIRM_SECS - now + ct ))s"; return
    fi
    if ld_start "$LD_IFC" "$LD_EARLY_LEASE"; then
        rm -f "$LD_CONFIRM"; MODE=serving; DETAIL="no other DHCP server on the link"
    else
        MODE=error; DETAIL="dnsmasq failed to start"
    fi
}

# Log the outcome only when it changes (the watcher re-checks every minute; its
# log lives on tmpfs, so an unchanged "serving" line must not grow it forever).
_LD_LAST=""
_finish(){
    [ "${MODE}|${DETAIL}" != "$_LD_LAST" ] && log "${LD_IFC:-?}: ${MODE} — ${DETAIL}"
    _LD_LAST="${MODE}|${DETAIL}"
    _json_state "$MODE" "${LD_IFC:-}" "$DETAIL"
}

ld_check(){
    MODE=""; DETAIL=""; LD_IFC=""
    if ! _enabled; then
        _priv || true
        [ -d "$LD_RUN" ] && { exec 6>>"$LD_CHECK_LOCK"; flock -w 10 6 2>/dev/null; }   # stopping is safe either way
        ld_stop "VALARK_LINK_DHCP is off"
        MODE=off; DETAIL="VALARK_LINK_DHCP is not 1"; _finish; exec 6>&-; return 0
    fi
    if ! _priv; then
        LD_IFC=$(_iface 2>/dev/null) || LD_IFC=""
        ld_stop "no root"     # best effort: a root dnsmasq can't be killed from here (logged)
        MODE=unavailable; DETAIL="needs root (or passwordless sudo) to probe/serve — not serving"; _finish; return 0
    fi
    if ! _run_dir; then
        ld_stop "no runtime dir"
        MODE=error; DETAIL="cannot create ${LD_RUN}"; _finish; return 0
    fi
    exec 6>>"$LD_CHECK_LOCK"
    if ! flock -w "$LD_LOCK_WAIT" 6 2>/dev/null; then
        exec 6>&-; log "another check holds ${LD_CHECK_LOCK} — skipping this one"; return 0
    fi
    _decide
    [ "$MODE" = serving ] || ld_stop "$DETAIL"
    _finish
    exec 6>&-
    return 0
}

_watch_exit(){
    trap - EXIT
    ld_stop "watcher exiting"
    [ "$MODE" = off ] || _json_state idle "${LD_IFC:-}" "watcher exited"
    rm -f "$LD_WATCH_PID" 2>/dev/null
}

ld_watch(){
    _priv || { log "needs root (or passwordless sudo) — watcher not started"; return 0; }
    _run_dir || { log "cannot create ${LD_RUN} — watcher not started"; return 0; }
    exec 7>>"$LD_WATCH_LOCK"
    flock -n 7 || { log "watcher already running"; return 0; }
    echo $$ > "$LD_WATCH_PID"
    trap '_watch_exit' EXIT
    trap 'exit 0' TERM INT HUP
    local last="" ep ifc now due=0
    while :; do
        if [ -f "${STATE_DIR}/STOP" ]; then log "STOP flag — watcher exiting"; break; fi
        ifc=$(_iface 2>/dev/null) || ifc=""
        ep=$(_epoch "$ifc"); now=$(date +%s)
        if [ "$ep" != "$last" ] || [ "$now" -ge "$due" ]; then
            [ -n "$last" ] && [ "$ep" != "$last" ] && log "link change on ${ifc:-?} (${ep})"
            last="$ep"
            _reload
            ld_check
            [ "$MODE" = off ] && { log "disabled — watcher exiting"; break; }
            if [ "$MODE" = probing ]; then due=$((now + LD_CONFIRM_SECS)); else due=$((now + LD_RECHECK_SECS)); fi
        fi
        sleep "$LD_WATCH_SECS" & wait $!
    done
    exit 0
}

_watch_running(){ [ -e "$LD_WATCH_LOCK" ] && ( exec 7>>"$LD_WATCH_LOCK"; ! flock -n 7 ) 2>/dev/null; }
_watch_pid(){
    local p; p=$({ tr -dc 0-9 < "$LD_WATCH_PID"; } 2>/dev/null)
    [ -n "$p" ] && { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | grep -qF "link-dhcp.sh watch" && echo "$p"
}
_stop_watch(){
    local p i=0; p=$(_watch_pid) || return 0
    kill "$p" 2>/dev/null
    while [ $i -lt 50 ] && [ -d "/proc/$p" ]; do sleep 0.1; i=$((i+1)); done   # its EXIT trap stops dnsmasq
}
_start_watch(){
    _watch_running && return 0
    setsid nohup bash "$_LD_SELF" watch >>"${LD_RUN}/watch.log" 2>&1 </dev/null 6>&- 7>&- 8>&- & disown
    log "watcher started (re-probes on link change, every ${LD_RECHECK_SECS}s)"
}

ld_ensure(){
    ld_check
    if ! _enabled; then _stop_watch; return 0; fi
    # Never stop the watcher while our dnsmasq is alive: it is what stops it.
    if _serving_pid >/dev/null; then _start_watch; return 0; fi
    # Can never serve here (config, ambiguous iface, no root, no dnsmasq)? Don't
    # park a watcher that logs the same line every minute; the next cycle retries.
    if [ "$MODE" = error ] || { [ "$MODE" = unavailable ] && [[ $DETAIL =~ needs\ root|dnsmasq\ not\ installed ]]; }; then
        _stop_watch; return 0
    fi
    _start_watch
}

case "${1:-}" in
    check)  ld_check ;;
    ensure) ld_ensure ;;
    watch)  ld_watch ;;
    stop)   _stop_watch; _priv; ld_stop "stopped by request"; _json_state idle "" "stopped by request" ;;
    status) cat "$LD_JSON" 2>/dev/null || echo '{"mode":"unknown"}' ;;
    *) echo "usage: link-dhcp.sh {check|ensure|watch|stop|status}" >&2; exit 64 ;;
esac
