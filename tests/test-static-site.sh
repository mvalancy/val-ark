#!/bin/bash
###############################################################################
# Test: the static catalog (scripts/lib/static_site.py, `librarian.sh site`, #257).
# All offline, on throwaway trees (and a fixture web-ui + hand-built ZIM files). Invariants:
#   - index.html + browse/<section>.html (card grid) + browse/item/*.html (detail pages) for
#     every non-empty section, none for empty ones; state/ and private/ are never listed
#   - every href / src is RELATIVE and alive (file:// + plain file servers); no external URL
#   - hostile file names are escaped in text and percent-encoded in links
#   - rich cards: model-card excerpt / licence / pipeline / first repo image as thumbnail;
#     tools from the web UI's TOOLS + TOOL_META (logo, description, features, screenshots,
#     one card across platforms); ZIM title / description / illustration read from the ZIM
#     itself (uncompressed and xz clusters) and cached; generated badges otherwise
#   - the shipped web UI's data tables parse (TOOLS, CONTENT_LIBRARY, MODEL_FAMILIES)
#   - caps: --max-rows, --max-files, --max-details 0 (cards link to folders), --walk-limit
#   - --listing / --pending / --walk; leftovers (*.part, dot files, .source.json) ignored;
#     unchanged pages are not rewritten; stale detail pages and thumbnails are removed
#   - exit codes: 0 ok, 1 missing root, 64 usage; librarian.sh site + the maintain throttle
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
A="$T/a"; W="$T/webui"
mkdir -p "$A/models/huggingface/acme/tiny-7b/sub" "$A/models/huggingface/acme/tiny-7b/assets" "$A/models/llm/qwen" \
         "$A/content/zim" "$A/tools/linux-arm64/btop" "$A/tools/windows-x64/btop" "$A/state" "$A/private/secret-stuff" \
         "$A/installers/ubuntu" "$W/logos" "$W/screenshots"
cat > "$A/models/huggingface/acme/tiny-7b/README.md" <<'EOF'
---
license: apache-2.0
pipeline_tag: text-generation
---
# Tiny 7B

![badge](https://img.shields.io/x.svg)
![logo](https://huggingface.co/acme/tiny-7b/resolve/main/assets/logo.png)

Tiny 7B is a small but capable [language model](https://example.com/x) trained for offline use.

It was trained on a curated mix of manuals and encyclopedias, and it runs on a laptop CPU.
EOF
printf '\x89PNG\r\n\x1a\nfakepng' > "$A/models/huggingface/acme/tiny-7b/assets/logo.png"
head -c 5000 /dev/zero > "$A/models/huggingface/acme/tiny-7b/model.safetensors"
: > "$A/models/huggingface/acme/tiny-7b/LICENSE"
for i in 1 2 3 4 5 6; do head -c $((i * 10)) /dev/zero > "$A/models/huggingface/acme/tiny-7b/sub/f$i.bin"; done
head -c 100 /dev/zero > "$A/models/huggingface/acme/tiny-7b/big.part"
head -c 100 /dev/zero > "$A/models/llm/qwen/q.gguf"
echo x > "$A/content/zim/<img src=x onerror=alert(1)>.zim"
echo x > "$A/content/zim/a\"b&c d.zim"
echo x > "$A/content/zim/.hidden.zim"
echo '{}' > "$A/content/zim/a\"b&c d.zim.source.json"
echo hi > "$A/tools/linux-arm64/btop/btop"; echo hi > "$A/tools/windows-x64/btop/btop.exe"
echo s > "$A/private/secret-stuff/keys.txt"
echo s > "$A/state/manifest.tsv"
echo '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$W/logos/btop.svg"
printf '\x89PNG\r\n\x1a\nshot' > "$W/screenshots/btop-1.png"
cat > "$W/index.html" <<'EOF'
<script>
const TOOLS = [
    {
        id: 'btop', name: 'btop++', category: 'dev-tools', icon: 'B', iconBg: '#123456', logo: 'logos/btop.svg',
        desc: 'Resource monitor ' + 'with CPU and memory graphs', // trailing comment
        screenshots: ['screenshots/btop-1.png'],
        details: { overview: 'A terminal monitor.', features: ['Mouse support', "Themes — many"],
                   cli: [{cmd: 'btop', desc: 'start it'}] },
    },
];
const TOOL_META = { 'btop': { maker: 'aristocratos', website: 'https://github.com/aristocratos/btop', license: 'Apache-2.0' } };
const CONTENT_LIBRARY = [ { id: 'wiki', name: 'Wiki Pedia', match: 'wikipedia_en_all_maxi', icon: 'W', iconBg: '#1a73e8',
    desc: 'Curated wiki description', details: { overview: 'Curated overview.', features: ['Every article'] } } ];
const MODEL_FAMILIES = [ { family: 'Qwen', slug: 'qwen', category: 'LLM', desc: 'Qwen family description',
    overview: 'Qwen overview.', usageTips: ['Use -ngl 999'], variants: [ {name: 'Q', file: 'llm/qwen/q.gguf'} ] } ];
const MODEL_META = { 'qwen': { maker: 'Alibaba Cloud', license: 'Apache 2.0' } };
</script>
EOF

# Hand-built ZIM files: M/Title, M/Description, M/Illustration_48x48@1 in one cluster
# (uncompressed for the first, xz for the second).
python3 -I - "$A/content/zim" <<'PYEOF'
import lzma, struct, sys
def zim(path, comp):
    blobs = [b'A tiny test wiki', b'\x89PNG\r\n\x1a\nicon-' + bytes([comp]), b'Testipedia']
    names = ['Description', 'Illustration_48x48@1', 'Title']   # sorted URL order
    mimes = b'text/plain\0image/png\0\0'
    offs, pos = [], 4 * (len(blobs) + 1)
    for b in blobs: offs.append(pos); pos += len(b)
    offs.append(pos)
    body = b''.join(struct.pack('<I', o) for o in offs) + b''.join(blobs)
    cluster = bytes([comp]) + (lzma.compress(body, format=lzma.FORMAT_XZ) if comp == 4 else body)
    dirents = [struct.pack('<HBcIII', 0, 0, b'M', 0, 0, i) + n.encode() + b'\0\0' for i, n in enumerate(names)]
    mime_pos = 80; d0 = mime_pos + len(mimes)
    dpos, p = [], d0
    for d in dirents: dpos.append(p); p += len(d)
    url_ptr = p; cl_ptr = url_ptr + 8 * len(dirents); cl0 = cl_ptr + 8
    head = struct.pack('<4sHH16sIIQQQQIIQ', b'ZIM\x04', 6, 1, b'\0' * 16, len(dirents), 1, url_ptr, url_ptr,
                       cl_ptr, mime_pos, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    with open(path, 'wb') as f:
        f.write(head + mimes + b''.join(dirents) + b''.join(struct.pack('<Q', x) for x in dpos)
                + struct.pack('<Q', cl0) + cluster)
zim(sys.argv[1] + '/wikipedia_en_all_maxi_2024-01.zim', 1)
zim(sys.argv[1] + '/xzwiki_en_all_nopic_2025-03.zim', 4)
PYEOF

gen() { python3 -I "$PY" --web-ui "$W" --now 1700000000 "$@"; }
out=$(gen --root "$A" 2>&1); rc=$?
check "build exits 0" '[ "$rc" -eq 0 ] || { echo "$out" >&2; false; }'
check "index + section pages + detail pages written" '[ -f "$A/index.html" ] && [ -f "$A/browse/models.html" ] && [ -f "$A/browse/content.html" ] && [ -f "$A/browse/tools.html" ] && [ -f "$A/browse/summary.json" ] && [ "$(ls "$A/browse/item" | wc -l)" -ge 7 ]'
check "empty section has no page" '[ ! -e "$A/browse/installers.html" ] && [ ! -e "$A/browse/datasets.html" ]'
check "state/ and private/ never listed" '! grep -rqE "secret-stuff|keys.txt|manifest.tsv" "$A/index.html" "$A/browse"'
check "art copied (light + dark)" '[ -f "$A/browse/art/models-light.svg" ] && [ -f "$A/browse/art/models-dark.svg" ]'

linkcheck() {
python3 -I - "$1" <<'PYEOF'
import glob, os, re, sys, urllib.parse
root = sys.argv[1]; bad = []
pages = [os.path.join(root, 'index.html')] + glob.glob(os.path.join(root, 'browse', '*.html')) + glob.glob(os.path.join(root, 'browse', 'item', '*.html'))
for f in pages:
    text = open(f, encoding='utf-8').read()
    if re.search(r'(?i)https?://|//[a-z0-9]', text.replace('http://www.w3.org/2000/svg', '')):
        bad.append(f'{f}: external URL')
    for m in re.finditer(r'(?:href|src|srcset)="([^"]*)"', text):
        u = m.group(1).replace('&amp;', '&')
        if re.match(r'^[a-z][a-z0-9+.-]*:', u, re.I) or u.startswith('/'):
            bad.append(f'{f}: absolute link {u}'); continue
        target = os.path.normpath(os.path.join(os.path.dirname(f), urllib.parse.unquote(u)))
        if not os.path.exists(target):
            bad.append(f'{f}: dead link {u}')
print('\n'.join(bad) or 'ok')
PYEOF
}
linkcheck "$A" > "$T/links.out" 2>&1
check "all links relative, alive, no external URL (index, sections, details)" 'grep -qx ok "$T/links.out" || { cat "$T/links.out" >&2; false; }'

C="$A/browse/content.html"; M="$A/browse/models.html"; TL="$A/browse/tools.html"; I="$A/browse/item"
item() { grep -l "<h1>$1</h1>" "$I"/*.html | head -1; }
check "hostile name escaped in text" 'grep -q "&lt;img src=x onerror=alert(1)&gt;" "$C" && ! grep -rq --include="*.html" "<img src=x" "$A/browse"'
check "hostile name percent-encoded in link" 'grep -rq "%3Cimg%20src%3Dx%20onerror%3Dalert%281%29%3E.zim" "$I"'
check "quote/ampersand escaped" 'grep -q "a&quot;b&amp;c d" "$C"'
check "dot files and .source.json sidecars ignored" '! grep -rqE "hidden.zim|source.json" "$C" "$I"'
check ".part leftovers ignored" '! grep -rq "big.part" "$A/browse"'
# models
TI="$(item tiny-7b)"
check "model card: excerpt on the card" 'grep -q "Tiny 7B is a small but capable language model trained for offline use." "$M"'
check "model card: org as subtitle" 'grep -q "<h4>tiny-7b</h4><div class=\"sub\">acme</div>" "$M"'
check "model card: longer text on the detail page" 'grep -q "runs on a laptop CPU" "$TI"'
check "model card: licence + pipeline chips" 'grep -q "licence: apache-2.0" "$M" && grep -q ">text-generation<" "$M"'
check "model card: badge / link URLs dropped" '! grep -rq "shields" "$A/browse" && ! grep -rq "example.com" "$A/browse"'
check "model card: repo image (absolute HF URL to its own repo) becomes the thumbnail" 'grep -q "thumbs/[0-9a-f]\{16\}\.png" "$M" && cmp -s "$A/models/huggingface/acme/tiny-7b/assets/logo.png" "$A/browse/$(grep -o "thumbs/[0-9a-f]\{16\}\.png" "$M" | head -1)"'
check "detail page: readme + licence links, files capped (default 60)" 'grep -q ">Read the full README</a>" "$TI" && grep -q ">Licence file</a>" "$TI" && grep -q "sub/f6.bin" "$TI"'
check "curated model family on llm/ folders" 'grep -q "Qwen family description" "$M" && grep -rq "Use -ngl 999" "$I"'
# tools
BI="$(item btop++)"
check "tool: curated name + description (string concat) on one card" '[ "$(grep -o "<h4>btop++</h4>" "$TL" | wc -l)" = 1 ] && grep -q "Resource monitor with CPU and memory graphs" "$TL"'
check "tool: platforms as chips + per-platform folder links" 'grep -q ">Linux arm64<" "$TL" && grep -q ">Windows<" "$TL" && grep -q "tools/windows-x64/btop/" "$BI"'
check "tool: logo copied as thumbnail" 'cmp -s "$W/logos/btop.svg" "$A/browse/$(grep -o "thumbs/[0-9a-f]\{16\}\.svg" "$TL" | head -1)"'
check "tool: features (\\u escape), CLI, maker, licence, screenshot" 'grep -q "Themes — many" "$BI" && grep -q "<code>btop</code>" "$BI" && grep -q "aristocratos" "$BI" && grep -q "licence: Apache-2.0" "$BI" && grep -q "screenshot\" loading" "$BI"'
check "tool: website shown as text, not a link" 'grep -q "github.com/aristocratos/btop" "$BI" && ! grep -q "href=\"[^\"]*github.com" "$BI"'
# ZIMs
WI="$(grep -l "kiwix-serve wikipedia_en_all_maxi_2024-01.zim" "$I"/*.html | head -1)"
check "ZIM: title + description read from the file (uncompressed cluster)" 'grep -q "<h4>Testipedia</h4>" "$C" && grep -q "A tiny test wiki" "$C"'
check "ZIM: xz cluster read too" '[ "$(grep -o "<h4>Testipedia</h4>" "$C" | wc -l)" = 2 ]'
check "ZIM: illustration extracted as thumbnail" 'ls "$A/browse/thumbs"/z-*.png >/dev/null 2>&1 && grep -q "thumbs/z-" "$C"'
check "ZIM: curated overview + how to open on the detail page" 'grep -q "Curated overview." "$WI" && grep -q "kiwix-serve wikipedia_en_all_maxi_2024-01.zim" "$WI"'
check "ZIM: name explained as subtitle" 'grep -q "Wikipedia (en) · full, with images · 2024-01" "$C"'
check "ZIM: metadata cached" 'grep -q "Testipedia" "$A/browse/zim-meta.json"'
gen --root "$A" --zim-limit 0 >/dev/null 2>&1
check "ZIM: cache used when no ZIM may be opened" 'grep -q "<h4>Testipedia</h4>" "$C"'
check "generated badge for items without a picture" 'grep -q "thumbs/b-[0-9a-f]\{12\}\.svg" "$C"'
check "totals in summary.json" 'python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));s={x[\"name\"]:x for x in d[\"sections\"]};sys.exit(0 if s[\"models\"][\"files\"]==11 and s[\"content\"][\"files\"]==4 and s[\"tools\"][\"entries\"]==1 else 1)" "$A/browse/summary.json"'
check "search box progressive (hidden until script runs)" 'grep -q "id=\"q\" type=\"search\"" "$M" && grep -q "aria-label=\"Search\" hidden" "$M"'
check "the shipped web UI data tables parse" 'python3 -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"ss\",\"$PY\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
c=m.Curated(\"$ROOT/web-ui\",\"$ROOT/data\")
sys.exit(0 if len(c.tools)>=20 and c.content and len(c.model_files)>=20 and c.installers and c.devstack else 1)"'

# unchanged output is not rewritten (network shares: no needless writes)
m1=$(stat -c %Y.%i "$M"); d1=$(stat -c %Y.%i "$TI"); sleep 1
gen --root "$A" >/dev/null 2>&1
check "unchanged section + detail pages not rewritten" '[ "$(stat -c %Y.%i "$M")" = "$m1" ] && [ "$(stat -c %Y.%i "$TI")" = "$d1" ]'

# stale detail pages + thumbnails are removed
rm -rf "$A/tools/windows-x64" "$A/tools/linux-arm64"; logo="$(grep -o "thumbs/[0-9a-f]\{16\}\.svg" "$TL" | head -1)"
gen --root "$A" >/dev/null 2>&1
check "stale detail page + thumbnail removed" '[ ! -e "$BI" ] && [ ! -e "$A/browse/$logo" ] && [ ! -e "$TL" ]'

# caps
gen --root "$A" --out "$T/cap" --max-rows 1 --max-files 2 >/dev/null 2>&1
check "--max-rows summarises the rest" 'grep -q "and 1 more entries" "$T/cap/browse/models.html"'
check "--max-files caps the file list" 'grep -rq "more in the folder" "$T/cap/browse/item"'
check "--out keeps links pointing at the root" 'grep -q "href=\"../../a/models/" "$T/cap/browse/models.html"'
linkcheck "$T/cap" > "$T/links2.out" 2>&1
check "--out: every link alive" 'grep -qx ok "$T/links2.out" || { cat "$T/links2.out" >&2; false; }'
gen --root "$A" --out "$T/nd" --max-details 0 >/dev/null 2>&1
check "--max-details 0: no detail pages, cards link to folders" '[ -z "$(ls "$T/nd/browse/item" 2>/dev/null)" ] && grep -q "href=\"../../a/models/huggingface/acme/tiny-7b/\"" "$T/nd/browse/models.html"'
gen --root "$A" --out "$T/wl" --walk-limit 2 >/dev/null 2>&1
check "--walk-limit marks partial totals" 'grep -q "larger than the scan limit" "$T/wl/browse/models.html"'

# listing + pending (no walk), --walk for the uncovered section
mkdir -p "$A/tools/linux-arm64/btop"; echo hi > "$A/tools/linux-arm64/btop/btop"
printf 'models/huggingface/big/llm/model-00001.safetensors\t4000000000\t1700000000\ncontent/zim/x_en_all_nopic_2025-02.zim\t12\t\nstate/secret\t5\t\n../escape\t1\t\nmodels/huggingface/big/llm/x.part\t9\t\n' > "$T/list.tsv"
printf 'models/huggingface/big/llm/model-00002.safetensors\t4000000000\nmodels/huggingface/new/repo/a.bin\t0\n' > "$T/pend.tsv"
gen --root "$A" --out "$T/l" --listing "$T/list.tsv" --pending "$T/pend.tsv" --walk tools >/dev/null 2>&1
LM="$T/l/browse/models.html"
check "listing: entries from the TSV only" 'grep -q "<h4>llm</h4><div class=\"sub\">big</div>" "$LM" && ! grep -q "tiny-7b" "$LM"'
check "listing: queued chip with size" 'grep -q "queued: 1 file, 4.0 GB" "$LM"'
check "listing: pending-only entry marked" 'grep -q "<h4>repo</h4>" "$LM" && grep -q "not downloaded yet" "$LM"'
check "listing: unknown size says files only" 'grep -q "queued: 1 file</span>" "$LM"'
check "listing: state/, .. and .part rows ignored" '! grep -rqE "secret|escape|x.part" "$T/l/browse"'
check "--walk adds the uncovered section" 'grep -q "<h4>btop++</h4>" "$T/l/browse/tools.html"'
check "listing: ZIM nopic explained" 'grep -q "X (en) · text only · 2025-02" "$T/l/browse/content.html"'

# datasets: depth by path prefix (open-data/<topic>/huggingface/<org>/<repo> is one entry)
printf 'datasets/open-data/weather/huggingface/org1/ds1/data/a.parquet\t10\t\ndatasets/open-data/weather/noaa/ghcnd/x.csv\t5\t\ndatasets/robotics/lerobot/set1/d/e.bin\t7\t\n' > "$T/ds.tsv"
gen --root "$A" --out "$T/ds" --listing "$T/ds.tsv" >/dev/null 2>&1
DS="$T/ds/browse/datasets.html"
check "datasets: HF open-data repo is one entry" 'grep -q "<h4>ds1</h4><div class=\"sub\">open-data / weather / huggingface / org1</div>" "$DS"'
check "datasets: other open-data sources four levels" 'grep -q "<h4>ghcnd</h4>" "$DS"'
check "datasets: robotics three levels" 'grep -q "<h4>set1</h4><div class=\"sub\">robotics / lerobot</div>" "$DS"'

# sources: one card per git bundle
mkdir -p "$A/sources/github/own"; echo b > "$A/sources/github/own/repo.bundle"
gen --root "$A" --out "$T/src" >/dev/null 2>&1
check "git bundles listed one per repo" 'grep -q "<h4>repo</h4><div class=\"sub\">own</div>" "$T/src/browse/sources.html"'

# exit codes
python3 -I "$PY" --root "$T/nope" >/dev/null 2>&1; rc=$?
check "missing root -> 1" '[ "$rc" -eq 1 ]'
python3 -I "$PY" --root "$A" --section bogus=x >/dev/null 2>&1; rc=$?
check "bad --section -> 64" '[ "$rc" -eq 64 ]'
python3 -I "$PY" --root "$A" --walk nope >/dev/null 2>&1; rc=$?
check "bad --walk -> 64" '[ "$rc" -eq 64 ]'
python3 -I "$PY" --bogus >/dev/null 2>&1; rc=$?
check "unknown flag -> 64" '[ "$rc" -eq 64 ]'
gen --root "$A" --section models=- --out "$T/drop" >/dev/null 2>&1
check "NAME=- drops a section" '[ ! -e "$T/drop/browse/models.html" ] && [ -f "$T/drop/browse/content.html" ]'

# librarian.sh site on the data-root layout (models live next to, not inside, VALARK_HOME)
D="$T/data"; mkdir -p "$D/models/llm/m1" "$D/val-ark/content/zim" "$D/val-ark/state"
head -c 10 /dev/zero > "$D/models/llm/m1/m.gguf"; echo z > "$D/val-ark/content/zim/wiktionary_en_all_2025-01.zim"
VAL_ARK_DATA="$D" bash "$ROOT/scripts/librarian.sh" site > "$T/lib.out" 2>&1; rc=$?
check "librarian.sh site exits 0" '[ "$rc" -eq 0 ] || { cat "$T/lib.out" >&2; false; }'
check "librarian.sh site writes VALARK_HOME/index.html" '[ -f "$D/val-ark/index.html" ] && [ -f "$D/val-ark/browse/models.html" ]'
check "models outside VALARK_HOME linked relatively" 'grep -rq "href=\"../../../models/llm/m1/\"" "$D/val-ark/browse/item"'
VALARK_STATIC_SITE=0 VAL_ARK_DATA="$T/data2" bash "$ROOT/scripts/librarian.sh" site >/dev/null 2>&1; rc=$?
check "VALARK_STATIC_SITE=0 is a no-op" '[ "$rc" -eq 0 ] && [ ! -e "$T/data2/val-ark/index.html" ]'

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
