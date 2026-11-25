#!/bin/bash
###############################################################################
# Test: Lastbook planned like any other content (#203) - scripts/lib/planner.py's
# handling of `lastbook` candidate rows, the catalog.sh feed and librarian.sh fill.
#
# All offline: synthetic candidate rows (the shape lastbook_mirror.py `candidates`
# prints) with small byte counts, a fake Lastbook dir with a .lastbook-verified.json,
# and a stubbed fetch (lastbook_fill). The mirror side (`candidates`, --pack-limit,
# --plus-held, lastbook.sh --plan-file) is covered by tests/test-lastbook.sh against
# its local fixture server.
# Invariants:
#   - the packs nest: at most ONE pack is planned; a bigger budget plans a bigger pack
#     (an upgrade refunds the smaller pick), never two
#   - a pack held and verified on disk satisfies every pack at most its size; a larger
#     one is still an upgrade candidate; a .part, a symlink or a wrong size is not held
#   - maps / the model / the installers need a pack (held or planned)
#   - survival essentials plan the Small pack + installers in phase 0; other profiles not
#   - the web catalog (--list-absent) never offers Lastbook rows
#   - catalog.sh: the cache is re-pointed at the current Lastbook dir and profile-weighted;
#     no rows when the operator chose the selection (PACK != auto, BUDGET, BUDGET_PCT, PLAN=0)
#   - librarian.sh fill fetches every planned Lastbook row in ONE lastbook_fill call, and
#     never adds them to the librarian's manifest
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; fi; }
P="$ROOT/scripts/lib/planner.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' EXIT
export LC_ALL=C FORCE_COLOR=0

LB="$T/lb"; mkdir -p "$LB"
K=1000
# rows: id bucket category value bytes source url dest extra   (sizes in bytes, scaled down)
row() { printf '%s\t%s\t%s\t%s\t%s\tlastbook\thttps://downloads.lastbook.org/x\t%s\t%s\n' "$@"; }
cands() {
    row lastbook:pack:small  content lastbook:pack 820 $((9*K))   "$LB" "pack|-|packs/Small.zip=$((8*K)),maps/base.zip=$((1*K))"
    row lastbook:pack:medium content lastbook:pack 840 $((69*K))  "$LB" "pack|-|packs/Medium.zip=$((68*K)),maps/base.zip=$((1*K))"
    row lastbook:pack:all    content lastbook:pack 860 $((390*K)) "$LB" "pack|-|packs/All.zip=$((389*K)),maps/base.zip=$((1*K))"
    row lastbook:map:CA      content lastbook:maps 640 $((4*K))   "$LB" "map|pack|maps/CA.zip=$((3*K)),addresses/CA.zip=$((1*K))"
    row lastbook:model:gemma models  lastbook:model 560 $((17*K)) "$LB" "model|pack|models/g.gguf=$((17*K))"
    row lastbook:app:1.1.11  content lastbook:app  900 $((1*K))   "$LB" "app|pack|app/1.1.11/a.deb=$((1*K))"
}
cands > "$T/c.tsv"
plan() { python3 "$P" --budget "$1" "${@:2}" < "$T/c.tsv" 2>"$T/plan.err"; }
packs() { cut -f1 | grep '^lastbook:pack:' | sed 's/^lastbook:pack://' | sort | tr '\n' ' ' | sed 's/ $//'; }
has() { grep -q "^$1	"; }

check "planner compiles" 'python3 -m py_compile "$P"'

# --- 1. packs nest: one pack, sized by the budget --------------------------------------------
check "5 KB: no pack fits -> nothing Lastbook (maps/model/app need a pack)" '[ -z "$(plan $((5*K)) | grep ^lastbook:)" ]'
plan $((15*K)) > "$T/p"
check "15 KB: the Small pack, once" '[ "$(packs < "$T/p")" = small ]'
check "15 KB: the installers ride with it" 'has lastbook:app:1.1.11 < "$T/p"'
plan $((100*K)) > "$T/p"
check "100 KB: Medium (an upgrade of the Small pick), never two packs" '[ "$(packs < "$T/p")" = medium ]'
check "100 KB: the budget counts Medium only (Small refunded): the model fits too" 'has lastbook:model:gemma < "$T/p" && has lastbook:map:CA < "$T/p"'
plan $((1000*K)) > "$T/p"
check "1 MB: All, alone" '[ "$(packs < "$T/p")" = all ]'
check "planned bytes never count two packs (no essentials)" '[ "$(awk -F"\t" "\$1 ~ /^lastbook:pack:/ {s+=\$5} END {print s}" "$T/p")" = $((390*K)) ]'

# the upgrade REFUNDS the smaller pick: at 70 KB, Medium (69 KB) fits only once Small's 9 KB come back
cands | grep -E "^lastbook:pack:(small|medium)	" > "$T/c-refund.tsv"
python3 "$P" --budget $((70*K)) < "$T/c-refund.tsv" > "$T/p" 2>/dev/null
check "tight budget: the upgrade to Medium only fits with Small refunded" '[ "$(packs < "$T/p")" = medium ]'
# ...and the refunded bytes are really spent again: a 10 KB filler planned AFTER the upgrade (same
# category, lower value per byte) fits at 80 KB only if Small's 9 KB came back (80 - 69 = 11 KB left)
printf 'x:filler\tcontent\tlastbook:pack\t100\t%s\turl\thttps://x/f\t%s/nonexist/f\tsha\n' $((10*K)) "$T" >> "$T/c-refund.tsv"
python3 "$P" --budget $((80*K)) < "$T/c-refund.tsv" > "$T/p" 2>/dev/null
check "upgrade refund: the filler after the Small->Medium upgrade still fits (refund applied)" '[ "$(packs < "$T/p")" = medium ] && has x:filler < "$T/p"'
python3 "$P" --budget $((68*K)) < "$T/c-refund.tsv" > "$T/p" 2>/dev/null
check "tight budget: Medium does not fit at all -> Small stays" '[ "$(packs < "$T/p")" = small ]'

# --- 2. a held pack satisfies smaller ones --------------------------------------------------------
mkdir -p "$LB/packs" "$LB/maps"
head -c $((68*K)) /dev/zero > "$LB/packs/Medium.zip"; head -c $((1*K)) /dev/zero > "$LB/maps/base.zip"
stampit() { python3 - "$LB" "$@" <<'EOF'
import json, os, sys
d, keys = sys.argv[1], sys.argv[2:]; f = os.path.join(d, ".lastbook-verified.json")
s = json.load(open(f)) if os.path.exists(f) else {}
for k in keys:
    if k.endswith(".part"):
        s[k] = {"part": True}; continue
    st = os.stat(os.path.join(d, k))
    s[k] = dict(sha256="0" * 64, size=st.st_size, mtime_ns=st.st_mtime_ns, **({"pack": "x"} if k.startswith("packs/") else {}))
json.dump(s, open(f, "w"))
EOF
}
stampit packs/Medium.zip maps/base.zip
plan $((100*K)) > "$T/p"
check "held Medium: neither Small nor Medium is planned again" '[ -z "$(packs < "$T/p")" ]'
check "held Medium: maps / model / installers follow the held pack" 'has lastbook:map:CA < "$T/p" && has lastbook:app:1.1.11 < "$T/p"'
plan $((1000*K)) > "$T/p"
check "held Medium + room: All is still an upgrade" '[ "$(packs < "$T/p")" = all ]'
echo junk >> "$LB/packs/Medium.zip"
plan $((100*K)) > "$T/p"
check "held file at the wrong size is not held: Medium planned again" '[ "$(packs < "$T/p")" = medium ]'
rm -f "$LB/packs/Medium.zip"; ln -s "$LB/maps/base.zip" "$LB/packs/Medium.zip"
plan $((100*K)) > "$T/p"
check "a symlink is not a held pack" '[ "$(packs < "$T/p")" = medium ]'
rm -f "$LB/packs/Medium.zip" "$LB/.lastbook-verified.json"
head -c $((8*K)) /dev/zero > "$LB/packs/Small.zip.part"; stampit packs/Small.zip.part
plan $((5*K)) > "$T/p"
check "a recorded .part is not a held pack: Small is planned (to resume it), not satisfied" '[ "$(packs < "$T/p")" = small ]'
rm -f "$LB/packs/Small.zip.part" "$LB/.lastbook-verified.json"
head -c $((8*K)) /dev/zero > "$LB/packs/Small.zip"; stampit packs/Small.zip
plan $((5*K)) > "$T/p"
check "held Small, 5 KB: no pack, but the installers + a map that fit follow it" '[ -z "$(packs < "$T/p")" ] && has lastbook:app:1.1.11 < "$T/p" && has lastbook:map:CA < "$T/p"'
rm -rf "$LB/packs" "$LB/.lastbook-verified.json"

# a .part is credited: Medium.zip.part holds 60 of 68 KB, so Medium costs 9 KB (with the base map)
mkdir -p "$LB/packs"; head -c $((60*K)) /dev/zero > "$LB/packs/Medium.zip.part"
plan $((20*K)) > "$T/p"
check ".part credited: at 20 KB Medium (resuming its .part) is planned, not Small" '[ "$(packs < "$T/p")" = medium ]'
check ".part credited: the row is emitted with the bytes still to fetch" '[ "$(awk -F"\t" "\$1==\"lastbook:pack:medium\" {print \$5}" "$T/p")" = $((9*K)) ]'
echo x >> "$LB/packs/Medium.zip.part"; head -c $((70*K)) /dev/zero > "$LB/packs/Medium.zip.part"
plan $((20*K)) > "$T/p"
check "an oversized .part is not credited (Small, not Medium)" '[ "$(packs < "$T/p")" = small ]'
rm -rf "$LB/packs"
# lb_on_disk: the stamps size must match the file AND the size the row lists
mkdir -p "$LB/packs"; head -c $((8*K)) /dev/zero > "$LB/packs/Small.zip"; stampit packs/Small.zip
check "lb_on_disk: recorded + listed size match -> held; a listed size that differs -> not held" "python3 -I -c '
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"p\",\"$P\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
ok=m.lb_on_disk(\"$LB\",\"packs/Small.zip\",$((8*K))) and not m.lb_on_disk(\"$LB\",\"packs/Small.zip\",$((7*K)))
sys.exit(0 if ok else 1)'"
rm -rf "$LB/packs" "$LB/.lastbook-verified.json"
# held_top is per PACK: a held two-file Medium (2 x 34 KB) satisfies a 50 KB pack (no single file does)
mkdir -p "$LB/packs"; head -c $((34*K)) /dev/zero > "$LB/packs/M1.zip"; head -c $((34*K)) /dev/zero > "$LB/packs/M2.zip"
stampit packs/M1.zip packs/M2.zip
python3 - "$LB/.lastbook-verified.json" <<'EOF'
import json, sys; f = sys.argv[1]; s = json.load(open(f))
for k in s: s[k]["pack"] = "medium"
json.dump(s, open(f, "w"))
EOF
{ row lastbook:pack:mid content lastbook:pack 830 $((50*K)) "$LB" "pack|-|packs/Mid.zip=$((50*K))"
  row lastbook:pack:medium content lastbook:pack 840 $((68*K)) "$LB" "pack|-|packs/M1.zip=$((34*K)),packs/M2.zip=$((34*K))"; } > "$T/c-multi.tsv"
python3 "$P" --budget $((100*K)) < "$T/c-multi.tsv" > "$T/p" 2>/dev/null
check "per-pack held size: a held two-file Medium (68 KB) satisfies a 50 KB pack" '[ -z "$(packs < "$T/p")" ]'
rm -rf "$LB/packs" "$LB/.lastbook-verified.json"
# a held pack re-released under a new name is charged (its refresh downloads it), not "satisfied"
mkdir -p "$LB/packs"; head -c $((389*K)) /dev/zero > "$LB/packs/All-old.zip"; stampit packs/All-old.zip
python3 - "$LB/.lastbook-verified.json" <<'EOF'
import json, sys; f = sys.argv[1]; s = json.load(open(f)); s["packs/All-old.zip"]["pack"] = "all"; json.dump(s, open(f, "w"))
EOF
plan $((1000*K)) > "$T/p"
check "re-released held All (new name): planned and charged; Small/Medium still satisfied" '[ "$(packs < "$T/p")" = all ] && [ "$(awk -F"\t" "\$1==\"lastbook:pack:all\" {print \$5}" "$T/p")" = $((390*K)) ]'
plan $((100*K)) > "$T/p"
check "re-released held All that does not fit: nothing re-planned, maps still follow the held pack" '[ -z "$(packs < "$T/p")" ] && has lastbook:map:CA < "$T/p"'
rm -rf "$LB/packs" "$LB/.lastbook-verified.json"

# --- 3. essentials (survival) ---------------------------------------------------------------------
E="$ROOT/data/essentials.tsv"
plan $((15*K)) --essentials "$E" --profile survival > "$T/p"
check "survival: Small pack planned in phase 0" 'awk -F"\t" "\$1==\"lastbook:pack:small\" && \$10==0" "$T/p" | grep -q .'
check "survival: installers in phase 0 after the pack" 'awk -F"\t" "\$1==\"lastbook:app:1.1.11\" && \$10==0" "$T/p" | grep -q .'
plan $((1000*K)) --essentials "$E" --profile survival > "$T/p"
check "survival + big disk: the essential Small STAYS planned beside All (fetched first; pruned once All verifies)" '[ "$(packs < "$T/p")" = "all small" ]'
check "survival + big disk: Small is phase 0, All a later phase" 'awk -F"\t" "\$1==\"lastbook:pack:small\" && \$10==0" "$T/p" | grep -q . && awk -F"\t" "\$1==\"lastbook:pack:all\" && \$10!=0" "$T/p" | grep -q .'
plan $((100*K)) --essentials "$E" --profile survival > "$T/p"
check "survival + 100 KB: essential Small + Medium (a later Medium pick is still replaced, Small kept)" '[ "$(packs < "$T/p")" = "medium small" ]'
plan $((15*K)) --essentials "$E" --profile balanced > "$T/p"
check "balanced: Lastbook is not an essential (no phase-0 Lastbook rows)" '! awk -F"\t" "\$1 ~ /^lastbook:/ && \$10==0" "$T/p" | grep -q .'
mkdir -p "$LB/packs"; head -c $((68*K)) /dev/zero > "$LB/packs/Medium.zip"; stampit packs/Medium.zip
plan $((15*K)) --essentials "$E" --profile survival > "$T/p"
check "survival + held Medium: the Small essential is satisfied (not planned)" '[ -z "$(packs < "$T/p")" ]'
rm -rf "$LB/packs" "$LB/.lastbook-verified.json"

# --- 4. competes with other content; never in the web catalog -----------------------------------------
{ cands; printf 'zim:a_en\tcontent\tzim:wikipedia\t990\t%s\tzim\thttps://x/a.zim\t%s/a.zim\ta\n' $((12*K)) "$T"; } > "$T/c2.tsv"
python3 "$P" --budget $((15*K)) < "$T/c2.tsv" > "$T/p" 2>/dev/null
check "15 KB with a 12 KB ZIM: both diversity picks cannot fit; the plan stays within budget" \
    '[ "$(awk -F"\t" "{s+=\$5} END {print s+0}" "$T/p")" -le $((15*K)) ]'
python3 "$P" --budget 1 --list-absent < "$T/c2.tsv" > "$T/p" 2>/dev/null
check "--list-absent: no Lastbook rows (no per-item request path)" '! grep -q "^lastbook:" "$T/p" && grep -q "^zim:a_en" "$T/p"'
# the Lastbook model has its own category: a held Lastbook GGUF does not cover model:assistant, and
# it never takes a diversity slot itself
{ cands; printf 'model:qwen\tmodels\tmodel:assistant\t700\t%s\thf-file\thttps://huggingface.co/x/resolve/main/q.gguf\t%s/m\tx/q\n' $((2*K)) "$T"; } > "$T/c3.tsv"
mkdir -p "$LB/models" "$LB/packs"; head -c $((17*K)) /dev/zero > "$LB/models/g.gguf"; head -c $((8*K)) /dev/zero > "$LB/packs/Small.zip"; stampit models/g.gguf packs/Small.zip
python3 "$P" --budget $((3*K)) < "$T/c3.tsv" > "$T/p" 2>/dev/null
check "a held Lastbook GGUF does not cover model:assistant (the curated assistant keeps its diversity slot)" 'awk -F"\t" "\$1==\"model:qwen\" && \$10==1" "$T/p" | grep -q .'
rm -rf "$LB/models" "$LB/packs" "$LB/.lastbook-verified.json"
python3 "$P" --budget $((30*K)) < "$T/c3.tsv" > "$T/p" 2>/dev/null
check "the Lastbook model never takes a diversity (phase 1) slot" '! awk -F"\t" "\$1==\"lastbook:model:gemma\" && \$10==1" "$T/p" | grep -q .'
python3 "$P" --budget $((1000*K)) --model-max-bytes $((10*K)) < "$T/c.tsv" > "$T/p" 2>/dev/null
check "small-models policy (VALARK_MODEL_MAX_GB) drops the Lastbook model too" '! has lastbook:model:gemma < "$T/p"'

# --- 5. catalog.sh feed --------------------------------------------------------------------------------
D="$T/data"; mkdir -p "$D"
cat_sh() { (unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED; export VAL_ARK_DATA="$D" VAL_ARK_CONFIG="$T/none.env"
    . "$ROOT/scripts/lib/catalog.sh"; mkdir -p "$CATALOG_DIR"; eval "$1") }
cat_sh '{ echo "# lastbook candidates manifest=x app=1.1.11 rows=6"; cands; } > "$LASTBOOK_CACHE"'
check "catalog: a cache without the format=2 header is ignored (it baked in an old selection)" '[ -z "$(cat_sh catalog_lastbook_candidates)" ]'
cat_sh '{ echo "# lastbook candidates format=2 manifest=x app=1.1.11 maps=all addresses=follow model=auto apps=current rows=6"; cands | sed "s#\t$LB\t#\t/old/place\t#"; } > "$LASTBOOK_CACHE"'
cat_sh 'catalog_lastbook_candidates' > "$T/feed"
check "catalog: six rows, comment dropped" '[ "$(wc -l < "$T/feed")" = 6 ]'
VALARK_LASTBOOK_MODEL=no VALARK_LASTBOOK_APPS=none cat_sh 'catalog_lastbook_candidates' > "$T/f2"
check "catalog: MODEL=no / APPS=none apply at once (stale cache or not)" '! grep -q "^lastbook:model:" "$T/f2" && ! grep -q "^lastbook:app:" "$T/f2" && grep -q "^lastbook:pack:small" "$T/f2"'
VALARK_LASTBOOK_MAPS=none cat_sh 'catalog_lastbook_candidates' > "$T/f2"
check "catalog: MAPS=none drops the maps" '! grep -q "^lastbook:map:" "$T/f2"'
VALARK_LASTBOOK_MAPS=tx cat_sh 'catalog_lastbook_candidates' > "$T/f2"
check "catalog: MAPS=TX keeps only TX (CA dropped)" '! grep -q "^lastbook:map:CA" "$T/f2"'
VALARK_LASTBOOK_ADDRESSES=none cat_sh 'catalog_lastbook_candidates' > "$T/f2"
check "catalog: ADDRESSES=none strips the address index and its bytes from each map row" 'grep -q "^lastbook:map:CA	content	lastbook:maps	640	$((3*K))	lastbook	.*	map|pack|maps/CA.zip=$((3*K))$" "$T/f2"'
check "catalog: dest re-pointed at the current Lastbook dir" '[ "$(cut -f8 "$T/feed" | sort -u)" = "$D/val-ark/content/lastbook" ]'
check "catalog: balanced profile keeps values" 'grep -q "^lastbook:pack:small	content	lastbook:pack	820	" "$T/feed"'
VALARK_PROFILE=survival cat_sh 'catalog_lastbook_candidates' > "$T/feed"
check "catalog: survival weights content (x1.4) and models (x0.8)" \
    'grep -q "^lastbook:pack:small	content	lastbook:pack	1148	" "$T/feed" && grep -q "^lastbook:model:gemma	models	lastbook:model	448	" "$T/feed"'
check "catalog: large byte counts kept verbatim" 'VALARK_PROFILE=survival cat_sh "sed -i \"s/\t$((390*K))\t/\t387878571619\t/\" \"\$LASTBOOK_CACHE\"; catalog_lastbook_candidates" | grep -q "	387878571619	lastbook	"'
for v in "VALARK_LASTBOOK_PACK=every" "VALARK_LASTBOOK_PACK=small" "VALARK_LASTBOOK_BUDGET=-1" "VALARK_LASTBOOK_BUDGET_PCT=50" "VALARK_LASTBOOK_PLAN=0" "VALARK_LASTBOOK_ADDRESSES=all" "VALARK_LASTBOOK_ADDRESSES=CA,TX"; do
    check "catalog: no Lastbook rows with $v (the operator chose)" '[ -z "$(env "$v" bash -c "$(declare -f cat_sh); D=$D T=$T ROOT=$ROOT; cat_sh catalog_lastbook_candidates")" ]'
done
check "catalog: a Lastbook dir on another filesystem than the data root -> share mode (no rows)" \
    '[ -z "$(cat_sh "_lb_dev() { case \"\$1\" in */lastbook) echo 2 ;; *) echo 1 ;; esac; }; catalog_lastbook_candidates")" ] && cat_sh "_lb_dev() { case \"\$1\" in */lastbook) echo 2 ;; *) echo 1 ;; esac; }; catalog_lastbook_manual_reason" | grep -q "another filesystem"'
check "catalog: same filesystem -> planner mode" '[ -z "$(cat_sh catalog_lastbook_manual_reason)" ]'
check "catalog: refresh is a no-op when the operator chose (no network)" \
    'VALARK_LASTBOOK_PACK=every cat_sh "rm -f \"\$LASTBOOK_CACHE\".attempt; catalog_refresh_lastbook; [ ! -e \"\$LASTBOOK_CACHE\".attempt ]"'
check "catalog: a failed refresh keeps the cache and backs off" \
    'cat_sh "LASTBOOK_PY=/nonexistent; cp \"\$LASTBOOK_CACHE\" \"$T/keep\"; catalog_refresh_lastbook --force; rc=\$?; cmp -s \"\$LASTBOOK_CACHE\" \"$T/keep\" && [ -e \"\$LASTBOOK_CACHE.attempt\" ] && [ \$rc = 1 ]"'

# --- 6. librarian.sh fill: one batch, never in the manifest ---------------------------------------------
bash -c '
TT="$2"; export VAL_ARK_DATA="$1" VAL_ARK_CONFIG="$2/none.env" FORCE_COLOR=0
. "$3/scripts/librarian.sh"; ensure_state
catalog_refresh_zim() { :; }; catalog_refresh_lastbook() { :; }; valark_budget_bytes() { echo 1000000; }
valark_fillable_bytes() { echo 100000000000; }
gen_candidates() { cat "$TT/c.tsv"; }
download_one() { echo "download_one $1" >> "$TT/calls"; return 0; }
lastbook_fill() { echo "lastbook_fill $(cut -f1 "$1" | sort | tr "\n" " ")" >> "$TT/calls"; return 0; }
prune_superseded() { :; }
cmd_fill >/dev/null 2>"$TT/fill.err"
[ -f "$MANIFEST" ] && grep -q "^lastbook:" "$MANIFEST" && echo "IN-MANIFEST" >> "$TT/calls"
exit 0' _ "$D" "$T" "$ROOT"
check "fill: exactly one lastbook_fill call" '[ "$(grep -c ^lastbook_fill "$T/calls")" = 1 ]'
check "fill: the batch holds every planned Lastbook row (one pack)" 'grep -q "^lastbook_fill lastbook:app:1.1.11 lastbook:map:CA lastbook:model:gemma lastbook:pack:all $" "$T/calls"'
check "fill: Lastbook rows never go through download_one" '! grep -q "^download_one lastbook:" "$T/calls"'
check "fill: Lastbook rows never enter the librarian manifest" '! grep -q IN-MANIFEST "$T/calls"'
check "librarian.sh has lastbook-plan" 'grep -q "lastbook-plan) shift; cmd_lastbook_plan" "$ROOT/scripts/librarian.sh"'

# fill harness: FILLENV extra shell code runs after the stubs (override them per case)
fillrun() {  # fillrun NAME 'extra stub code' [cmd_fill args...]
    local name="$1" extra="$2"; shift 2
    : > "$T/calls"; mkdir -p "$T/fd-$name"
    bash -c '
TT="$2"; export VAL_ARK_DATA="$1" VAL_ARK_CONFIG="$2/none.env" FORCE_COLOR=0
. "$3/scripts/librarian.sh"; ensure_state
catalog_refresh_zim() { :; }; catalog_refresh_lastbook() { :; }; valark_budget_bytes() { echo 1000000; }
valark_fillable_bytes() { echo 100000000000; }
gen_candidates() { cat "$TT/c-fill.tsv"; }
download_one() { echo "download_one $1" >> "$TT/calls"; return 0; }
lastbook_fill() { echo "lastbook_fill secs=${2:-0} $(cut -f1 "$1" | sort | tr "\n" " ")" >> "$TT/calls"; echo 4242 > "$TMPDIR_VA/lastbook-added"; return 0; }
cmd_evict() { echo "evict $*" >> "$TT/calls"; }
prune_superseded() { :; }
eval "$4"; shift 4
cmd_fill "$@" > "$TT/fill.out" 2>"$TT/fill.err"
exit 0' _ "$T/fd-$name" "$T" "$ROOT" "$extra" "$@"
}
{ cands; printf 'zim:z_en\tcontent\tzim:other\t500\t0\tzim\thttps://x/z.zim\t%s/z.zim\tz\n' "$T"; } > "$T/c-fill.tsv"
# survival: the phase-0 essentials (Small + installers) in their own batch first, then everything
VALARK_PROFILE=survival fillrun surv ''
check "fill, survival: two Lastbook batches" '[ "$(grep -c ^lastbook_fill "$T/calls")" = 2 ]'
check "fill, survival: batch 1 = the phase-0 essentials only (Small + installers)" '[ "$(grep ^lastbook_fill "$T/calls" | head -1)" = "lastbook_fill secs=0 lastbook:app:1.1.11 lastbook:pack:small " ]'
check "fill, survival: batch 2 = every planned row (Small kept beside All)" 'grep ^lastbook_fill "$T/calls" | sed -n 2p | grep -q "lastbook:pack:all lastbook:pack:small $"'
# the remaining --time budget bounds the batch; only bytes a run really added are counted
fillrun timed '' --time 600
check "fill --time 600: the Lastbook batch gets the remaining seconds" 'grep ^lastbook_fill "$T/calls" | grep -qE "secs=(59[0-9]|600) "'
check "fill: counts the bytes the mirror reported (4242 = 4.2KB), not the planned total" 'grep -q "OK lastbook (4.2KB added)" "$T/fill.out" && grep -q "fill done: .* 4.2KB added" "$T/fill.out"'
fillrun busy 'lastbook_fill() { echo busy >> "$TT/calls"; rm -f "$TMPDIR_VA/lastbook-added"; return 75; }'
check "fill: a busy Lastbook lock (75) is a skip: no failure, nothing counted" 'grep -q "another Lastbook mirror run is active" "$T/fill.out" && grep -q "0 failed" "$T/fill.out" && ! grep -q "lastbook (exit" "$T/fill.out"'
fillrun tight 'valark_fillable_bytes() { echo 1073741824; }'
check "fill: headroom is checked against the whole Lastbook batch (skipped), smaller items still go" \
    '! grep -q ^lastbook_fill "$T/calls" && grep -q "for the Lastbook batch" "$T/fill.out" && grep -q "^download_one zim:z_en" "$T/calls"'
fillrun stop ': > "$STOP_FLAG"; lastbook_fill() { echo "stopflag=$VALARK_STOP_FLAG" >> "$TT/calls"; return 0; }'
check "fill: a STOP flag halts before the Lastbook batch" '! grep -q "^lastbook_fill\|^stopflag" "$T/calls"'
check "fill: lastbook_fill passes the STOP flag and a timeout to lastbook.sh" 'grep -q "VALARK_STOP_FLAG=\"\$STOP_FLAG\"" "$ROOT/scripts/librarian.sh" && grep -q "timeout --kill-after=60" "$ROOT/scripts/librarian.sh"'

# --- 7. request never resolves a Lastbook row (no per-item path), and refuses before evicting ---------------
reqrun() {  # reqrun 'extra stub code' KIND ID
    : > "$T/calls"; mkdir -p "$T/rq"
    bash -c '
TT="$2"; export VAL_ARK_DATA="$1" VAL_ARK_CONFIG="$2/none.env" FORCE_COLOR=0
. "$3/scripts/librarian.sh"; ensure_state; : > "$PINS"
catalog_refresh_zim() { :; }; catalog_refresh_lastbook() { :; }; valark_budget_bytes() { echo 1; }
gen_candidates() { cat "$TT/c.tsv"; }
download_one() { echo "download_one $1" >> "$TT/calls"; return 1; }
cmd_evict() { echo "evict $*" >> "$TT/calls"; }
eval "$4"
cmd_request "$5" "$6" > "$TT/req.out" 2>&1; echo "rc=$?" >> "$TT/calls"
[ -s "$PINS" ] && echo "PINNED $(cut -f2 "$PINS")" >> "$TT/calls"
exit 0' _ "$T/rq" "$T" "$ROOT" "$1" "$2" "$3"
}
reqrun '' model gemma
check "request model gemma: no match (never the 17 GB Lastbook GGUF), no pin, no eviction" 'grep -q "^rc=1" "$T/calls" && ! grep -q "^PINNED\|^evict\|^download_one" "$T/calls"'
reqrun '' content lastbook
check "request content lastbook: no match (never pack:all)" 'grep -q "^rc=1" "$T/calls" && ! grep -q "^PINNED\|^evict" "$T/calls"'
reqrun 'resolve_candidate() { grep "^lastbook:pack:all	" "$TT/c.tsv"; }' content all
check "request: a source download_one cannot fetch is refused BEFORE any pin or eviction" 'grep -q "^rc=1" "$T/calls" && ! grep -q "^PINNED\|^evict\|^download_one" "$T/calls" && grep -q "no per-item request path" "$T/req.out"'

echo "lastbook-planner: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
