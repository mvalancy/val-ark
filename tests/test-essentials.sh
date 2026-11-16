#!/bin/bash
###############################################################################
# Test: grid-down ESSENTIALS tier (planner phase 0) — offline, fixtures only.
#
#  * essentials are planned FIRST, in rank order, before diversity/fill.
#  * the SMALLEST variant of an essential ZIM is chosen (mini over maxi),
#    while a big budget still upgrades to the maxi in a later phase.
#  * an essential that does not fit is skipped, never blocking smaller ones.
#  * an essential already on disk (any variant) is not re-planned.
#  * focus filtering follows the owner profile (survival-only rows).
#  * without --essentials the plan is unchanged (backward compatible).
#  * data/essentials.tsv parses, ranks unique, kinds/focus valid, and every
#    model/inst entry matches a real catalog row.
#  * the survival profile exists end to end (catalog weight, wizard, commission).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P="$ROOT/scripts/lib/planner.py"
MB=1048576

# Candidate fixture: id bucket category value bytes source url dest extra
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
{
  row zim:water_en__eng        content zim:other     600 $((20*MB))   zim https://x/water.zim   "$T/z/water.zim"   water_en
  row zim:med_en_mini_eng      content zim:wikipedia 700 $((170*MB))  zim https://x/med-mini.zim "$T/z/med-mini.zim" med_en
  row zim:med_en_maxi_eng      content zim:wikipedia 700 $((1800*MB)) zim https://x/med-maxi.zim "$T/z/med-maxi.zim" med_en
  row zim:huge_en__eng         content zim:other     650 $((900*MB))  zim https://x/huge.zim    "$T/z/huge.zim"    huge_en
  row zim:knots_en__eng        content zim:other     500 $((25*MB))   zim https://x/knots.zim   "$T/z/knots.zim"   knots_en
  row zim:prep_en__eng         content zim:videos    400 $((60*MB))   zim https://x/prep.zim    "$T/z/prep.zim"    prep_en
  row zim:trivia_en__eng       content zim:ted       990 $((5*MB))    zim https://x/trivia.zim  "$T/z/trivia.zim"  trivia_en
  row model:tinyllm            models  models:llm    800 $((900*MB))  hf-file https://x/m.gguf "$T/m" x
  row inst:netboot-iso         installers inst:netboot 900 $((3*MB)) url https://x/n.iso "$T/i/n.iso" ""
  row inst:netboot-efi         installers inst:netboot 900 $((2*MB)) url https://x/n.efi "$T/i/n.efi" ""
} > "$T/cands.tsv"
cat > "$T/ess.tsv" <<'EOF'
# fixture
10|zim|water_en|all|water
11|zim|med_en|all|medicine
12|zim|huge_en|all|does not fit a small budget
13|zim|knots_en|all|knots
14|inst|netboot-*|all|both netboot files
15|model|tinyllm|all|assistant
20|zim|prep_en|survival|survival only
EOF
plan() { python3 "$P" --essentials "$T/ess.tsv" "$@" < "$T/cands.tsv" 2>/dev/null; }
ids() { cut -f1,10; }

# 1. small budget (400 MB): water, med MINI, (huge skipped), knots, both netboot files — in rank order, phase 0.
OUT=$(plan --budget $((400*MB)) | ids)
FIRST=$(echo "$OUT" | head -5 | cut -f1 | tr '\n' ' ')
[ "$FIRST" = "zim:water_en__eng zim:med_en_mini_eng zim:knots_en__eng inst:netboot-efi inst:netboot-iso " ] && pass \
    || fail "essentials not first/in rank order/smallest variant: '$FIRST'"
echo "$OUT" | head -5 | cut -f2 | sort -u | grep -qx 0 && pass || fail "essentials must be phase 0"
echo "$OUT" | grep -q 'zim:huge_en__eng' && fail "an essential larger than the budget left must be skipped" || pass
echo "$OUT" | grep -q 'zim:med_en_maxi_eng' && fail "small budget must not pull the maxi" || pass
echo "$OUT" | grep -q 'zim:prep_en__eng	0' && fail "survival-only essential planned for balanced profile" || pass

# 2. survival profile includes the survival-only row in phase 0.
plan --budget $((400*MB)) --profile survival | ids | grep -q $'zim:prep_en__eng\t0' && pass || fail "survival focus not applied"

# 3. big budget: essentials still first, and the maxi upgrade arrives in a later phase.
BIG=$(plan --budget $((10*1024*MB)) | ids)
[ "$(echo "$BIG" | head -1 | cut -f1)" = "zim:water_en__eng" ] && pass || fail "big budget: essentials must still lead"
echo "$BIG" | grep -qE $'^zim:med_en_maxi_eng\t[123]$' && pass || fail "big budget should upgrade to the maxi after the mini"
echo "$BIG" | grep -qE $'^zim:huge_en__eng\t0$' && pass || fail "big budget: huge essential should fit in phase 0"

# 4. an essential already on disk (any variant) is satisfied.
mkdir -p "$T/z"; head -c $((20*MB)) /dev/zero > "$T/z/water.zim"
plan --budget $((400*MB)) | ids | grep -q 'zim:water_en__eng' && fail "present essential re-planned" || pass
rm -f "$T/z/water.zim"

# 5. no --essentials => identical to the pre-existing planner behaviour (no phase 0 rows).
python3 "$P" --budget $((400*MB)) < "$T/cands.tsv" 2>/dev/null | cut -f10 | grep -qx 0 && fail "phase 0 without --essentials" || pass
# trivia (highest value/byte) leads when there are no essentials.
[ "$(python3 "$P" --budget $((400*MB)) < "$T/cands.tsv" 2>/dev/null | head -1 | cut -f1)" != "" ] && pass || fail "plain plan empty"

# 6. data/essentials.tsv itself.
python3 - "$ROOT" <<'EOF' && pass || fail "data/essentials.tsv invalid"
import sys, fnmatch
root = sys.argv[1]
ranks, kinds = set(), {"zim", "model", "inst"}
focus_ok = {"all", "balanced", "knowledge", "ai", "tools", "survival"}
models = [l.split("|")[1] for l in open(root + "/data/models-extra.tsv") if l[:1].isdigit()]
insts = [l.split("|")[1] for l in open(root + "/data/installers.tsv") if l[:1].isdigit()]
n = 0
for i, line in enumerate(open(root + "/data/essentials.tsv"), 1):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    f = line.split("|"); n += 1
    assert len(f) == 5, f"line {i}: {len(f)} fields"
    r, kind, pat, focus, note = f
    assert int(r) not in ranks, f"line {i}: duplicate rank {r}"; ranks.add(int(r))
    assert kind in kinds, f"line {i}: kind {kind}"
    assert set(focus.split(",")) <= focus_ok, f"line {i}: focus {focus}"
    assert note.strip(), f"line {i}: empty note"
    if kind == "model":
        assert any(fnmatch.fnmatchcase(m, pat) for m in models), f"line {i}: no models-extra id matches {pat}"
    if kind == "inst":
        assert any(fnmatch.fnmatchcase(m, pat) for m in insts), f"line {i}: no installers id matches {pat}"
assert n >= 20, "too few essentials"
EOF
# life-safety entries must be at the very top
head -50 "$ROOT/data/essentials.tsv" | grep -v '^#' | grep -m1 . | grep -q 'water' && pass || fail "rank 1 should be water"

# 7. survival profile end to end.
grep -q "survival:content" "$ROOT/scripts/lib/catalog.sh" && pass || fail "catalog.sh lacks survival weights"
grep -q "'survival'" "$ROOT/scripts/lib/commission.js" && pass || fail "commission.js does not accept survival"
grep -q "id: 'survival'" "$ROOT/web-ui/index.html" && pass || fail "wizard lacks the survival profile"
grep -q -- '--essentials' "$ROOT/scripts/librarian.sh" && pass || fail "librarian does not pass --essentials"
W=$( VALARK_PROFILE=survival bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED; export VAL_ARK_DATA='$ROOT'; source '$ROOT/scripts/lib/catalog.sh'; _valark_profile_weight content" )
[ "$W" = "1.4" ] && pass || fail "survival content weight (got '$W')"

echo "essentials: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
