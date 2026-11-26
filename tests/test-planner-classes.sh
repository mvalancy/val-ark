#!/bin/bash
###############################################################################
# Test: the planner's CLASS ORDER (#347): apps and library before AI models.
# Offline, fixtures only (no catalog fetch, no downloads).
#
#  * after the phase-0 essentials, every app (installer) and library (ZIM,
#    Lastbook) candidate that fits is planned before any AI model; datasets and
#    other bulk rows come after the models.
#  * models are planned once the apps + library are exhausted, or the rest does
#    not fit (a ZIM too big for the budget left does not block a small model).
#  * a tiny disk still gets the essentials first, the essential assistant model
#    included, even when the library does not fit.
#  * the order holds whatever the values say (profile weights only rank inside
#    a class); the one exception: --profile ai keeps one small model early.
#  * diversity still applies inside each class (one item per category first).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/require-cmd.sh"; require_python3 "planner class order"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P="$ROOT/scripts/lib/planner.py"
MB=1048576; GB=$((1024*MB))

# id bucket category value bytes source url dest extra
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
z() { row "zim:$1" content "zim:$2" "$3" "$4" zim "https://x/$1.zim" "$T/z/$1.zim" "$1"; }
m() { row "model:$1" models "model:$2" "$3" "$4" hf-file "https://x/$1.gguf" "$T/m/$1" "r/$1"; }
i() { row "inst:$1" installers "inst:$2" "$3" "$4" url "https://x/$1.iso" "$T/i/$1.iso" ""; }
{
  # apps (installers)
  i netboot      netboot          900 $((2*MB))
  i alpine       os-install       700 $((60*MB))
  i ubuntu       os-install       650 $((900*MB))
  i gitea-src    server-source    600 $((40*MB))
  i openwrt      router-firmware  500 $((10*MB))
  # library (ZIMs: books, references, videos) + a Lastbook pack and map
  z water_en     other            600 $((20*MB))
  z gutenberg_en gutenberg        800 $((700*MB))
  z wikipedia_en wikipedia        900 $((1500*MB))
  z ted_en       ted              600 $((300*MB))
  z devdocs_en   devdocs          720 $((30*MB))
  row lastbook:pack:small content lastbook:pack 700 $((400*MB)) lastbook https://x/lb "$T/lb" "pack|-|packs/small.zim=$((400*MB))"
  row lastbook:map:ca     content lastbook:maps 600 $((100*MB)) lastbook https://x/lb "$T/lb" "map|pack|maps/ca.pmtiles=$((100*MB))"
  # models: high values and tiny sizes, so value/byte alone would plan them first
  m assistant    assistant        999 $((900*MB))
  m tinyembed    embed            999 $((50*MB))
  m tinyvlm      tiny-vlm         999 $((300*MB))
  m code7b       code             950 $((4500*MB))
  row model:scout-a--b models model:small-llm 990 $((20*MB)) hf-repo a/b "$T/m/scout" "*"
  row lastbook:model:gemma models lastbook:model 800 $((200*MB)) lastbook https://x/lb "$T/lb" "model|pack|models/g.gguf=$((200*MB))"
  # bulk (datasets)
  row ds:open-data datasets ds:open 999 $((5*MB)) url https://x/ds.tar "$T/d/ds.tar" ""
} > "$T/cands.tsv"
cat > "$T/ess.tsv" <<'EOF'
10|zim|water_en|all|water
32|model|assistant|all|small offline assistant
EOF
plan() { python3 "$P" --essentials "$T/ess.tsv" "$@" < "$T/cands.tsv" 2>"$T/err"; }
cls() {   # id bucket -> class (mirrors planner.item_class)
  awk -F'\t' '{ c = ($2=="installers") ? "apps" : ($2=="models") ? "models" : ($2=="content" || $6=="lastbook") ? "library" : "bulk";
                print $1 "\t" c "\t" $10 }'
}
APPS_LIB="inst:netboot inst:alpine inst:ubuntu inst:gitea-src inst:openwrt zim:water_en zim:gutenberg_en zim:wikipedia_en zim:ted_en zim:devdocs_en lastbook:pack:small lastbook:map:ca"

# order_ok FILE: no app after a library/model/bulk row, no library after a model/bulk, no model
# after a bulk row (phase-0 rows and the ai early model are exempt via $2 = rows to skip).
order_ok() {
  awk -F'\t' -v skip="${2:-}" 'BEGIN { r["apps"]=1; r["library"]=2; r["models"]=3; r["bulk"]=4; split(skip, s, " "); for (k in s) sk[s[k]]=1 }
       $3 == 0 || ($1 in sk) { next }
       { if (r[$2] < hi) { print "out of order: " $1 " (" $2 ") after a later class"; bad=1 } if (r[$2] > hi) hi = r[$2] }
       END { exit bad }' "$1"
}

# 1. A disk that fits apps + library + some models: all apps + library first, then models.
plan --budget $((5*GB)) | cls > "$T/p1"
for id in $APPS_LIB; do grep -q "^$id	" "$T/p1" || fail "budget 5G: $id (app/library) must be planned"; done; pass
order_ok "$T/p1" && pass || fail "budget 5G: class order broken: $(order_ok "$T/p1")"
grep -q $'^model:assistant\tmodels\t0$' "$T/p1" && pass || fail "the essential assistant model stays in phase 0"
[ "$(head -1 "$T/p1" | cut -f1)" = "zim:water_en" ] && pass || fail "essentials lead the plan"
awk -F'\t' '$3!=0 && $2=="models"' "$T/p1" | grep -q . && pass || fail "budget 5G: some models must be planned after the library"
FIRST_MODEL=$(awk -F'\t' '$3!=0 && $2=="models" {print NR; exit}' "$T/p1")
LAST_AL=$(awk -F'\t' '$3!=0 && ($2=="apps" || $2=="library") {n=NR} END {print n}' "$T/p1")
[ "$FIRST_MODEL" -gt "$LAST_AL" ] && pass || fail "first non-essential model (line $FIRST_MODEL) before the last app/library row (line $LAST_AL)"
# datasets / bulk after the models
BULK=$(awk -F'\t' '$2=="bulk" {print NR; exit}' "$T/p1")
LAST_M=$(awk -F'\t' '$2=="models" {n=NR} END {print n}' "$T/p1")
[ -n "$BULK" ] && [ "$BULK" -gt "$LAST_M" ] && pass || fail "bulk (datasets) must come after the models (bulk line '$BULK', last model $LAST_M)"
grep -q 'by class: apps=' "$T/err" && pass || fail "planner summary must report the per-class counts"

# 2. Diversity inside a class: the library's phase-1 rows cover each library category once,
#    and the apps class does the same before its phase 2/3.
awk -F'\t' '$2=="library" && $3==1 {print $1}' "$T/p1" | grep -q 'zim:ted_en' && pass || fail "library diversity: ted (its own category) must get a phase-1 slot"
python3 "$P" --essentials "$T/ess.tsv" --budget $((5*GB)) < "$T/cands.tsv" 2>/dev/null \
  | awk -F'\t' '$2=="installers" && $10==1 {print $3}' | sort | uniq -d | grep -q . \
  && fail "apps diversity: two phase-1 rows in one category" || pass

# 3. At any budget, a non-essential model is planned only when no unplanned app or library
#    item would have fitted in what the apps + library passes left (budget minus essentials,
#    apps and library planned). Checked over a sweep of budgets.
starved() {   # BUDGET PLANFILE -> prints the app/library ids a model displaced
  awk -F'\t' -v B="$1" 'FNR==NR { if ($3==0 || $2=="apps" || $2=="library") used[$1]=1; planned[$1]=1; next }
       ($1 in used) { spent += $5 } { c[$1]=$2; sz[$1]=$5 }
       END { for (k in c) if ((c[k]=="installers" || c[k]=="content") && !(k in planned) && sz[k] <= B - spent) print k }' "$2" "$T/cands.tsv"
}
for gb in 1 1.5 2 2.5 3 3.5 4; do
  B=$(awk -v g="$gb" 'BEGIN { printf "%.0f", g * 1073741824 }')
  plan --budget "$B" | cls > "$T/p3"
  S=$(starved "$B" "$T/p3")
  if awk -F'\t' '$2=="models" && $3!=0' "$T/p3" | grep -q . && [ -n "$S" ]; then
    fail "budget ${gb}G: a model was planned while these app/library items still fitted: $S"
  else pass; fi
  order_ok "$T/p3" && pass || fail "budget ${gb}G: class order broken: $(order_ok "$T/p3")"
done
# ...and a 2 GB disk spends what is left after the essentials on apps + library.
plan --budget $((2*GB)) | cls > "$T/p3"
awk -F'\t' '$2=="library" && $3!=0' "$T/p3" | grep -q . && pass || fail "budget 2G: library items must be planned"

# 4. "Does not fit" ends the class: when only a ZIM too big for the rest is left, models follow.
#    Budget = everything except wikipedia (1.5 GB) + a little room for small models.
AL_BYTES=$(awk -F'\t' '($2=="installers" || $2=="content") && $1!="zim:wikipedia_en" {s+=$5} END {print s}' "$T/cands.tsv")
B4=$(( AL_BYTES + 900*MB + 400*MB ))   # + the essential assistant + room for small models
plan --budget "$B4" | cls > "$T/p4"
grep -q '^zim:wikipedia_en' "$T/p4" && fail "budget: wikipedia should not fit here" || pass
awk -F'\t' '$2=="models" && $3!=0' "$T/p4" | grep -q . && pass || fail "a library item too big for the budget must not block the models that fit"
order_ok "$T/p4" && pass || fail "budget (no wikipedia): class order broken"

# 5. Tiny disk: the essentials first (assistant model included), nothing jumps them.
plan --budget $((950*MB)) | cls > "$T/p5"
[ "$(cut -f1 "$T/p5" | head -2 | tr '\n' ' ')" = "zim:water_en model:assistant " ] && pass \
  || fail "tiny disk: essentials (water, the assistant) must come first: $(cut -f1 "$T/p5" | tr '\n' ' ')"
awk -F'\t' '$2=="models" && $3!=0' "$T/p5" | grep -q . && fail "tiny disk: no model beyond the essentials" || pass
plan --budget $((25*MB)) | cut -f1,10 > "$T/p5b"
[ "$(head -1 "$T/p5b")" = $'zim:water_en\t0' ] && pass || fail "a 25 MB disk still gets the first essential (got '$(head -1 "$T/p5b")')"

# 6. The order holds whatever the values say (a profile weight only scales values in a class):
#    every model valued 999 vs installers ~500-900 above; and a "tools"-like low app value too.
sed 's/^\(inst:[^\t]*\tinstallers\t[^\t]*\t\)[0-9]*/\1100/' "$T/cands.tsv" > "$T/lowapps.tsv"
python3 "$P" --essentials "$T/ess.tsv" --budget $((5*GB)) --profile knowledge < "$T/lowapps.tsv" 2>/dev/null | cls > "$T/p6"
order_ok "$T/p6" && pass || fail "low app values (profile weights) must not reorder the classes"
for prof in balanced knowledge tools survival; do
  plan --budget $((5*GB)) --profile "$prof" | cls > "$T/p6.$prof"
  order_ok "$T/p6.$prof" && pass || fail "profile $prof: class order broken"
done

# 7. The ai profile's one exception: ONE small curated model right after the essentials.
plan --budget $((5*GB)) --profile ai | cls > "$T/p7"
EARLY=$(awk -F'\t' '$3!=0 {print $1 "\t" $2; exit}' "$T/p7")
[ "$(cut -f2 <<<"$EARLY")" = models ] && pass || fail "ai profile: the first row after the essentials should be its early model (got '$EARLY')"
EID=$(cut -f1 <<<"$EARLY")
[ "$EID" != "model:scout-a--b" ] && [ "$EID" != "lastbook:model:gemma" ] && pass || fail "ai early model must be curated (got $EID)"
order_ok "$T/p7" "$EID" && pass || fail "ai profile: apart from its one early model, class order must hold"
N_EARLY=$(awk -F'\t' '$3!=0 && $2=="models" {n++} $3!=0 && $2!="models" {exit} END {print n+0}' "$T/p7")
[ "$N_EARLY" = 1 ] && pass || fail "ai profile: exactly one model before the apps (got $N_EARLY)"
plan --budget $((2*GB)) --profile ai | cls > "$T/p7b"
EID2=$(awk -F'\t' '$3!=0 {print $1; exit}' "$T/p7b")
[ "$EID2" = "$EID" ] && pass || fail "ai profile on a small disk: the early model still leads (got $EID2)"
order_ok "$T/p7b" "$EID2" && pass || fail "ai profile on a small disk: apart from the early model, class order must hold"

# 8. Held items: an app already on disk does not hold the models back.
mkdir -p "$T/i"
awk -F'\t' '$2=="installers" {print $8 "\t" $5}' "$T/cands.tsv" | while IFS=$'\t' read -r d b; do truncate -s "$b" "$d"; done
plan --budget $((5*GB)) | cls > "$T/p8"
grep -q '^inst:' "$T/p8" && fail "held installers must not be re-planned" || pass
order_ok "$T/p8" && pass || fail "with apps held: library still before models"
rm -rf "$T/i"

echo "planner-classes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
