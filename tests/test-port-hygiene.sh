#!/bin/bash
###############################################################################
# Test: test-suite port hygiene (parallel runs on one box).
#
#  * no tests/test-*.sh starts a server on a hardcoded port: a literal port made
#    parallel runs (several worktrees/workers) talk to each other's servers or
#    fail "server did not start" while a leftover held it.
#  * no small fixed offsets either ($((PORT+1)) can collide with another run's
#    free_port); take a second free_port instead.
#  * every test that starts server.js stops it via stop_pids (its EXIT trap must
#    kill the server, not just delete the temp dir).
#  * tests/lib/ports.sh: free_port returns a bindable port; a TERM'd test whose EXIT
#    trap calls stop_pids leaves no server behind, and a broken trap (one that never
#    kills the server) IS detected as a leak (negative control); stop_pids escalates
#    to KILL for a child that ignores TERM.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$ROOT/tests/lib/ports.sh"

# 1. structural: in a test that starts server.js, no shell var gets a literal port and no
#    port is derived by a big fixed offset ($((port + 9000)) overflows 65535 on an ephemeral port).
HITS=$(grep -lE 'scripts/server\.js' "$ROOT"/tests/test-*.sh | xargs grep -nE '^\s*[A-Z_0-9]*P[A-Z_0-9]*=[0-9]{4,5}\b|\+ ?[0-9]{4,}\)\)|\(\( ?[A-Za-z_]*(PORT|port)[A-Za-z_0-9]* ?\+ ?[0-9]+ ?\)\)' 2>/dev/null)
[ -z "$HITS" ] && pass || fail "hardcoded server ports (use free_port from tests/lib/ports.sh):
$HITS"

# 1b. every server test stops its servers through stop_pids (an EXIT trap that only removes
#     the temp dir leaks the server on any early exit).
grep -lE 'scripts/server\.js' "$ROOT"/tests/test-*.sh | while read -r f; do
    grep -q 'stop_pids' "$f" || echo "$(basename "$f")"; done > "$T/nostop"
[ ! -s "$T/nostop" ] && pass || fail "server tests that never call stop_pids: $(tr '\n' ' ' < "$T/nostop")"

# 2. free_port: numeric, bindable, and two picks are (almost always) distinct.
P1=$(free_port); P2=$(free_port)
[[ "$P1" =~ ^[0-9]+$ ]] && [ "$P1" -gt 1024 ] && [ "$P1" -lt 65536 ] && pass || fail "free_port returned '$P1'"
python3 -c 'import socket,sys; s=socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.close()' "$P1" \
    && pass || fail "free_port's port $P1 is not bindable"

# 3. A TERM'd test's cleanup: with an EXIT trap that calls stop_pids, its "server" is gone;
#    with a broken trap (cleans the temp dir, never kills the server) the leak IS detected.
#    The broken case is a negative control: it proves this check can fail.
leaks_after_term() {  # leaks_after_term '<EXIT trap body>' -> 0 if the server outlived the test
    rm -f "$T/srv.pid"
    cat > "$T/child.sh" <<EOS
. "$ROOT/tests/lib/ports.sh"
sleep 300 & SRV=\$!; echo \$SRV > "$T/srv.pid"
trap '$1' EXIT; trap_signals
wait
EOS
    bash "$T/child.sh" & local ch=$!
    for _ in $(seq 1 30); do [ -s "$T/srv.pid" ] && break; sleep 0.1; done
    kill -TERM "$ch"; wait "$ch" 2>/dev/null; sleep 0.3
    local srv; srv=$(cat "$T/srv.pid")
    if kill -0 "$srv" 2>/dev/null; then kill -9 "$srv" 2>/dev/null; return 0; fi   # our own leaked sleep
    return 1
}
leaks_after_term 'stop_pids $SRV' && fail "a TERM'd test whose EXIT trap calls stop_pids leaked its server" || pass
leaks_after_term 'rm -rf /nonexistent-cleanup-only' && pass || fail "negative control: a trap that never kills the server must be seen as a leak"

# 4. stop_pids escalates to KILL for a process that ignores TERM.
bash -c 'trap "" TERM; while :; do sleep 0.1; done' & STUB=$!; disown "$STUB"   # no "Killed" job notice
sleep 0.2; stop_pids "$STUB"; sleep 0.2   # bounded: a broken stop_pids must FAIL here, not hang
if kill -0 "$STUB" 2>/dev/null; then fail "stop_pids left a TERM-ignoring process alive"; kill -9 "$STUB"; else pass; fi

echo "port-hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
