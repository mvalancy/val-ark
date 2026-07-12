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
# Session-crypto unit checks: IP-binding, tamper/expiry rejection, rotate = sign-out
# everywhere, and the >=8-char passcode minimum.
"$NODE" -e '
const a=require(process.argv[1]); const d=process.argv[2]; require("fs").mkdirSync(d,{recursive:true});
a.setPassword("unittest8","admin",d);
const t=a.issueSession(d,60000,"10.0.0.5");
let ok = a.verifySession(t,d,"10.0.0.5")===true
      && a.verifySession(t,d,"10.0.0.9")===false                       // IP-bound
      && a.verifySession(t.slice(0,-2)+"zz",d,"10.0.0.5")===false       // tampered
      && a.verifySession(a.issueSession(d,-1,"10.0.0.5"),d,"10.0.0.5")===false; // expired
a.rotateSessionSecret(d); ok = ok && a.verifySession(t,d,"10.0.0.5")===false;    // rotate invalidates
let minok=false; try{ a.setPassword("short7x","admin",d); }catch(e){ minok=/8 characters/.test(e.message); }
process.exit(ok && minok ? 0 : 1);
' "$ROOT/scripts/lib/auth.js" "$T/unit" && pass || fail "session crypto: IP-bind/tamper/expiry/rotate + >=8 passcode"

# Seed: an admin passcode + Passworded Use Mode.
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("testpass","admin",d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/state"

PORT=3919; B="http://127.0.0.1:$PORT"
VALARK_TEST_FORCE_REMOTE=1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
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
# 6b. /api/setup/profile (download-priorities) is admin-only too.
[ "$(jpost -d '{"profile":"ai"}' "$B/api/setup/profile")" = "401" ] && pass || fail "setup/profile must be 401 without admin"
c=$(jpost -b "$T/cj" -d '{"profile":"ai"}' "$B/api/setup/profile"); [ "$c" != "401" ] && pass || fail "setup/profile must pass the gate for an admin (got $c)"
# 6c. /api/maintenance/repair (one-click self-heal) is admin-only too.
[ "$(jpost -d '{}' "$B/api/maintenance/repair")" = "401" ] && pass || fail "maintenance/repair must be 401 without admin"
c=$(jpost -b "$T/cj" -d '{}' "$B/api/maintenance/repair"); [ "$c" != "401" ] && pass || fail "maintenance/repair must pass the gate for an admin (got $c)"
# 7. Logout returns a clearing cookie.
curl -s -i -X POST "$B/api/auth/logout" 2>/dev/null | tr -d '\r' | grep -i 'set-cookie' | grep -q 'varksid=;' && pass || fail "logout must clear the session cookie"
# 8. A tampered session is rejected (still 401).
[ "$(jpost -H 'Cookie: varksid=forged.deadbeef' -d '{"target":"all"}' "$B/api/download/content")" = "401" ] && pass || fail "forged session must be rejected"

# 9. Read-wall: content reads are gated for un-authed LAN visitors in Passworded mode,
#    but the shell/auth/health stay open so the wall can render + you can sign in.
gcode() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
[ "$(gcode "$B/api/status/disk")" = "401" ] && pass || fail "unauthed content read must be 401 (read-wall)"
[ "$(gcode "$B/api/health")" = "200" ] && pass || fail "/api/health must stay open (wall reachable)"
[ "$(gcode "$B/api/auth/status")" = "200" ] && pass || fail "/api/auth/status must stay open"
[ "$(gcode "$B/")" = "200" ] && pass || fail "static shell / must stay open so the wall can render"
c=$(gcode -b "$T/cj" "$B/api/status/disk"); [ "$c" = "200" ] && pass || fail "authed content read must be allowed (got $c)"

# 10. Regression (adversarial-review finding): the RAW data trees served straight from
#     ROOT by the static router must be gated too — they're the same library bytes.
for p in content models tools sources assets docs; do
    [ "$(gcode "$B/$p/")" = "401" ] && pass || fail "unauthed /$p/ must be 401 (data-tree read-wall)"
done
c=$(gcode -b "$T/cj" "$B/content/"); [ "$c" != "401" ] && pass || fail "authed data-tree read must be allowed (got $c)"
# the UI shell + its assets stay open so the login wall can render
[ "$(gcode "$B/styles.css")" = "200" ] && pass || fail "/styles.css must stay open for the wall"

# 11. Recovery card + forgot-password (the one-time recovery code).
[ "$(gcode "$B/api/setup/recovery-card")" = "401" ] && pass || fail "recovery card must be admin-only (401 un-authed)"
CARD="$(curl -s -b "$T/cj" "$B/api/setup/recovery-card")"
echo "$CARD" | grep -q '"recovery"' && pass || fail "authed recovery card returns the code"
RCODE="$(printf '%s' "$CARD" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).recovery||"")}catch(e){}})')"
[ "$(jpost -d '{"code":"WRON-GWRO-NGXX","password":"brandnew9"}' "$B/api/auth/recover")" = "401" ] && pass || fail "recover with a wrong code must be 401"
RESP="$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"code\":\"$RCODE\",\"password\":\"brandnew9\"}" "$B/api/auth/recover")"
printf '%s' "$RESP" | grep -qE '"ok" ?: ?true' && pass || fail "recover with the correct code must succeed"
printf '%s' "$RESP" | grep -q '"recovery"' && pass || fail "recover returns a fresh (rotated) recovery code"
[ "$(jpost -d "{\"code\":\"$RCODE\",\"password\":\"another99\"}" "$B/api/auth/recover")" = "401" ] && pass || fail "old recovery code must be single-use (dead after use)"

echo "access: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
