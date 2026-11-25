#!/bin/bash
###############################################################################
# Test: link DHCP + DNS for a direct-connect laptop (issue #148).
#
# scripts/lib/link-dhcp.sh must serve DHCP+DNS on ONE wired interface only when
# no other DHCP server answers (two empty probes, CONFIRM_SECS apart), never
# serve when one does, and stop -- dnsmasq killed AND its address removed -- on
# every other outcome: a server appears, link down, probe failure, bad config,
# ambiguous interface, no root, no dnsmasq, knob off, watcher exit / STOP.
# Fully offline: the DHCP probe, dnsmasq, ip, sudo, id and /sys/class/net are
# stubs, so nothing touches this machine's networking. Also safe when run as
# root (the privilege check goes through a stub `id`).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LD="$ROOT/scripts/lib/link-dhcp.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$1"; then pass; else fail "$2"; fi; }

T="$(mktemp -d)"
RUN="$T/run"
killall_ours() {
    local f p
    for f in "$RUN/watch.pid" "$RUN/dnsmasq.pid"; do
        p=$(cat "$f" 2>/dev/null) && [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    for f in $(grep -lzF -- "$T/" /proc/[0-9]*/cmdline 2>/dev/null); do
        p=${f#/proc/}; p=${p%/cmdline}; [ "$p" != "$$" ] && kill "$p" 2>/dev/null
    done
}
trap 'killall_ours; sleep 0.3; rm -rf "$T"' EXIT
NET="10.254.77"; ALT="192.168.77"   # module default /24 prefix; an alternative private one
SELF_IP="$NET.1"   # the module's default link address

mkdir -p "$T/bin" "$T/sys/eth0/device" "$T/sys/wlan0/device" "$T/sys/wlan0/wireless" "$T/state" "$RUN"
echo 1 > "$T/sys/eth0/carrier"; echo 1 > "$T/sys/wlan0/carrier"; echo 1 > "$T/sys/eth0/carrier_changes"

# Probe stub, behaviour from $T/probe-mode: none = silence; server = a router
# answers; self = a second Ark answers from OUR default address (must still count:
# own offers are dropped by MAC/pkttype inside dhcp_probe.py, not by IP); fail.
cat > "$T/bin/probe" <<STUB
#!/bin/bash
echo "\$*" >> "$T/probe.calls"
case "\$(cat "$T/probe-mode")" in
  none)   exit 0 ;;
  server) echo 192.0.2.1; exit 0 ;;
  self)   echo $SELF_IP; exit 0 ;;
  fail)   exit 2 ;;
esac
STUB
# dnsmasq stub: records argv; then like the daemon: a background process whose
# argv carries the same args (incl. --pid-file / --conf-file), pid written, exit 0.
# $T/dnsmasq-mode: ok | nopid (exits 0, never comes up) | fail (exit 1).
cat > "$T/bin/dnsmasq" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$T/dnsmasq.args"; echo run >> "$T/dnsmasq.runs"
case "\$(cat "$T/dnsmasq-mode" 2>/dev/null)" in nopid) exit 0 ;; fail) exit 1 ;; esac
pf=""; for a in "\$@"; do case "\$a" in --pid-file=*) pf="\${a#--pid-file=}" ;; esac; done
bash -c 'while :; do sleep 0.2; done' dnsmasq-stub "\$@" >/dev/null 2>&1 &
echo \$! > "\$pf"
exit 0
STUB
# ip stub with state: $T/addrs holds "dev ip/24" lines; $T/routes is `route show match` output.
cat > "$T/bin/ip" <<STUB
#!/bin/bash
echo "\$*" >> "$T/ip.calls"
A="$T/addrs"; touch "\$A"
case "\$*" in
  "-4 addr show dev "*) d="\${!#}"; awk -v d="\$d" '\$1==d{print "    inet "\$2" scope global "d}' "\$A" ;;
  "-4 -o addr show")    awk '{print NR": "\$1"    inet "\$2" scope global "\$1}' "\$A" ;;
  "addr add "*)         echo "\$5 \$3" >> "\$A" ;;
  "addr del "*)         grep -vxF "\$5 \$3" "\$A" > "\$A.n"; mv "\$A.n" "\$A" ;;
  "-4 route show match "*) cat "$T/routes" 2>/dev/null ;;
esac
exit 0
STUB
cat > "$T/bin/sudo-ok" <<'STUB'
#!/bin/bash
[ "$1" = -n ] && shift
exec "$@"
STUB
printf '#!/bin/bash\nexit 1\n' > "$T/bin/sudo-no"
cat > "$T/bin/id" <<STUB
#!/bin/bash
case "\$1" in
  -u) [ -f "$T/as-root" ] && echo 0 || echo 1000 ;;
  dnsmasq) [ -f "$T/has-dnsmasq-user" ] ;;
  *) exec /usr/bin/id "\$@" ;;
esac
STUB
chmod +x "$T"/bin/*

export VAL_ARK_CONFIG="$T/env.conf" VAL_ARK_DATA="$T/disk" FORCE_COLOR=0
mkdir -p "$VAL_ARK_DATA"
# conf [enabled] [iface] [dnsmasq] [sudo] — the .env the module reads. Extra lines via $EXTRA.
conf() {
    {
        echo "VALARK_STATE_DIR=$T/state"
        [ "${1:-1}" = none ] || echo "VALARK_LINK_DHCP=${1:-1}"
        echo "VALARK_LINK_DHCP_IFACE=${2-eth0}"
        echo "VALARK_LINK_DHCP_PROBE_CMD=$T/bin/probe"
        echo "VALARK_LINK_DHCP_DNSMASQ=${3:-$T/bin/dnsmasq}"
        echo "VALARK_LINK_DHCP_IP=$T/bin/ip"
        echo "VALARK_LINK_DHCP_SUDO=${4:-$T/bin/sudo-ok}"
        echo "VALARK_LINK_DHCP_ID=$T/bin/id"
        echo "VALARK_LINK_DHCP_SYSFS=$T/sys"
        echo "VALARK_LINK_DHCP_RUN=$RUN"
        echo "VALARK_LINK_DHCP_NAMES=ark-test"
        echo "VALARK_LINK_DHCP_WATCH_SECS=0.2"
        echo "VALARK_LINK_DHCP_RECHECK_SECS=${RECHECK:-3600}"
        echo "VALARK_LINK_DHCP_CONFIRM_SECS=${CONFIRM:-0}"
        echo "VALARK_LINK_DHCP_EARLY_SECS=${EARLY:-3600}"
        echo "VALARK_LINK_DHCP_LOCK_WAIT=1"
        [ -n "${EXTRA:-}" ] && printf '%s\n' "$EXTRA"
    } > "$VAL_ARK_CONFIG"
}
run() { bash "$LD" "$@" > "$T/out" 2>&1; }
mode() { sed -n 's/.*"mode":"\([a-z]*\)".*/\1/p' "$T/state/link-dhcp.json" 2>/dev/null; }
runs() { [ -f "$T/dnsmasq.runs" ] && wc -l < "$T/dnsmasq.runs" | tr -d ' ' || echo 0; }
dpid() { cat "$RUN/dnsmasq.pid" 2>/dev/null; }
stubpid() { local f p; for f in $(grep -lzF -- "--pid-file=$RUN/dnsmasq.pid" /proc/[0-9]*/cmdline 2>/dev/null); do p=${f#/proc/}; echo "${p%/cmdline}"; done | head -1; }
alive() { [ -n "$(stubpid)" ]; }
has_addr() { grep -qxF "${1:-eth0} $SELF_IP/24" "$T/addrs" 2>/dev/null; }
waitfor() { local i; for i in $(seq 1 "${2:-50}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
reset() {
    bash "$LD" stop >/dev/null 2>&1; killall_ours; sleep 0.3
    rm -f "$T"/dnsmasq.args "$T"/dnsmasq.runs "$T"/ip.calls "$T"/probe.calls "$T"/addrs "$T"/routes \
          "$T"/dnsmasq-mode "$T"/as-root "$T"/has-dnsmasq-user "$T/state/STOP" "$T/state/link-dhcp.json"
    rm -rf "$RUN"; mkdir -p "$RUN"
    echo 1 > "$T/sys/eth0/carrier"; rm -rf "$T/sys/eth1"
    unset RECHECK CONFIRM EARLY EXTRA
}
serve_now() { conf 1 "$@"; echo none > "$T/probe-mode"; run check; run check; }   # two empty probes
arg() { grep -qx -- "$1" "$T/dnsmasq.args" 2>/dev/null; }

# --- 1. off by default: never probes, never serves -----------------------------
reset; conf 0; echo none > "$T/probe-mode"; run check
check '[ "$(mode)" = off ]' "VALARK_LINK_DHCP=0 must report mode off (got $(mode))"
check '[ "$(runs)" = 0 ] && [ ! -s "$T/probe.calls" ]' "disabled must never probe or start dnsmasq"

# --- 2. a DHCP server answers -> NEVER serves ----------------------------------
reset; conf 1; echo server > "$T/probe-mode"; run check; run check; run check
check '[ "$(mode)" = present ]' "server present must report mode present (got $(mode))"
check '[ "$(runs)" = 0 ] && ! has_addr' "server present must NEVER start dnsmasq or add an address"
check 'grep -q "192.0.2.1" "$T/out"' "log must name the server that answered"
check 'grep -q "^eth0 " "$T/probe.calls"' "probe must run on the configured interface"

# --- 3. no server: needs TWO empty probes CONFIRM_SECS apart (finding 3) -------
reset; CONFIRM=0 conf 1; echo none > "$T/probe-mode"; run check
check '[ "$(mode)" = probing ] && [ "$(runs)" = 0 ]' "first empty probe must only start confirming (got $(mode))"
run check
check '[ "$(mode)" = serving ] && [ "$(runs)" = 1 ] && alive' "second empty probe must serve (got $(mode)): $(cat "$T/out")"
reset; CONFIRM=30 conf 1; echo none > "$T/probe-mode"; run check; run check
check '[ "$(mode)" = probing ] && [ "$(runs)" = 0 ]' "two probes inside CONFIRM_SECS must not serve yet"
reset; conf 1; echo none > "$T/probe-mode"; run check
echo 2 > "$T/sys/eth0/carrier_changes"; run check
check '[ "$(mode)" = probing ] && [ "$(runs)" = 0 ]' "a link change between probes must restart confirmation"
run check; check '[ "$(mode)" = serving ]' "confirmation on the new epoch must then serve"
reset; conf 1; echo none > "$T/probe-mode"; run check; echo server > "$T/probe-mode"; run check
echo none > "$T/probe-mode"; run check
check '[ "$(mode)" = probing ] && [ "$(runs)" = 0 ]' "a server answering mid-confirmation must reset it"
echo 1 > "$T/sys/eth0/carrier_changes"

# --- 4. serving binds ONE interface, sane options --------------------------------
reset; serve_now
check '[ "$(grep -c "^--interface=" "$T/dnsmasq.args")" = 1 ] && arg --interface=eth0' "exactly ONE --interface=eth0"
check 'arg --bind-interfaces && arg --except-interface=lo && arg --listen-address=$SELF_IP' "bind-interfaces, no lo, link address only"
check 'arg --conf-file=/dev/null && arg --dhcp-option=3' "no system config, no router option"
check 'arg "--dhcp-range=$NET.10,$NET.60,255.255.255.0,5m"' "first minutes of serving use the short early lease"
check 'arg "--host-record=valark,valark.home.arpa,$SELF_IP" && arg "--host-record=ark-test,ark-test.home.arpa,$SELF_IP"' "DNS must resolve the box names to the link address"
check 'arg --no-resolv && arg --local=/home.arpa/ && arg --dhcp-option=option:domain-search,home.arpa' "DNS local mode: local names only, REFUSE the rest"
check 'arg --user=nobody' "no dnsmasq user -> --user=nobody"
check '! grep -q wlan0 "$T/dnsmasq.args"' "dnsmasq must never mention another interface"
check 'has_addr eth0' "must assign itself $SELF_IP/24 on eth0"
check 'grep -qx -- "--pid-file=$RUN/dnsmasq.pid" "$T/dnsmasq.args" && grep -qx -- "--dhcp-leasefile=$RUN/leases" "$T/dnsmasq.args"' "pid/leases on the runtime dir (tmpfs), finding 4"
check '[ ! -e "$T/state/link-dhcp" ] && [ -f "$T/state/link-dhcp.json" ]' "only link-dhcp.json goes to state/"
run check
check '[ "$(mode)" = serving ] && [ "$(runs)" = 1 ]' "re-check while alone keeps serving without a restart"

# --- 5. a real server appears -> stops at once ----------------------------------
oldpid=$(stubpid); echo server > "$T/probe-mode"; run check
check '[ "$(mode)" = present ] && ! alive && ! has_addr' "server appearing must stop dnsmasq and remove the address"
check 'grep -q "stopped serving" "$T/out"' "stop must log a clear line"
# a second Ark answering from OUR address still counts (finding 5)
reset; conf 1; echo self > "$T/probe-mode"; run check; run check
check '[ "$(mode)" = present ] && [ "$(runs)" = 0 ]' "a server at $SELF_IP (another Ark) must count as present"
reset; serve_now; echo self > "$T/probe-mode"; run check
check '! alive && [ "$(mode)" = present ]' "while serving, an answer from $SELF_IP must stop us (no shell-side IP skip)"

# --- 6. probe can't run -> fail closed ----------------------------------------------
reset; conf 1; echo fail > "$T/probe-mode"; run check; run check
check '[ "$(runs)" = 0 ] && [ "$(mode)" = unavailable ]' "failed probe must never serve"
reset; serve_now; echo fail > "$T/probe-mode"; run check
check '! alive && ! has_addr' "failed probe while serving must stop (fail closed)"

# --- 7. link down while serving -> stops ----------------------------------------
reset; serve_now; echo 0 > "$T/sys/eth0/carrier"; run check
check '! alive && ! has_addr && [ "$(mode)" = idle ]' "link down must stop serving"

# --- 8. no root -> clear line, no serving; meaningful even when run as root ----------
reset; conf 1 eth0 "" "$T/bin/sudo-no"; echo none > "$T/probe-mode"; run check; run check
check '[ "$(runs)" = 0 ] && grep -q "needs root" "$T/out"' "without root: no dnsmasq + 'needs root' line"
reset; touch "$T/as-root"; serve_now eth0 "" "$T/bin/sudo-no"
check 'alive' "uid 0 (stubbed) must serve without sudo"

# --- 9. no dnsmasq -> clear line; dnsmasq user present -> no --user ---------------------
reset; conf 1 eth0 "$T/bin/no-such-dnsmasq"; echo none > "$T/probe-mode"; run check; run check
check 'grep -q "dnsmasq not found" "$T/out" && ! has_addr' "missing dnsmasq must log it and touch nothing"
reset; touch "$T/has-dnsmasq-user"; serve_now
check '! arg --user=nobody' "an existing dnsmasq user must be kept"

# --- 10. interface autodetect --------------------------------------------------------
reset; conf 1 ""; echo server > "$T/probe-mode"; run check
check 'grep -q "^eth0 " "$T/probe.calls"' "autodetect must pick the single wired iface (not wlan0)"
mkdir -p "$T/sys/eth1/device"; echo 1 > "$T/sys/eth1/carrier"; rm -f "$T/probe.calls"; run check
check '[ ! -s "$T/probe.calls" ] && grep -q "several wired interfaces" "$T/out"' "two wired ifaces + no IFACE must refuse"

# --- 11. finding 1: every non-serve outcome stops a running server -------------------------
reset; serve_now ""
mkdir -p "$T/sys/eth1/device"; echo 1 > "$T/sys/eth1/carrier"; run ensure
check '! alive && ! has_addr && [ "$(mode)" = error ]' "iface turning ambiguous (USB NIC) while serving must stop dnsmasq + address"
check '[ -z "$(cat "$RUN/watch.pid" 2>/dev/null)" ]' "and no watcher left behind"
reset; serve_now; conf 1 eth0 "" "$T/bin/sudo-no"; run check
check '! alive && ! has_addr' "losing root while serving must stop (best effort) rather than leave it"
reset; serve_now; conf 1 eth0 "$T/bin/no-such-dnsmasq"; run check
check '! alive && ! has_addr' "dnsmasq binary vanishing while serving must stop the running one"
reset; serve_now; EXTRA="VALARK_LINK_DHCP_LEASE=1d" conf 1; run check
check '! alive && ! has_addr && [ "$(mode)" = error ]' "bad config while serving must stop"

# --- 12. finding 4: lock not obtained -> no action; pidfile lost -> still found -----------
reset; conf 1; echo none > "$T/probe-mode"; run check
( exec 9>>"$RUN/check.lock"; flock 9; sleep 3 ) & holder=$!
sleep 0.3; run check
check '[ "$(runs)" = 0 ] && grep -q "skipping" "$T/out"' "busy check lock must skip without acting"
kill $holder 2>/dev/null; wait $holder 2>/dev/null
reset; serve_now; rm -f "$RUN/dnsmasq.pid"; echo server > "$T/probe-mode"; run check
check '! alive' "lost pidfile: our dnsmasq must be found by cmdline and stopped"
reset; serve_now; rm -rf "$T/state"; echo server > "$T/probe-mode"; run check
check '[ ! -e "$T/state" ] && ! alive' "no state/ dir: must not create it (#58) and must still act"
mkdir -p "$T/state"

# --- 13. finding 8: a stale address is removed even without a live dnsmasq ----------------
reset; conf 1; echo "eth0 $SELF_IP/24" > "$T/addrs"; echo server > "$T/probe-mode"; run check
check '! has_addr' "stale $SELF_IP/24 must be removed on a non-serve outcome"

# --- 14. finding 10: config validation ------------------------------------------------------
for bad in "VALARK_LINK_DHCP_NET=8.8.8" "VALARK_LINK_DHCP_NET=300.1.1" "VALARK_LINK_DHCP_NET=10.0" \
           "VALARK_LINK_DHCP_NET=172.32.0" "VALARK_LINK_DHCP_RANGE_START=x" "VALARK_LINK_DHCP_RANGE_END=255" \
           "VALARK_LINK_DHCP_LEASE=1d" "VALARK_LINK_DHCP_DNS=all"; do
    reset; EXTRA="$bad" conf 1; echo none > "$T/probe-mode"; run check; run check
    check '[ "$(mode)" = error ] && [ "$(runs)" = 0 ]' "invalid $bad must refuse (got $(mode))"
done
reset; EXTRA="VALARK_LINK_DHCP_NET=$ALT" conf 1; echo none > "$T/probe-mode"; run check; run check
check '[ "$(mode)" = serving ] && arg "--listen-address=$ALT.1"' "a valid private NET must be used"
reset; conf 1; echo "10.0.0.0/8 dev wlan0 scope link" > "$T/routes"; echo none > "$T/probe-mode"; run check; run check
check '[ "$(mode)" = error ] && [ "$(runs)" = 0 ] && grep -q "already in use" "$T/out"' "NET routed via another iface must refuse"
reset; conf 1; echo "default via 192.0.2.254 dev wlan0" > "$T/routes"; serve_now
check 'alive' "a plain default route via Wi-Fi must not block serving"

# --- 15. finding 11: names are sanitised, never globbed -----------------------------------------
reset; mkdir -p "$T/cwd"; touch "$T/cwd/GLOBBED"
EXTRA='VALARK_LINK_DHCP_NAMES="* a,6.6.6.6 good-name"' conf 1; echo none > "$T/probe-mode"
( cd "$T/cwd" && bash "$LD" check >/dev/null 2>&1 && bash "$LD" check > "$T/out" 2>&1 )
check 'arg "--host-record=good-name,good-name.home.arpa,$SELF_IP"' "valid extra name kept"
check '! grep -q "6.6.6.6\|GLOBBED\|^--host-record=\*" "$T/dnsmasq.args"' "globs and comma injections must be dropped"

# --- 16. finding 12/13: re-add a removed address; failed start cleans up --------------------------
reset; serve_now; : > "$T/addrs"; run check
check 'has_addr && alive && [ "$(mode)" = serving ] && grep -q "re-added" "$T/out"' "serving must re-add an address something removed"
reset; echo nopid > "$T/dnsmasq-mode"; serve_now
check '! has_addr && [ "$(mode)" = error ]' "dnsmasq that never comes up must remove the address"
reset; echo fail > "$T/dnsmasq-mode"; serve_now
check '! has_addr && [ "$(mode)" = error ]' "dnsmasq that fails must remove the address"

# --- 17. finding 3: early lease switches to the normal lease once settled ------------------------
reset; EARLY=0 conf 1; echo none > "$T/probe-mode"; run check; run check; run check
check 'arg "--dhcp-range=$NET.10,$NET.60,255.255.255.0,1h" && [ "$(runs)" = 2 ] && alive' "after EARLY_SECS dnsmasq restarts with the normal lease"

# --- 18. finding 14: DNS modes ---------------------------------------------------------------
reset; EXTRA="VALARK_LINK_DHCP_DNS=off" serve_now
check 'arg --port=0 && arg --dhcp-option=6 && ! grep -q host-record "$T/dnsmasq.args"' "DNS off: no DNS server, none advertised"
reset; EXTRA="VALARK_LINK_DHCP_DNS=forward" serve_now
check '! arg --no-resolv && arg --local=/home.arpa/' "DNS forward: local names + upstream for the rest"

# --- 19. watcher: re-check, carrier_changes, STOP, TERM, knob removal (findings 2, 7, 9) ---------
reset; RECHECK=1 conf 1; echo none > "$T/probe-mode"
bash "$LD" watch > "$T/watch.out" 2>&1 & wpid=$!
check 'waitfor alive 60' "watcher must start serving when alone"
echo server > "$T/probe-mode"
check 'waitfor "! alive && [ \"\$(mode)\" = present ]" 40' "watcher must stop serving once a real server answers"
kill $wpid 2>/dev/null; wait $wpid 2>/dev/null

reset; conf 1; echo none > "$T/probe-mode"       # RECHECK 3600: only a link change triggers
bash "$LD" watch > "$T/watch.out" 2>&1 & wpid=$!
waitfor alive 60
echo server > "$T/probe-mode"; echo 7 > "$T/sys/eth0/carrier_changes"   # flap faster than the poll
check 'waitfor "! alive" 40' "a carrier_changes bump (no visible carrier change) must re-probe and stop"
check 'grep -q "link change" "$T/watch.out"' "watcher must log the link change"
echo 1 > "$T/sys/eth0/carrier_changes"; kill $wpid 2>/dev/null; wait $wpid 2>/dev/null

reset; conf 1; echo none > "$T/probe-mode"
bash "$LD" watch > "$T/watch.out" 2>&1 & wpid=$!
waitfor alive 60; touch "$T/state/STOP"
check 'waitfor "! kill -0 $wpid 2>/dev/null" 30 && ! alive && ! has_addr' "STOP flag must stop dnsmasq before the watcher exits"
wait $wpid 2>/dev/null; rm -f "$T/state/STOP"

reset; conf 1; echo none > "$T/probe-mode"
bash "$LD" watch > "$T/watch.out" 2>&1 & wpid=$!
waitfor alive 60; kill -TERM $wpid
check 'waitfor "! kill -0 $wpid 2>/dev/null" 30 && ! alive && ! has_addr' "SIGTERM to the watcher must stop dnsmasq"
wait $wpid 2>/dev/null

reset; RECHECK=1 conf 1; echo none > "$T/probe-mode"
bash "$LD" watch > "$T/watch.out" 2>&1 & wpid=$!
waitfor alive 60; RECHECK=1 conf none        # the VALARK_LINK_DHCP line REMOVED from .env
check 'waitfor "! kill -0 $wpid 2>/dev/null" 40 && ! alive' "removing the knob line from .env must disable (no stale exported var)"
wait $wpid 2>/dev/null

# --- 20. ensure: one watcher; none without root; knob off stops both; no lock fds (16) -------------
reset; conf 1 eth0 "" "$T/bin/sudo-no"; echo none > "$T/probe-mode"; run ensure
check '[ -z "$(cat "$RUN/watch.pid" 2>/dev/null)" ]' "ensure without root must not park a watcher"
reset; conf 1; echo none > "$T/probe-mode"
: > "$T/loop.lock"
( exec 8>"$T/loop.lock"; flock 8; timeout 30 bash "$LD" ensure > "$T/out" 2>&1 )
check 'waitfor "[ -s \"$RUN/watch.pid\" ]" 30' "ensure must start the watcher"
w1=$(cat "$RUN/watch.pid" 2>/dev/null)
check 'waitfor alive 80' "the watcher's second probe must serve"
run ensure; sleep 0.3
check '[ "$(cat "$RUN/watch.pid" 2>/dev/null)" = "$w1" ]' "a second ensure must not start a second watcher"
lockfds() { local p; for p in "$@"; do ls -l "/proc/$p/fd" 2>/dev/null; done | grep -E "loop\.lock|check\.lock" ; }
check '[ -n "$w1" ] && [ -z "$(lockfds "$w1" "$(stubpid)")" ]' "watcher and dnsmasq must hold no loop.lock/check.lock fd: $(lockfds "$w1" "$(stubpid)")"
check '! ls -l "/proc/$(stubpid)/fd" 2>/dev/null | grep -q "watch\.lock"' "dnsmasq must not hold the watcher lock"
( exec 9>>"$T/loop.lock"; flock -w 5 9 ) && pass || fail "loop.lock must be free after ensure returns (no inherited fd)"
conf 0; run ensure
check 'waitfor "[ ! -d /proc/$w1 ]" 50 && ! alive && ! has_addr' "ensure with the knob off must stop the watcher and dnsmasq"

# --- 21. wiring, docs, probe hardening --------------------------------------------------------
check 'grep -q "lib/link-dhcp.sh\"" "$ROOT/scripts/loop.sh" && grep -q "bash \"\$sh\" ensure" "$ROOT/scripts/loop.sh" && grep -qE "^ *step \"2f\\..*ensure_link_dhcp" "$ROOT/scripts/loop.sh"' "loop.sh must run link-dhcp.sh ensure each cycle (step 2f)"
check 'grep -q "/run/valark-link-dhcp}/dnsmasq.pid" "$ROOT/scripts/loop.sh"' "loop fast path must look at the /run runtime dir"
check 'grep -q "^# VALARK_LINK_DHCP=1" "$ROOT/.env.example"' ".env.example must document VALARK_LINK_DHCP"
check 'grep -q "python3 -I " "$LD"' "probe must run as python3 -I"

# --- 22. the real probe's packet code (offline: fake sockets, no network) -------------------------
cat > "$T/probe_unit.py" <<'PY'
import importlib.util, struct, sys
spec = importlib.util.spec_from_file_location("dp", sys.argv[1]); dp = importlib.util.module_from_spec(spec); spec.loader.exec_module(dp)
mac = bytes.fromhex("020000000001"); other = bytes.fromhex("020000000002"); xid = 0x12345678
d = dp.discover(xid, mac)
assert d[0] == 1 and struct.unpack("!I", d[4:8])[0] == xid and d[236:240] == dp.MAGIC, "bad DISCOVER header"
assert bytes([53, 1, 1]) in d[240:] and bytes([53, 1, 3]) not in d, "DISCOVER only, never REQUEST"
def frame(msgtype, sid, sport=67, dport=68, x=xid, ihl=5, frag=0, magic=True, overload=None):
    b = bytearray(d); b[0] = 2; b[4:8] = struct.pack("!I", x)
    if not magic:
        b = bytes(b[:236])
    else:
        opts = b""
        if msgtype is not None:
            opts += bytes([53, 1, msgtype])
        if sid:
            opts += bytes([54, 4]) + bytes(sid)
        if overload:
            fileopts = opts + b"\xff"; b[108:108 + len(fileopts)] = fileopts
            opts = bytes([52, 1, 1])
        b = bytes(b[:240]) + opts + b"\xff"
    udp = struct.pack("!HHHH", sport, dport, 8 + len(b), 0)
    hdr = bytes([0x40 | ihl, 0]) + struct.pack("!H", ihl * 4 + len(udp) + len(b)) + bytes(2) + struct.pack("!H", frag) + bytes([64, 17]) + bytes(2) + bytes([192, 0, 2, 9]) + bytes(4)
    hdr += bytes(max(0, ihl * 4 - 20))
    return hdr + udp + b
X = {xid}
assert dp.parse_offer(frame(2, [192, 0, 2, 1]), X) == "192.0.2.1", "OFFER server id"
assert dp.parse_offer(frame(2, None), X) == "192.0.2.9", "OFFER without option 54 -> source address"
assert dp.parse_offer(frame(5, [192, 0, 2, 1]), X) is None, "ACK is not an offer"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], x=1), X) is None, "other xid ignored"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], dport=67), X) is None, "non-client port ignored"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], dport=40000), X, (68, 40000)) == "192.0.2.1", "tx ephemeral port accepted (finding 6)"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], dport=41000), X, (68, 40000)) is None, "other ports still ignored"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], ihl=4), X) is None, "IHL < 20 dropped"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], ihl=6), X) == "192.0.2.1", "IP options (IHL 24) handled"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], frag=0x2000), X) is None, "MF fragment dropped"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], frag=0x0010), X) is None, "non-zero fragment offset dropped"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], overload=True), X) == "192.0.2.1", "option 52 overload (file field) parsed"
assert dp.parse_offer(frame(None, [192, 0, 2, 1]), X) == "192.0.2.1", "BOOTP reply w/o option 53 = server present"
assert dp.parse_offer(frame(None, None, magic=False), X) == "192.0.2.9", "plain BOOTP reply = server present"
assert not dp.accept_link(("eth0", 0x800, dp.PACKET_OUTGOING, 1, other), mac), "PACKET_OUTGOING dropped (own dnsmasq)"
assert not dp.accept_link(("eth0", 0x800, 0, 1, mac), mac), "our own NIC MAC dropped"
assert dp.accept_link(("eth0", 0x800, 1, 1, other), mac), "another host's broadcast accepted"
# run_probe: several DISCOVERs, fresh xid each; an answer to a LATER one is accepted
sent = []
def send(p): sent.append(p)
def recv(t):
    import time; time.sleep(min(t, 0.005))
    if len(sent) == 3:
        x = struct.unpack("!I", sent[2][4:8])[0]
        return frame(2, [192, 0, 2, 1], x=x), ("eth0", 0x800, 1, 1, other)
    return None
assert dp.run_probe(send, recv, mac, (68,), (0, 0.02, 0.04, 0.08), 0.05) == ["192.0.2.1"], "answer to 3rd DISCOVER"
assert len({struct.unpack("!I", p[4:8])[0] for p in sent}) == len(sent) == 3, "fresh xid per DISCOVER"
sent.clear()
def quiet(t):
    import time; time.sleep(min(t, 0.01)); return None
assert dp.run_probe(send, quiet, mac, (68,), (0, 0.02, 0.04, 0.08), 0.05) == [] and len(sent) == 4, "4 DISCOVERs then give up"
assert dp.SCHEDULE == (0, 2, 4, 8), "default backoff 0/2/4/8 s"
own = []
def ownrecv(t):
    import time; time.sleep(min(t, 0.01))
    if sent:
        x = struct.unpack("!I", sent[-1][4:8])[0]
        return frame(2, [10, 254, 77, 1], x=x), ("eth0", 0x800, dp.PACKET_OUTGOING, 1, mac)
sent.clear()
assert dp.run_probe(send, ownrecv, mac, (68,), (0, 0.02), 0.03) == [], "our own dnsmasq's OFFER never counts"
assert dp.main(["x"]) == 64 and dp.main(["x", "eth0", "-1"]) == 64, "usage"
assert dp.main(["x", "no-such-iface-xyz", "0.1"]) == 2, "missing iface -> 2 (unknown, callers fail closed)"
PY
python3 -I "$T/probe_unit.py" "$ROOT/scripts/lib/dhcp_probe.py" 2>"$T/pu.err" && pass || fail "dhcp_probe.py packet build/parse: $(tail -3 "$T/pu.err")"

echo "link-dhcp: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
