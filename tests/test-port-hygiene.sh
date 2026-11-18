#!/bin/bash
###############################################################################
# Test: test-suite port hygiene (parallel runs on one box).
#
#  * no tests/test-*.sh starts a server on a hardcoded port: a literal port made
#    parallel runs (several worktrees/workers) talk to each other's servers or
#    fail "server did not start" while a leftover held it.
#  * tests/lib/ports.sh: free_port returns a bindable port; trap_signals makes a
#    TERM'd test run its EXIT cleanup (bash skips EXIT on an untrapped signal);
#    stop_pids escalates to KILL for a child that ignores TERM.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$ROOT/tests/lib/ports.sh"

# 1. structural: in a test that starts server.js, no shell var gets a literal port and no
#    port is derived by a big fixed offset ($((port + 9000)) overflows 65535 on an ephemeral port).
HITS=$(grep -lE 'scripts/server\.js' "$ROOT"/tests/test-*.sh | xargs grep -nE '^\s*[A-Z_0-9]*P[A-Z_0-9]*=[0-9]{4,5}\b|\+ ?[0-9]{4,}\)\)' 2>/dev/null)
[ -z "$HITS" ] && pass || fail "hardcoded server ports (use free_port from tests/lib/ports.sh):
$HITS"

# 2. free_port: numeric, bindable, and two picks are (almost always) distinct.
P1=$(free_port); P2=$(free_port)
[[ "$P1" =~ ^[0-9]+$ ]] && [ "$P1" -gt 1024 ] && [ "$P1" -lt 65536 ] && pass || fail "free_port returned '$P1'"
python3 -c 'import socket,sys; s=socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.close()' "$P1" \
    && pass || fail "free_port's port $P1 is not bindable"

# 3. trap_signals: a TERM'd script still runs its EXIT cleanup (kills its "server").
cat > "$T/child.sh" <<EOS
. "$ROOT/tests/lib/ports.sh"
sleep 300 & SRV=\$!; echo \$SRV > "$T/srv.pid"
trap 'stop_pids \$SRV' EXIT; trap_signals
wait
EOS
bash "$T/child.sh" & CH=$!
for _ in $(seq 1 30); do [ -s "$T/srv.pid" ] && break; sleep 0.1; done
kill -TERM "$CH"; wait "$CH" 2>/dev/null
SRV=$(cat "$T/srv.pid"); sleep 0.3
kill -0 "$SRV" 2>/dev/null && { fail "TERM'd test leaked its server (pid $SRV)"; kill -9 "$SRV"; } || pass

# 4. stop_pids escalates to KILL for a process that ignores TERM.
bash -c 'trap "" TERM; while :; do sleep 0.1; done' & STUB=$!
sleep 0.2; stop_pids "$STUB"; wait "$STUB" 2>/dev/null
kill -0 "$STUB" 2>/dev/null && { fail "stop_pids left a TERM-ignoring process alive"; kill -9 "$STUB"; } || pass

echo "port-hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
