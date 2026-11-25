#!/bin/bash
###############################################################################
# Test: test-suite port hygiene (parallel runs on one box).
#
#  * no tests/test-*.sh starts a server on a hardcoded port: a literal port made
#    parallel runs (several worktrees/workers) talk to each other's servers or
#    fail "server did not start" while a leftover held it.
#  * no port arithmetic either ($((PORT+1)), $(($PORT + 1)), $((1+PORT)), $((SP + 1))
#    on any variable assigned from free_port): it can collide with another run's
#    free_port; take a second free_port instead.
#  * every test that starts server.js stops it from its EXIT trap: the LAST trap (or
#    the cleanup function it names, plus helpers it calls) calls stop_pids on the
#    variable holding that server's pid. A stop_pids call only mid-test doesn't count,
#    and a mid-test stop_pids $X must clear X (`; X=""`) so the trap can't signal a
#    reused pid. The lint is tests/lib/port_hygiene.py; §1d runs it on one fixture
#    per case it must catch (or must not flag).
#  * tests/lib/ports.sh: free_port returns a bindable port; a TERM'd test whose EXIT
#    trap calls stop_pids leaves no server behind, and a broken trap (one that never
#    kills the server) IS detected as a leak (negative control); stop_pids escalates
#    to KILL for a child that ignores TERM.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/require-cmd.sh"; require_python3 "port-hygiene"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$ROOT/tests/lib/ports.sh"

# 1. The lint (tests/lib/port_hygiene.py) on every real test: no literal port, no port
#    arithmetic, every server launch has a known pid variable that the LAST EXIT trap
#    stop_pids-es, and every mid-test stop_pids clears its variable.
REAL=(); for f in "$ROOT"/tests/test-*.sh; do [ "$f" -ef "${BASH_SOURCE[0]}" ] || REAL+=("$f"); done   # not this file's fixture text
OUT=$(python3 -I "$ROOT/tests/lib/port_hygiene.py" "${REAL[@]}" 2>&1)
[ -z "$OUT" ] && pass || fail "port hygiene (see tests/lib/port_hygiene.py for the codes):
$OUT"

# 1d. The lint itself, on fixtures (one per case the #211 review found; each is a mutation of a
#     correct file). fx <name> <expected: CLEAN or a CODE> then the file body on stdin.
LINT="$ROOT/tests/lib/port_hygiene.py"
mkdir -p "$T/fx"
fx() {
    local name="$1" want="$2" f="$T/fx/test-$1.sh" got
    cat > "$f"
    got=$(python3 -I "$LINT" "$f" 2>&1)
    if [ "$want" = CLEAN ]; then
        [ -z "$got" ] && pass || fail "lint fixture $name must be clean, got: $got"
    else
        grep -q ": $want " <<<"$got" && pass || fail "lint fixture $name must report $want, got: '${got}'"
    fi
}
L='"$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &'
fx control CLEAN <<EOF
PORT=\$(free_port); SRV_PID=""
trap 'stop_pids "\$SRV_PID"; rm -rf "\$T"' EXIT
$L
SRV_PID=\$!
stop_pids "\$SRV_PID"; SRV_PID=""
EOF
fx last-trap-wins TRAP <<EOF
PORT=\$(free_port)
trap 'stop_pids "\$SRV_PID"' EXIT
$L
SRV_PID=\$!
trap 'rm -rf "\$T"' EXIT
EOF
fx unquoted-noclear NOCLEAR <<EOF
PORT=\$(free_port)
trap 'stop_pids "\$SRV_PID"' EXIT
$L
SRV_PID=\$!
stop_pids \$SRV_PID
EOF
fx offset-any-port-var OFFSET <<EOF
SP=\$(free_port)
trap 'stop_pids "\$NPID"' EXIT
"\$NODE" "\$ROOT/scripts/server.js" "\$SP" >"\$T/srv.log" 2>&1 &
NPID=\$!
VALARK_HTTPS_PORT=\$((SP + 1))
EOF
fx offset-dollar-form OFFSET <<EOF
PORT=\$(free_port)
trap 'stop_pids "\$SRV_PID"' EXIT
$L
SRV_PID=\$!
H=\$((\$PORT+1))
EOF
fx offset-reversed OFFSET <<EOF
PORT=\$(free_port)
trap 'stop_pids "\$SRV_PID"' EXIT
$L
SRV_PID=\$!
H=\$((1 + PORT))
EOF
fx literal-port LITERAL <<EOF
PORT=3700
trap 'stop_pids "\$SRV_PID"' EXIT
$L
SRV_PID=\$!
EOF
fx amp-on-continuation TRAP <<EOF
PORT=\$(free_port)
trap 'rm -rf "\$T"' EXIT
VALARK_BIND=127.0.0.1 \\
  "\$NODE" "\$ROOT/scripts/server.js" "\$PORT" \\
  >"\$T/srv.log" 2>&1 &
SRV_PID=\$!
EOF
fx one-line-cleanup TRAP <<EOF
PORT=\$(free_port)
cleanup() { rm -rf "\$T"; }
trap cleanup EXIT
$L
SRV_PID=\$!
stop_pids "\$SRV_PID"; SRV_PID=""
later() {
    echo later
}
EOF
fx no-pid-var NOPID <<EOF
PORT=\$(free_port)
trap 'rm -rf "\$T"' EXIT
$L
EOF
fx quoted-trap-name CLEAN <<EOF
PORT=\$(free_port)
cleanup() { stop_pids "\$SRV_PID"; rm -rf "\$T"; }
trap 'cleanup' EXIT
$L
SRV_PID=\$!
EOF
fx helper-indirection CLEAN <<EOF
PORT=\$(free_port)
kill_servers() { stop_pids "\$SRV_PID"; }
cleanup() {
    kill_servers
    rm -rf "\$T"
}
trap cleanup EXIT
$L
SRV_PID=\$!
EOF
fx pid-array CLEAN <<EOF
PORT=\$(free_port); PIDS=()
trap 'stop_pids "\${PIDS[@]}"' EXIT
$L
PIDS+=(\$!)
EOF
fx subshell-capture CLEAN <<EOF
PORT=\$(free_port)
start() { $L echo \$!; }
SRV_PID=\$(start)
trap 'stop_pids "\$SRV_PID"' EXIT
EOF
fx comment-only-stop TRAP <<EOF
PORT=\$(free_port)
cleanup() {
    # stop_pids "\$SRV_PID"   (commented out: must not count)
    rm -rf "\$T"
}
trap cleanup EXIT
$L
SRV_PID=\$!
EOF

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
