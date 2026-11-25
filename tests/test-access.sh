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
. "$ROOT/tests/lib/require-cmd.sh"
[ -n "$NODE" ] || missing_cmd node "access"

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
stop_pids "$SRV_PID"; SRV_PID=""   # §12's LAN server; don't leave it running
if start_open VALARK_TEST_FORCE_REMOTE=1; then
    for p in content/%2e./docs/ content/.%2e/docs/ content/../docs/ kiwix/a/..%5cb kiwix/a/%5c%2e%2e%5cb kiwix/a/%2e%2e%5cb; do
        c=$(gcode --path-as-is "$B/$p"); [ "$c" = "404" ] && pass || fail "a '..' segment behind encoded dots (/$p) must be 404 (got $c)"
    done
    # dots inside a name or in the query are not traversal (Kiwix titles like "...And_Justice")
    # (Kiwix is off here, so a request that passes the traversal check gets 503, not 404)
    for p in "kiwix/content/w/A/...And_Justice_for_All" "kiwix/search?pattern=wait..." "kiwix/content/w/A/foo..bar"; do
        c=$(gcode --path-as-is "$B/$p"); [ "$c" != "404" ] && pass || fail "/$p must not be refused as traversal (got $c)"
    done
    # the proxies forward the raw URL, so a path that only looks like /kiwix or /app after
    # decoding or cleaning is refused (0.1.31 Gate-2 follow-up)
    for p in "kiwix/./a" "kiwix//a" "%6biwix/a" "app/chat/./x" "%61pp/chat/x" "kiwix%2Fa" "app/chat%2Fx"; do
        c=$(gcode --path-as-is "$B/$p"); [ "$c" = "404" ] && pass || fail "/$p must be 404 before the proxy (got $c)"
    done
else
    fail "open-mode server for the '..' checks did not start"
fi
stop_pids "$SRV_PID"; SRV_PID=""

# 14. Use Mode from the web UI (#303): POST /api/setup/usemode is admin-only, refuses a
#     gated mode until an admin passcode exists, and switching really engages the wall.
"$NODE" -e '
const a=require(process.argv[1]), c=require(process.argv[2]), d=process.argv[3], d2=process.argv[4];
let refused=false; try { a.setUseMode("passworded", d); } catch (e) { refused=/admin passcode/.test(e.message); }
const r=c.commission(d2,{name:"box",useMode:"accounts"},{trusted:true});
process.exit(refused && a.status(d).useMode==="open" && r.error && !c.isCommissioned(d2) && a.status(d2).useMode==="open" ? 0 : 1);
' "$ROOT/scripts/lib/auth.js" "$ROOT/scripts/lib/commission.js" "$T/um-nopass-unit" "$T/um-wiz-unit" \
  && pass || fail "setUseMode + commission refuse a gated mode with no admin passcode"
start_um() {   # $1 = state dir, $2 = extra env assignment (or empty)
    PORT=$(free_port); B="http://127.0.0.1:$PORT"
    env $2 VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
      VALARK_STATE_DIR="$1" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
      "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv-um.log" 2>&1 &
    SRV_PID=$!
    for i in $(seq 1 24); do sleep 0.5; curl -s -o /dev/null --max-time 2 "$B/api/health" && return 0; done
    return 1
}
mode_now() { curl -s "$B/api/auth/status" | grep -o '"useMode":"[a-z]*"'; }
mkdir -p "$T/um" "$T/um-nopass"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("testpass","admin",d);a.setUseMode("open",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/um"
# 14a. A LAN peer: un-authed is refused; a signed-in admin switches and the wall engages.
if start_um "$T/um" VALARK_TEST_FORCE_REMOTE=1; then
    [ "$(jpost -d '{"mode":"passworded"}' "$B/api/setup/usemode")" = "401" ] && pass || fail "usemode from an un-authed LAN peer must be 401"
    mode_now | grep -q '"open"' && pass || fail "a refused usemode must leave the mode Open"
    [ "$(gcode "$B/api/status/disk")" = "200" ] && pass || fail "Open: a LAN peer reads before the switch"
    curl -s -c "$T/cj-um" -X POST -H 'Content-Type: application/json' -d '{"password":"testpass"}' "$B/api/auth/login" | grep -q '"ok":true' \
      && pass || fail "LAN admin login for the usemode checks"
    [ "$(jpost -b "$T/cj-um" -d '{"mode":"sideways"}' "$B/api/setup/usemode")" = "400" ] && pass || fail "an invalid Use Mode must be 400"
    [ "$(jpost -b "$T/cj-um" -d '{}' "$B/api/setup/usemode")" = "400" ] && pass || fail "a missing Use Mode must be 400"
    [ "$(jpost -b "$T/cj-um" -d '{"mode":"passworded"}' "$B/api/setup/usemode")" = "200" ] && pass || fail "a signed-in admin must be able to set Passworded"
    mode_now | grep -q '"passworded"' && pass || fail "auth/status must report Passworded after the switch"
    [ "$(gcode "$B/api/status/disk")" = "401" ] && pass || fail "the read-wall must engage right after switching to Passworded"
    [ "$(jpost -d '{"target":"all"}' "$B/api/download/content")" = "401" ] && pass || fail "use-actions must need sign-in after switching to Passworded"
    [ "$(gcode -b "$T/cj-um" "$B/api/status/disk")" = "200" ] && pass || fail "the admin's session must survive the switch (no needless rotation)"
    grep -q '\[access\] Use Mode changed: open -> passworded' "$T/srv-um.log" && pass || fail "the Use Mode change must be logged"
    [ "$(jpost -b "$T/cj-um" -d '{"mode":"accounts"}' "$B/api/setup/usemode")" = "200" ] && pass || fail "a signed-in admin must be able to set Accounts"
    [ "$(gcode "$B/api/status/disk")" = "401" ] && pass || fail "the read-wall must stay up in Accounts"
    [ "$(jpost -b "$T/cj-um" -d '{"mode":"open"}' "$B/api/setup/usemode")" = "200" ] && pass || fail "a signed-in admin must be able to go back to Open"
    [ "$(gcode "$B/api/status/disk")" = "200" ] && pass || fail "Open again: un-authed LAN reads must be allowed"
else
    fail "usemode server (LAN peer) did not start"
fi
stop_pids "$SRV_PID"; SRV_PID=""
# 14b. A public peer is refused before any auth check.
if start_um "$T/um" VALARK_TEST_FORCE_PUBLIC=1; then
    [ "$(jpost -d '{"mode":"passworded"}' "$B/api/setup/usemode")" = "403" ] && pass || fail "usemode from a public peer must be 403"
    mode_now | grep -q '"open"' && pass || fail "a public peer must not change the mode"
else
    fail "usemode server (public peer) did not start"
fi
stop_pids "$SRV_PID"; SRV_PID=""
# 14c. The box itself (localhost = admin) with NO admin passcode: Open is fine, a gated
#      mode is refused (nobody on the LAN could sign in).
if start_um "$T/um-nopass" ""; then
    [ "$(jpost -d '{"mode":"passworded"}' "$B/api/setup/usemode")" = "409" ] && pass || fail "Passworded with no admin passcode must be refused (409)"
    [ "$(jpost -d '{"mode":"accounts"}' "$B/api/setup/usemode")" = "409" ] && pass || fail "Accounts with no admin passcode must be refused (409)"
    mode_now | grep -q '"open"' && pass || fail "a refused gated mode must leave the box Open"
    [ "$(jpost -d '{"mode":"open"}' "$B/api/setup/usemode")" = "200" ] && pass || fail "localhost admin may set Open with no passcode"
else
    fail "usemode server (no passcode) did not start"
fi
stop_pids "$SRV_PID"; SRV_PID=""
# 14d. Safe Mode: a corrupt auth.json must never be overwritten by a mode change (it would
#      be read as defaults and written back, erasing the admin passcode) — not from
#      Settings on the box itself, and not from `valark usemode` (auth.js setmode).
mkdir -p "$T/um-corrupt"
printf '{corrupt' > "$T/um-corrupt/auth.json"; cp "$T/um-corrupt/auth.json" "$T/auth-corrupt.orig"
if start_um "$T/um-corrupt" ""; then
    c=$(curl -s -o "$T/um-corrupt.out" -w '%{http_code}' --max-time 6 -X POST -H 'Content-Type: application/json' -d '{"mode":"open"}' "$B/api/setup/usemode")
    [ "$c" = "409" ] && pass || fail "Safe Mode: usemode from localhost must be 409 (got $c)"
    grep -qi 'safe mode' "$T/um-corrupt.out" && pass || fail "Safe Mode: the refusal must say Safe Mode ($(cat "$T/um-corrupt.out"))"
    [ "$(cat "$T/um-corrupt/auth.json")" = "$(cat "$T/auth-corrupt.orig")" ] && pass || fail "Safe Mode: Settings must leave the corrupt auth.json untouched"
else
    fail "usemode server (corrupt auth.json) did not start"
fi
stop_pids "$SRV_PID"; SRV_PID=""
VALARK_STATE_DIR="$T/um-corrupt" "$NODE" "$ROOT/scripts/lib/auth.js" setmode open >"$T/cli-corrupt.out" 2>&1 \
  && fail "Safe Mode: valark usemode must fail on a corrupt auth.json" || pass
grep -q 'corrupt' "$T/cli-corrupt.out" && pass || fail "Safe Mode: valark usemode must say auth.json is corrupt"
[ "$(cat "$T/um-corrupt/auth.json")" = "$(cat "$T/auth-corrupt.orig")" ] && pass || fail "Safe Mode: valark usemode must leave the corrupt auth.json untouched"
# 14e. `valark usemode` logs the change the same way Settings does (stderr line).
VALARK_STATE_DIR="$T/um" "$NODE" "$ROOT/scripts/lib/auth.js" setmode passworded >"$T/cli-um.out" 2>"$T/cli-um.err" \
  && grep -q '\[access\] Use Mode changed: open -> passworded (by valark usemode' "$T/cli-um.err" \
  && pass || fail "valark usemode must log the change on stderr"

# 15. CSRF (#314): a web page elsewhere can't POST, even to the box's own localhost (which
#     counts as Admin). Same-origin browser POSTs and header-less clients (curl, CLI) work.
stop_pids "$SRV_PID"; SRV_PID=""
if start_open ""; then
    xpost() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST "$@" "$B/api/maintenance/repair"; }
    c=$(xpost -H 'Origin: http://evil.example' -H 'Content-Type: text/plain' --data '{}'); [ "$c" = "403" ] && pass || fail "cross-origin POST from localhost must be 403 (got $c)"
    c=$(xpost -H 'Origin: null' --data '{}'); [ "$c" = "403" ] && pass || fail "Origin: null POST must be 403 (got $c)"
    c=$(xpost -H "Origin: http://localhost:1" --data '{}'); [ "$c" = "403" ] && pass || fail "another local port is another origin: 403 (got $c)"
    c=$(xpost -H 'Sec-Fetch-Site: cross-site' --data '{}'); [ "$c" = "403" ] && pass || fail "Sec-Fetch-Site: cross-site must be 403 (got $c)"
    c=$(xpost -H 'Sec-Fetch-Site: same-site' --data '{}'); [ "$c" = "403" ] && pass || fail "Sec-Fetch-Site: same-site (another port) must be 403 (got $c)"
    c=$(xpost -H "Origin: $B" -H 'Content-Type: application/json' --data '{}'); [ "$c" != "403" ] && pass || fail "same-origin POST must be accepted (got $c)"
    c=$(xpost -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' --data '{}'); [ "$c" != "403" ] && pass || fail "Sec-Fetch-Site: same-origin must be accepted (got $c)"
    c=$(xpost -H 'Content-Type: application/json' --data '{}'); [ "$c" != "403" ] && pass || fail "a header-less client (curl, CLI) must still work (got $c)"
    # review of #316: no CORS for other localhost origins; DNS rebinding; scheme + port spelling
    h=$(curl -s -D - -o /dev/null -H 'Origin: http://localhost:5173' "$B/api/setup/recovery-card" | tr -d '\r' | grep -i '^access-control-allow-origin' || true)
    [ -z "$h" ] && pass || fail "another localhost origin must not get CORS access ($h)"
    c=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: rebind.evil.example' "$B/api/health"); [ "$c" = "421" ] && pass || fail "a foreign Host name must be 421 (got $c)"
    for hn in "evil.com@127.0.0.1" "evil.com%2elocal" "evil.com.local.attacker.com" "127.0.0.1.nip.io"; do
        c=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $hn" "$B/api/health"); [ "$c" = "421" ] && pass || fail "Host $hn must be 421 (got $c)"
    done
    for hn in valark.local ark.lan myark x.ts.net "[::1]" valark.local. ark.fritz.box "[fe80::1%25eth0]"; do
        c=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $hn" "$B/api/health"); [ "$c" = "200" ] && pass || fail "Host $hn must be served (got $c)"
    done
    c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: valark.local:80' -H 'Origin: http://valark.local' -H 'Content-Type: application/json' --data '{}' "$B/api/maintenance/repair"); [ "$c" != "403" ] && pass || fail "Host with an explicit default port matches its Origin (got $c)"
    c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: valark.local' -H 'Origin: https://valark.local' --data '{}' "$B/api/maintenance/repair"); [ "$c" = "403" ] && pass || fail "an https Origin on a plain-http request must be 403 (got $c)"
    c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: [fe80::1%25eth0]:80' -H 'Origin: http://[fe80::1%25eth0]' -H 'Content-Type: application/json' --data '{}' "$B/api/maintenance/repair"); [ "$c" != "403" ] && [ "$c" != "421" ] && pass || fail "a zone-id IPv6 same-origin POST must reach the endpoint (got $c)"
    c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: [fe80::1%25eth0]:80' -H 'Origin: http://[fe80::1%25wlan0]' -H 'Content-Type: application/json' --data '{}' "$B/api/maintenance/repair"); [ "$c" = "403" ] && pass || fail "a different IPv6 zone is another origin: 403 (got $c)"
else
    fail "open-mode server for the CSRF checks did not start"
fi
# The TLS domain: the exact name is served; one label under it only when it's a private name
# (the local CA's *.<tls> cert); a real domain or public suffix is never trusted wholesale.
tls_host() {   # $1 = TLS domain, $2 = Host, $3 = expected code
    stop_pids "$SRV_PID"; SRV_PID=""
    if start_open "VALARK_TLS_DOMAIN=$1"; then
        c=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $2" "$B/api/health"); [ "$c" = "$3" ] && pass || fail "TLS domain $1: Host $2 must be $3 (got $c)"
    else fail "server with VALARK_TLS_DOMAIN=$1 did not start"; fi
}
tls_host ark.example.org ark.example.org 200
tls_host ark.example.org lib.ark.example.org 421
tls_host com evil.com 421
tls_host co.uk evil.co.uk 421
tls_host ark.home.arpa lib.ark.home.arpa 200
tls_host myark.lan a.b.myark.lan 200

echo "access: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
