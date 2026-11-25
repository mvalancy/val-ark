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
. "$ROOT/tests/lib/ports.sh"   # free_port / trap_signals: no fixed ports (parallel runs)
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

SRV_PID=""
T="$(mktemp -d)"; trap 'rm -rf "$T"; stop_pids "$SRV_PID"' EXIT
trap_signals
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

PORT=$(free_port); B="http://127.0.0.1:$PORT"
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
for p in %2fcontent/ %2Fdocs/ ./docs/; do   # #297: no encoded / doubled slash or dot-segment bypass
    [ "$(gcode --path-as-is "$B/$p")" = "401" ] && pass || fail "unauthed /$p must be 401 (normalized before the read-wall)"
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

# 12. Library reads stay on the local network (#297). Even in Open mode, a peer that
#     isn't LAN, tailnet or localhost can't read the library; the shell, health, auth
#     and setup stay reachable. VALARK_TEST_FORCE_PUBLIC=1 simulates that peer (fail-safe:
#     it only takes access away).
stop_pids "$SRV_PID"; SRV_PID=""
mkdir -p "$T/open"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("testpass","admin",d);a.setUseMode("open",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/open"
start_open() {   # $1 = extra env assignment (or empty)
    PORT=$(free_port); B="http://127.0.0.1:$PORT"
    env $1 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
      VALARK_STATE_DIR="$T/open" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
      "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv-open.log" 2>&1 &
    SRV_PID=$!
    for i in $(seq 1 24); do sleep 0.5; curl -s -o /dev/null --max-time 2 "$B/api/health" && return 0; done
    return 1
}
if start_open VALARK_TEST_FORCE_PUBLIC=1; then
    for p in api/status/disk api/catalog/content api/packages api/archive/content/x api/downloads/stream \
             content/ models/ tools/ sources/ docs/ DOCS/ kiwix/ app/chat/ \
             %2fdocs/ %2Fcontent/ ./docs/ api/status/disk/; do
        c=$(gcode --path-as-is "$B/$p"); [ "$c" = "403" ] && pass || fail "Open mode: public peer reading /$p must be 403 (got $c)"
    done
    c=$(gcode "$B/docs%00/x"); [ "$c" = "404" ] && pass || fail "a NUL in the path must be 404, not 500 (got $c)"
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -I "$B/docs/"); [ "$c" = "403" ] && pass || fail "Open mode: public HEAD /docs/ must be 403 (got $c)"
    # "//docs/…" is read as a protocol-relative URL (host "docs"), so it serves the shell: no doc leaks
    curl -s "$B//docs/ARCHITECTURE.md" | grep -q 'Val Ark - Architecture' && fail "public //docs/ must not leak a doc" || pass
    curl -s "$B/api/auth/status" | grep -q '"localOnly":true' && pass || fail "auth/status must tell a public peer localOnly:true (UI wall)"
    for p in "" api/health api/auth/status styles.css; do
        c=$(gcode "$B/$p"); [ "$c" = "200" ] && pass || fail "Open mode: /$p must stay reachable for a public peer (got $c)"
    done
    c=$(jpost -d '{"kind":"content","id":"x"}' "$B/api/request"); [ "$c" = "403" ] && pass || fail "public peer POST must stay 403 (got $c)"
else
    fail "open-mode server (public peer) did not start"
fi
stop_pids "$SRV_PID"; SRV_PID=""
if start_open VALARK_TEST_FORCE_REMOTE=1; then
    c=$(gcode "$B/api/status/disk"); [ "$c" = "200" ] && pass || fail "Open mode: a LAN peer can still read (got $c)"
    curl -s "$B/api/auth/status" | grep -q '"localOnly":false' && pass || fail "auth/status must tell a LAN peer localOnly:false"
else
    fail "open-mode server (LAN peer) did not start"
fi

# 13. Edge cases from the 0.1.30 review (#300): a macOS/utun tailnet, a global-IPv6 LAN
#     peer on the box's own /64, and '..' segments hidden behind encoded dots.
"$NODE" -e '
const src = require("fs").readFileSync(process.argv[1], "utf8");
const grab = n => src.match(new RegExp("function " + n + "\\([\\s\\S]*?\\n}\\n"))[0];
const f = new Function("function netIfaces(){return {};}" + grab("arrivedOnTailnet") + grab("ipv6ToBig") + grab("onLinkV6") + "return {arrivedOnTailnet, onLinkV6};")();
const ifs = {
  tailscale0: [{ address: "100.101.1.2", family: "IPv4" }],
  utun4: [{ address: "100.88.7.6", family: "IPv4" }, { address: "fd7a:115c:a1e0::5", family: "IPv6", cidr: "fd7a:115c:a1e0::5/128" }],
  utun7: [{ address: "100.96.0.3", family: "IPv4" }],                    // another VPN (WARP-like): not Tailscale
  eth9: [{ address: "203.0.113.5", family: "IPv4" },                     // a cloud / WAN uplink with a shared /64
         { address: "2001:db8:9:9::5", family: "IPv6", cidr: "2001:db8:9:9::5/64" }],
  utun1: [{ address: "fe80::1", family: "IPv6", cidr: "fe80::1/64" }],
  en0: [{ address: "10.0.0.5", family: "IPv4" },
        { address: "2001:db8:1:2::10", family: "IPv6", cidr: "2001:db8:1:2::10/64" },
        { address: "2001:db8:ffff::1", family: "IPv6", cidr: "2001:db8:ffff::1/48" }],
};
const rq = la => ({ socket: { localAddress: la } });
const ok = [
  f.arrivedOnTailnet(rq("100.101.1.2"), ifs) === true,      // linux tailscale0
  f.arrivedOnTailnet(rq("100.88.7.6"), ifs) === true,       // macOS utunN with a 100.64/10 address
  f.arrivedOnTailnet(rq("100.70.0.9"), ifs) === false,      // CGNAT uplink, not ours
  f.arrivedOnTailnet(rq("100.96.0.3"), ifs) === false,      // a utun with 100.x but no Tailscale IPv6
  f.onLinkV6("2001:db8:9:9::77", ifs) === false,            // shared /64 on an uplink with no private IPv4
  f.onLinkV6("::1:2:3:4:5:6:7:8", ifs) === false,           // 9 groups: malformed
  f.arrivedOnTailnet(rq(""), ifs) === false,
  f.onLinkV6("2001:db8:1:2::abcd", ifs) === true,           // same /64 as en0
  f.onLinkV6("2001:db8:1:3::1", ifs) === false,             // another /64
  f.onLinkV6("2001:db8:ffff:1::1", ifs) === false,          // only a /48 shared: too wide to trust
  f.onLinkV6("2606:4700::1111", ifs) === false,             // the internet
  f.onLinkV6("not-an-ip", ifs) === false,
];
process.exit(ok.every(Boolean) ? 0 : (console.error(ok), 1));
' "$ROOT/scripts/server.js" && pass || fail "tailnet (tailscale0/utun) and on-link IPv6 detection (#300)"
if start_open VALARK_TEST_FORCE_REMOTE=1; then
    for p in content/%2e./docs/ content/.%2e/docs/ content/../docs/; do
        c=$(gcode --path-as-is "$B/$p"); [ "$c" = "404" ] && pass || fail "a '..' segment behind encoded dots (/$p) must be 404 (got $c)"
    done
    # dots inside a name or in the query are not traversal (Kiwix titles like "...And_Justice")
    # (Kiwix is off here, so a request that passes the traversal check gets 503, not 404)
    for p in "kiwix/content/w/A/...And_Justice_for_All" "kiwix/search?pattern=wait..." "kiwix/content/w/A/foo..bar"; do
        c=$(gcode --path-as-is "$B/$p"); [ "$c" != "404" ] && pass || fail "/$p must not be refused as traversal (got $c)"
    done
else
    fail "open-mode server for the '..' checks did not start"
fi

echo "access: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
