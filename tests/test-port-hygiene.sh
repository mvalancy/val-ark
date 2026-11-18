#!/bin/bash
###############################################################################
# Test: test-suite port hygiene (parallel runs on one box).
#
#  * no tests/test-*.sh starts a server on a hardcoded port: a literal port made
#    parallel runs (several worktrees/workers) talk to each other's servers or
#    fail "server did not start" while a leftover held it.
#  * no small fixed offsets either ($((PORT+1)), $(($PORT + 1)), $((1+PORT)) can
#    collide with another run's free_port); take a second free_port instead.
#  * every test that starts server.js stops it from its EXIT trap: the trap (or the
#    cleanup function it names) calls stop_pids on the variable holding that
#    server's pid. A stop_pids call only mid-test doesn't count, and a mid-test
#    stop_pids "$X" must clear X (`; X=""`) so the trap can't signal a reused pid.
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
HITS=$(grep -lE 'scripts/server\.js' "$ROOT"/tests/test-*.sh | xargs grep -nE '^\s*[A-Z_0-9]*P[A-Z_0-9]*=[0-9]{4,5}\b|\+ ?[0-9]{4,}\)\)|\(\( *\$?\{?[A-Za-z_]*(PORT|port)[A-Za-z_0-9]*\}? *[-+] *[0-9]+ *\)\)|\(\( *[0-9]+ *\+ *\$?\{?[A-Za-z_]*(PORT|port)' 2>/dev/null)
[ -z "$HITS" ] && pass || fail "hardcoded server ports (use free_port from tests/lib/ports.sh):
$HITS"

# 1b. every server test's EXIT trap stops the server: find the variable that holds each
#     server.js pid (`X=$!` after the launch, `X="$(cat ...pid)"` for a subshell launch,
#     or an accumulator like ALL_PIDS="$ALL_PIDS $pid"), then require the EXIT trap body
#     (inline, or the function it names) to call stop_pids with that variable.
python3 - "$ROOT"/tests/test-*.sh > "$T/nostop" <<'PY'
import re, sys
for path in sys.argv[1:]:
    src = open(path).read()
    lines = src.split("\n")
    pidvars = set()
    for i, l in enumerate(lines):
        if not re.search(r'scripts/server\.js"? .*&', l):
            continue
        win = "\n".join(lines[i:i + 3])
        m = re.search(r'\b([A-Za-z_][A-Za-z0-9_]*)=\$!', win)
        if m:
            v = m.group(1)
            acc = re.search(r'\b([A-Z_][A-Z0-9_]*)="\$\1 \$%s"' % re.escape(v), src)
            pidvars.add(acc.group(1) if acc else v)
        elif re.search(r'echo \$! *> *"?([^ ")]+)', win):
            f = re.search(r'echo \$! *> *"?([^ ")]+)', win).group(1)
            m2 = re.search(r'\b([A-Z_][A-Z0-9_]*)="?\$\(cat "?%s' % re.escape(f), src)
            pidvars.add(m2.group(1) if m2 else "?unknown-pid-var")
        else:
            pidvars.add("?unknown-pid-var")
    if not pidvars:
        continue
    bodies = []
    for m in re.finditer(r"""trap +(?:'([^']*)'|"([^"]*)"|([A-Za-z_][A-Za-z0-9_]*)) +EXIT""", src):
        body = m.group(1) or m.group(2)
        if m.group(3):  # trap <function> EXIT -> that function's body
            fm = re.search(r'^%s\(\) *\{(.*?)^\}|^%s\(\) *\{([^\n]*)\}' % (m.group(3), m.group(3)), src, re.M | re.S)
            body = (fm.group(1) or fm.group(2)) if fm else ""
        bodies.append(body or "")
    calls = " ".join(re.findall(r'stop_pids[^;\n]*', " ".join(bodies)))
    missing = [v for v in sorted(pidvars) if not re.search(r'\$\{?%s\b' % re.escape(v), calls)]
    if missing:
        print("%s (EXIT trap does not stop_pids: %s)" % (path.rsplit("/", 1)[-1], " ".join(missing)))
PY
[ ! -s "$T/nostop" ] && pass || fail "server tests whose EXIT trap does not stop their server: $(tr '\n' ' ' < "$T/nostop")"

# 1c. a mid-test `stop_pids "$X"` must clear X on the same line (`; X=""`), or the EXIT trap
#     later signals a dead pid that may by then belong to someone else's process. Calls inside
#     the cleanup function the EXIT trap names are exempt (the shell is exiting).
python3 - "$ROOT"/tests/test-*.sh > "$T/noclear" <<'PY'
import re, sys
for path in sys.argv[1:]:
    src = open(path).read()
    if not any(re.search(r'scripts/server\.js"? .*&', l) for l in src.split("\n")):
        continue  # only tests that launch a server
    exempt = set()
    for m in re.finditer(r'trap +([A-Za-z_][A-Za-z0-9_]*) +EXIT', src):
        fm = re.search(r'^%s\(\) *\{.*?^\}|^%s\(\) *\{[^\n]*\}' % (m.group(1), m.group(1)), src, re.M | re.S)
        if fm:
            exempt.update(range(src.count("\n", 0, fm.start()) + 1, src.count("\n", 0, fm.end()) + 2))
    for n, line in enumerate(src.split("\n"), 1):
        if n in exempt or re.search(r'\btrap\b', line):
            continue
        for v in re.findall(r'stop_pids +"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"', line):
            if not re.search(r'\b%s=""' % re.escape(v), line):
                print("%s:%d stop_pids \"$%s\" without %s=\"\"" % (path.rsplit("/", 1)[-1], n, v, v))
PY
[ ! -s "$T/noclear" ] && pass || fail "a mid-test stop_pids must clear its pid var: $(tr '\n' ' ' < "$T/noclear")"

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
