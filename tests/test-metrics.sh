#!/bin/bash
###############################################################################
# Test: live host metrics for the Health page (roadmap Phase 6b, part 1).
#
# GET /api/status/metrics returns pure-local gauges (/proc + os + cached disk) with
# NO Telegraf/InfluxDB present — never throws, degrades every field to null off-Linux.
# CPU% and net rate are two-sample deltas (first read null, filled on the next). The
# endpoint is read-gated by the /api/status/ prefix, exactly like /api/status/disk —
# no new gate code, no new POST, no secret.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

T="$(mktemp -d)"; SRV_PID=""
trap 'rm -rf "$T"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/state" "$T/content/zim" "$T/models"   # EMPTY state — no influx, no reports

# --- server on an empty box (no telegraf/influxd anywhere) --------------------
PORT=3931; B="http://127.0.0.1:$PORT"
VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
[ "$up" = 1 ] && pass || { fail "server did not start on :$PORT"; echo "metrics: ${PASS} passed, ${FAIL} failed"; exit 1; }

# 1. shape: 200 + live source + the always-available fields, never throwing with no influx.
curl -s --max-time 6 "$B/api/status/metrics" | "$NODE" -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const m=JSON.parse(s);
    const ok = m.source==="live"
      && m.cpu && Array.isArray(m.cpu.loadavg) === (m.cpu.loadavg!==null)   // array or null
      && m.cpu.cores>0
      && m.mem && m.mem.total>0 && m.mem.used>0 && typeof m.mem.percent==="number"
      && m.disk && typeof m.disk.percent==="number"
      && m.host && typeof m.host.hostname==="string" && typeof m.host.uptime==="number";
    process.exit(ok?0:1);
  });' && pass || fail "/api/status/metrics must return live gauges (source/cpu/mem/disk/host)"

# 2. two-sample delta: the SECOND read fills cpu.percent (a number) though the first may be null.
FIRST="$(curl -s --max-time 6 "$B/api/status/metrics")"
sleep 1
SECOND="$(curl -s --max-time 6 "$B/api/status/metrics")"
echo "$SECOND" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=JSON.parse(s);process.exit(typeof m.cpu.percent==="number"?0:1)})' \
    && pass || fail "second /api/status/metrics read must fill cpu.percent (two-sample delta)"
# first read is allowed to be null (baseline) — assert it is null OR a number, never NaN/undefined
echo "$FIRST" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const p=JSON.parse(s).cpu.percent;process.exit((p===null||typeof p==="number")?0:1)})' \
    && pass || fail "first cpu.percent must be null or a number (never NaN)"

# 3. never a 500: the handler is a pure read that must not throw.
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$B/api/status/metrics")" = "200" ] && pass || fail "metrics endpoint must answer 200"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# 4. read-gate: on a Passworded LAN box it inherits the /api/status/ read-wall (401),
#    but localhost stays open — no bespoke gate, exactly like /api/status/disk.
mkdir -p "$T/s2"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("metricspass",("admin"),d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/s2"
PORT=3932; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/s2" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv2.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
[ "$up" = 1 ] && pass || { fail "second server did not start"; echo "metrics: ${PASS} passed, ${FAIL} failed"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$B/api/status/metrics")" = "401" ] && pass || fail "/api/status/metrics must be read-gated on a Passworded LAN (401)"

echo "metrics: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
