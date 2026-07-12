#!/bin/bash
###############################################################################
# Test: admin identity + recovery CLI (scripts/valark) — Phase 2 safety net.
#
# Verifies the security-critical invariants:
#   - a fresh box has NO default credential (localhost/console is the only admin)
#   - the passcode is stored hashed (never plaintext) in a 0600 file
#   - verify accepts the right passcode and rejects the wrong one
#   - tier-1 reset forgets the admin
#   - CONTENT-SAFETY INVARIANT: a config reset never touches content/models
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALARK="${ROOT}/scripts/valark"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# The CLI needs a node runtime; skip cleanly if truly absent (CI provides one).
if ! "$HOME/.local/node/bin/node" -v >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
    echo "SKIP: no node runtime for the valark CLI" >&2
    exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Isolate state + content + models into the temp tree (valark-env honors these).
export VALARK_STATE_DIR="$T/state" VALARK_CONTENT_DIR="$T/content" VALARK_MODELS_DIR="$T/models"
mkdir -p "$T/content/zim" "$T/models/llm"
echo "WIKIPEDIA-ALL-MAXI" > "$T/content/zim/wikipedia_sentinel.zim"
echo "GGUF-WEIGHTS"       > "$T/models/llm/model_sentinel.gguf"
BEFORE="$(cat "$T/content/zim/wikipedia_sentinel.zim" "$T/models/llm/model_sentinel.gguf" | sha256sum)"

status_has() { "$VALARK" auth status 2>/dev/null | grep -q "$1"; }

# 1. No default credential on a fresh box.
status_has '"adminSet":false' && pass || fail "fresh box must not be commissioned"

# 2. setpassword creates a hashed, locked-down store.
"$VALARK" setpassword "s3cret-pass" >/dev/null 2>&1
[ -f "$T/state/auth.json" ] && pass || fail "setpassword should create auth.json"
[ "$(stat -c '%a' "$T/state/auth.json" 2>/dev/null)" = "600" ] && pass || fail "auth.json must be chmod 600"
if grep -q "s3cret-pass" "$T/state/auth.json"; then fail "passcode must NOT be stored in clear"; else pass; fi
status_has '"adminSet":true' && pass || fail "adminSet must be true after setpassword"

# 3. verify accepts right, rejects wrong.
"$VALARK" verify "s3cret-pass" >/dev/null 2>&1 && pass || fail "correct passcode must verify"
if "$VALARK" verify "nope" >/dev/null 2>&1; then fail "wrong passcode must be rejected"; else pass; fi

# 4. tier-1 reset forgets the admin (recovery path).
"$VALARK" reset --tier1 >/dev/null 2>&1
status_has '"adminSet":false' && pass || fail "tier1 reset must clear the admin"

# 5. CONTENT-SAFETY INVARIANT — a config reset never touches content/models.
"$VALARK" setpassword "again-123" >/dev/null 2>&1
"$VALARK" reset --tier2 >/dev/null 2>&1
AFTER="$(cat "$T/content/zim/wikipedia_sentinel.zim" "$T/models/llm/model_sentinel.gguf" | sha256sum)"
if [ -f "$T/state/auth.json" ]; then fail "tier2 reset must clear the config"; else pass; fi
[ "$BEFORE" = "$AFTER" ] && pass || fail "tier2 reset must keep content+models byte-identical"

echo "auth: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
