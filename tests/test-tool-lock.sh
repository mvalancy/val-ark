#!/bin/bash
###############################################################################
# Test: tool-mirror serialization lock (issue #55).
#
# download-tools.sh is spawned four ways with no shared lock — the loop's weekly
# `tool_refresh` (`all`), the web one-click "request tool" (librarian.sh request →
# here) and POST /api/download/tools, and manual CLI. Two runs mirroring the SAME
# tool `curl -C -` into the same .part at independent offsets, and an empty HEAD
# Content-Length lets the corrupt part be served. A whole-run flock on tools.lock
# serialises every entry point. Invariants:
#   - lock FREE: acquire succeeds (rc 0) in both bulk and single modes
#   - lock HELD, bulk (`all`): yields immediately (-n) → rc 1, then `all` exits 75
#     so the loop's tool_refresh retries instead of stamping "done"
#   - lock HELD, single (a request): waits VALARK_TOOL_LOCK_WAIT then queues → rc 1,
#     and the single-tool run exits 0 (pinned; the running mirror completes it)
#   - contention never lets a second run reach run_all/run_tool (no double-writer)
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
DL="$ROOT/scripts/download-tools.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null' EXIT
STATE="$T/state"; mkdir -p "$STATE"
LOCK="$STATE/tools.lock"
CONF="$T/empty.conf"; : > "$CONF"
DISK="$T/disk"; mkdir -p "$DISK"

# --- 0. the shipped script parses --------------------------------------------
bash -n "$DL" 2>/dev/null && pass || fail "download-tools.sh must be syntactically valid"

# --- isolated harness: the REAL extracted acquire_tools_lock -----------------
H="$T/harness.sh"
{
    echo "STATE_DIR=\"$STATE\""
    echo "TOOLS_DIR=\"$DISK/tools\""
    echo 'TOOLS_LOCK_FD=7; log_warn(){ :; }; log_info(){ :; }'
    awk '/^acquire_tools_lock\(\) \{/,/^\}/' "$DL"
    echo '"$@"'
} > "$H"
grep -q 'flock' "$H" && pass || fail "harness must contain the real acquire_tools_lock"

# --- 1. lock FREE → acquire succeeds (both modes) ----------------------------
( bash "$H" acquire_tools_lock bulk ); [ $? = 0 ] && pass || fail "bulk acquire on a free lock must succeed"
( bash "$H" acquire_tools_lock single ); [ $? = 0 ] && pass || fail "single acquire on a free lock must succeed"

# --- hold the lock from an external process ----------------------------------
flock "$LOCK" -c 'touch "'"$T"'/held"; while [ ! -f "'"$T"'/release" ]; do sleep 0.03; done' &
HOLDER=$!
for i in $(seq 1 100); do [ -f "$T/held" ] && break; sleep 0.03; done
[ -f "$T/held" ] && pass || fail "external holder must acquire tools.lock"

# --- 2. lock HELD → bulk yields (rc 1), single waits then queues (rc 1) -------
bash "$H" acquire_tools_lock bulk; [ $? = 1 ] && pass || fail "bulk acquire on a held lock must yield (rc 1)"
VALARK_TOOL_LOCK_WAIT=1 bash "$H" acquire_tools_lock single; [ $? = 1 ] && pass || fail "single acquire on a held lock must queue after the wait (rc 1)"

# --- 3. END-TO-END contention: the real dispatch exits at the lock (no DL) ----
COMMON=(VAL_ARK_CONFIG="$CONF" VAL_ARK_DATA="$DISK" VALARK_STATE_DIR="$STATE" FORCE_COLOR=0)
# 3a: `all` under contention → exit 75, run_all never reached (no banner)
out=$(env "${COMMON[@]}" bash "$DL" all 2>&1); rc=$?
[ "$rc" = 75 ] && pass || fail "download-tools.sh all under contention must exit 75 (got $rc)"
echo "$out" | grep -q 'Tool Downloader' && fail "run_all must NOT start under contention (banner appeared)" || pass
echo "$out" | grep -qi 'skipping this bulk refresh' && pass || fail "bulk contention must log the skip (got: $(echo "$out" | tail -1))"
# 3b: single tool under contention → exit 0 (queued), run_tool never reached
out=$(env "${COMMON[@]}" VALARK_TOOL_LOCK_WAIT=1 bash "$DL" btop 2>&1); rc=$?
[ "$rc" = 0 ] && pass || fail "a single-tool request under contention must exit 0/queued (got $rc)"
echo "$out" | grep -qi 'queued' && pass || fail "single contention must report 'queued'"
echo "$out" | grep -q 'Tool: btop' && fail "run_tool must NOT start under contention" || pass

# --- release + confirm the lock is grantable again ---------------------------
touch "$T/release"; wait "$HOLDER" 2>/dev/null; HOLDER=""
( bash "$H" acquire_tools_lock bulk ); [ $? = 0 ] && pass || fail "a released lock must be re-acquirable"

# --- 4. structural: the dispatch wires the lock into BOTH spawn arms ----------
disp="$(sed -n '/^case "${1:-all}" in/,/^esac/p' "$DL")"
echo "$disp" | awk '/^    all\)/,/;;/' | grep -q 'acquire_tools_lock bulk' && pass \
    || fail "the all) arm must acquire the bulk lock"
echo "$disp" | awk '/^    all\)/,/;;/' | grep -q 'exit 75' && pass \
    || fail "the all) arm must exit 75 on contention so tool_refresh retries"
echo "$disp" | awk '/^    \*\)/,/;;/' | grep -q 'acquire_tools_lock single' && pass \
    || fail "the single-tool arm must acquire the single lock"
echo "$disp" | awk '/^    \*\)/,/;;/' | grep -q 'exit 0' && pass \
    || fail "the single-tool arm must exit 0 (queued) on contention"

echo "tool-lock: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
