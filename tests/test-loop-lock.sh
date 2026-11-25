#!/bin/bash
###############################################################################
# Test: loop.sh single-cycle lock discipline (issue #56).
#
# Every full loop cycle must serialise on loop.lock (fd 8) so a `loop.sh run`
# supervision loop never overlaps the installed cron `once` ticks (or the admin
# one-click repair, which also spawns `loop.sh once`). Two concurrent loop_once
# cycles flap the web server (fuser -k) and double-run tool_refresh onto the same
# .part files. Invariants:
#   - lock FREE: run_locked runs the payload (both busy-modes) and returns its rc
#   - lock HELD, "exit" mode (cron `once`): skips cleanly with exit 0, no payload
#   - lock HELD, "skip" mode (a `run` iteration): RETURNS non-zero (never exits) so
#     the forever loop survives contention — a stuck cycle must not deadlock it
#   - the shipped dispatch: `once` uses "exit", `run` takes the lock ("skip") AND
#     releases it (`exec 8>&-`) between iterations so cron can work during the sleep
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
LOOP="$ROOT/scripts/loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null' EXIT
STATE_DIR="$T/state"; mkdir -p "$STATE_DIR"
LOCK="$STATE_DIR/loop.lock"

# --- 0. the shipped script parses --------------------------------------------
bash -n "$LOOP" 2>/dev/null && pass || fail "loop.sh must be syntactically valid"

# --- harness: source the REAL run_locked with a stub payload + temp STATE_DIR --
# (Drive the shipped function in isolation — a real cycle is heavy + networked.)
H="$T/harness.sh"
{
    echo 'STATE_DIR="'"$STATE_DIR"'"'
    echo 'log(){ :; }'
    echo 'payload(){ echo ran >> "'"$T"'/trace"; return 0; }'
    awk '/^run_locked\(\) \{/,/^\}/' "$LOOP"
} > "$H"
# sanity: the extraction actually captured the function body
grep -q 'flock -n 8' "$H" && pass || fail "harness must contain the real run_locked (flock -n 8)"

# --- 1. lock FREE → payload runs, both modes ---------------------------------
: > "$T/trace"
( . "$H"; run_locked exit payload ); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l < "$T/trace")" = 1 ] && pass || fail "exit-mode with a free lock must run the payload (rc=$rc)"
: > "$T/trace"
( . "$H"; run_locked skip payload ); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l < "$T/trace")" = 1 ] && pass || fail "skip-mode with a free lock must run the payload (rc=$rc)"

# --- hold the lock from an external process (simulates a cycle mid-flight) ----
flock "$LOCK" -c 'touch "'"$T"'/held"; while [ ! -f "'"$T"'/release" ]; do sleep 0.03; done' &
HOLDER=$!
for i in $(seq 1 100); do [ -f "$T/held" ] && break; sleep 0.03; done
[ -f "$T/held" ] && pass || fail "external lock holder must acquire loop.lock"

# --- 2. lock HELD, exit-mode (cron `once`) → clean exit 0, payload SKIPPED ----
: > "$T/trace"
( . "$H"; run_locked exit payload ); rc=$?
[ "$rc" = 0 ] && pass || fail "exit-mode on a held lock must exit 0 (cron tick skips cleanly), got rc=$rc"
[ ! -s "$T/trace" ] && pass || fail "exit-mode on a held lock must NOT run a second concurrent payload"

# --- 3. lock HELD, skip-mode (a `run` iteration) → RETURN non-zero, no exit ---
# Run in a child script so an accidental `exit` (the bug) would be caught: the
# marker line after the call only writes if run_locked RETURNED instead of exiting.
cat > "$T/skip.sh" <<EOF
. "$H"
run_locked skip payload; ec=\$?
echo "rc=\$ec survived" > "$T/skip_out"
EOF
: > "$T/trace"; rm -f "$T/skip_out"
bash "$T/skip.sh"
grep -q 'rc=1 survived' "$T/skip_out" 2>/dev/null && pass || fail "skip-mode on a held lock must RETURN 1 and keep running (got: $(cat "$T/skip_out" 2>/dev/null))"
[ ! -s "$T/trace" ] && pass || fail "skip-mode on a held lock must NOT run a second concurrent payload"

# release the external holder
touch "$T/release"; wait "$HOLDER" 2>/dev/null; HOLDER=""

# --- 4. once released, the lock is grantable again ---------------------------
: > "$T/trace"
( . "$H"; run_locked exit payload ); rc=$?
[ "$rc" = 0 ] && [ -s "$T/trace" ] && pass || fail "a released lock must be re-acquirable (rc=$rc)"

# --- 5. structural: the shipped dispatch wires the lock the RIGHT way ---------
# `once` (cron / admin repair) must exit-skip; `run` must skip-survive + release.
disp="$(sed -n '/^case "${1:-once}" in/,/^esac/p' "$LOOP")"
# once) arm (up to its first ;;) must call run_locked in exit mode — robust to the
# arm being one line or several (a mount guard now precedes the mkdir + lock).
echo "$disp" | awk '/^    once\)/,/;;/' | grep -q 'run_locked exit loop_once' && pass \
    || fail "the once) arm must call 'run_locked exit loop_once'"
echo "$disp" | grep -q 'run_locked skip loop_once' && pass \
    || fail "the run) arm must guard each iteration with 'run_locked skip loop_once'"
echo "$disp" | grep -q 'exec 8>&-' && pass \
    || fail "the run) arm must release the lock (exec 8>&-) between iterations so a cron tick can run during the sleep"
# run) must mkdir STATE_DIR before the loop so 'exec 8>loop.lock' can open the fd
echo "$disp" | awk '/run\)/,/done ;;/' | grep -q 'mkdir -p "\$STATE_DIR"' && pass \
    || fail "the run) arm must mkdir STATE_DIR before opening the lock fd"

# --- 6. the cycle lock must NOT leak into detached daemons (issue #56 regression) ---
# run_locked holds loop.lock on fd 8 for ALL of loop_once, which (re)starts the web
# server (and community daemons) as DETACHED, long-lived processes. If any inherits
# fd 8 it shares the open-file-description that holds the flock, so the lock is NEVER
# released — every later cycle's `flock -n 8` then fails forever ("another loop cycle
# is running; skipping"), silently starving ALL maintenance. Every daemon spawn
# reachable from loop_once MUST close the lock fd (8>&-). Drive the REAL _va_start_web
# with a fake long-lived "node", hold the lock exactly like run_locked does, then
# assert a fresh non-blocking flock ACQUIRES it while the fake daemon is still alive.
# (This FAILS against the pre-fix _va_start_web — daemon inherits fd 8 — and PASSES
# once the spawn closes it.)
FAKE="$T/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/node" <<EOF
#!/bin/bash
echo \$\$ > "$T/daemon.pid"
exec sleep 30
EOF
chmod +x "$FAKE/node"
# kill the fake daemon (and any holder) on exit, then clean up the temp dir
trap 'kill "$(cat "$T/daemon.pid" 2>/dev/null)" 2>/dev/null; [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$T"' EXIT

WH="$T/webharness.sh"
{
    echo 'LOG_DIR="'"$T"'"; _DIR="'"$T"'"'
    echo 'log(){ :; }'
    echo '_va_node(){ echo "'"$FAKE/node"'"; }'   # resolve node -> our fake daemon
    awk '/^_va_start_web\(\) \{/,/^\}/' "$LOOP"
} > "$WH"
grep -q 'setsid' "$WH" && pass || fail "web harness must contain the real _va_start_web"

WLOCK="$STATE_DIR/loop2.lock"; rm -f "$T/daemon.pid"
# Simulate one run_locked cycle: take loop.lock on fd 8, (re)start the web daemon,
# then release OUR copy — exactly what the `run` loop's `exec 8>&-` does per iteration.
(
    . "$WH"
    exec 8>"$WLOCK"
    flock -n 8 || exit 7
    _va_start_web 3900
    exec 8>&-
) 2>/dev/null
# wait for the fake daemon so its (possibly inherited) fd 8 is live during the check
for i in $(seq 1 100); do [ -f "$T/daemon.pid" ] && break; sleep 0.03; done
DPID="$(cat "$T/daemon.pid" 2>/dev/null)"
[ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null && pass \
    || fail "the fake web daemon must be alive during the lock check (else the test proves nothing)"
# THE assertion: with the run shell's copy closed, loop.lock must be FREE — i.e. the
# detached daemon must NOT be holding it. FAILS on the buggy code (daemon inherited
# fd 8 → flock never releases); PASSES once _va_start_web spawns with 8>&-.
if flock -n "$WLOCK" -c 'true'; then pass; else \
    fail "loop.lock LEAKED into the detached web daemon — a fresh flock -n must succeed after a cycle (daemon must be spawned with 8>&-)"; fi
kill "$DPID" 2>/dev/null

# --- 6b. functional: a community-service spawn must NOT leak the cycle lock (issue #56) ---
# The web server is not the only daemon reachable from loop_once: ensure_services runs
# `timeout 120 bash "$sh" start … 8>&-` under the cycle lock, and each service script
# spawns long-lived detached daemons (ngIRCd/The Lounge/maddy/NodeBB/…). The 8>&- on
# that central guard must close fd 8 for the whole service subtree so no service daemon
# inherits loop.lock (a shared fd holds the flock forever, deadlocking every later cycle).
# Drive the REAL ensure_services with a fake service that spawns a long-lived detached
# daemon — exactly the way section 6 drives _va_start_web — then assert a fresh flock -n
# ACQUIRES the lock while the daemon is still alive. FAILS if 8>&- is dropped from the
# ensure_services guard (daemon inherits fd 8); PASSES with it.
SVCROOT="$T/svcroot"; mkdir -p "$SVCROOT/services"
cat > "$SVCROOT/services/chat.sh" <<EOF
#!/bin/bash
[ "\$1" = "start" ] || exit 0
# spawn a detached, long-lived daemon that keeps whatever fds it inherits open
setsid bash -c 'echo \$\$ > "$T/svc.pid"; exec sleep 30' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
EOF
chmod +x "$SVCROOT/services/chat.sh"
# extend cleanup to also reap the service daemon
trap 'kill "$(cat "$T/daemon.pid" 2>/dev/null)" 2>/dev/null; kill "$(cat "$T/svc.pid" 2>/dev/null)" 2>/dev/null; [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$T"' EXIT

SVCLOCK="$STATE_DIR/loop3.lock"; rm -f "$T/svc.pid"
SH="$T/svcharness.sh"
{
    echo '_DIR="'"$SVCROOT"'"'
    echo 'log(){ :; }'
    echo 'VALARK_SERVICES="chat"'
    sed -n '/^ensure_services()/,/^}/p' "$LOOP"
} > "$SH"
grep -q 'timeout .*bash "\$sh" start' "$SH" && pass || fail "service harness must contain the real ensure_services"
# Simulate one run_locked cycle: take loop.lock on fd 8, launch the service, then release
# OUR copy — exactly what the `run` loop's `exec 8>&-` does per iteration.
(
    . "$SH"
    exec 8>"$SVCLOCK"
    flock -n 8 || exit 7
    ensure_services
    exec 8>&-
) 2>/dev/null
for i in $(seq 1 100); do [ -f "$T/svc.pid" ] && break; sleep 0.03; done
SPID="$(cat "$T/svc.pid" 2>/dev/null)"
[ -n "$SPID" ] && kill -0 "$SPID" 2>/dev/null && pass \
    || fail "the fake service daemon must be alive during the lock check (else the test proves nothing)"
# THE assertion: the detached service daemon must NOT hold loop.lock.
if flock -n "$SVCLOCK" -c 'true'; then pass; else \
    fail "loop.lock LEAKED into a detached service daemon — ensure_services must spawn with 8>&-"; fi
kill "$SPID" 2>/dev/null

# --- 7. structural: cycle-reachable daemon spawns close the lock fd (8>&-) -----------
# Belt-and-suspenders for the spawns section 6 can't all drive live: the web server
# spawn AND the central service-launch guard must close fd 8. Assert the OPERATIVE
# redirection, NOT the explanatory comment: both functions carry a "# 8>&- : …" comment,
# so a bare `grep 8>&-` would still PASS even if the real redirect were deleted (#96).
# Strip full-line comments first, then require 8>&- on the actual spawn command line.
awk '/^_va_start_web\(\) \{/,/^\}/' "$LOOP" | grep -v '^[[:space:]]*#' | grep -q 'setsid.*8>&-' && pass \
    || fail "_va_start_web must close the lock fd (8>&-) on the actual web-server spawn line (not just a comment)"
sed -n '/^ensure_services()/,/^}/p' "$LOOP" | grep -v '^[[:space:]]*#' | grep -q 'timeout .*bash .*8>&-' && pass \
    || fail "ensure_services must close the lock fd (8>&-) on the actual service-spawn line (not just a comment)"

echo "loop-lock: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
