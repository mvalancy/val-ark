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
# Decision, in order:
#   1. `tailscale status --json` answers with BackendState "Running": its "TUN"
#      decides. false = userspace. true = kernel, unless a second tailscaled PROVEN
#      to share our network namespace (step 2's ns/net or net/dev check, never the
#      cgroup guess) has --tun=userspace-networking (a host-network container).
#      A BackendState other than Running = not connected = absent.
#   2. No answer from the CLI: every tailscaled in /proc (be-child helpers skipped)
#      is classified:
#        - another network namespace (a container with its own network), so its
#          127.0.0.1 isn't ours: skipped. Proven by /proc/<pid>/ns/net differing
#          from /proc/self/ns/net (both readable), else by the inode of
#          /proc/<pid>/net/dev differing from /proc/self/net/dev (world-readable,
#          one per network namespace: works for root's tailscaled seen by a
#          non-root server);
#        - neither readable and /proc/<pid>/cgroup names docker, containerd,
#          kubepods, libpod, lxc or machine.slice (systemd-nspawn), and isn't our
#          own cgroup: a container we can't check -> "unknown" with evidence (a
#          warning, never critical);
#        - otherwise a local daemon: --tun=userspace-networking in its argv, or no
#          tailscale0 / --tun=NAME interface in /sys/class/net (Linux) -> userspace;
#          the interface present -> kernel.
#      Any local userspace daemon wins; then kernel; then a container we couldn't
#      check (unknown); then nothing (absent).
#
# Output (one JSON object):
#   {"ts":"…","state":"absent|kernel|userspace|unknown","userspace":true|false,
#    "running":true|false,"evidence":["…",…]}
#
# Test seams (all optional):
#   VALARK_TAILSCALE_CMD     the tailscale CLI to query (a stub in tests);
#                            "none" = behave as if it isn't installed
#   VALARK_TAILSCALE_PROC    stands in for /proc (fixture: <pid>/cmdline, <pid>/ns/net
#                            symlink, <pid>/cgroup, self/ns/net, self/cgroup)
#   VALARK_TAILSCALE_SYSNET  stands in for /sys/class/net (fixture dir of iface names)
#
# Usage:
#   tailscale-mode.sh check          print the JSON
#   tailscale-mode.sh write FILE     write the JSON to FILE atomically (and print it)
###############################################################################
set -u

PROC="${VALARK_TAILSCALE_PROC:-/proc}"
SYSNET="${VALARK_TAILSCALE_SYSNET:-/sys/class/net}"
CONTAINER_RE='docker|containerd|kubepods|libpod|lxc|machine\.slice'

ts_cli() {
    local c="${VALARK_TAILSCALE_CMD:-}"
    if [ "$c" = "none" ]; then return 1; fi
    if [ -n "$c" ]; then [ -x "$c" ] && { printf '%s' "$c"; return 0; }; return 1; fi
    c="$(command -v tailscale 2>/dev/null)" || return 1
    [ -n "$c" ] && printf '%s' "$c"
}

# run with a time limit when `timeout` exists (it doesn't on stock macOS).
with_timeout() {  # SECS CMD...
    local s="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi
}

# The --tun value from an argv (one arg per line); empty when not given.
tun_arg() {
    awk '
        want { print; exit }
        /^--?tun=/ { sub(/^--?tun=/, ""); print; exit }
        /^--?tun$/ { want = 1 }
    '
}

# Can we look at interfaces? Linux sysfs, or a test fixture.
sysnet_ok() {
    [ -d "$SYSNET" ] || return 1
    [ -n "${VALARK_TAILSCALE_SYSNET:-}" ] && return 0
    [ "$(uname -s 2>/dev/null)" = Linux ]
}

EVIDENCE=()
LOCAL_USER=0; LOCAL_KERNEL=0; LOCAL_SEEN=0; CONTAINER_SEEN=0
CONFIRMED_USER=0; CONFIRMED_EVIDENCE=()   # --tun=userspace-networking in a netns proven to be ours

# Classify every tailscaled in $PROC (see the header). Reads cmdline files directly,
# so no `pgrep -f` pattern can match its own argv (gotchas.md, tailscale-ssh).
scan_daemons() {
    local f d pid a0 args tun ifname ns_self ns_pid ino_self ino_pid cg_self cg_pid same e
    [ -d "$PROC" ] || return 0
    ns_self="$(readlink "$PROC/self/ns/net" 2>/dev/null)" || ns_self=""
    # /proc/<pid>/net/dev is world-readable and its inode differs per network
    # namespace, so it still works when ns/net isn't readable (root's tailscaled
    # seen by a non-root server).
    ino_self="$(stat -L -c %i "$PROC/self/net/dev" 2>/dev/null)" || ino_self=""
    cg_self="$(cat "$PROC/self/cgroup" 2>/dev/null)" || cg_self=""
    for f in "$PROC"/[0-9]*/cmdline; do
        [ -r "$f" ] || continue
        # argv[0] with a bash builtin (no fork per process); only a match is parsed.
        a0=""; IFS= read -r -d '' a0 < "$f" 2>/dev/null
        case "${a0##*/}" in tailscaled) ;; *) continue ;; esac
        args="$(tr '\0' '\n' < "$f" 2>/dev/null)" || continue
        printf '%s\n' "$args" | sed -n 2p | grep -qx 'be-child' && continue
        d="${f%/cmdline}"; pid="${d##*/}"

        # same: 1 = our network namespace (proven), 0 = another one, "" = can't tell
        same=""
        ns_pid="$(readlink "$d/ns/net" 2>/dev/null)" || ns_pid=""
        if [ -n "$ns_self" ] && [ -n "$ns_pid" ]; then
            [ "$ns_pid" = "$ns_self" ] && same=1 || same=0
        else
            ino_pid="$(stat -L -c %i "$d/net/dev" 2>/dev/null)" || ino_pid=""
            if [ -n "$ino_self" ] && [ -n "$ino_pid" ]; then
                [ "$ino_pid" = "$ino_self" ] && same=1 || same=0
            fi
        fi
        [ "$same" = 0 ] && continue                          # its own network: not our 127.0.0.1
        if [ -z "$same" ]; then
            cg_pid="$(cat "$d/cgroup" 2>/dev/null)" || cg_pid=""
            if printf '%s' "$cg_pid" | grep -qE "$CONTAINER_RE" && [ "$cg_pid" != "$cg_self" ]; then
                CONTAINER_SEEN=1; continue
            fi
        fi

        LOCAL_SEEN=1
        tun="$(printf '%s\n' "$args" | tun_arg)"
        if [ "$tun" = "userspace-networking" ]; then
            e="tailscaled (pid ${pid}) was started with --tun=userspace-networking"
            LOCAL_USER=1; EVIDENCE+=("$e")
            [ "$same" = 1 ] && { CONFIRMED_USER=1; CONFIRMED_EVIDENCE+=("$e"); }
            continue
        fi
        ifname="${tun:-tailscale0}"
        if sysnet_ok; then
            case "$ifname" in */*|.|..) ifname="tailscale0" ;; esac
            if [ -e "$SYSNET/$ifname" ]; then LOCAL_KERNEL=1
            else LOCAL_USER=1; EVIDENCE+=("tailscaled (pid ${pid}) is running but there is no ${ifname} interface"); fi
        fi
    done
    return 0
}

detect() {
    local running=false state="" cli st="" tunflag="" backend=""
    if cli="$(ts_cli)"; then
        # A read-only query; the time limit keeps a wedged daemon from stalling the loop.
        st="$(with_timeout 8 "$cli" status --json 2>/dev/null)" || st=""
        if [ -n "$st" ]; then
            backend="$(printf '%s' "$st" | grep -oE '"BackendState"[[:space:]]*:[[:space:]]*"[A-Za-z]*"' | head -1 | sed -E 's/.*"([A-Za-z]*)"$/\1/')"
            if printf '%s' "$st" | grep -qE '"TUN"[[:space:]]*:[[:space:]]*false'; then tunflag=false
            elif printf '%s' "$st" | grep -qE '"TUN"[[:space:]]*:[[:space:]]*true'; then tunflag=true
            fi
        fi
    fi

    if [ "$backend" = Running ]; then
        running=true
        if [ "$tunflag" = true ]; then
            # The CLI's daemon has a TUN, but a second, userspace tailscaled proven to
            # share our network (e.g. a container with network_mode: host) still
            # proxies tailnet peers to our 127.0.0.1.
            scan_daemons
            if [ "$CONFIRMED_USER" = 1 ]; then state=userspace; EVIDENCE=("${CONFIRMED_EVIDENCE[@]}")
            else state=kernel; EVIDENCE=()
            fi
        elif [ "$tunflag" = false ]; then state=userspace; EVIDENCE+=("tailscale status reports no TUN interface")
        fi
    elif [ -n "$backend" ]; then
        state=absent       # the daemon answered, but it isn't connected to a tailnet
    fi

    if [ -z "$state" ]; then
        scan_daemons
        [ "$LOCAL_SEEN" = 1 ] && running=true
        if [ "$LOCAL_USER" = 1 ]; then state=userspace
        elif [ "$LOCAL_KERNEL" = 1 ]; then state=kernel
        elif [ "$LOCAL_SEEN" = 1 ]; then state=unknown
        elif [ "$CONTAINER_SEEN" = 1 ]; then
            state=unknown
            EVIDENCE+=("a tailscaled runs in a container whose network could not be checked")
        elif [ "$running" = true ]; then state=unknown
        else state=absent
        fi
    fi

    local ev="" e first=1
    for e in "${EVIDENCE[@]+"${EVIDENCE[@]}"}"; do
        e=${e//[[:cntrl:]]/}; e=${e//\\/\\\\}; e=${e//\"/\\\"}
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
