#!/bin/bash
###############################################################################
# Val Ark — is Tailscale running in userspace-networking mode on this box? (#311)
#
# In userspace-networking mode (`tailscaled --tun=userspace-networking`, common in
# containers and on some NAS boxes) tailscaled has no network interface: it accepts
# a tailnet peer's connection itself and connects onward to server.js from
# 127.0.0.1. server.js then sees every tailnet peer as the box's own console, which
# is the Admin. This detector lets the loop and the Health page say so loudly.
#
# Read-only and fail-soft: it only reads /proc, /sys/class/net and runs
# `tailscale status --json` (a query, never a change). Any error degrades to
# "unknown" or "absent"; it never exits non-zero for a detection result.
#
# Signals, strongest first:
#   1. `tailscale status --json` reports "TUN": false   (the daemon's own word)
#   2. tailscaled's argv has --tun=userspace-networking (also -tun, and a split value)
#   3. tailscaled is running but its interface (tailscale0, or the --tun=NAME it
#      was given) is not in /sys/class/net (Linux only)
# "kernel" needs the daemon to say TUN true, or the interface to exist.
#
# Output (one JSON object):
#   {"ts":"…","state":"absent|kernel|userspace|unknown","userspace":true|false,
#    "running":true|false,"evidence":["…",…]}
#
# Test seams (all optional):
#   VALARK_TAILSCALE_CMD     the tailscale CLI to query (a stub in tests);
#                            "none" = behave as if it isn't installed
#   VALARK_TAILSCALE_PROC    stands in for /proc       (fixture dir of <pid>/cmdline)
#   VALARK_TAILSCALE_SYSNET  stands in for /sys/class/net (fixture dir of iface names)
#
# Usage:
#   tailscale-mode.sh check          print the JSON
#   tailscale-mode.sh write FILE     write the JSON to FILE atomically (and print it)
###############################################################################
set -u

PROC="${VALARK_TAILSCALE_PROC:-/proc}"
SYSNET="${VALARK_TAILSCALE_SYSNET:-/sys/class/net}"

ts_cli() {
    local c="${VALARK_TAILSCALE_CMD:-}"
    if [ "$c" = "none" ]; then return 1; fi
    if [ -n "$c" ]; then [ -x "$c" ] && { printf '%s' "$c"; return 0; }; return 1; fi
    c="$(command -v tailscale 2>/dev/null)" || return 1
    [ -n "$c" ] && printf '%s' "$c"
}

# tailscaled's argv, one arg per line (the main daemon, not its be-child helpers).
# Prints nothing when no tailscaled is running. Reads cmdline files directly, so
# no `pgrep -f` pattern can match its own argv (see gotchas.md, tailscale-ssh).
daemon_argv() {
    local f args a0
    if [ -d "$PROC" ]; then
        for f in "$PROC"/[0-9]*/cmdline; do
            [ -r "$f" ] || continue
            # argv[0] with a bash builtin (no fork per process); only a match is parsed.
            a0=""; IFS= read -r -d '' a0 < "$f" 2>/dev/null
            case "${a0##*/}" in
                tailscaled) ;;
                *) continue ;;
            esac
            args="$(tr '\0' '\n' < "$f" 2>/dev/null)" || continue
            printf '%s\n' "$args" | sed -n 2p | grep -qx 'be-child' && continue
            printf '%s\n' "$args"
            return 0
        done
    fi
    return 0
}

# The --tun value from an argv (one arg per line); empty when not given.
tun_arg() {
    awk '
        want { print; exit }
        /^--?tun=/ { sub(/^--?tun=/, ""); print; exit }
        /^--?tun$/ { want = 1 }
    '
}

detect() {
    local running=false state=unknown evidence=() argv tun="" cli st="" tunflag=""
    argv="$(daemon_argv)"
    if [ -n "$argv" ]; then
        running=true
        tun="$(printf '%s\n' "$argv" | tun_arg)"
    fi

    if cli="$(ts_cli)"; then
        # A read-only query. timeout keeps a wedged daemon from stalling the loop.
        st="$(timeout 8 "$cli" status --json 2>/dev/null)" || st=""
        if [ -n "$st" ]; then
            if printf '%s' "$st" | grep -qE '"TUN"[[:space:]]*:[[:space:]]*false'; then tunflag=false
            elif printf '%s' "$st" | grep -qE '"TUN"[[:space:]]*:[[:space:]]*true'; then tunflag=true
            fi
            # A status answer means a daemon is there, even if /proc hid it from us.
            printf '%s' "$st" | grep -qE '"BackendState"' && running=true
        fi
    fi

    if [ "$running" != true ]; then
        state=absent
    else
        [ "$tunflag" = false ] && evidence+=("tailscale status reports no TUN interface")
        [ "$tun" = "userspace-networking" ] && evidence+=("tailscaled was started with --tun=userspace-networking")
        local ifname="${tun:-tailscale0}" ifstate=""
        if [ "$ifname" != "userspace-networking" ] && [ -d "$SYSNET" ] && [ "$(uname -s 2>/dev/null)" = Linux -o -n "${VALARK_TAILSCALE_SYSNET:-}" ]; then
            if [ -e "$SYSNET/$ifname" ]; then ifstate=present; else ifstate=missing; fi
        fi
        if [ "${#evidence[@]}" -gt 0 ]; then
            state=userspace
        elif [ "$tunflag" = true ] || [ "$ifstate" = present ]; then
            state=kernel
        elif [ "$ifstate" = missing ]; then
            state=userspace
            evidence+=("tailscaled is running but there is no ${ifname} interface")
        fi
    fi

    local ev="" e first=1
    for e in "${evidence[@]+"${evidence[@]}"}"; do
        e=${e//\\/\\\\}; e=${e//\"/\\\"}
        [ "$first" = 1 ] && first=0 || ev="${ev},"
        ev="${ev}\"${e}\""
    done
    local us=false; [ "$state" = userspace ] && us=true
    printf '{"ts":"%s","state":"%s","userspace":%s,"running":%s,"evidence":[%s]}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$state" "$us" "$running" "$ev"
}

case "${1:-check}" in
    check) detect ;;
    write)
        out="${2:-}"
        [ -n "$out" ] || { echo "usage: tailscale-mode.sh write FILE" >&2; exit 64; }
        json="$(detect)"
        mkdir -p "$(dirname -- "$out")" 2>/dev/null
        if printf '%s\n' "$json" > "${out}.tmp.$$" 2>/dev/null && mv -f "${out}.tmp.$$" "$out" 2>/dev/null; then :
        else rm -f "${out}.tmp.$$" 2>/dev/null; echo "tailscale-mode: could not write $out" >&2; fi
        printf '%s\n' "$json"
        ;;
    *) echo "usage: tailscale-mode.sh check | write FILE" >&2; exit 64 ;;
esac
exit 0
