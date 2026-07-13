#!/bin/bash
###############################################################################
# Test: moderation SERVER endpoints (roadmap Phase 7 — the web door to the
# fail-closed decision core in scripts/lib/moderation.sh).
#
# Exercises the live HTTP surface with a STUB classifier (VALARK_MODERATION_CMD),
# so no model is needed:
#   GET  /api/status/moderation   — health card (enabled + runner readiness)
#   POST /api/moderation/check     — raw-body screen → {decision}; size-capped; FAIL-CLOSED
#   POST /api/setup/moderation     — admin-only toggle/tune; disabled → check skips
# The security invariants: the check reader is size-capped (over-cap → hold/413, never
# OOM/allow), an empty body holds, the settings write is admin-only, and turning the
# engine OFF makes check return skip (explicitly NOT allow-by-policy).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

SRV_PID=""
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/state" "$T/content/zim" "$T/models"

# A stub classifier standing in for a real model: emits the RAW verdict the parser
# reduces. args are "<kind> <file>"; content containing BADWORD is unsafe, else safe.
cat > "$T/stub" <<'EOF'
#!/bin/bash
if grep -q BADWORD "$2" 2>/dev/null; then echo unsafe; else echo safe; fi
EOF
chmod +x "$T/stub"

# Admin passcode so the admin-only settings write can be exercised via a session; Use
# Mode stays Open, so the "use" action (check) is reachable from the LAN without a login.
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("modtestpass","admin",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/state"

PORT=3927; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 \
  VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" VALARK_MODERATION_CMD="$T/stub" \
  VALARK_MODERATION_MAX_BYTES=4096 \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
if [ "$up" != 1 ]; then fail "server did not start on :$PORT"; echo "moderation-api: ${PASS} passed, ${FAIL} failed"; exit 1; fi
pass

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }
chk()  { curl -s --max-time 20 -X POST --data-binary "$1" "$B/api/moderation/check"; }   # $1 = body (or @file)

# --- 1. status card: default ON (fail-closed default), stub makes runner ready -----
S="$(curl -s --max-time 6 "$B/api/status/moderation")"
echo "$S" | grep -q '"enabled":true'      && pass || fail "moderation enabled ON by default (got: $S)"
echo "$S" | grep -q '"runnerReady":true'  && pass || fail "stub classifier reports runnerReady:true"
echo "$S" | grep -q '"effective":"screening"' && pass || fail "effective=screening when enabled+ready"

# --- 2. check: clean content → allow; flagged content → block ---------------------
echo "$(chk 'a perfectly nice message')" | grep -q '"decision":"allow"' && pass || fail "clean content → allow"
echo "$(chk 'contains BADWORD here')"    | grep -q '"decision":"block"' && pass || fail "flagged content → block"

# --- 3. check FAIL-CLOSED: empty body holds; over-cap holds (413), never allow -----
echo "$(chk '')" | grep -q '"decision":"hold"' && pass || fail "empty body → hold"
head -c 8000 /dev/zero > "$T/big"                                   # > 4096-byte cap
c=$(code -X POST --data-binary @"$T/big" "$B/api/moderation/check")
[ "$c" = 413 ] && pass || fail "over-cap body → 413 (got $c)"
body=$(curl -s --max-time 8 -X POST --data-binary @"$T/big" "$B/api/moderation/check")
echo "$body" | grep -q '"decision":"hold"' && pass || fail "over-cap body → hold decision (got $body)"
echo "$body" | grep -q '"decision":"allow"' && fail "over-cap MUST NEVER allow" || pass

# --- 4. settings write is ADMIN-ONLY (ADMIN_ONLY_POSTS) ---------------------------
jpost() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST -H 'Content-Type: application/json' "$@"; }
[ "$(jpost -d '{"enabled":false}' "$B/api/setup/moderation")" = "401" ] && pass || fail "setup/moderation must be 401 without admin"
curl -s -c "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"password":"modtestpass"}' "$B/api/auth/login" >/dev/null
grep -q varksid "$T/cj" && pass || fail "admin login for settings write"

# --- 5. turn OFF → check returns skip (explicitly NOT allow); status reflects off ---
curl -s -b "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"enabled":false}' "$B/api/setup/moderation" | grep -q '"enabled":false' && pass || fail "admin can disable moderation"
echo "$(chk 'contains BADWORD here')" | grep -q '"decision":"skip"' && pass || fail "disabled engine → check returns skip (not allow)"
echo "$(chk 'contains BADWORD here')" | grep -q '"decision":"block"' && fail "disabled engine must NOT block/allow — only skip" || pass
curl -s --max-time 6 "$B/api/status/moderation" | grep -q '"effective":"off"' && pass || fail "status effective=off when disabled"

# --- 6. re-enable + tune sensitivity persists -------------------------------------
curl -s -b "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"enabled":true,"sensitivity":"strict"}' "$B/api/setup/moderation" >/dev/null
curl -s --max-time 6 "$B/api/status/moderation" | grep -q '"sensitivity":"strict"' && pass || fail "sensitivity persists after re-enable"
echo "$(chk 'a perfectly nice message')" | grep -q '"decision":"allow"' && pass || fail "re-enabled engine screens again"

echo "moderation-api: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
