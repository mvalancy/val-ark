#!/bin/bash
###############################################################################
# Test: the loop runs the unplanned app mirrors BEFORE the model fill (#347).
# Offline, stubs only: the real loop_once / tool_refresh / devstack_mirror from
# scripts/loop.sh run against stub scripts (librarian, download-tools,
# release_mirror.py, ...). No network, no downloads, no real data root.
#
#  * loop_once order: 5c tool refresh -> 5d dev-stack mirror -> 6 top-up fill.
#  * dev-stack: release_mirror.py fetch --dest DEVSTACK_DIR --budget <librarian
#    budget> with VALARK_STOP_FLAG; VALARK_DEVSTACK_MAX_GB caps the budget by
#    what the tree holds; VALARK_DEVSTACK_GROUPS -> --group.
#  * off switches: VALARK_DEVSTACK=0, VALARK_DEVSTACK_REFRESH_DAYS=0; the STOP
#    flag skips both app mirrors; under 1 GiB of budget skips them.
#  * schedule: complete -> next in N days; deferred (exit 3) / error -> 1 day;
#    cut by its time bound -> due again next cycle.
#  * fail-soft: a failing mirror never stops the cycle (the fill still runs).
#  * VALARK_MAX_GB counts the dev-stack tree (valark_data_used_bytes).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/require-cmd.sh"; require_python3 "loop apps-first"; require_cmd timeout "loop apps-first"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
GIB=1073741824

bash -n "$ROOT/scripts/loop.sh" && pass || fail "loop.sh must parse"
# Sourcing a loop.sh without its source guard would DISPATCH a real cycle: refuse to go on.
if ! grep -q '^\[ "${BASH_SOURCE\[0\]}" != "$0" \] && return 0' "$ROOT/scripts/loop.sh"; then
    fail "loop.sh must not dispatch when sourced (source guard missing)"; echo "loop-apps-first: $PASS passed, $FAIL failed"; exit 1
fi

# --- stub scripts -------------------------------------------------------------------------
F="$T/fake"; mkdir -p "$F/lib"
cat > "$F/librarian.sh" <<'EOF'
echo "librarian $1" >> "$TRACE"
[ "$1" = essentials-done ] && exit "${STUB_ESS_RC:-0}"
exit 0
EOF
cat > "$F/download-tools.sh" <<'EOF'
echo "tools $*" >> "$TRACE"; exit "${STUB_TOOLS_RC:-0}"
EOF
for s in verify.sh mirror-self.sh lib/mod-sweep.sh; do echo 'exit 0' > "$F/$s"; done
cat > "$F/lib/release_mirror.py" <<'EOF'
import os, sys, time
with open(os.environ["TRACE"], "a") as f:
    f.write("devstack " + " ".join(sys.argv[1:]) + " stop=" + os.environ.get("VALARK_STOP_FLAG", "") + "\n")
time.sleep(float(os.environ.get("STUB_SLEEP", "0")))
sys.exit(int(os.environ.get("STUB_DEV_RC", "0")))
EOF

# --- harness: source the REAL loop.sh (it does not dispatch when sourced), stub the rest ---
H="$T/harness.sh"
cat > "$H" <<EOF
export VAL_ARK_DATA="$T/data" VAL_ARK_CONFIG="$T/empty.env" TRACE="$T/trace"
mkdir -p "$T/data"; : > "$T/empty.env"
unset VALARK_DEVSTACK VALARK_DEVSTACK_REFRESH_DAYS VALARK_DEVSTACK_MAX_GB VALARK_DEVSTACK_GROUPS \
      VALARK_DEVSTACK_TIMEOUT VALARK_TOOL_REFRESH_DAYS VALARK_MAX_GB GITHUB_TOKEN _VALARK_ENV_LOADED
. "$ROOT/scripts/loop.sh"
_DIR="$F"; LIBRARIAN="$F/librarian.sh"; VERIFY="$F/verify.sh"
mkdir -p "\$STATE_DIR" "\$LOG_DIR"
log() { echo "\$*" >> "$T/log"; }
for fn in valark_ensure_writable valark_ensure_layout ensure_web_server ensure_public_port ensure_services \
          ensure_link_dhcp tailscale_check ensure_mdns link_check_repair coordination write_health ui_smoke; do
    eval "\$fn() { :; }"
done
valark_budget_bytes() { echo "\${STUB_BUDGET:-$((500*GIB))}"; }
valark_fillable_bytes() { echo 0; }
EOF
reset() { rm -rf "$T/data" "$T/trace" "$T/log"; }
drive() { ( . "$H"; "$@" ) >/dev/null 2>&1; }
order() { awk '$1=="librarian" {print $1 "_" $2; next} {print $1}' "$T/trace" 2>/dev/null | tr '\n' ' '; }
nextin() { ( . "$H"; m=$(cat "$STATE_DIR/$1" 2>/dev/null); echo $(( ${m:-0} - $(date +%s) )) ) 2>/dev/null; }

# 1. one full cycle with stubs: tools, then the dev stack, then the fill.
reset; drive loop_once
O=$(order)
case "$O" in
  *"librarian_pins librarian_essentials-done tools devstack librarian_fill"*) pass ;;
  *) fail "loop_once order must be tool refresh, dev-stack, then the fill (got: $O)" ;;
esac
grep -q '^librarian verify' "$T/trace" && pass || fail "loop_once must still run the other librarian steps"
L=$(grep -m1 '^devstack' "$T/trace")
DS=$( ( . "$H"; echo "$DEVSTACK_DIR" ) 2>/dev/null)
ST=$( ( . "$H"; echo "$STATE_DIR" ) 2>/dev/null)
[[ "$L" == *"fetch --dest $DS --budget $((125*GIB))"* ]] && pass || fail "dev-stack: fetch --dest DEVSTACK_DIR --budget 25% share of the librarian budget (got: $L)"
[[ "$L" == *"stop=$ST/STOP" ]] && pass || fail "dev-stack must pass the STOP flag path (got: $L)"
[[ "$DS" == "$T/data/val-ark/dev-stack" ]] && pass || fail "DEVSTACK_DIR defaults to <home>/dev-stack (got $DS)"
N=$(nextin devstack-refresh.next); [ "$N" -gt $((6*86400)) ] && [ "$N" -le $((7*86400)) ] && pass || fail "a complete dev-stack run is next due in 7 days (got ${N}s)"
grep -q 'GITHUB_TOKEN not set' "$T/log" && pass || fail "without GITHUB_TOKEN the loop says so"

# 2. not due: a second cycle skips both app mirrors but still fills.
rm -f "$T/trace"; ( . "$H"; loop_once ) >/dev/null 2>&1
grep -q '^devstack' "$T/trace" && fail "a dev-stack mirror that is not due must not run" || pass
grep -q '^tools' "$T/trace" && fail "a tool refresh that is not due must not run" || pass
grep -q '^librarian fill' "$T/trace" && pass || fail "the fill runs every cycle"

# 3. the off switch, and REFRESH_DAYS=0.
reset; ( . "$H"; VALARK_DEVSTACK=0; loop_once ) >/dev/null 2>&1
grep -q '^devstack' "$T/trace" && fail "VALARK_DEVSTACK=0 must turn the dev-stack mirror off" || pass
grep -q '^librarian fill' "$T/trace" && pass || fail "with the dev stack off, the fill still runs"
grep -q 'VALARK_DEVSTACK=0' "$T/log" && pass || fail "the off switch is logged"
reset; ( . "$H"; VALARK_DEVSTACK_REFRESH_DAYS=0; devstack_mirror ) >/dev/null 2>&1
grep -q '^devstack' "$T/trace" 2>/dev/null && fail "VALARK_DEVSTACK_REFRESH_DAYS=0 must turn it off" || pass

# 4. STOP flag: neither app mirror runs.
reset; ( . "$H"; touch "$STATE_DIR/STOP"; tool_refresh; devstack_mirror ) >/dev/null 2>&1
grep -qE '^(devstack|tools)' "$T/trace" 2>/dev/null && fail "the STOP flag must skip the app mirrors" || pass

# 5. budget under 1 GiB (reserve / VALARK_MAX_GB): skipped, the dev stack retries in a day.
reset; ( . "$H"; STUB_BUDGET=$((GIB/2)); tool_refresh; devstack_mirror ) >/dev/null 2>&1
grep -qE '^(devstack|tools)' "$T/trace" 2>/dev/null && fail "under 1 GiB of budget the app mirrors must not run" || pass
N=$(nextin devstack-refresh.next); [ "$N" -gt 80000 ] && [ "$N" -le 86400 ] && pass || fail "a skipped (no room) dev stack retries in 1 day (got ${N}s)"

# 6. VALARK_DEVSTACK_MAX_GB caps the budget by what the tree already holds; groups knob.
reset; ( . "$H"; mkdir -p "$DEVSTACK_DIR"; head -c 1048576 /dev/zero > "$DEVSTACK_DIR/held.bin"
         VALARK_DEVSTACK_MAX_GB=2 VALARK_DEVSTACK_GROUPS="python,security"; devstack_mirror ) >/dev/null 2>&1
L=$(grep -m1 '^devstack' "$T/trace")
[[ "$L" == *"--budget $((2*GIB - 1048576)) --group python --group security"* ]] && pass \
  || fail "VALARK_DEVSTACK_MAX_GB / _GROUPS: budget = cap - held, --group per group (got: $L)"

# 6b. B1: a bounded share by default (VALARK_DEVSTACK_PCT, 25), never the whole budget;
#     100 = the whole budget; the explicit MAX_GB still applies on top.
reset; ( . "$H"; VALARK_DEVSTACK_PCT=10; devstack_mirror ) >/dev/null 2>&1
L=$(grep -m1 '^devstack' "$T/trace"); [[ "$L" == *"--budget $((50*GIB))"* ]] && pass || fail "VALARK_DEVSTACK_PCT=10 of 500 GiB -> 50 GiB (got: $L)"
reset; ( . "$H"; VALARK_DEVSTACK_PCT=100; devstack_mirror ) >/dev/null 2>&1
L=$(grep -m1 '^devstack' "$T/trace"); [[ "$L" == *"--budget $((500*GIB))"* ]] && pass || fail "VALARK_DEVSTACK_PCT=100 -> the whole budget (got: $L)"
reset; ( . "$H"; mkdir -p "$DEVSTACK_DIR"; head -c 1048576 /dev/zero > "$DEVSTACK_DIR/held.bin"; devstack_mirror ) >/dev/null 2>&1
L=$(grep -m1 '^devstack' "$T/trace")
[[ "$L" == *"--budget $(( (500*GIB + 1048576)/100*25 - 1048576 ))"* ]] && pass || fail "the share counts what the tree already holds (got: $L)"
reset; ( . "$H"; VALARK_DEVSTACK_MAX_GB=10; devstack_mirror ) >/dev/null 2>&1
L=$(grep -m1 '^devstack' "$T/trace"); [[ "$L" == *"--budget $((10*GIB))"* ]] && pass || fail "MAX_GB below the share still caps (got: $L)"

# 6c. B1: loop steps 5c/5d wait for `librarian.sh essentials-done` (exit 0); the fill still runs.
for rc in 1 2; do
  reset; ( . "$H"; export STUB_ESS_RC=$rc; loop_once ) >/dev/null 2>&1
  grep -qE '^(devstack|tools)' "$T/trace" && fail "essentials-done exit $rc: 5c/5d must not run" || pass
  grep -q '^librarian essentials-done' "$T/trace" && pass || fail "the loop must ask librarian essentials-done"
  grep -q '^librarian fill' "$T/trace" && pass || fail "essentials-done exit $rc: the fill (which takes the essentials) still runs"
  grep -q 'waiting for the grid-down essentials\|held back' "$T/log" && pass || fail "the hold-back is logged"
done
reset; ( . "$H"; export STUB_ESS_RC=0; loop_once ) >/dev/null 2>&1
grep -q '^tools' "$T/trace" && grep -q '^devstack' "$T/trace" && pass || fail "essentials held (exit 0): 5c/5d run"
# the gate is asked once per cycle, before both (not once per mirror)
[ "$(grep -c '^librarian essentials-done' "$T/trace")" = 1 ] && pass || fail "essentials-done is asked once per cycle"

# 7. exit codes -> schedule; a failing mirror never stops the cycle.
reset; ( . "$H"; export STUB_DEV_RC=3; devstack_mirror ) >/dev/null 2>&1
N=$(nextin devstack-refresh.next); [ "$N" -gt 80000 ] && [ "$N" -le 86400 ] && pass || fail "deferred (exit 3) retries in 1 day (got ${N}s)"
reset; ( . "$H"; export STUB_DEV_RC=2 STUB_TOOLS_RC=1; loop_once ) >/dev/null 2>&1
grep -q '^librarian fill' "$T/trace" && pass || fail "a failing tool refresh / dev-stack mirror must not stop the fill"
N=$(nextin devstack-refresh.next); [ "$N" -gt 80000 ] && [ "$N" -le 86400 ] && pass || fail "a failed dev-stack run retries in 1 day (got ${N}s)"
reset; ( . "$H"; export STUB_SLEEP=5; VALARK_DEVSTACK_TIMEOUT=1; devstack_mirror ) >/dev/null 2>&1
N=$(nextin devstack-refresh.next); [ "$N" -le 0 ] && pass || fail "a run cut by its time bound is due again next cycle (got ${N}s)"
grep -q 'hit its 1s bound' "$T/log" && pass || fail "the time bound is logged"
# N5: exit 1 (resolve failures) must not hide deferred files (exit 3): the summary line is logged
reset; ( . "$H"; mkdir -p "$LOG_DIR"; export STUB_DEV_RC=1; STUB_SUMMARY=1
         sed -i 's/^sys.exit/sys.stderr.write("summary: resolve_failures=1 fetch_errors=0 deferred=4\\n"); sys.exit/' "$F/lib/release_mirror.py"
         devstack_mirror ) >/dev/null 2>&1
grep -q 'exit 1) summary: resolve_failures=1 fetch_errors=0 deferred=4' "$T/log" && pass || fail "a failed run logs release_mirror's summary (exit 1 + deferred) (got: $(cat "$T/log" 2>/dev/null | tail -3))"

# 8. the VALARK_MAX_GB footprint counts the dev-stack tree.
reset
U=$( ( . "$H"; mkdir -p "$DEVSTACK_DIR"; head -c 3145728 /dev/zero > "$DEVSTACK_DIR/x.bin"; valark_data_used_bytes ) 2>/dev/null)
[ "${U:-0}" -ge 3145728 ] && pass || fail "valark_data_used_bytes must count DEVSTACK_DIR (got $U)"

echo "loop-apps-first: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
