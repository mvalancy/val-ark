#!/bin/bash
###############################################################################
# Test: the setup wizard keeps its promises (issue #306).
#
#   * scripts/lib/mdns.sh publishes <name>.local when avahi is there (a kept-up
#     avahi-publish child, fd 8 closed), says why when it isn't, and treats a
#     hostname that already equals the name as "native";
#   * loop.sh runs it each cycle (step 2h) with fd 8 closed;
#   * server.js: boxAddress() is the one place that picks <name>.local or the LAN IP,
#     and the wizard state, the recovery card and the Health detail all carry it;
#     commissioning starts ONE `loop.sh once` when no cron entry exists (fixed argv,
#     fd 8 closed) and not when the loop is installed; POST /api/setup/loop-install
#     is admin-only, same-origin, and runs exactly `loop.sh install 30`.
#
# Everything is stubbed: avahi-publish (VALARK_MDNS_PUBLISH), the avahi-daemon check
# (VALARK_MDNS_DAEMON_CMD), crontab (a stub first on PATH) and loop.sh
# (VALARK_TEST_LOOP_SH records its argv; no real cycle runs). Every server and stub
# publisher started here is stopped on exit.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/ports.sh"
. "$ROOT/tests/lib/require-cmd.sh"
require_python3 "setup promises (free_port)"
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || missing_cmd node "setup promises"
require_cmd curl "setup promises"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
MDNS="$ROOT/scripts/lib/mdns.sh"

T="$(mktemp -d)"; SRV_PID=""
stop_publishers() { local f p; for f in "$T"/*/mdns.pid "$T"/*/*/mdns.pid; do [ -f "$f" ] || continue; p=$(head -1 "$f" | tr -cd '0-9'); [ -n "$p" ] && kill "$p" 2>/dev/null; done; return 0; }
trap 'stop_pids "$SRV_PID"; stop_publishers; rm -rf "$T"' EXIT
trap_signals
HAVE_PROC_FD=0; [ -e /proc/self/fd/0 ] && HAVE_PROC_FD=1

bash -n "$MDNS" && pass || fail "mdns.sh must be valid bash"

# --- stubs --------------------------------------------------------------------
mkdir -p "$T/bin"
# avahi-publish: records its argv + whether fd 8 reached it, then stays up.
cat > "$T/bin/avahi-publish" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PUB_REC"
if [ -e /proc/self/fd/8 ]; then echo open; else echo closed; fi >> "$PUB_FD"
while :; do sleep 1; done
EOF
# A publisher that dies at once (avahi's "Local name collision").
cat > "$T/bin/avahi-publish-dies" <<'EOF'
#!/bin/bash
echo "Failed to add address: Local name collision"; exit 1
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/daemon-up"
# crontab: `-l` prints $CRONTAB_FILE (exit 1 "no crontab" when it doesn't exist).
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-l" ] || exit 1
[ -f "$CRONTAB_FILE" ] || { echo "no crontab for this user" >&2; exit 1; }
cat "$CRONTAB_FILE"
EOF
# loop.sh: records argv + fd 8; `install` writes a tagged entry like cron_install.
cat > "$T/bin/loop.sh" <<'EOF'
#!/bin/bash
{ printf 'argv=%s\n' "$*"; if [ -e /proc/self/fd/8 ]; then echo fd8=open; else echo fd8=closed; fi; } >> "$LOOP_REC"
[ "$1" = install ] && echo "*/$2 * * * * bash loop.sh once # val-ark-loop" >> "$CRONTAB_FILE"
exit 0
EOF
chmod +x "$T/bin/"*
jget() { "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v;try{v=JSON.parse(s)}catch(e){process.stdout.write("<bad json>");return}for(const k of process.argv[1].split("."))v=v==null?undefined:v[k];process.stdout.write(v===undefined?"<undef>":typeof v==="object"?JSON.stringify(v):String(v))})' "$1"; }
settings() { mkdir -p "$1"; printf '{\n  "name": "%s",\n  "commissionedAt": "2026-01-01T00:00:00Z"\n}\n' "$2" > "$1/settings.json"; }

# --- 1. mdns.sh: avahi absent / daemon stopped / no publisher --------------------
S="$T/m1"; settings "$S" "My Box"
OUT=$(VALARK_MDNS_PUBLISH=none VALARK_MDNS_DAEMON_CMD=none VALARK_MDNS_IP=10.0.0.5 VALARK_MDNS_OS=Linux bash "$MDNS" ensure "$S")
[ "$(printf '%s' "$OUT" | jget state)" = unavailable ] && pass || fail "no avahi -> unavailable (got $OUT)"
printf '%s' "$OUT" | jget reason | grep -qiE 'not installed|not running' && pass || fail "no avahi -> a reason (got $OUT)"
[ "$(jget label < "$S/mdns.json")" = my-box ] && pass || fail "ensure writes mdns.json with the label"
[ ! -f "$S/mdns.pid" ] && pass || fail "nothing is published without avahi"
OUT=$(VALARK_MDNS_PUBLISH=none VALARK_MDNS_DAEMON_CMD="$T/bin/daemon-up" VALARK_MDNS_IP=10.0.0.5 VALARK_MDNS_HOSTNAME=other VALARK_MDNS_OS=Linux bash "$MDNS" check "$S")
printf '%s' "$OUT" | jget reason | grep -q 'avahi-publish is not installed' && pass || fail "daemon without avahi-publish -> says so (got $OUT)"
[ "$(printf '%s' "$OUT" | jget canPublish)" = false ] && pass || fail "no publisher -> canPublish false"

# --- 2. mdns.sh: avahi present -> one kept-up publisher, fd 8 closed -------------
S="$T/m2"; settings "$S" "My Box"
export PUB_REC="$T/pub.rec" PUB_FD="$T/pub.fd"
menv=(VALARK_MDNS_PUBLISH="$T/bin/avahi-publish" VALARK_MDNS_DAEMON_CMD="$T/bin/daemon-up" VALARK_MDNS_IP=10.0.0.5 VALARK_MDNS_HOSTNAME=otherhost VALARK_MDNS_OS=Linux VALARK_MDNS_SETTLE=0.4)
OUT=$(env "${menv[@]}" bash "$MDNS" check "$S")
[ "$(printf '%s' "$OUT" | jget state)" = available ] && [ ! -f "$PUB_REC" ] && pass || fail "check reports available and publishes nothing (got $OUT)"
OUT=$(env "${menv[@]}" bash "$MDNS" ensure "$S" 8>"$T/fake.lock")
[ "$(printf '%s' "$OUT" | jget state)" = published ] && pass || fail "avahi present -> published (got $OUT)"
[ "$(cat "$PUB_REC" 2>/dev/null)" = "-a -R my-box.local 10.0.0.5" ] && pass || fail "publisher argv is fixed: -a -R <label>.local <ip> (got $(cat "$PUB_REC" 2>/dev/null))"
if [ "$HAVE_PROC_FD" = 1 ]; then [ "$(cat "$PUB_FD")" = closed ] && pass || fail "the publisher must not inherit fd 8 (loop.lock)"; fi
P1=$(head -1 "$S/mdns.pid"); kill -0 "$P1" 2>/dev/null && pass || fail "the publisher stays up"
env "${menv[@]}" bash "$MDNS" ensure "$S" >/dev/null
[ "$(head -1 "$S/mdns.pid")" = "$P1" ] && [ "$(wc -l < "$PUB_REC")" -eq 1 ] && pass || fail "a second ensure keeps the same publisher (no respawn)"
kill "$P1"; sleep 0.3
env "${menv[@]}" bash "$MDNS" ensure "$S" >/dev/null
P2=$(head -1 "$S/mdns.pid"); [ "$P2" != "$P1" ] && kill -0 "$P2" 2>/dev/null && pass || fail "a dead publisher is restarted"
settings "$S" "Kitchen Ark"
env "${menv[@]}" bash "$MDNS" ensure "$S" >/dev/null; sleep 0.2
! kill -0 "$P2" 2>/dev/null && tail -1 "$PUB_REC" | grep -qx -- "-a -R kitchen-ark.local 10.0.0.5" && pass || fail "a renamed box replaces the publisher"
P3=$(head -1 "$S/mdns.pid")
OUT=$(env "${menv[@]}" VALARK_MDNS_HOSTNAME=kitchen-ark bash "$MDNS" ensure "$S"); sleep 0.2
[ "$(printf '%s' "$OUT" | jget state)" = native ] && ! kill -0 "$P3" 2>/dev/null && pass || fail "hostname == name -> native, our publisher stopped (got $OUT)"
OUT=$(env "${menv[@]}" VALARK_MDNS_PUBLISH="$T/bin/avahi-publish-dies" bash "$MDNS" ensure "$S")
[ "$(printf '%s' "$OUT" | jget state)" = unavailable ] && printf '%s' "$OUT" | jget reason | grep -q collision && pass || fail "a publisher that exits -> unavailable with its error (got $OUT)"
# a pid file pointing at someone else's process is never killed
sleep 300 & OTHER=$!
printf '%s\nnot-our-argv\nx\n' "$OTHER" > "$S/mdns.pid"
bash "$MDNS" stop "$S"; kill -0 "$OTHER" 2>/dev/null && pass || fail "stop must not kill a recycled pid"
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null

# --- 3. one label rule: commission.js mdnsLabel == mdns.sh -----------------------
for n in "My Box" "kitchen_ark" "--Ark--" "ARK 2" "x__ y" "!!!"; do
    S="$T/lbl"; settings "$S" "$n"
    a=$(VALARK_MDNS_PUBLISH=none VALARK_MDNS_DAEMON_CMD=none bash "$MDNS" check "$S" | jget label)
    b=$("$NODE" -e 'process.stdout.write(require(process.argv[1]).mdnsLabel(process.argv[2]))' "$ROOT/scripts/lib/commission.js" "$n")
    [ "$a" = "$b" ] && pass || fail "label rule differs for '$n': mdns.sh=$a commission.js=$b"
done

# --- 4. loop.sh step 2h runs mdns.sh ensure with fd 8 closed ----------------------
grep -q 'step "2h\. publish <name>\.local' "$ROOT/scripts/loop.sh" && grep -qE '^ *step "2h.*ensure_mdns$' "$ROOT/scripts/loop.sh" && pass || fail "loop_once must run ensure_mdns (step 2h)"
mkdir -p "$T/lp/lib"
printf '#!/bin/bash\n{ echo "$*"; if [ -e /proc/self/fd/8 ]; then echo open; else echo closed; fi; } > "%s"\necho "{\\"state\\":\\"published\\",\\"host\\":\\"x.local\\"}"\n' "$T/lp.rec" > "$T/lp/lib/mdns.sh"
{ echo '_DIR="'"$T/lp"'"; STATE_DIR="'"$T/lp/state"'"; YELLOW=""; NC=""; log(){ :; }'; awk '/^ensure_mdns\(\) \{/,/^\}/' "$ROOT/scripts/loop.sh"; echo ensure_mdns; } > "$T/lp/run.sh"
bash "$T/lp/run.sh" 8>"$T/fake.lock"
[ "$(head -1 "$T/lp.rec")" = "ensure $T/lp/state" ] && pass || fail "ensure_mdns calls mdns.sh ensure STATE_DIR (got $(head -1 "$T/lp.rec" 2>/dev/null))"
if [ "$HAVE_PROC_FD" = 1 ]; then [ "$(sed -n 2p "$T/lp.rec")" = closed ] && pass || fail "ensure_mdns must close fd 8"; fi

# --- 5. server: no avahi, no cron -> LAN IP shown, one loop.sh once started -------
start_server() {   # STATEDIR LOG ENV...
    local sd="$1" log="$2"; shift 2
    PORT=$(free_port); B="http://127.0.0.1:$PORT"
    env PATH="$T/bin:$PATH" VALARK_TEST_NO_SPAWN=1 VALARK_TEST_LOOP_SH="$T/bin/loop.sh" VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 \
        VALARK_WEB_PORT="$PORT" VALARK_HTTPS_PORT="$(free_port)" VALARK_STATE_DIR="$sd" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
        VALARK_MDNS_OS=Linux VALARK_MDNS_IP=10.0.0.5 VALARK_MDNS_HOSTNAME=otherhost VALARK_MDNS_SETTLE=0.4 \
        "$@" "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$log" 2>&1 8>"$T/fake.lock" &
    SRV_PID=$!
    local i; for i in $(seq 1 30); do sleep 0.3; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && return 0; done
    return 1
}
mkdir -p "$T/content/zim" "$T/models"
export LOOP_REC="$T/loop.rec" CRONTAB_FILE="$T/crontab.txt"
rm -f "$LOOP_REC" "$CRONTAB_FILE"
if start_server "$T/s1" "$T/srv1.log" VALARK_MDNS_PUBLISH=none VALARK_MDNS_DAEMON_CMD=none; then
    sleep 0.5   # the boot-time mdns check
    ST=$(curl -s --max-time 5 "$B/api/setup/state")
    [ "$(printf '%s' "$ST" | jget access.canPublish)" = false ] && [ "$(printf '%s' "$ST" | jget access.mdns)" = false ] && pass || fail "wizard state: .local not possible without avahi (got $ST)"
    printf '%s' "$ST" | jget access.reason | grep -qiE 'not installed|not running' && pass || fail "wizard state says why .local is unavailable"
    R=$(curl -s --max-time 15 -H 'Content-Type: application/json' -d '{"name":"My Box"}' "$B/api/setup/commission")
    [ "$(printf '%s' "$R" | jget ok)" = true ] && pass || fail "localhost commissions (got $R)"
    [ "$(printf '%s' "$R" | jget fill.started)" = true ] && [ "$(printf '%s' "$R" | jget fill.loopInstalled)" = false ] && pass || fail "no cron -> the first fill starts (got $R)"
    IPU=$(printf '%s' "$R" | jget access.ipUrl); URL=$(printf '%s' "$R" | jget access.url)
    if [ "$IPU" != null ] && [ "$IPU" != "<undef>" ]; then
        [ "$URL" = "$IPU" ] && printf '%s' "$URL" | grep -qE "^http://[0-9.]+:$PORT/$" && pass || fail "no mDNS -> the address is the LAN IP (url=$URL ipUrl=$IPU)"
    else
        echo "  (no private IPv4 on this host: the LAN-IP pick falls back to the .local URL)"; pass
    fi
    [ "$(printf '%s' "$R" | jget access.mdns)" = false ] && pass || fail "commission response must not claim .local"
    for i in $(seq 1 20); do [ -s "$LOOP_REC" ] && break; sleep 0.2; done
    [ "$(sed -n 1p "$LOOP_REC" 2>/dev/null)" = "argv=once" ] && pass || fail "the fill is exactly 'loop.sh once' (got $(cat "$LOOP_REC" 2>/dev/null))"
    if [ "$HAVE_PROC_FD" = 1 ]; then [ "$(sed -n 2p "$LOOP_REC")" = fd8=closed ] && pass || fail "the spawned loop must not inherit fd 8"; fi
    [ "$(grep -c '^argv=' "$LOOP_REC")" = 1 ] && pass || fail "exactly one loop.sh started"
    [ "$(jget started < "$T/s1/first-fill.json")" = true ] && pass || fail "first-fill.json records the start"
    ST=$(curl -s --max-time 5 "$B/api/setup/state")
    printf '%s' "$ST" | jget fill.startedAt | grep -qE '^20[0-9]{2}-' && pass || fail "setup state carries fill.startedAt for Home (got $ST)"
    CARD=$(curl -s --max-time 5 "$B/api/setup/recovery-card")
    [ "$(printf '%s' "$CARD" | jget address)" = "$URL" ] && pass || fail "the recovery card shows the same address as setup (got $CARD)"
    printf '%s' "$CARD" | jget mdnsNote | grep -q 'my-box.local is unavailable' && pass || fail "the recovery card says .local is unavailable (got $CARD)"
    H=$(curl -s --max-time 5 "$B/api/status/health")
    [ "$(printf '%s' "$H" | jget access.url)" = "$URL" ] && [ "$(printf '%s' "$H" | jget fill.loopInstalled)" = false ] && pass || fail "Health carries the same address + loop state"
    # loop-install: same-origin rules (#316), fixed argv
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Origin: http://evil.example' "$B/api/setup/loop-install")
    [ "$c" = 403 ] && pass || fail "cross-site loop-install must be 403 (got $c)"
    [ "$(grep -c '^argv=install' "$LOOP_REC")" = 0 ] && pass || fail "a refused loop-install runs nothing"
    R=$(curl -s --max-time 10 -X POST -H "Origin: http://127.0.0.1:$PORT" "$B/api/setup/loop-install")
    [ "$(printf '%s' "$R" | jget loopInstalled)" = true ] && pass || fail "admin loop-install (Origin = Host) installs (got $R)"
    grep -qx 'argv=install 30' "$LOOP_REC" && pass || fail "loop-install runs exactly 'loop.sh install 30' (got $(cat "$LOOP_REC"))"
    [ "$(curl -s --max-time 5 "$B/api/setup/state" | jget fill.loopInstalled)" = true ] && pass || fail "setup state sees the cron entry after install"
else
    fail "server 1 did not start (see srv1.log)"; cat "$T/srv1.log" >&2
fi
stop_pids "$SRV_PID"; SRV_PID=""

# --- 6. loop-install is admin-only (a LAN peer on a Passworded box) ---------------
rm -f "$LOOP_REC" "$CRONTAB_FILE"
settings "$T/s2" "box"
"$NODE" -e 'const a=require(process.argv[1]);a.setPassword("setup-pass-1","admin",process.argv[2]);a.setUseMode("passworded",process.argv[2]);' "$ROOT/scripts/lib/auth.js" "$T/s2"
if start_server "$T/s2" "$T/srv2.log" VALARK_TEST_FORCE_REMOTE=1 VALARK_MDNS_PUBLISH=none VALARK_MDNS_DAEMON_CMD=none; then
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$B/api/setup/loop-install")
    [ "$c" = 401 ] && pass || fail "loop-install without admin must be 401 (got $c)"
    [ ! -s "$LOOP_REC" ] && pass || fail "an un-authed loop-install runs nothing"
else
    fail "server 2 did not start (see srv2.log)"
fi
stop_pids "$SRV_PID"; SRV_PID=""

# --- 7. server: avahi present + cron installed -> .local, no extra fill -----------
rm -f "$LOOP_REC" "$PUB_REC"
echo "*/30 * * * * bash loop.sh once # val-ark-loop" > "$CRONTAB_FILE"
if start_server "$T/s3" "$T/srv3.log" VALARK_MDNS_PUBLISH="$T/bin/avahi-publish" VALARK_MDNS_DAEMON_CMD="$T/bin/daemon-up"; then
    sleep 0.5
    [ "$(curl -s --max-time 5 "$B/api/setup/state" | jget access.canPublish)" = true ] && pass || fail "wizard state: this box can publish .local"
    R=$(curl -s --max-time 15 -H 'Content-Type: application/json' -d '{"name":"Kitchen Ark"}' "$B/api/setup/commission")
    [ "$(printf '%s' "$R" | jget access.mdns)" = true ] && [ "$(printf '%s' "$R" | jget access.url)" = "http://kitchen-ark.local:$PORT/" ] && pass || fail "avahi present -> http://<name>.local (got $R)"
    [ "$(cat "$PUB_REC" 2>/dev/null)" = "-a -R kitchen-ark.local 10.0.0.5" ] && pass || fail "commissioning published <name>.local (got $(cat "$PUB_REC" 2>/dev/null))"
    [ "$(printf '%s' "$R" | jget fill.loopInstalled)" = true ] && [ "$(printf '%s' "$R" | jget fill.started)" = false ] && pass || fail "cron installed -> no extra fill (got $R)"
    sleep 0.5; [ ! -s "$LOOP_REC" ] && pass || fail "cron installed -> loop.sh not started"
    CARD=$(curl -s --max-time 5 "$B/api/setup/recovery-card")
    [ "$(printf '%s' "$CARD" | jget address)" = "http://kitchen-ark.local:$PORT/" ] && [ -z "$(printf '%s' "$CARD" | jget mdnsNote)" ] && pass || fail "recovery card shows .local when it answers (got $CARD)"
    # the publisher dies -> the server stops promising .local
    kill "$(head -1 "$T/s3/mdns.pid")" 2>/dev/null; sleep 0.3
    [ "$(curl -s --max-time 5 "$B/api/status/health" | jget access.mdns)" = false ] && pass || fail "a dead publisher -> .local no longer promised"
else
    fail "server 3 did not start (see srv3.log)"; cat "$T/srv3.log" >&2
fi
stop_pids "$SRV_PID"; SRV_PID=""
sleep 1   # let a restart the server triggered settle before stopping publishers
stop_publishers

echo "setup-promises: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
