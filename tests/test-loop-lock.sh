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
echo "$disp" | grep -qE 'once\).*run_locked exit loop_once' && pass \
    || fail "the once) arm must call 'run_locked exit loop_once'"
echo "$disp" | grep -q 'run_locked skip loop_once' && pass \
    || fail "the run) arm must guard each iteration with 'run_locked skip loop_once'"
echo "$disp" | grep -q 'exec 8>&-' && pass \
    || fail "the run) arm must release the lock (exec 8>&-) between iterations so a cron tick can run during the sleep"
# run) must mkdir STATE_DIR before the loop so 'exec 8>loop.lock' can open the fd
echo "$disp" | awk '/run\)/,/done ;;/' | grep -q 'mkdir -p "\$STATE_DIR"' && pass \
    || fail "the run) arm must mkdir STATE_DIR before opening the lock fd"

echo "loop-lock: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
