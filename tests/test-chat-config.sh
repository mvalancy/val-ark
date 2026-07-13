#!/bin/bash
###############################################################################
# Test: chat config generation (services/chat.sh).
#
# Guards the real-box fixes without needing a full ngIRCd/The Lounge build:
#   - default access mode is PUBLIC (no login wall); VALARK_CHAT_PUBLIC=0 → private
#   - ngIRCd MaxNickLength is raised off the classic-IRC default of 9 (the cause of
#     "nickname too long" for ordinary names)
#   - starter channels exist + the MOTD teaches /list and /join (discovery)
# Runs the two config writers in isolation (like the verify/loop report tests).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

gen() {  # $1 = PUBLIC value, $2 = output dir
    local H="$2"; mkdir -p "$H"
    {
        echo 'log(){ :; }; warn(){ :; }; err(){ :; }'
        echo "BIND=127.0.0.1; IRC_PORT=6667; WEB_PORT=9000; NETWORK_NAME='Val Ark'"
        echo "NGIRCD_CONF='$H/ngircd.conf'; NGIRCD_PID='$H/ngircd.pid'; THELOUNGE_HOME='$H'"
        echo "PUBLIC=$1"
        awk '/^_write_ngircd_conf\(\) \{/,/^}$/'    "$ROOT/scripts/services/chat.sh"
        awk '/^_write_thelounge_conf\(\) \{/,/^}$/' "$ROOT/scripts/services/chat.sh"
        echo '_write_ngircd_conf; _write_thelounge_conf'
    } > "$H/harness.sh"
    bash "$H/harness.sh" 2>/dev/null
}

gen 1 "$T/pub"      # default (public)
gen 0 "$T/priv"     # VALARK_CHAT_PUBLIC=0

L="$T/pub/config.js"; N="$T/pub/ngircd.conf"

# 1. default is public/open chat (no login wall).
grep -qE '^\s*public:\s*true' "$L" && pass || fail "default The Lounge config must be public:true"
# 2. VALARK_CHAT_PUBLIC=0 flips it to private.
grep -qE '^\s*public:\s*false' "$T/priv/config.js" && pass || fail "VALARK_CHAT_PUBLIC=0 must produce public:false"
# 3. nickname length is raised off the broken default of 9.
nl=$(grep -oE 'MaxNickLength = [0-9]+' "$N" | grep -oE '[0-9]+'); nl=${nl:-0}
[ "$nl" -ge 20 ] 2>/dev/null && pass || fail "ngIRCd MaxNickLength must be >=20 (got '$nl') — fixes 'nickname too long'"
# 4. starter channels are pre-created (not a single empty room).
for ch in '#valark' '#general' '#help' '#random'; do
    grep -qE "Name = ${ch}\b" "$N" && pass || fail "ngIRCd must pre-create ${ch}"
done
# 5. MOTD teaches discovery (/list) + channel creation (/join).
grep -q '/list' "$N" && pass || fail "MOTD must mention /list (see channels)"
grep -q '/join' "$N" && pass || fail "MOTD must mention /join (create/join a channel)"
# 6. new arrivals land in a populated room (default join includes #general).
grep -qE 'join:\s*"[^"]*#general' "$L" && pass || fail "The Lounge defaults.join must include #general"
# 7. ark-themed leave message (not the old bare string).
grep -q 'Val Ark' "$L" && grep -qE 'leaveMessage:.*(Sailing|aboard|⚓)' "$L" && pass || fail "leaveMessage should be the ark-themed one"

echo "chat-config: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
