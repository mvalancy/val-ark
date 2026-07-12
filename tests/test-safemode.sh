#!/bin/bash
###############################################################################
# Test: Safe Mode — a box with a CORRUPT config still boots (recovery-only) and
# heals, and never touches content.
#
#   - a corrupt settings.json trips Safe Mode (not a dead port): /api/health 200
#     with safeMode:true
#   - the content/model library is untouched
#   - localhost recovery (no code) sets a new admin AND repairs the config, so
#     Safe Mode clears with no restart
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
echo "WIKIPEDIA" > "$T/content/zim/w.zim"; echo "GGUF" > "$T/models/m.gguf"
SUM_BEFORE="$(cat "$T/content/zim/w.zim" "$T/models/m.gguf" | sha256sum)"
# Corrupt the config — a present-but-unparseable settings.json.
printf '{ this is NOT valid json ' > "$T/state/settings.json"

PORT=3921; B="http://127.0.0.1:$PORT"
# No VALARK_TEST_FORCE_REMOTE → the test client is localhost, so it can recover with no code.
VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "$B/api/health" >/dev/null 2>&1 && { up=1; break; }; done
if [ "$up" != 1 ]; then fail "server did not boot with corrupt config (should still come up in Safe Mode)"; echo "safemode: ${PASS} passed, ${FAIL} failed"; exit 1; fi
pass   # booted despite corrupt config → never a dead port

# 1. Safe Mode is reported on /api/health.
curl -s --max-time 5 "$B/api/health" | grep -q '"safeMode":true' && pass || fail "corrupt config must trip Safe Mode on /api/health"
# 2. …and on /api/setup/state.
curl -s --max-time 5 "$B/api/setup/state" | grep -q '"safeMode":true' && pass || fail "Safe Mode must surface on /api/setup/state"
# 3. localhost recovery (no code) heals it.
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' -d '{"password":"recovered9"}' "$B/api/auth/recover" | grep -qE '"ok" ?: ?true' \
    && pass || fail "localhost recovery (no code) must succeed in Safe Mode"
# 4. Safe Mode clears (config repaired) — no restart.
curl -s --max-time 5 "$B/api/health" | grep -q '"safeMode":false' && pass || fail "Safe Mode must clear after recovery"
# 5. settings.json is valid JSON again.
"$NODE" -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$T/state/settings.json" 2>/dev/null && pass || fail "settings.json must be valid JSON after repair"
# 6. Content-safety: the library was never touched.
SUM_AFTER="$(cat "$T/content/zim/w.zim" "$T/models/m.gguf" | sha256sum)"
[ "$SUM_BEFORE" = "$SUM_AFTER" ] && pass || fail "Safe Mode + recovery must keep content+models byte-identical"

echo "safemode: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
