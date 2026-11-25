#!/bin/bash
###############################################################################
# Test: link DHCP + DNS for a direct-connect laptop (issue #148).
#
# scripts/lib/link-dhcp.sh must serve DHCP+DNS on ONE wired interface only when
# no other DHCP server answers, never serve when one does, and stop as soon as a
# real server appears (or the link drops, or the probe can't run). Fully offline:
# the DHCP probe, dnsmasq, ip, sudo and /sys/class/net are all stubs, so nothing
# touches this machine's networking.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LD="$ROOT/scripts/lib/link-dhcp.sh"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
cleanup() {
    local p; p=$(cat "$T/state/link-dhcp/dnsmasq.pid" 2>/dev/null) && [ -n "$p" ] && kill "$p" 2>/dev/null
    p=$(cat "$T/state/link-dhcp/watch.pid" 2>/dev/null) && [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT
SELF_IP="10.254.77.1"   # the module's default link address (NET.1)

mkdir -p "$T/bin" "$T/sys/eth0/device" "$T/sys/wlan0/device" "$T/sys/wlan0/wireless" "$T/state"
echo 1 > "$T/sys/eth0/carrier"; echo 1 > "$T/sys/wlan0/carrier"

# Probe stub: behaviour from $T/probe-mode. none = silence (but echoes our own
# address while our stub dnsmasq runs, like a real dnsmasq answering the probe);
# server = a real router answers; fail = probe can't run.
cat > "$T/bin/probe" <<STUB
#!/bin/bash
echo "\$*" >> "$T/probe.calls"
case "\$(cat "$T/probe-mode")" in
  none)   p=\$(cat "$T/state/link-dhcp/dnsmasq.pid" 2>/dev/null); [ -n "\$p" ] && [ -d /proc/\$p ] && echo "$SELF_IP"; exit 0 ;;
  server) [ -f "$T/state/link-dhcp/dnsmasq.pid" ] && echo "$SELF_IP"; echo 192.0.2.1; exit 0 ;;
  fail)   exit 2 ;;
esac
STUB
# dnsmasq stub: records argv, then behaves like the daemon: a background process
# carrying --pid-file=<path> in its argv, pid written to that file, parent exits 0.
cat > "$T/bin/dnsmasq" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$DNSMASQ_ARGS"; echo run >> "$DNSMASQ_RUNS"
pf=""; for a in "$@"; do case "$a" in --pid-file=*) pf="${a#--pid-file=}" ;; esac; done
bash -c 'while :; do sleep 0.2; done' "--pid-file=$pf" >/dev/null 2>&1 &
echo $! > "$pf"
exit 0
STUB
cat > "$T/bin/ip" <<'STUB'
#!/bin/bash
echo "$*" >> "$IP_CALLS"
exit 0
STUB
cat > "$T/bin/sudo-ok" <<'STUB'
#!/bin/bash
[ "$1" = -n ] && shift
exec "$@"
STUB
printf '#!/bin/bash\nexit 1\n' > "$T/bin/sudo-no"
chmod +x "$T"/bin/*

export VAL_ARK_CONFIG="$T/env.conf" VAL_ARK_DATA="$T/disk" VALARK_STATE_DIR="$T/state" FORCE_COLOR=0
export DNSMASQ_ARGS="$T/dnsmasq.args" DNSMASQ_RUNS="$T/dnsmasq.runs" IP_CALLS="$T/ip.calls"
mkdir -p "$VAL_ARK_DATA"
conf() {   # write the .env the module reads (it overrides the process env)
    cat > "$VAL_ARK_CONFIG" <<EOF
VALARK_STATE_DIR=$T/state
VALARK_LINK_DHCP=${1:-1}
VALARK_LINK_DHCP_IFACE=${2-eth0}
VALARK_LINK_DHCP_PROBE_CMD=$T/bin/probe
VALARK_LINK_DHCP_DNSMASQ=${3:-$T/bin/dnsmasq}
VALARK_LINK_DHCP_IP=$T/bin/ip
VALARK_LINK_DHCP_SUDO=${4:-$T/bin/sudo-ok}
VALARK_LINK_DHCP_SYSFS=$T/sys
VALARK_LINK_DHCP_NAMES=ark-test
VALARK_LINK_DHCP_WATCH_SECS=0.2
VALARK_LINK_DHCP_RECHECK_SECS=${RECHECK:-3600}
EOF
}
run() { bash "$LD" "$@" > "$T/out" 2>&1; }
mode() { sed -n 's/.*"mode":"\([a-z]*\)".*/\1/p' "$T/state/link-dhcp.json" 2>/dev/null; }
runs() { wc -l < "$DNSMASQ_RUNS" 2>/dev/null | tr -d ' ' || echo 0; }
dpid() { cat "$T/state/link-dhcp/dnsmasq.pid" 2>/dev/null; }
alive() { local p; p=$(dpid); [ -n "$p" ] && [ -d "/proc/$p" ]; }
reset() { bash "$LD" stop >/dev/null 2>&1; rm -f "$DNSMASQ_ARGS" "$DNSMASQ_RUNS" "$IP_CALLS" "$T/probe.calls"; : > "$DNSMASQ_RUNS"; }
: > "$DNSMASQ_RUNS"

# --- 1. off by default: never probes, never serves -----------------------------
conf 0; echo none > "$T/probe-mode"; run check
[ "$(mode)" = off ] && pass || fail "VALARK_LINK_DHCP=0 must report mode off (got $(mode))"
[ "$(runs)" = 0 ] && pass || fail "disabled must never start dnsmasq"
[ ! -s "$T/probe.calls" ] && pass || fail "disabled must not even probe"

# --- 2. a DHCP server answers -> NEVER serves ----------------------------------
reset; conf 1; echo server > "$T/probe-mode"; run check
[ "$(mode)" = present ] && pass || fail "server present must report mode present (got $(mode))"
[ "$(runs)" = 0 ] && pass || fail "server present must NEVER start dnsmasq"
! grep -q "addr add" "$IP_CALLS" 2>/dev/null && pass || fail "server present must not add a link address"
grep -q "192.0.2.1" "$T/out" && pass || fail "log must name the server that answered"
grep -q "^eth0 " "$T/probe.calls" && pass || fail "probe must run on the configured interface"
run check   # and a second cycle still doesn't
[ "$(runs)" = 0 ] && pass || fail "repeated checks with a server present must still never serve"

# --- 3. no server -> serves on THAT interface only -----------------------------
reset; conf 1; echo none > "$T/probe-mode"; run check
[ "$(mode)" = serving ] && pass || fail "no server must report mode serving (got $(mode)): $(cat "$T/out")"
[ "$(runs)" = 1 ] && pass || fail "no server must start dnsmasq exactly once (got $(runs))"
alive && pass || fail "dnsmasq (stub) must be running after serve"
[ "$(grep -c '^--interface=' "$DNSMASQ_ARGS")" = 1 ] && pass || fail "dnsmasq must get exactly ONE --interface"
grep -qx -- '--interface=eth0' "$DNSMASQ_ARGS" && pass || fail "dnsmasq must be bound to eth0"
grep -qx -- '--bind-interfaces' "$DNSMASQ_ARGS" && pass || fail "dnsmasq must use --bind-interfaces"
grep -qx -- '--except-interface=lo' "$DNSMASQ_ARGS" && pass || fail "dnsmasq must not listen on lo"
grep -qx -- "--listen-address=$SELF_IP" "$DNSMASQ_ARGS" && pass || fail "dnsmasq must listen only on the link address"
grep -qx -- '--conf-file=/dev/null' "$DNSMASQ_ARGS" && pass || fail "dnsmasq must ignore the system config"
grep -qx -- '--dhcp-option=3' "$DNSMASQ_ARGS" && pass || fail "no router option (laptop keeps its own default route)"
grep -q -- '^--dhcp-range=10\.254\.77\.' "$DNSMASQ_ARGS" && pass || fail "dhcp range must be on the link subnet"
grep -qx -- "--host-record=valark,$SELF_IP" "$DNSMASQ_ARGS" && pass || fail "DNS must resolve the box name to the link address"
grep -qx -- "--host-record=ark-test,$SELF_IP" "$DNSMASQ_ARGS" && pass || fail "extra VALARK_LINK_DHCP_NAMES must resolve too"
! grep -q 'wlan0' "$DNSMASQ_ARGS" && pass || fail "dnsmasq must never mention another interface"
grep -q "addr add $SELF_IP/24 dev eth0" "$IP_CALLS" && pass || fail "must assign itself $SELF_IP/24 on eth0"

# --- 4. re-check while alone: ignores its own answer, keeps serving ------------
run check
[ "$(mode)" = serving ] && pass || fail "re-check while alone must keep serving (got $(mode))"
[ "$(runs)" = 1 ] && pass || fail "re-check must not start a second dnsmasq"

# --- 5. a real server appears -> stops at once ----------------------------------
oldpid=$(dpid); echo server > "$T/probe-mode"; run check
[ "$(mode)" = present ] && pass || fail "server appearing must flip mode to present (got $(mode))"
sleep 0.5
[ ! -d "/proc/$oldpid" ] && pass || fail "dnsmasq must be stopped when a real server appears"
grep -q "addr del $SELF_IP/24 dev eth0" "$IP_CALLS" && pass || fail "stop must remove the link address"
grep -q "stopped serving" "$T/out" && pass || fail "stop must log a clear line"

# --- 6. probe can't run -> fail closed (never serves; stops if serving) ---------
reset; conf 1; echo fail > "$T/probe-mode"; run check
[ "$(runs)" = 0 ] && pass || fail "failed probe must never start dnsmasq"
[ "$(mode)" = unavailable ] && pass || fail "failed probe must report unavailable (got $(mode))"
echo none > "$T/probe-mode"; run check; alive && pass || fail "setup: serving"
echo fail > "$T/probe-mode"; run check
! alive && pass || fail "failed probe while serving must stop (fail closed)"

# --- 7. link down while serving -> stops ---------------------------------------
reset; conf 1; echo none > "$T/probe-mode"; run check; alive && pass || fail "setup: serving before link down"
echo 0 > "$T/sys/eth0/carrier"; run check
! alive && pass || fail "link down must stop serving"
[ "$(mode)" = idle ] && pass || fail "link down must report idle (got $(mode))"
echo 1 > "$T/sys/eth0/carrier"

# --- 8. not root and no passwordless sudo -> clear line, no serving -------------
reset; conf 1 eth0 "" "$T/bin/sudo-no"; echo none > "$T/probe-mode"; run check
[ "$(runs)" = 0 ] && pass || fail "without root must not start dnsmasq"
grep -q "needs root" "$T/out" && pass || fail "without root must log 'needs root' (got: $(cat "$T/out"))"

# --- 9. no dnsmasq -> clear line --------------------------------------------------
reset; conf 1 eth0 "$T/bin/no-such-dnsmasq"; echo none > "$T/probe-mode"; run check
grep -q "dnsmasq not found" "$T/out" && pass || fail "missing dnsmasq must log it (got: $(cat "$T/out"))"
! grep -q "addr add" "$IP_CALLS" 2>/dev/null && pass || fail "missing dnsmasq must not touch addresses"

# --- 10. interface autodetect ----------------------------------------------------
reset; conf 1 ""; echo server > "$T/probe-mode"; run check
grep -q "^eth0 " "$T/probe.calls" && pass || fail "autodetect must pick the single wired iface (not wlan0)"
mkdir -p "$T/sys/eth1/device"; echo 1 > "$T/sys/eth1/carrier"; rm -f "$T/probe.calls"; run check
[ ! -s "$T/probe.calls" ] && pass || fail "two wired ifaces + no IFACE must refuse to pick"
grep -q "several wired interfaces" "$T/out" && pass || fail "ambiguous autodetect must say so"
rm -rf "$T/sys/eth1"

# --- 11. watcher: periodic re-check stops serving when a server appears; link
#         changes trigger an immediate re-check ------------------------------------
reset; RECHECK=1 conf 1; echo none > "$T/probe-mode"
bash "$LD" watch > "$T/watch.out" 2>&1 &
wpid=$!
for _ in $(seq 1 50); do alive && break; sleep 0.1; done
alive && pass || fail "watcher must start serving when alone"
echo server > "$T/probe-mode"
for _ in $(seq 1 40); do ! alive && [ "$(mode)" = present ] && break; sleep 0.1; done
! alive && pass || fail "watcher must stop serving once a real server answers"
[ "$(mode)" = present ] && pass || fail "watcher must leave mode present (got $(mode))"
echo none > "$T/probe-mode"; echo 0 > "$T/sys/eth0/carrier"
for _ in $(seq 1 30); do grep -q "link change" "$T/watch.out" && break; sleep 0.1; done
grep -q "link change on eth0 (carrier 0)" "$T/watch.out" && pass || fail "watcher must notice the link going down"
echo 1 > "$T/sys/eth0/carrier"
for _ in $(seq 1 50); do alive && break; sleep 0.1; done
alive && pass || fail "watcher must re-probe on link-up and serve when alone again"
touch "$T/state/STOP"; for _ in $(seq 1 30); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.1; done
kill "$wpid" 2>/dev/null; rm -f "$T/state/STOP"

# --- 12. ensure with the knob off stops a running server --------------------------
reset; conf 1; echo none > "$T/probe-mode"; run check; alive && pass || fail "setup: serving before disable"
conf 0; run ensure
! alive && pass || fail "turning VALARK_LINK_DHCP off must stop serving"

# --- 12b. ensure (the loop entry): starts ONE watcher when it can serve, none
#          when it never can (no root) ------------------------------------------------
reset; conf 1 eth0 "" "$T/bin/sudo-no"; echo none > "$T/probe-mode"; run ensure
[ ! -s "$T/state/link-dhcp/watch.pid" ] && pass || fail "ensure without root must not park a watcher"
reset; conf 1; echo none > "$T/probe-mode"; run ensure
for _ in $(seq 1 30); do [ -s "$T/state/link-dhcp/watch.pid" ] && break; sleep 0.1; done
w1=$(cat "$T/state/link-dhcp/watch.pid" 2>/dev/null)
[ -n "$w1" ] && [ -d "/proc/$w1" ] && pass || fail "ensure must start the watcher"
run ensure; sleep 0.3
[ "$(cat "$T/state/link-dhcp/watch.pid" 2>/dev/null)" = "$w1" ] && pass || fail "a second ensure must not start a second watcher"
conf 0; run ensure; sleep 0.3
[ ! -d "/proc/$w1" ] && ! alive && pass || fail "ensure with the knob off must stop the watcher and dnsmasq"

# --- 13. loop wiring ---------------------------------------------------------------
grep -q 'lib/link-dhcp.sh"' "$ROOT/scripts/loop.sh" && grep -q 'bash "$sh" ensure' "$ROOT/scripts/loop.sh" \
    && grep -qE '^ *step "2f\..*ensure_link_dhcp' "$ROOT/scripts/loop.sh" && pass || fail "loop.sh must run link-dhcp.sh ensure each cycle (step 2f)"
grep -q '^# VALARK_LINK_DHCP=1' "$ROOT/.env.example" && pass || fail ".env.example must document VALARK_LINK_DHCP"
# --- 14. the real probe's packet code (offline: build + parse, no sockets) ---------
cat > "$T/probe_unit.py" <<'PY'
import importlib.util, struct, sys
spec = importlib.util.spec_from_file_location("dp", sys.argv[1]); dp = importlib.util.module_from_spec(spec); spec.loader.exec_module(dp)
mac = bytes.fromhex("020000000001"); xid = 0x12345678
d = dp.discover(xid, mac)
assert d[0] == 1 and struct.unpack("!I", d[4:8])[0] == xid and d[236:240] == dp.MAGIC, "bad DISCOVER header"
assert bytes([53, 1, 1]) in d[240:], "DISCOVER must carry message type 1"
assert bytes([53, 1, 3]) not in d, "probe must never REQUEST"
def frame(msgtype, sid, sport=67, dport=68, x=xid):
    b = bytearray(d); b[0] = 2; b[4:8] = struct.pack("!I", x)
    opts = bytes([53, 1, msgtype]) + (bytes([54, 4]) + bytes(sid) if sid else b"") + b"\xff"
    b = bytes(b[:240]) + opts
    udp = struct.pack("!HHHH", sport, dport, 8 + len(b), 0)
    ip = bytes([0x45, 0]) + struct.pack("!H", 20 + len(udp) + len(b)) + bytes(5) + bytes([17]) + bytes(2) + bytes([192, 0, 2, 9]) + bytes(4)
    return ip + udp + b
assert dp.parse_offer(frame(2, [192, 0, 2, 1]), xid) == "192.0.2.1", "OFFER server id"
assert dp.parse_offer(frame(2, None), xid) == "192.0.2.9", "OFFER without option 54 -> source address"
assert dp.parse_offer(frame(5, [192, 0, 2, 1]), xid) is None, "ACK is not an offer"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], x=1), xid) is None, "other xid ignored"
assert dp.parse_offer(frame(2, [192, 0, 2, 1], dport=67), xid) is None, "non-client port ignored"
assert dp.main(["x"]) == 64, "usage"
assert dp.main(["x", "no-such-iface-xyz", "0.1"]) == 2, "missing iface -> 2 (unknown, callers fail closed)"
PY
python3 "$T/probe_unit.py" "$ROOT/scripts/lib/dhcp_probe.py" 2>"$T/pu.err" && pass || fail "dhcp_probe.py packet build/parse: $(tail -2 "$T/pu.err")"

echo "link-dhcp: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
