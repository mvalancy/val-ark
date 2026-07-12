#!/bin/bash
###############################################################################
# Test: access-mode enforcement + admin login/session (Phase 2).
#
# On a Passworded box, "use" actions (downloads/requests) and every admin action
# require a signed session from the LAN — obtained by POSTing the admin passcode.
# The box's own console/localhost is always admin (tested separately). Here we use
# VALARK_TEST_FORCE_REMOTE=1 to simulate a LAN client (fail-safe: it only removes
# the localhost bypass), so the gate is actually exercised.
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
# Seed: an admin passcode + Passworded Use Mode.
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("testpass","admin",d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/state"

PORT=3919; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
if [ "$up" != 1 ]; then fail "server did not start on :$PORT"; echo "access: ${PASS} passed, ${FAIL} failed"; exit 1; fi
pass

jpost() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST -H 'Content-Type: application/json' "$@"; }

# 1. Un-authed "use" action is refused in Passworded mode.
[ "$(jpost -d '{"target":"all"}' "$B/api/download/content")" = "401" ] && pass || fail "unauthed use-action must be 401 in Passworded mode"
# 2. status reflects not-authed.
curl -s "$B/api/auth/status" | grep -q '"authed":false' && pass || fail "status authed:false when not signed in"
# 3. Wrong passcode is rejected.
[ "$(jpost -d '{"password":"nope"}' "$B/api/auth/login")" = "401" ] && pass || fail "wrong passcode must be 401"
# 4. Correct passcode returns a session cookie.
curl -s -c "$T/cj" -X POST -H 'Content-Type: application/json' -d '{"password":"testpass"}' "$B/api/auth/login" | grep -q '"ok":true' && pass || fail "login with correct passcode must succeed"
grep -q varksid "$T/cj" && pass || fail "login must set a varksid session cookie"
# 5. With the session, status shows authed and the use-action is allowed (not 401).
curl -s -b "$T/cj" "$B/api/auth/status" | grep -q '"authed":true' && pass || fail "status authed:true with a valid session"
c=$(jpost -b "$T/cj" -d '{"target":"all"}' "$B/api/download/content"); [ "$c" != "401" ] && pass || fail "authed use-action must pass the gate (got $c)"
# 6. Admin-only action (adduser) is refused without admin, allowed with.
[ "$(jpost -d '{"id":"chat","username":"x"}' "$B/api/service/adduser")" = "401" ] && pass || fail "adduser must be 401 without admin"
c=$(jpost -b "$T/cj" -d '{"id":"forum","username":"x"}' "$B/api/service/adduser"); [ "$c" != "401" ] && pass || fail "adduser must pass the gate for an admin (got $c)"
# 7. Logout returns a clearing cookie.
curl -s -i -X POST "$B/api/auth/logout" 2>/dev/null | tr -d '\r' | grep -i 'set-cookie' | grep -q 'varksid=;' && pass || fail "logout must clear the session cookie"
# 8. A tampered session is rejected (still 401).
[ "$(jpost -H 'Cookie: varksid=forged.deadbeef' -d '{"target":"all"}' "$B/api/download/content")" = "401" ] && pass || fail "forged session must be rejected"

echo "access: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
