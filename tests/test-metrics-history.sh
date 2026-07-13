#!/bin/bash
###############################################################################
# Test: metrics history ring buffer (roadmap Phase 6b, part 2).
#
# The zero-dep server samples getHostMetrics() into a capped on-disk ring
# (state/metrics-history.jsonl) and serves it at GET /api/status/metrics/history
# for the Health page's sparklines — NO daemon, NO token, NO outbound call. Empty
# on a fresh box → 200 {source:'ring',series:[]}, never 500. Read-gated by the
# /api/status/ prefix. ?window is allowlist-mapped (never a path/index).
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

start_srv() { # $1=port $2=statedir  (extra env — METRICS_SAMPLE_MS/FORCE_REMOTE — inherited from caller prefix)
    VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 \
      VALARK_WEB_PORT="$1" VALARK_STATE_DIR="$2" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
      "$NODE" "$ROOT/scripts/server.js" "$1" >"$T/srv.$1.log" 2>&1 &
    SRV_PID=$!
    for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "http://127.0.0.1:$1/api/health" >/dev/null 2>&1 && return 0; done
    return 1
}

# --- 1. EMPTY box: history is 200 {source:ring, series:[]}, never 500 ---------
PORT=3933
VALARK_METRICS_SAMPLE_MS=999999 start_srv "$PORT" "$T/state"
[ $? -eq 0 ] && pass || { fail "server did not start"; echo "metrics-history: $PASS passed, $FAIL failed"; exit 1; }
B="http://127.0.0.1:$PORT"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$B/api/status/metrics/history")
[ "$code" = "200" ] && pass || fail "empty history must be 200 (got $code)"
curl -s "$B/api/status/metrics/history" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.exit(j.source==="ring"&&Array.isArray(j.series)?0:1)})' \
    && pass || fail "empty history must be {source:ring, series:[]}"
# 1b. ?window allowlist: garbage falls back, bounded, still 200 (never a path/index).
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$B/api/status/metrics/history?window=garbage999")" = "200" ] && pass || fail "garbage ?window must fall back to 200"
curl -s "$B/api/status/metrics/history?window=day" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.exit(JSON.parse(s).window==="day"?0:1)})' && pass || fail "?window=day must resolve to day"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 2. FIXTURE: a seeded ring file is read back as a numeric series ----------
mkdir -p "$T/s2"
{ echo '{"t":1000,"cpu":10,"mem":20,"load":0.5,"rx":100,"tx":50,"temp":40}'
  echo '{"t":2000,"cpu":30,"mem":22,"load":0.7,"rx":200,"tx":60,"temp":41}'
  echo '{"t":3000,"cpu":25,"mem":21,"load":0.6,"rx":150,"tx":55,"temp":42}'; } > "$T/s2/metrics-history.jsonl"
PORT=3934
VALARK_METRICS_SAMPLE_MS=999999 start_srv "$PORT" "$T/s2"
B="http://127.0.0.1:$PORT"
curl -s "$B/api/status/metrics/history" | "$NODE" -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const j=JSON.parse(s);
    const ok = j.series.length===3
      && j.series.every(r=>typeof r.t==="number"&&typeof r.cpu==="number"&&isFinite(r.cpu))
      && j.series[0].t < j.series[2].t;   // monotonic
    process.exit(ok?0:1);
  });' && pass || fail "seeded history must read back a monotonic numeric series"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 3. SELF-SAMPLER: the server fills the ring on its own cadence ------------
mkdir -p "$T/s3"
PORT=3935
VALARK_METRICS_SAMPLE_MS=200 start_srv "$PORT" "$T/s3"
B="http://127.0.0.1:$PORT"
grew=0; for i in $(seq 1 20); do
    n=$(curl -s "$B/api/status/metrics/history" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).series.length)}catch(e){console.log(0)}})')
    [ "${n:-0}" -ge 2 ] 2>/dev/null && { grew=1; break; }; sleep 0.5
done
[ "$grew" = 1 ] && pass || fail "self-sampler must grow the ring on its own"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 4. READ-GATE: /api/status/ prefix gates history on a Passworded LAN ------
mkdir -p "$T/s4"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("histpass",("admin"),d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/s4"
PORT=3936
VALARK_TEST_FORCE_REMOTE=1 VALARK_METRICS_SAMPLE_MS=999999 start_srv "$PORT" "$T/s4"
B="http://127.0.0.1:$PORT"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$B/api/status/metrics/history")" = "401" ] && pass || fail "history must be read-gated (401) on a Passworded LAN"

echo "metrics-history: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
