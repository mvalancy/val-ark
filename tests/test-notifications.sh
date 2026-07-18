#!/bin/bash
###############################################################################
# Test: Notification center endpoint (issue #69 slice 1).
#
# GET /api/status/notifications aggregates recent self-heal events
# (heal-events.jsonl) + current warning/critical conditions (selfheal.json /
# verify.json / disk / Safe Mode) into a bounded, read-gated list for the web
# UI's bell/inbox. This checks: the response shape, stable ids + severity from a
# seeded feed, the bare-box empty case (never throws), and read-gating (401 on a
# passworded LAN box). Fully offline: no network, no real data disk, no crontab.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

T="$(mktemp -d)"; SRV_PID=""
trap 'rm -rf "$T"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/bare/state" "$T/seed/state" "$T/content/zim" "$T/models"

# --- Seed a state dir with a self-heal feed + current conditions -------------
# Two events (an info restart + a warning moderation-error), a failed verify
# check (comp=models), and a missing-asset residue in the self-heal snapshot.
cat > "$T/seed/state/heal-events.jsonl" <<'EOF'
{"ts":"2026-07-18T00:00:00Z","kind":"restart","detail":"Refreshed the library server"}
{"ts":"2026-07-18T00:01:00Z","kind":"moderation-error","detail":"Could not quarantine 2 flagged upload(s)"}
EOF
cat > "$T/seed/state/selfheal.json" <<'EOF'
{"ts":"2026-07-18T00:02:00Z","overall":"attention","deadLinks":0,"missingAssets":3,"verify":{"pass":10,"fail":1,"skip":0},"repairs":[]}
EOF
cat > "$T/seed/state/verify.json" <<'EOF'
{"ts":"2026-07-18T00:02:00Z","pass":10,"fail":1,"skip":0,"checks":[{"status":"FAIL","comp":"models","label":"llm inference"},{"status":"PASS","comp":"server","label":"web api"}]}
EOF

wait_up() {  # $1=port
    local up=0 i; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "http://127.0.0.1:$1/api/health" >/dev/null 2>&1 && { up=1; break; }; done
    [ "$up" = 1 ]
}

# --- 1. Seeded box: shape + stable ids + severity ----------------------------
PORT=3995; B="http://127.0.0.1:$PORT"
VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/seed/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv-$PORT.log" 2>&1 &
SRV_PID=$!
if wait_up "$PORT"; then pass; else fail "seeded server did not start on :$PORT"; echo "notifications: ${PASS} passed, ${FAIL} failed"; exit 1; fi

N1="$(curl -s --max-time 6 "$B/api/status/notifications")"
echo "$N1" | "$NODE" -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const j=JSON.parse(s), it=j.items;
    const shapeOk = Array.isArray(it) && it.every(n =>
        typeof n.id==="string" && n.id.length>0 &&
        ["critical","warning","info"].includes(n.severity) &&
        typeof n.title==="string" && typeof n.source==="string" && "ts" in n);
    const ev   = it.filter(n => n.id.startsWith("ev-"));
    const info = ev.find(n => n.severity==="info");          // the restart event
    const modw = ev.find(n => n.severity==="warning");       // moderation-error → warning
    const vfail= it.find(n => n.id==="cond-verify-models" && n.severity==="warning");
    const miss = it.find(n => n.id==="cond-missing-assets" && n.severity==="warning");
    process.exit(shapeOk && info && modw && vfail && miss ? 0 : 1);
  });
' && pass || fail "/api/status/notifications must aggregate events + conditions with correct shape/severity (got: $N1)"

# ids are STABLE across calls (so a client-side dismissal persists across reloads)
N2="$(curl -s --max-time 6 "$B/api/status/notifications")"
"$NODE" -e '
  const a=JSON.parse(process.argv[1]).items.map(n=>n.id).sort();
  const b=JSON.parse(process.argv[2]).items.map(n=>n.id).sort();
  process.exit(a.length && JSON.stringify(a)===JSON.stringify(b) ? 0 : 1);
' "$N1" "$N2" && pass || fail "notification ids must be stable across identical reads"

# bounded: never unbounded (cap is 60)
echo "$N1" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.exit(JSON.parse(s).items.length<=60?0:1)})' \
    && pass || fail "notifications must be bounded (<=60)"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 2. Bare box: never throws, no phantom events ----------------------------
PORT=3996; B="http://127.0.0.1:$PORT"
VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/bare/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv-$PORT.log" 2>&1 &
SRV_PID=$!
if wait_up "$PORT"; then pass; else fail "bare server did not start on :$PORT"; echo "notifications: ${PASS} passed, ${FAIL} failed"; exit 1; fi
NB="$(curl -s --max-time 6 "$B/api/status/notifications")"
echo "$NB" | "$NODE" -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const it=JSON.parse(s).items;
    // A box with no state files yields no self-heal events (disk conditions depend
    // on the host, so we only assert the feed is empty + the call is well-formed).
    process.exit(Array.isArray(it) && !it.some(n=>n.id.startsWith("ev-")) ? 0 : 1);
  });
' && pass || fail "bare box must return a well-formed empty-feed list (got: $NB)"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 3. Read-gating: 401 on a passworded LAN box -----------------------------
mkdir -p "$T/pw/state"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("notifpass","admin",d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/pw/state"
PORT=3997; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/pw/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv-$PORT.log" 2>&1 &
SRV_PID=$!
if wait_up "$PORT"; then pass; else fail "passworded server did not start on :$PORT"; cat "$T/srv-$PORT.log" >&2; echo "notifications: ${PASS} passed, ${FAIL} failed"; exit 1; fi
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$B/api/status/notifications")"
[ "$CODE" = "401" ] && pass || fail "/api/status/notifications must be read-gated (401) on a passworded LAN box (got $CODE)"

echo "notifications: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
