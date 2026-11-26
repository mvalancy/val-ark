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
#  * the librarian's REAL prune_superseded: the superseded file is deleted and
#    only its exact manifest id dropped (prefix ids kept); pinned and in-progress
#    (.part) entries untouched; a STOP-halted fill skips the prune (#177).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/require-cmd.sh"; require_python3 "essentials"
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
# ...including when only the FULL (maxi) variant is on disk.
truncate -s $((1800*MB)) "$T/z/med-maxi.zim"
plan --budget $((400*MB)) | ids | grep -q 'zim:med_en_' && fail "maxi on disk must satisfy the medicine essential" || pass

# 4b. superseded: once the maxi is complete, the managed + unpinned mini is listed for removal.
truncate -s $((170*MB)) "$T/z/med-mini.zim"
printf 'zim:med_en_mini_eng\tcontent\tzim:wikipedia\t%s\t1\t1\tzim\t0\n' "$T/z/med-mini.zim" > "$T/manifest.tsv"
SUP() { python3 "$P" --budget 1 --superseded --manifest "$T/manifest.tsv" "$@" < "$T/cands.tsv" 2>/dev/null | cut -f1; }
[ "$(SUP)" = "zim:med_en_mini_eng" ] && pass || fail "superseded must list the mini once the maxi is on disk (got '$(SUP)')"
printf 'content\tzim:med_en_mini_eng\t0\tpinned\n' > "$T/pins.tsv"
[ -z "$(SUP --pins "$T/pins.tsv")" ] && pass || fail "a pinned mini must never be superseded"
: > "$T/manifest.tsv"
[ -z "$(SUP)" ] && pass || fail "an unmanaged (owner-placed) file must never be superseded"
rm -f "$T/z/med-maxi.zim"
printf 'zim:med_en_mini_eng\tcontent\tzim:wikipedia\t%s\t1\t1\tzim\t0\n' "$T/z/med-mini.zim" > "$T/manifest.tsv"
[ -z "$(SUP)" ] && pass || fail "without the full variant on disk the mini must stay"
rm -f "$T/z/med-mini.zim"

# 4c. glob entries re-plan only the missing file (netboot efi present, iso missing).
mkdir -p "$T/i"; truncate -s $((2*MB)) "$T/i/n.efi"
G=$(plan --budget $((400*MB)) | ids)
grep -q $'^inst:netboot-iso\t0$' <<<"$G" && ! grep -q 'inst:netboot-efi' <<<"$G" && pass || fail "glob essential: plan only the missing file"
rm -f "$T/i/n.efi"

# 4d. phase-0 picks count as category coverage: no extra phase-1 item for zim:other on a tight budget.
# (prep_en is zim:videos — not covered; huge_en/trivia are other categories. zim:other is covered by water/knots.)
python3 "$P" --essentials "$T/ess.tsv" --budget $((60*MB)) < "$T/cands.tsv" 2>/dev/null | awk -F'\t' '$10==1 && $3=="zim:other"' | grep -q . \
    && fail "phase 1 added a diversity item for a category essentials already cover" || pass
python3 "$P" --essentials "$T/ess.tsv" --budget $((60*MB)) < "$T/cands.tsv" 2>/dev/null | awk -F'\t' '$10==1 && $3=="zim:ted"' | grep -q . \
    && pass || fail "phase 1 must still cover categories the essentials do not"

# 5. no --essentials => identical to the pre-existing planner behaviour (no phase 0 rows).
python3 "$P" --budget $((400*MB)) < "$T/cands.tsv" 2>/dev/null | cut -f10 | grep -qx 0 && fail "phase 0 without --essentials" || pass
# trivia (highest value/byte) leads when there are no essentials.
[ "$(python3 "$P" --budget $((400*MB)) < "$T/cands.tsv" 2>/dev/null | head -1 | cut -f1)" != "" ] && pass || fail "plain plan empty"

# 6. data/essentials.tsv itself.
python3 - "$ROOT" <<'EOF' && pass || fail "data/essentials.tsv invalid"
import sys, fnmatch
root = sys.argv[1]
ranks, kinds = set(), {"zim", "model", "inst", "lastbook"}
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
    if kind == "lastbook":  # lastbook_mirror.py candidates ids: lastbook:<pack|map|model|app>:<id>
        assert pat.split(":", 1)[0] in ("pack", "map", "model", "app") and ":" in pat, f"line {i}: lastbook kind {pat}"
assert n >= 20, "too few essentials"
EOF
# life-safety entries must be at the very top
head -50 "$ROOT/data/essentials.tsv" | grep -v '^#' | grep -m1 . | grep -q 'water' && pass || fail "rank 1 should be water"

# 7. survival profile end to end.
grep -q "survival:content" "$ROOT/scripts/lib/catalog.sh" && pass || fail "catalog.sh lacks survival weights"
node -e "const c=require('$ROOT/scripts/lib/commission.js');const fs=require('fs'),os=require('os'),path=require('path');
const d=fs.mkdtempSync(path.join(os.tmpdir(),'ess-'));const r=c.commission(d,{token:c.ensureClaim(d),name:'x',profile:'survival',password:'setup-pass'},{trusted:true});
process.exit(r.ok && c.readSettings(d).profile==='survival'?0:1)" 2>/dev/null && pass || fail "commissioning with profile=survival must persist it"
grep -q -- '--superseded' "$ROOT/scripts/librarian.sh" && pass || fail "librarian fill does not prune superseded variants"
grep -q "'survival'" "$ROOT/scripts/lib/commission.js" && pass || fail "commission.js does not accept survival"
grep -q "id: 'survival'" "$ROOT/web-ui/index.html" && pass || fail "wizard lacks the survival profile"
grep -q -- '--essentials' "$ROOT/scripts/librarian.sh" && pass || fail "librarian does not pass --essentials"
W=$( VALARK_PROFILE=survival bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED; export VAL_ARK_DATA='$ROOT'; source '$ROOT/scripts/lib/catalog.sh'; _valark_profile_weight content" )
[ "$W" = "1.4" ] && pass || fail "survival content weight (got '$W')"

# 8. the librarian's REAL prune (rm + exact-id manifest rewrite), and its STOP-flag rule (#177).
#    Runs in a child bash (sourcing librarian.sh sets env/options); it prints PASS / FAIL: lines.
PR=$(T="$T" ROOT="$ROOT" bash <<'EOS' 2>/dev/null
export VAL_ARK_DATA="$T/prune-data"; mkdir -p "$VAL_ARK_DATA"
export VAL_ARK_CONFIG="$T/prune.env"; : > "$VAL_ARK_CONFIG"
. "$ROOT/scripts/librarian.sh"; ensure_state
ok_() { echo PASS; }; no_() { echo "FAIL: $1"; }
Z="$ZIM_DIR"; MB=1048576
r() { printf '%s\tcontent\tzim:other\t500\t%s\tzim\thttps://x/%s\t%s\t%s\n' "$1" "$2" "$1" "$Z/$3" "$4"; }
m() { printf '%s\tcontent\tzim:other\t%s\t1\t1\tzim\t0\n' "$1" "$Z/$2"; }
cands() {
  r zim:med_en_mini_eng     $MB      med-mini.zim   med_en      # superseded -> removed
  r zim:med_en_maxi_eng     $((4*MB)) med-maxi.zim  med_en      # full variant, complete
  r zim:med_en_mini_eng_old $MB      med-old.zim    medold_en   # id has the superseded id as a PREFIX
  r zim:med_en_mini         $MB      med-pfx.zim    medpfx_en   # id is a PREFIX of the superseded id
  r zim:knots_en_mini_eng   $MB      knots-mini.zim knots_en    # pinned small variant -> kept
  r zim:knots_en_maxi_eng   $((4*MB)) knots-maxi.zim knots_en
  r zim:food_en_mini_eng    $MB      food-mini.zim  food_en     # full variant still a .part -> kept
  r zim:food_en_maxi_eng    $((4*MB)) food-maxi.zim food_en
}
gen_candidates() { cands; }
setup() {
  rm -f "$Z"/*.zim "$Z"/*.part
  for f in med-mini med-old med-pfx knots-mini food-mini; do truncate -s $MB "$Z/$f.zim"; done
  for f in med-maxi knots-maxi; do truncate -s $((4*MB)) "$Z/$f.zim"; done
  truncate -s $((2*MB)) "$Z/food-maxi.zim.part"
  { m zim:med_en_mini_eng med-mini.zim; m zim:med_en_maxi_eng med-maxi.zim
    m zim:med_en_mini_eng_old med-old.zim; m zim:med_en_mini med-pfx.zim
    m zim:knots_en_mini_eng knots-mini.zim; m zim:knots_en_maxi_eng knots-maxi.zim
    m zim:food_en_mini_eng food-mini.zim; } > "$MANIFEST"
  printf 'content\tzim:knots_en_mini_eng\t0\tpinned\n' > "$PINS"
}
ids() { cut -f1 "$MANIFEST" | sort | tr '\n' ' '; }
KEEP="zim:food_en_mini_eng zim:knots_en_maxi_eng zim:knots_en_mini_eng zim:med_en_maxi_eng zim:med_en_mini zim:med_en_mini_eng_old "

setup; prune_superseded >/dev/null
[ ! -e "$Z/med-mini.zim" ] && ok_ || no_ "prune: the superseded mini must be deleted"
[ "$(ids)" = "$KEEP" ] && ok_ || no_ "prune: manifest must drop exactly the superseded id (got '$(ids)')"
for f in med-maxi med-old med-pfx knots-mini knots-maxi food-mini; do   # one result per file
  [ -e "$Z/$f.zim" ] && ok_ || no_ "prune: $f.zim must be kept"
done
[ -e "$Z/food-maxi.zim.part" ] && ok_ || no_ "prune: an in-progress .part must be untouched"
prune_superseded >/dev/null; [ "$(ids)" = "$KEEP" ] && ok_ || no_ "prune: second run must be a no-op"

# The fill path: STOP mid-fill skips the prune; an un-halted fill prunes.
catalog_refresh_zim() { :; }; catalog_refresh_lastbook() { :; }; valark_budget_bytes() { echo $((100*1024*MB)); }
valark_fillable_bytes() { echo $((100*1024*MB)); }
build_plan() {   # two planned items, so a STOP raised by the first halts before the second
  for i in a b; do printf 'zim:%s\tcontent\tzim:other\t1\t0\tzim\tu\t%s\t-\t1\n' "$i" "$Z/$i"; done
  : > "$TMPDIR_VA/plan.summary"; }
download_one() { [ -n "${STOP_ON_DL:-}" ] && : > "$STOP_FLAG"; return 0; }
setup; STOP_ON_DL=1 cmd_fill >"$T/fill.err" 2>&1
[ -e "$Z/med-mini.zim" ] && grep -q 'skipping superseded-variant prune' "$T/fill.err" && ok_ \
  || no_ "fill halted by STOP must not prune (it deletes files while the owner asked to stop)"
grep -q 'med_en_mini_eng	' "$MANIFEST" && ok_ || no_ "STOP-halted fill must leave the manifest alone"
rm -f "$STOP_FLAG"; cmd_fill >/dev/null 2>&1
[ ! -e "$Z/med-mini.zim" ] && [ "$(ids)" = "$KEEP" ] && ok_ || no_ "an un-halted fill must prune the superseded mini"
EOS
)
[ -n "$PR" ] || fail "real-prune fixture produced no results"
while IFS= read -r l; do case "$l" in PASS) pass ;; FAIL:*) fail "${l#FAIL: }" ;; esac; done <<<"$PR"

# --- librarian.sh essentials-done (#347 B1): the gate the loop puts before the app mirrors -------------
ED="$T/ed"; mkdir -p "$ED/z"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' zim:water_en__eng content zim:other 600 $((20*MB)) zim https://x/w.zim "$ED/z/water.zim" water_en > "$ED/c.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' zim:huge_en__eng content zim:other 650 $((90000*MB)) zim https://x/h.zim "$ED/z/huge.zim" huge_en >> "$ED/c.tsv"
printf '10|zim|water_en|all|water\n12|zim|huge_en|all|too big for the budget\n' > "$ED/ess.tsv"
ess_done() {   # CANDIDATES-FILE BUDGET -> prints rc
  bash -c '
  TT="$2"; export VAL_ARK_DATA="$1" VAL_ARK_CONFIG="$2/none.env" FORCE_COLOR=0
  . "$3/scripts/librarian.sh"; ensure_state
  catalog_refresh_zim() { :; }; catalog_refresh_lastbook() { :; }
  DATA_DIR="$2"; cp "$2/ess.tsv" "$2/essentials.tsv"
  CF="$4"; gen_candidates() { cat "$CF"; }
  cmd_essentials_done "$5" >"$2/ed.out" 2>"$2/ed.err"; echo $?' _ "$T/edroot" "$ED" "$ROOT" "$1" "$2"
}
mkdir -p "$T/edroot"
[ "$(ess_done "$ED/c.tsv" $((10*1024*MB)))" = 1 ] && pass || fail "essentials-done: a missing essential that fits -> exit 1"
head -c $((20*MB)) /dev/zero > "$ED/z/water.zim"
[ "$(ess_done "$ED/c.tsv" $((10*1024*MB)))" = 0 ] && pass || fail "essentials-done: every essential that fits is held (the huge one does not fit) -> exit 0"
: > "$ED/none.tsv"
[ "$(ess_done "$ED/none.tsv" $((10*1024*MB)))" = 2 ] && pass || fail "essentials-done: no catalog -> exit 2 (cannot judge)"
# a model-only catalog with ZIM essentials listed (the Kiwix fetch failed) -> exit 2, not "all held"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' hf:tiny models models:small 500 $((MB)) hf https://x/m.gguf "$ED/m.gguf" tiny > "$ED/model-only.tsv"
r=$(ess_done "$ED/model-only.tsv" $((10*1024*MB))); [ "$r" = 2 ] && pass || { fail "essentials-done: model-only catalog but zim essentials listed -> exit 2 (got $r)"; cat "$ED/ed.out" "$ED/ed.err" >&2; }
grep -q 'essentials-done) shift; cmd_essentials_done' "$ROOT/scripts/librarian.sh" && pass || fail "librarian.sh dispatches essentials-done"

echo "essentials: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
