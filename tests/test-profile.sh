#!/bin/bash
###############################################################################
# Test: owner PROFILE biases curation value per bucket (roadmap Phase 5).
#
# The commissioning wizard stores a profile (balanced/knowledge/ai/tools) in
# settings.json; the librarian applies a per-bucket multiplier so the box fills
# according to what the owner wants. Verifies the resolver + the value bias.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
export VAL_ARK_DATA="$ROOT"   # repo mode → fast, uses data/*.tsv

# sum of a bucket's candidate values for a given VALARK_PROFILE
bucket_sum() { # $1=profile  $2=candidate-fn
    ( VALARK_PROFILE="$1" bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED; source '$ROOT/scripts/lib/catalog.sh'; $2 | awk -F'\t' '{s+=\$4} END{print s+0}'" )
}

AI_M=$(bucket_sum ai catalog_model_candidates)
KN_M=$(bucket_sum knowledge catalog_model_candidates)
BAL_M=$(bucket_sum balanced catalog_model_candidates)
TO_I=$(bucket_sum tools catalog_installer_candidates)
BAL_I=$(bucket_sum balanced catalog_installer_candidates)

# 1. ai profile boosts MODELS above balanced + knowledge.
[ -n "$AI_M" ] && [ "$AI_M" -gt "$BAL_M" ] 2>/dev/null && pass || fail "ai profile must boost model values above balanced ($AI_M vs $BAL_M)"
[ "$AI_M" -gt "$KN_M" ] 2>/dev/null && pass || fail "ai profile must boost models above knowledge ($AI_M vs $KN_M)"
# 2. knowledge profile de-emphasises MODELS (below balanced).
[ "$KN_M" -lt "$BAL_M" ] 2>/dev/null && pass || fail "knowledge profile must lower model values vs balanced ($KN_M vs $BAL_M)"
# 3. tools profile boosts installers/tools above balanced.
[ -n "$TO_I" ] && [ "$TO_I" -gt "$BAL_I" ] 2>/dev/null && pass || fail "tools profile must boost installer values above balanced ($TO_I vs $BAL_I)"

# 4. The resolver reads the profile from settings.json (what the wizard writes).
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo '{ "profile": "knowledge", "name": "x", "commissionedAt": "2026-01-01" }' > "$T/settings.json"
GOT=$( VALARK_STATE_DIR="$T" bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED VALARK_PROFILE; source '$ROOT/scripts/lib/catalog.sh'; _valark_profile" )
[ "$GOT" = "knowledge" ] && pass || fail "resolver must read profile from settings.json (got '$GOT')"
# 5. VALARK_PROFILE env overrides settings.json.
GOT2=$( VALARK_STATE_DIR="$T" VALARK_PROFILE="ai" bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED; source '$ROOT/scripts/lib/catalog.sh'; _valark_profile" )
[ "$GOT2" = "ai" ] && pass || fail "VALARK_PROFILE env must override settings.json (got '$GOT2')"
# 6. unknown/absent profile → balanced (weight 1.0, no bias).
W=$( bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED VALARK_PROFILE VALARK_STATE_DIR; source '$ROOT/scripts/lib/catalog.sh'; _valark_profile_weight content" )
[ "$W" = "1.0" ] && pass || fail "default profile must be neutral (content weight 1.0, got '$W')"

echo "profile: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
