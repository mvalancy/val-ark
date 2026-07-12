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

echo "commission: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
