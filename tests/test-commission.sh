#!/bin/bash
###############################################################################
# Test: first-boot commissioning (scripts/lib/commission.js) — Phase 1.
#
# The security-critical invariants of claiming a fresh box:
#   - a fresh box is un-commissioned and prints a claim token
#   - FAIL-CLOSED from the LAN: no/wrong claim token is refused, box stays fresh
#   - the right token (or the trusted box/localhost) commissions
#   - the claim token is single-use (consumed on success)
#   - re-commissioning an owned box is refused
#   - commissioning never touches the content/model libraries
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime for commission.js" >&2; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models"
mkdir -p "$T/content/zim" "$T/models/llm"
echo "WIKIPEDIA" > "$T/content/zim/w.zim"; echo "GGUF" > "$T/models/llm/m.gguf"
SUM_BEFORE="$(cat "$T/content/zim/w.zim" "$T/models/llm/m.gguf" | sha256sum)"

C="$ROOT/scripts/lib/commission.js"
runjs() { "$NODE" -e "const c=require('$C');const d=process.env.VALARK_STATE_DIR;$1"; }

# 1. Fresh box: un-commissioned + a well-formed claim token is generated.
runjs "const t=c.ensureClaim(d);process.exit(!c.isCommissioned(d)&&/^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(t)?0:1)" \
    && pass || fail "fresh box is un-commissioned with a claim token"
TOKEN="$(runjs "process.stdout.write(c.readClaim(d))")"
[ -n "$TOKEN" ] && pass || fail "claim token is readable"

# 2. FAIL-CLOSED: an untrusted (LAN) caller with a wrong or missing token is refused.
runjs "process.exit(c.commission(d,{token:'WRONG-XXXX',name:'x'},{trusted:false}).error?0:1)" \
    && pass || fail "LAN commission with wrong token is refused"
runjs "process.exit(c.commission(d,{name:'x'},{trusted:false}).error?0:1)" \
    && pass || fail "LAN commission with no token is refused"
runjs "process.exit(!c.isCommissioned(d)?0:1)" \
    && pass || fail "refused attempts leave the box un-commissioned"

# 3. The RIGHT token commissions (LAN path), setting name + admin.
runjs "process.exit(c.commission(d,{token:'$TOKEN',name:'homelab',profile:'ai',password:'setup-pass'},{trusted:false}).ok?0:1)" \
    && pass || fail "LAN commission with the correct token succeeds"
runjs "process.exit(c.isCommissioned(d)?0:1)" \
    && pass || fail "box is commissioned after success"

# 4. Single-use: the claim token is consumed.
[ ! -f "$T/state/claim-token.txt" ] && pass || fail "claim token is consumed on commission"

# 5. Idempotent: an already-owned box refuses re-commissioning (even when trusted).
runjs "process.exit(c.commission(d,{},{trusted:true}).error?0:1)" \
    && pass || fail "already-commissioned box refuses re-commission"

# 6. Content-safety: commissioning never touches content/models.
SUM_AFTER="$(cat "$T/content/zim/w.zim" "$T/models/llm/m.gguf" | sha256sum)"
[ "$SUM_BEFORE" = "$SUM_AFTER" ] && pass || fail "commissioning keeps content+models byte-identical"

# ---- server-level regression: grandfather-flip must be impossible ---------------
# (A LAN peer must not be able to seed the library to fake "already set up", and a
#  library appearing after boot must not flip an un-owned box.)
PORT=3917
S2="$T/srv"; mkdir -p "$S2/content/zim" "$S2/models"
VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 VALARK_WEB_PORT="$PORT" \
  VALARK_STATE_DIR="$S2/state" VALARK_CONTENT_DIR="$S2/content" VALARK_MODELS_DIR="$S2/models" \
  "$NODE" "$ROOT/scripts/server.js" "$PORT" >"$T/srv.log" 2>&1 &
SRV_PID=$!
up=0; for i in $(seq 1 24); do sleep 0.5; curl -sf --max-time 2 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && { up=1; break; }; done
if [ "$up" = 1 ]; then
    curl -s --max-time 4 "http://127.0.0.1:$PORT/api/setup/state" | grep -q '"commissioned":false' \
        && pass || fail "fresh server reports un-commissioned"
    # mutating actions are refused before commissioning (fresh box → wizard, not catalog)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H 'Content-Type: application/json' -d '{"target":"all"}' "http://127.0.0.1:$PORT/api/download/content")
    [ "$code" = "409" ] && pass || fail "pre-commission download POST refused (got $code, want 409)"
    # a library appearing AFTER boot (what a download's mkdir -p would create) must NOT
    # flip the box to commissioned — the decision is snapshotted, not live.
    mkdir -p "$S2/models/llm/some-model"
    curl -s --max-time 4 "http://127.0.0.1:$PORT/api/setup/state" | grep -q '"commissioned":false' \
        && pass || fail "post-boot library must NOT flip the box to commissioned"
    # the owner (localhost, trusted) can still commission through the wizard
    curl -s --max-time 6 -H 'Content-Type: application/json' -d '{"name":"box"}' "http://127.0.0.1:$PORT/api/setup/commission" | grep -q '"ok":true' \
        && pass || fail "localhost can still commission the fresh box"
    curl -s --max-time 4 "http://127.0.0.1:$PORT/api/setup/state" | grep -q '"commissioned":true' \
        && pass || fail "box is commissioned after the wizard"
else
    fail "test server did not start on :$PORT (see srv.log)"
fi
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null

echo "commission: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
