#!/bin/bash
###############################################################################
# Test: Health & self-heal reporting + one-click repair (roadmap Phase 6).
#
# The loop/verify write structured self-heal reports; the server surfaces them at
# GET /api/status/health (read-gated) and exposes a one-click self-heal at
# POST /api/maintenance/repair (admin-only). This checks the report shapes, the
# composition endpoint, the access gate, and the repair contract — the last via
# VALARK_TEST_NO_SPAWN so CI never actually runs the heavy maintenance loop.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

T="$(mktemp -d)"; SRV_PID=""
trap 'rm -rf "$T"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/state" "$T/content/zim" "$T/models"

# --- 1. verify.sh serialises per-check results with component attribution -----
VAL_ARK_DATA="$ROOT" VALARK_STATE_DIR="$T/state" VALARK_WEB_PORT=1 FORCE_COLOR=0 \
    timeout 90 bash "$ROOT/scripts/verify.sh" local >/dev/null 2>&1
if [ -f "$T/state/verify.json" ]; then
    "$NODE" -e '
      const j=require(process.argv[1]);
      const ok = Array.isArray(j.checks) && typeof j.pass==="number" && typeof j.fail==="number"
              && j.checks.every(c=>c.status&&c.comp&&typeof c.label==="string");
      process.exit(ok?0:1);
    ' "$T/state/verify.json" && pass || fail "verify.json must carry a per-check {status,comp,label} array"
else fail "verify.sh must write verify.json"; fi

# --- 2. loop.sh write_health emits valid health.json + heal-events feed -------
# Drive write_health() in isolation (a full loop cycle is heavy/networked).
cat > "$T/wh.sh" <<'EOF'
set -o pipefail
export VAL_ARK_DATA="$VA"; export VALARK_STATE_DIR="$SD"
. "$RT/scripts/lib/valark-env.sh"
LINKREPORT="$STATE_DIR/linkcheck.txt"; HEALTH_JSON="$STATE_DIR/health.json"; HEAL_EVENTS_LOG="$STATE_DIR/heal-events.jsonl"
HEAL_EVENTS=("restart|Refreshed the library server" "start|Started the web server")
log(){ :; }
_hj_str(){ local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//$'\r'/}; printf '"%s"' "$s"; }
printf 'DEAD(404) http://x/a\nMISSING-ASSET logos/z.svg\n' > "$LINKREPORT"
printf '{ "ts":"t","pass":13,"fail":0,"skip":1 }\n' > "$STATE_DIR/verify.json"
EOF
awk '/^write_health\(\) \{/,/^\}/' "$ROOT/scripts/loop.sh" >> "$T/wh.sh"
echo 'write_health' >> "$T/wh.sh"
VA="$ROOT" SD="$T/state" RT="$ROOT" bash "$T/wh.sh" >/dev/null 2>&1
"$NODE" -e '
  const h=require(process.argv[1]);
  const ok = h.overall && typeof h.deadLinks==="number" && typeof h.missingAssets==="number"
          && h.verify && Array.isArray(h.repairs) && h.repairs.length===2
          && h.overall==="attention";   // a missing asset is an unresolved box fault
  process.exit(ok?0:1);
' "$T/state/health.json" && pass || fail "write_health must emit a valid health.json (overall=attention on missing asset)"
if [ -f "$T/state/heal-events.jsonl" ]; then
    "$NODE" -e 'require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").forEach(l=>JSON.parse(l))' \
        "$T/state/heal-events.jsonl" && pass || fail "heal-events.jsonl must be valid JSONL"
else fail "write_health must append to heal-events.jsonl when repairs happened"; fi

# --- 3. server composes /api/status/health from the report files -------------
PORT=3927; B="http://127.0.0.1:$PORT"
VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
[ "$up" = 1 ] && pass || { fail "server did not start on :$PORT"; echo "health: ${PASS} passed, ${FAIL} failed"; exit 1; }

HD="$(curl -s --max-time 6 "$B/api/status/health")"
echo "$HD" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.exit(j.verify&&j.heal&&Array.isArray(j.events)&&j.events.length>=1&&j.safeMode===false?0:1)})' \
    && pass || fail "/api/status/health must compose {verify,heal,events,safeMode}"

# --- 4. one-click repair is admin-only + honours the dedupe contract ---------
jpost() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST -H 'Content-Type: application/json' "$@"; }
# localhost (this caller) is admin in Open mode → allowed
R1="$(curl -s -X POST --max-time 6 "$B/api/maintenance/repair")"
echo "$R1" | grep -q '"started":true' && pass || fail "localhost admin repair must start (got: $R1)"
# immediate second call is de-duped (running) — never a second spawn
R2="$(curl -s -X POST --max-time 6 "$B/api/maintenance/repair")"
echo "$R2" | grep -qE '"started":false' && pass || fail "a repeat repair must be de-duped (got: $R2)"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 5. read-gate + admin-gate under a Passworded box (simulated LAN) --------
mkdir -p "$T/s2"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("healthpass",("admin"),d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/s2"
PORT=3928; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/s2" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv2.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
[ "$up" = 1 ] && pass || { fail "second server did not start"; echo "health: ${PASS} passed, ${FAIL} failed"; exit 1; }
# health detail is read-gated (reveals what's on the box)
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$B/api/status/health")" = "401" ] && pass || fail "/api/status/health must be read-gated on a Passworded LAN"
# repair is admin-only → 401 without a session
[ "$(jpost "$B/api/maintenance/repair")" = "401" ] && pass || fail "/api/maintenance/repair must be 401 without admin"

echo "health: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
