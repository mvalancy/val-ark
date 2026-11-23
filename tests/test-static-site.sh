#!/bin/bash
###############################################################################
# Test: static browse pages (scripts/lib/static_site.py, `librarian.sh site`, #257).
# All offline, on a throwaway tree. Invariants:
#   - index.html + browse/<section>.html for every non-empty section, none for empty ones;
#     sections are found by dir name (models, content, tools, ...), anything else
#     (state/, private/) is never listed
#   - every href / src is RELATIVE (no scheme, no leading '/'): works over file:// and plain
#     file servers; no external URL anywhere in the pages
#   - hostile file names are escaped in text and percent-encoded in links (no markup injection)
#   - model cards: excerpt + licence from README front matter; ZIM names explained
#   - caps: --max-rows summarises the rest, --max-files caps the per-entry file list,
#     --walk-limit marks a section as partial
#   - --listing (no walk) and --pending (queued chips) feed the same pages; --walk adds a
#     section the listing does not cover
#   - leftovers (*.part, dot files) are ignored; an unchanged page is not rewritten
#   - exit codes: 0 ok, 1 missing root, 64 usage
#   - librarian.sh site writes the pages for the data-root layout (models outside VALARK_HOME)
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; fi; }
PY="$ROOT/scripts/lib/static_site.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
A="$T/a"
mkdir -p "$A/models/huggingface/acme/tiny-7b/sub" "$A/models/llm/qwen" "$A/content/zim" \
         "$A/tools/linux-arm64/btop" "$A/state" "$A/private/secret-stuff" "$A/installers/ubuntu"
cat > "$A/models/huggingface/acme/tiny-7b/README.md" <<'EOF'
---
license: apache-2.0
pipeline_tag: text-generation
---
# Tiny 7B

![badge](https://img.shields.io/x.svg)

Tiny 7B is a small but capable [language model](https://example.com/x) trained for offline use.
EOF
head -c 5000 /dev/zero > "$A/models/huggingface/acme/tiny-7b/model.safetensors"
: > "$A/models/huggingface/acme/tiny-7b/LICENSE"
for i in 1 2 3 4 5 6; do head -c $((i * 10)) /dev/zero > "$A/models/huggingface/acme/tiny-7b/sub/f$i.bin"; done
head -c 100 /dev/zero > "$A/models/huggingface/acme/tiny-7b/big.part"
head -c 100 /dev/zero > "$A/models/llm/qwen/q.gguf"
head -c 9000 /dev/zero > "$A/content/zim/wikipedia_en_all_maxi_2024-01.zim"
echo x > "$A/content/zim/<img src=x onerror=alert(1)>.zim"
echo x > "$A/content/zim/a\"b&c d.zim"
echo x > "$A/content/zim/.hidden.zim"
echo hi > "$A/tools/linux-arm64/btop/btop"
echo s > "$A/private/secret-stuff/keys.txt"
echo s > "$A/state/manifest.tsv"

out=$(python3 -I "$PY" --root "$A" --now 1700000000 2>&1); rc=$?
check "build exits 0" '[ "$rc" -eq 0 ]'
check "index + section pages written" '[ -f "$A/index.html" ] && [ -f "$A/browse/models.html" ] && [ -f "$A/browse/content.html" ] && [ -f "$A/browse/tools.html" ] && [ -f "$A/browse/summary.json" ]'
check "empty section has no page" '[ ! -e "$A/browse/installers.html" ] && [ ! -e "$A/browse/datasets.html" ]'
check "state/ and private/ never listed" '! grep -qE "secret-stuff|keys.txt|manifest.tsv" "$A"/index.html "$A"/browse/*.html "$A/browse/summary.json"'
check "art copied (light + dark)" '[ -f "$A/browse/art/models-light.svg" ] && [ -f "$A/browse/art/models-dark.svg" ]'

# every href/src relative; no external URL anywhere
python3 -I - "$A" > "$T/links.out" 2>&1 <<'PYEOF'
import glob, os, re, sys, urllib.parse
root = sys.argv[1]; bad = []
for f in [os.path.join(root, 'index.html')] + glob.glob(os.path.join(root, 'browse', '*.html')):
    text = open(f, encoding='utf-8').read()
    if re.search(r'(?i)https?://|//[a-z0-9]', text.replace('http://www.w3.org/2000/svg', '')):
        bad.append(f'{f}: external URL')
    for m in re.finditer(r'(?:href|src|srcset)="([^"]*)"', text):
        u = m.group(1).replace('&amp;', '&')
        if re.match(r'^[a-z][a-z0-9+.-]*:', u, re.I) or u.startswith('/'):
            bad.append(f'{f}: absolute link {u}')
            continue
        target = os.path.normpath(os.path.join(os.path.dirname(f), urllib.parse.unquote(u)))
        if not os.path.exists(target):
            bad.append(f'{f}: dead link {u}')
print('\n'.join(bad) or 'ok')
PYEOF
check "all links relative, alive, no external URL" 'grep -qx ok "$T/links.out" || { cat "$T/links.out" >&2; false; }'

C="$A/browse/content.html"; M="$A/browse/models.html"
check "hostile name escaped in text" 'grep -q "&lt;img src=x onerror=alert(1)&gt;.zim" "$C" && ! grep -q "<img src=x" "$C"'
check "hostile name percent-encoded in link" 'grep -q "%3Cimg%20src%3Dx%20onerror%3Dalert%281%29%3E.zim" "$C"'
check "quote/ampersand escaped" 'grep -q "a&quot;b&amp;c d.zim" "$C"'
check "dot files ignored" '! grep -q "hidden.zim" "$C"'
check ".part leftovers ignored" '! grep -q "big.part" "$M"'
check "ZIM name explained" 'grep -q "Wikipedia (en) · full, with images · 2024-01" "$C"'
check "model card excerpt" 'grep -q "Tiny 7B is a small but capable language model trained for offline use." "$M"'
check "model card licence + pipeline chips" 'grep -q "licence: apache-2.0" "$M" && grep -q ">text-generation<" "$M"'
check "badge image / link URL dropped from excerpt" '! grep -q "shields" "$M" && ! grep -q "example.com" "$M"'
check "huggingface entry is org/repo" 'grep -q ">acme/tiny-7b</a>" "$M"'
check "other model dirs one level deeper" 'grep -q ">qwen</a>" "$M"'
check "per-entry file list capped (--max-files default 8)" '[ "$(grep -o "<li><a" "$M" | wc -l)" -le 9 ]'
check "licence + readme links" 'grep -q ">licence file</a>" "$M" && grep -q ">readme</a>" "$M"'
check "totals in summary.json" 'python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));s={x[\"name\"]:x for x in d[\"sections\"]};sys.exit(0 if s[\"models\"][\"files\"]==10 and s[\"content\"][\"files\"]==3 else 1)" "$A/browse/summary.json"'
check "filter box works without JS (hidden until script runs)" 'grep -q "id=\"q\" type=\"search\"" "$M" && grep -q "hidden></div>" "$M"'

# unchanged output is not rewritten (network shares: no needless writes)
m1=$(stat -c %Y.%i "$M"); sleep 1
python3 -I "$PY" --root "$A" --now 1700000000 >/dev/null 2>&1
check "unchanged page not rewritten" '[ "$(stat -c %Y.%i "$M")" = "$m1" ]'

# caps
python3 -I "$PY" --root "$A" --out "$T/cap" --max-rows 1 --max-files 2 --now 1700000000 >/dev/null 2>&1
check "--max-rows summarises the rest" 'grep -q "and 1 more entries" "$T/cap/browse/models.html"'
check "--max-files caps the file list" 'grep -q "more in the folder" "$T/cap/browse/models.html"'
check "--out keeps links pointing at the root" 'grep -q "href=\"../../a/models/" "$T/cap/browse/models.html"'
python3 -I "$PY" --root "$A" --out "$T/wl" --walk-limit 2 --now 1700000000 >/dev/null 2>&1
check "--walk-limit marks partial totals" 'grep -q "larger than the scan limit" "$T/wl/browse/models.html"'

# listing + pending (no walk), --walk for the uncovered section
printf 'models/huggingface/big/llm/model-00001.safetensors\t4000000000\t1700000000\ncontent/zim/x_en_all_nopic_2025-02.zim\t12\t\nstate/secret\t5\t\n../escape\t1\t\nmodels/huggingface/big/llm/x.part\t9\t\n' > "$T/list.tsv"
printf 'models/huggingface/big/llm/model-00002.safetensors\t4000000000\nmodels/huggingface/new/repo/a.bin\t0\n' > "$T/pend.tsv"
python3 -I "$PY" --root "$A" --out "$T/l" --listing "$T/list.tsv" --pending "$T/pend.tsv" --walk tools --now 1700000000 >/dev/null 2>&1
LM="$T/l/browse/models.html"
check "listing: entries from the TSV only" 'grep -q ">big/llm</a>" "$LM" && ! grep -q "tiny-7b" "$LM"'
check "listing: queued chip with size" 'grep -q "queued: 1 file, 4.0 GB" "$LM"'
check "listing: pending-only entry shown, not linked" 'grep -q "<b>new/repo</b>" "$LM" && grep -q "not downloaded yet" "$LM"'
check "listing: unknown size says files only" 'grep -q "queued: 1 file</span>" "$LM"'
check "listing: state/, .. and .part rows ignored" '! grep -qE "secret|escape|x.part" "$T"/l/browse/*.html'
check "--walk adds the uncovered section" '[ -f "$T/l/browse/tools.html" ] && grep -q ">btop</a>" "$T/l/browse/tools.html"'
check "listing: ZIM nopic explained" 'grep -q "X (en) · text only · 2025-02" "$T/l/browse/content.html"'

# exit codes
python3 -I "$PY" --root "$T/nope" >/dev/null 2>&1; rc=$?
check "missing root -> 1" '[ "$rc" -eq 1 ]'
python3 -I "$PY" --root "$A" --section bogus=x >/dev/null 2>&1; rc=$?
check "bad --section -> 64" '[ "$rc" -eq 64 ]'
python3 -I "$PY" --root "$A" --walk nope >/dev/null 2>&1; rc=$?
check "bad --walk -> 64" '[ "$rc" -eq 64 ]'
python3 -I "$PY" --bogus >/dev/null 2>&1; rc=$?
check "unknown flag -> 64" '[ "$rc" -eq 64 ]'
python3 -I "$PY" --root "$A" --section models=- --out "$T/drop" >/dev/null 2>&1
check "NAME=- drops a section" '[ ! -e "$T/drop/browse/models.html" ] && [ -f "$T/drop/browse/content.html" ]'

# librarian.sh site on the data-root layout (models live next to, not inside, VALARK_HOME)
D="$T/data"; mkdir -p "$D/models/llm/m1" "$D/val-ark/content/zim" "$D/val-ark/state"
head -c 10 /dev/zero > "$D/models/llm/m1/m.gguf"; echo z > "$D/val-ark/content/zim/wiktionary_en_all_2025-01.zim"
VAL_ARK_DATA="$D" bash "$ROOT/scripts/librarian.sh" site > "$T/lib.out" 2>&1; rc=$?
check "librarian.sh site exits 0" '[ "$rc" -eq 0 ] || { cat "$T/lib.out" >&2; false; }'
check "librarian.sh site writes VALARK_HOME/index.html" '[ -f "$D/val-ark/index.html" ] && [ -f "$D/val-ark/browse/models.html" ]'
check "models outside VALARK_HOME linked relatively" 'grep -q "href=\"../../models/llm/m1/\"" "$D/val-ark/browse/models.html"'
VALARK_STATIC_SITE=0 VAL_ARK_DATA="$T/data2" bash "$ROOT/scripts/librarian.sh" site >/dev/null 2>&1; rc=$?
check "VALARK_STATIC_SITE=0 is a no-op" '[ "$rc" -eq 0 ] && [ ! -e "$T/data2/val-ark/index.html" ]'

# a top-level-only section (sources: one folder per project) has no "(top level)" header row
mkdir -p "$A/sources/proj"; echo s > "$A/sources/proj/p.tar.gz"
python3 -I "$PY" --root "$A" --out "$T/src" --now 1700000000 >/dev/null 2>&1
mkdir -p "$A/sources/github/own"; echo b > "$A/sources/github/own/repo.bundle"
python3 -I "$PY" --root "$A" --out "$T/src2" --now 1700000000 >/dev/null 2>&1
check "git bundles listed one per repo" 'grep -q ">own/repo.bundle</a>" "$T/src2/browse/sources.html"'
check "no group header when every entry is top level" '! grep -q "(top level)" "$T/src/browse/sources.html" && grep -q ">proj</a>" "$T/src/browse/sources.html"'

# maintain throttles the refresh (VALARK_STATIC_SITE_HOURS) and runs it when stale. Sourced
# librarian with the network/disk steps stubbed out; cmd_site just records that it ran.
M2="$T/m"; mkdir -p "$M2/val-ark/state"
run_maintain() {
    VAL_ARK_DATA="$M2" bash -c '. "$1/scripts/librarian.sh"
        catalog_refresh_zim() { return 0; }; cmd_verify() { :; }; cmd_fill() { :; }
        cmd_site() { echo ran >> "$VALARK_HOME/site.calls"; }
        cmd_maintain >/dev/null 2>&1' _ "$ROOT"
}
run_maintain
check "maintain refreshes the pages when there is no index.html" '[ "$(wc -l < "$M2/val-ark/site.calls" 2>/dev/null)" = 1 ]'
: > "$M2/val-ark/index.html"; run_maintain
check "maintain skips a fresh index.html" '[ "$(wc -l < "$M2/val-ark/site.calls")" = 1 ]'
touch -d "7 hours ago" "$M2/val-ark/index.html"; run_maintain
check "maintain refreshes a stale index.html (default 6 h)" '[ "$(wc -l < "$M2/val-ark/site.calls")" = 2 ]'
: > "$M2/val-ark/index.html"; VALARK_STATIC_SITE_HOURS=0 run_maintain
check "VALARK_STATIC_SITE_HOURS=0 refreshes every time" '[ "$(wc -l < "$M2/val-ark/site.calls")" = 3 ]'

# web UI opened from file:// points at the static catalog
check "web UI file:// hint links ../index.html" 'grep -q "id=\"static-hint\"" "$ROOT/web-ui/index.html" && grep -q "location.protocol===.file:." "$ROOT/web-ui/index.html"'

echo "static-site: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
