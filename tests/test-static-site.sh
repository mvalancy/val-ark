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
# model-scout layout: models/scouted/<org>/<repo>; one finished (stamped), one cut off
mkdir -p "$A/models/scouted/Qwen/Qwen3-ASR" "$A/models/scouted/Qwen/Qwen3-TTS/.cache/huggingface/download"
head -c 300 /dev/zero > "$A/models/scouted/Qwen/Qwen3-ASR/model.safetensors"; date > "$A/models/scouted/Qwen/Qwen3-ASR/.valark-complete"
head -c 200 /dev/zero > "$A/models/scouted/Qwen/Qwen3-TTS/config.json"
: > "$A/models/scouted/Qwen/Qwen3-TTS/.cache/huggingface/download/x.incomplete"
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
        id: 'piper-tts', name: 'Piper TTS', category: 'ai-inference', icon: 'P', downloadTarget: 'piper',
        desc: 'Fast local neural text to speech',
    },
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
import lzma, shutil, struct, subprocess, sys
def zim(path, comp):
    blobs = [b'A tiny test wiki', b'\x89PNG\r\n\x1a\nicon-' + bytes([comp]), b'Testipedia']
    names = ['Description', 'Illustration_48x48@1', 'Title']   # sorted URL order
    mimes = b'text/plain\0image/png\0\0'
    offs, pos = [], 4 * (len(blobs) + 1)
    for b in blobs: offs.append(pos); pos += len(b)
    offs.append(pos)
    body = b''.join(struct.pack('<I', o) for o in offs) + b''.join(blobs)
    if comp == 4:
        body = lzma.compress(body, format=lzma.FORMAT_XZ)
    elif comp == 5:
        body = subprocess.run(['zstd', '-q', '-c'], input=body, capture_output=True, check=True).stdout
    cluster = bytes([comp]) + body
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
if shutil.which('zstd'):
    zim(sys.argv[1] + '/zstwiki_en_all_maxi_2025-04.zim', 5)
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
check "scouted repos get one card each (org/repo, not one per org)" 'grep -q "<h4>Qwen3-ASR</h4>" "$M" && grep -q "<h4>Qwen3-TTS</h4>" "$M" && ! grep -q "<h4>Qwen</h4>" "$M"'
check "a cut-off scouted pull is labelled incomplete" '[ -n "$(item Qwen3-TTS)" ] && grep -q "incomplete download" "$(item Qwen3-TTS)"'
check "a stamped scouted pull is not" '[ -n "$(item Qwen3-ASR)" ] && ! grep -q "incomplete download" "$(item Qwen3-ASR)"'
check "the stamp and .cache never show as files" '! grep -rq "valark-complete\|x.incomplete" "$A/browse/item"'
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
check "ZIM: xz cluster read too" 'grep -q "Xzwiki (en) · text only · 2025-03" "$C" && [ "$(grep -o "<h4>Testipedia</h4>" "$C" | wc -l)" -ge 2 ]'
if command -v zstd >/dev/null 2>&1; then
    check "ZIM: zstd cluster read through the zstd CLI" '[ "$(grep -o "<h4>Testipedia</h4>" "$C" | wc -l)" = 3 ] && [ "$(ls "$A/browse/thumbs"/z-*.png | wc -l)" = 3 ]'
else
    echo "SKIP: zstd cluster case (no zstd CLI)" >&2
fi
check "ZIM: illustration extracted as thumbnail" 'ls "$A/browse/thumbs"/z-*.png >/dev/null 2>&1 && grep -q "thumbs/z-" "$C"'
check "ZIM: curated overview + how to open on the detail page" 'grep -q "Curated overview." "$WI" && grep -q "kiwix-serve wikipedia_en_all_maxi_2024-01.zim" "$WI"'
check "ZIM: name explained as subtitle" 'grep -q "Wikipedia (en) · full, with images · 2024-01" "$C"'
check "ZIM: metadata cached" 'grep -q "Testipedia" "$A/browse/zim-meta.json"'
gen --root "$A" --zim-limit 0 >/dev/null 2>&1
check "ZIM: cache used when no ZIM may be opened" 'grep -q "<h4>Testipedia</h4>" "$C"'
check "generated badge for items without a picture" 'grep -q "thumbs/b-[0-9a-f]\{12\}\.svg" "$C"'
NZ=$(ls "$A/content/zim" | grep -c '\.zim$')
check "totals in summary.json" 'python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));s={x[\"name\"]:x for x in d[\"sections\"]};sys.exit(0 if s[\"models\"][\"files\"]==13 and s[\"content\"][\"files\"]==int(sys.argv[2]) and s[\"tools\"][\"entries\"]==1 else 1)" "$A/browse/summary.json" "$NZ"'
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
check "--max-rows summarises the rest" 'grep -q "and 3 more entries" "$T/cap/browse/models.html"'
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

# naming helpers: tool archives / notes / versioned source dirs fold into one tool; queued ZIMs get
# a readable title and a kind group; code paragraphs never become a card description
check "tool_key, zim_title, zim_group, code paragraphs skipped" 'python3 -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"ss\",\"$PY\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
ok = [m.tool_key(n) for n in (\"blender.tar.zst.README.txt\",\"maddy-0.9.7-src\",\"node\",\"llama-server.exe\")] == [\"blender\",\"maddy\",\"node\",\"llama-server\"]
z = m.zim_parts(\"3dprinting.stackexchange.com_en_all_2026-10.zim\")
ok = ok and m.zim_title(z) == \"3Dprinting Stack Exchange\" and m.zim_group(z) == \"stack_exchange\"
z = m.zim_parts(\"wikipedia_en_medicine_maxi_2026-01.zim\")
ok = ok and m.zim_title(z) == \"Wikipedia — medicine\" and m.zim_group(z) == \"wikipedia\"
c = m.card(\"import ChatTTS\\nfrom IPython.display import Audio\\n\\nChatTTS is a text-to-speech model designed for dialogue scenarios such as assistants.\\n\")
ok = ok and c[\"excerpt\"].startswith(\"ChatTTS is a text-to-speech\")
sys.exit(0 if ok else 1)"'
mkdir -p "$T/lb/content/lastbook/maps" "$T/lb/content/lastbook/packs"; echo a > "$T/lb/content/lastbook/maps/m.pmtiles"; echo b > "$T/lb/content/lastbook/packs/p.zip"
gen --root "$T/lb" >/dev/null 2>&1
check "Lastbook is one card" '[ "$(grep -o "class=\"item\"" "$T/lb/browse/content.html" | wc -l)" = 1 ]'

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

# thumbnails already copied are reused without reading the source again
chmod 000 "$A/models/huggingface/acme/tiny-7b/assets/logo.png"
gen --root "$A" >/dev/null 2>&1
check "cached thumbnail reused without reading the source" 'grep -q "thumbs/[0-9a-f]\{16\}\.png" "$M"'
chmod 644 "$A/models/huggingface/acme/tiny-7b/assets/logo.png"
printf '\x89PNG\r\n\x1a\nreplaced-picture' > "$A/models/huggingface/acme/tiny-7b/assets/logo.png"
gen --root "$A" >/dev/null 2>&1
check "a replaced picture gets a new thumbnail (old one removed)" 'cmp -s "$A/models/huggingface/acme/tiny-7b/assets/logo.png" "$A/browse/$(grep -o "thumbs/[0-9a-f]\{16\}\.png" "$M" | head -1)" && [ "$(grep -rl "fakepng" "$A/browse/thumbs" | wc -l)" = 0 ]'

# review #261: real tool paths, image containment + magic bytes, malformed cache, JS reader, stamps, temp files
R="$T/r"; mkdir -p "$R/tools/linux-x86_64" "$R/tools/sources/maddy-0.9.7-src" "$R/models/huggingface/o/m/assets"
echo z > "$R/tools/linux-x86_64/blender.tar.zst"; echo n > "$R/tools/linux-x86_64/blender.tar.zst.README.txt"
echo s > "$R/tools/sources/maddy-0.9.7-src/main.go"
printf '\x89PNG\r\n\x1a\nOUTSIDE-SECRET' > "$T/secret.png"
ln -s "$T/secret.png" "$R/models/huggingface/o/m/assets/evil.png"
echo 'not an image' > "$R/models/huggingface/o/m/assets/fake.png"
echo '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>' > "$R/models/huggingface/o/m/assets/x.svg"
printf -- '---\nlicense: mit\n---\n![a](assets/evil.png)\n![b](assets/fake.png)\n![c](assets/x.svg)\n\nA model whose card points at a symlinked picture outside its repo, a fake PNG and an SVG.\n' > "$R/models/huggingface/o/m/README.md"
gen --root "$R" >/dev/null 2>&1
check "tools: archive + versioned -src dir fold into their tools" '[ "$(grep -o "class=\"item\"" "$R/browse/tools.html" | wc -l)" = 2 ]'
check "tools: links go to the real archive / folder" 'grep -rq "href=\"../../tools/linux-x86_64/blender.tar.zst\"" "$R/browse/item" && grep -rq "href=\"../../tools/sources/maddy-0.9.7-src/\"" "$R/browse/item"'
linkcheck "$R" > "$T/links3.out" 2>&1
check "tools: every platform / card link resolves" 'grep -qx ok "$T/links3.out" || { cat "$T/links3.out" >&2; false; }'
gen --root "$R" --out "$T/rnd" --max-details 0 >/dev/null 2>&1
linkcheck "$T/rnd" > "$T/links4.out" 2>&1
check "tools: card links resolve without detail pages" 'grep -qx ok "$T/links4.out" || { cat "$T/links4.out" >&2; false; }'
check "images: a symlink out of the repo is never copied" '! for f in "$R"/browse/thumbs/*; do cmp -s "$f" "$T/secret.png" && echo leaked; done | grep -q leaked'
check "images: non-image bytes and README SVGs are refused (badge instead)" '! ls "$R/browse/thumbs"/*.svg 2>/dev/null | xargs -r grep -l "<script>" | grep -q . && grep -q "thumbs/b-" "$R/browse/models.html"'
printf '{"a.zim|1": "not a dict", "b.zim|2": {"title": "Ok", "icon": "../../../etc/passwd"}, "c": 5}\n' > "$R/browse/zim-meta.json"
gen --root "$R" > "$T/mal.out" 2>&1; rc=$?
check "malformed zim-meta.json: no crash, bad entries dropped" '[ "$rc" -eq 0 ] && ! grep -q "passwd" "$R/browse/zim-meta.json"'
printf '[1, 2]\n' > "$R/browse/zim-meta.json"; gen --root "$R" >/dev/null 2>&1; rc=$?
check "zim-meta.json that is not an object: no crash" '[ "$rc" -eq 0 ]'
check "clean_zim_cache keeps only well-formed entries" 'python3 -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"ss\",\"$PY\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
c=m.clean_zim_cache({\"a|1\":{\"title\":\"T\",\"icon\":\"thumbs/z-0123456789abcdef.png\"},\"b|2\":{\"icon\":\"x/../y\"},\"c|3\":[],7:{}})
sys.exit(0 if c=={\"a|1\":{\"title\":\"T\",\"icon\":\"thumbs/z-0123456789abcdef.png\"},\"b|2\":{}} else 1)"'
mkdir -p "$T/badui"; printf 'const TOOLS = [ { id: \x27x\x27 /* never closed\n' > "$T/badui/index.html"
check "JS reader: an unterminated comment does not hang" 'timeout 10 python3 -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location(\"ss\",\"$PY\");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.Curated(\"$T/badui\",\"$T/none\")"'
m1=$(stat -c %Y.%i "$R/browse/models.html"); d1=$(stat -c %Y.%i "$(ls "$R"/browse/item/models-*.html | head -1)"); sleep 1
python3 -I "$PY" --web-ui "$W" --now 1800000000 --root "$R" >/dev/null 2>&1
check "a new generation time rewrites only the front page" '[ "$(stat -c %Y.%i "$R/browse/models.html")" = "$m1" ] && [ "$(stat -c %Y.%i "$(ls "$R"/browse/item/models-*.html | head -1)")" = "$d1" ] && grep -q "2027-01-15" "$R/index.html"'
: > "$R/browse/item/models-x.html.tmp-4242"; touch -d "2 hours ago" "$R/browse/item/models-x.html.tmp-4242"
: > "$R/browse/item/fresh.html.tmp-4243"; : > "$R/keep.tmp-4244"
gen --root "$R" >/dev/null 2>&1
check "old temp files of an interrupted run are removed, fresh / foreign ones kept" '[ ! -e "$R/browse/item/models-x.html.tmp-4242" ] && [ -e "$R/browse/item/fresh.html.tmp-4243" ] && [ -e "$R/keep.tmp-4244" ]'
check "titles keep their case (search placeholder, back link)" 'grep -q "Search AI models…" "$R/browse/models.html" && grep -rq "All AI models" "$R/browse/item"'

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
        catalog_refresh_zim() { return 0; }; catalog_refresh_scout() { return 0; }; cmd_verify() { :; }; cmd_fill() { :; }
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

# --- every card carries a description (#270): web UI aliases, tool-script headers, wheel METADATA,
#     version-named folders, ZIM name templates, caller hints, and a generated sentence otherwise
D="$T/d"
mkdir -p "$T/tsh" "$D/tools/linux-x86_64/foo" "$D/tools/linux-x86_64/piper" "$D/tools/linux-x86_64/zzz" \
         "$D/dev-stack/python/pypi/demo" "$D/dev-stack/python/python/3.12.1" "$D/datasets/open-data/weather/noaa" \
         "$D/datasets/open-data/crops/huggingface/acme/fields" "$D/installers/ubuntu/24.04" "$D/content/zim" \
         "$D/models/huggingface/acme/yolo-tiny" "$D/sources/blender" "$D/software/releases/acme/widget/1.0"
printf '#!/bin/bash\n# Val Ark - Mirror Foo, the frobnicator\n#\n# Foo turns widgets into gadgets offline. It also does more.\n' > "$T/tsh/foo.sh"
echo x > "$D/tools/linux-x86_64/foo/foo"; echo x > "$D/tools/linux-x86_64/piper/piper"; echo x > "$D/tools/linux-x86_64/zzz/zzz"
python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("demo-1.0.dist-info/METADATA", "Metadata-Version: 2.1\nName: demo\nSummary: Demo package that does demos\n\nlong text")' \
    "$D/dev-stack/python/pypi/demo/demo-1.0-py3-none-any.whl"
echo x > "$D/dev-stack/python/python/3.12.1/Python-3.12.1.tar.xz"
echo x > "$D/content/zim/devdocs_en_react_2025-01.zim"
echo x > "$D/content/zim/ted_mul_ai_2026-01.zim"
echo x > "$D/content/zim/weirdsite.org_fr_all_nopic_2026-02.zim"
echo x > "$D/datasets/open-data/weather/noaa/readme.txt"
echo x > "$D/datasets/open-data/crops/huggingface/acme/fields/data.parquet"
echo x > "$D/installers/ubuntu/24.04/ubuntu.iso"
echo x > "$D/models/huggingface/acme/yolo-tiny/model.onnx"
echo x > "$D/sources/blender/blender-4.0.tar.xz"
echo x > "$D/software/releases/acme/widget/1.0/widget.zip"
printf 'datasets/open-data/weather/noaa/readme.txt\t{"description": "NOAA daily weather station records", "collection": "Public open data"}\n' > "$T/hints.tsv"
printf 'bad line without json\nx/../y\t{"description": "escape attempt here"}\n' >> "$T/hints.tsv"
dout=$(python3 -I "$PY" --root "$D" --web-ui "$W" --tools-dir "$T/tsh" --hints "$T/hints.tsv" --now 1700000000 2>&1); rc=$?
check "description build exits 0" '[ "$rc" -eq 0 ] || { echo "$dout" >&2; false; }'
nodesc=$(python3 -I - "$D/browse" <<'PYEOF'
import glob, re, sys
bad = []
for f in glob.glob(sys.argv[1] + '/*.html'):
    s = open(f, encoding='utf-8').read()
    for t, body in re.findall(r'<div class="tx"><h4>(.*?)</h4>(.*?)</a>', s, re.S):
        if not re.search(r'<p>\s*\S', body):
            bad.append(f.rsplit('/', 1)[-1] + ':' + t)
for f in glob.glob(sys.argv[1] + '/item/*.html'):
    s = open(f, encoding='utf-8').read()
    m = re.search(r'</h1>(.*?)<h3|</h1>(.*?)</main>', s, re.S)
    if m and not re.search(r'<p[^>]*>\s*[^<\s]', m.group(0)):
        bad.append('item:' + f.rsplit('/', 1)[-1])
print(' '.join(bad))
PYEOF
)
check "every card has a description" '[ -z "$nodesc" ] || { echo "no description: $nodesc" >&2; false; }'
check "tool found by its download target (piper -> Piper TTS)" 'grep -q "Fast local neural text to speech" "$D/browse/tools.html"'
check "tool without a web-UI card: scripts/tools header" 'grep -q "<p>Foo, the frobnicator. Foo turns widgets into gadgets offline.</p>" "$D/browse/tools.html"'
check "unknown tool: generated sentence" 'grep -q "zzz: portable builds for Linux x86_64" "$D/browse/tools.html"'
check "pypi package: Summary from the wheel METADATA" 'grep -q "Demo package that does demos" "$D/browse/dev-stack.html"'
check "version folder named by its project" 'grep -q "<h4>python</h4>" "$D/browse/dev-stack.html" && ! grep -q "<h4>3.12.1</h4>" "$D/browse/dev-stack.html"'
check "installer version folder titled with its parent" 'grep -q "<h4>ubuntu 24.04</h4>" "$D/browse/installers.html"'
check "ZIM template: DevDocs" 'grep -q "DevDocs reference for react" "$D/browse/content.html"'
check "ZIM template: TED" 'grep -q "TED talks about ai (several languages)" "$D/browse/content.html"'
check "ZIM without a template: generated" 'grep -q "in French, text only: an offline archive" "$D/browse/content.html"'
check "caller hint used as the description" 'grep -q "NOAA daily weather station records" "$D/browse/datasets.html"'
check "hint with .. ignored" '! grep -rq "escape attempt" "$D/browse"'
check "dataset: generated with topic and org" 'grep -q "A crops dataset: fields from acme" "$D/browse/datasets.html"'
check "model without a card: task from its name" 'grep -q "An object detection model — yolo-tiny from acme" "$D/browse/models.html" && grep -q "ONNX Runtime" "$D/browse/models.html"'
check "software release: generated" 'grep -q "Upstream release assets of acme/widget" "$D/browse/software.html"'
check "source archive: generated" 'grep -q "Source archive of blender" "$D/browse/sources.html"'
check "summary.json counts generated descriptions" 'python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));c={s[\"name\"]:s[\"descriptions\"] for s in d[\"sections\"]};sys.exit(0 if c[\"datasets\"][\"hint\"]==1 and c[\"tools\"][\"generated\"]>=1 else 1)" "$D/browse/summary.json"'
check "the run reports hint + generated counts" 'echo "$dout" | grep -q "descriptions from hints 1 / generated"'

# review fixes (#271): corrupt wheel, script headers, task words, a/an, run hints, tool hints, long hint
#     lines, wheel cache, scoped tool names
D2="$T/d2"; mkdir -p "$T/tsh2" "$D2/dev-stack/python/pypi/broken" "$D2/models/huggingface/acme/dinov2-vits14" \
    "$D2/models/huggingface/acme/vae-decoder" "$D2/models/huggingface/acme/dolphin-x" "$D2/models/huggingface/acme/ocr-small" \
    "$D2/models/huggingface/acme/yolo11n" "$D2/tools/linux-x86_64/audio" "$D2/tools/linux-x86_64/bar" \
    "$D2/tools/linux-x86_64/hinted" "$D2/datasets/misc/node" "$D2/dev-stack/python/pypi/demo"
python3 -I -c 'import sys, zipfile, zlib
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("broken-1.0.dist-info/METADATA", "Summary: should not crash\n" * 50)
b = bytearray(open(sys.argv[1], "rb").read()); i = b.find(b"PK\x03\x04") + 30 + len("broken-1.0.dist-info/METADATA")
b[i:i + 20] = b"\xff" * 20; open(sys.argv[1], "wb").write(bytes(b))' "$D2/dev-stack/python/pypi/broken/broken-1.0-py3-none-any.whl"
python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("demo-1.0.dist-info/METADATA", "Metadata-Version: 2.1\nName: demo\nSummary: Cached summary text\n")' \
    "$D2/dev-stack/python/pypi/demo/demo-1.0-py3-none-any.whl"
printf '#!/bin/bash\n# Val Ark - Download Audio\nsource x\n' > "$T/tsh2/audio.sh"
printf '#!/bin/bash\n# Val Ark - Mirror Bar, the offline thing (https://bar.example, MIT;\n# source https://github.com/x/bar): docs and maps.\n#\n# linux + windows: rolling builds -- current by design.\n' > "$T/tsh2/bar.sh"
for m in dinov2-vits14 vae-decoder dolphin-x ocr-small; do echo x > "$D2/models/huggingface/acme/$m/weights.bin"; done
echo x > "$D2/models/huggingface/acme/yolo11n/yolo11n.pt"
echo x > "$D2/tools/linux-x86_64/audio/audio"; echo x > "$D2/tools/linux-x86_64/bar/bar"; echo x > "$D2/tools/linux-x86_64/hinted/hinted"
echo x > "$D2/datasets/misc/node/data.csv"
{ printf 'tools/linux-x86_64/hinted/hinted\t{"description": "A hinted tool description"}\n'
  python3 -I -c 'print("x" * 200000)'
  printf 'datasets/misc/node/data.csv\t{"description": "after the long line"}\n'; } > "$T/hints2.tsv"
d2() { python3 -I "$PY" --root "$D2" --web-ui "$W" --tools-dir "$T/tsh2" --hints "$T/hints2.tsv" --now 1700000000 "$@"; }
out2=$(d2 2>&1); rc=$?
check "a corrupt wheel METADATA does not crash the build" '[ "$rc" -eq 0 ] || { echo "$out2" >&2; false; }'
check "...the fixture really is corrupt (zlib error on read)" '! python3 -I -c "import sys,zipfile;zipfile.ZipFile(sys.argv[1]).read(\"broken-1.0.dist-info/METADATA\")" "$D2/dev-stack/python/pypi/broken/broken-1.0-py3-none-any.whl" 2>/dev/null'
check "...and still gets a description" 'grep -A3 "<h4>broken</h4>" "$D2/browse/dev-stack.html" | grep -q "<p>"'
check "a 'Download X' header is not used as the description" '! grep -q "<p>Download Audio\|<p>Audio\.</p>" "$D2/browse/tools.html" && grep -q "audio: portable builds" "$D2/browse/tools.html"'
check "header: verb dropped, URLs removed, build notes skipped" 'grep -q "Bar, the offline thing: docs and maps\." "$D2/browse/tools.html" && ! grep -q "rolling builds\|https://" "$D2/browse/tools.html"'
check "task words are whole tokens (vits14, decoder, dolphin)" '! grep -q "text to speech model — dinov2\|code language model — vae\|language model — dolphin" "$D2/browse/models.html"'
check "a / an" 'grep -q "An OCR / document model — ocr-small" "$D2/browse/models.html" && grep -q "An object detection model — yolo11n" "$D2/browse/models.html"'
check "no transformers hint without safetensors / config.json" 'grep -o "<h4>yolo11n</h4>[^<]*<div[^>]*>[^<]*</div><p>[^<]*</p>" "$D2/browse/models.html" | grep -q "acme (1 file, 2 B)\.</p>"'
check "a hint reaches the tool card (tools/<platform>/<name>)" 'grep -q "A hinted tool description" "$D2/browse/tools.html"'
check "an over-long hint line is skipped, later lines still read" 'grep -q "after the long line" "$D2/browse/datasets.html"'
check "tool names do not leak into other sections (datasets/node)" '! grep -q "Node.js LTS runtime" "$D2/browse/datasets.html"'
check "wheel Summary cached by file + size" 'grep -q "demo-1.0-py3-none-any.whl|" "$D2/browse/pypi-meta.json"'
rm "$D2/dev-stack/python/pypi/demo/demo-1.0-py3-none-any.whl"; python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("demo-1.0.dist-info/METADATA", "Metadata-Version: 2.1\nName: demo\nSummary: Cached summary text\n")' \
    "$D2/dev-stack/python/pypi/demo/demo-1.0-py3-none-any.whl"
chmod 000 "$D2/dev-stack/python/pypi/demo/demo-1.0-py3-none-any.whl"
d2 >/dev/null 2>&1
if [ "$(id -u)" -ne 0 ]; then   # root reads a mode-000 file, so this proves nothing there
    check "...and reused without opening the wheel again" 'grep -q "Cached summary text" "$D2/browse/dev-stack.html"'
fi
chmod 644 "$D2/dev-stack/python/pypi/demo/demo-1.0-py3-none-any.whl"

printf '#!/bin/bash\n# Val Ark - Mirror Baz, a mapping kit with offline tiles\n#\n# scripts/lib/baz_mirror.py reads the manifest and keeps the current release.\n' > "$T/tsh2/baz.sh"
mkdir -p "$D2/tools/linux-x86_64/baz"; echo x > "$D2/tools/linux-x86_64/baz/baz"; d2 >/dev/null 2>&1
check "header: implementation notes (script paths) skipped" 'grep -q "<p>Baz, a mapping kit with offline tiles.</p>" "$D2/browse/tools.html"'

printf '#!/bin/bash\n# Val Ark - Download Qux\n# Distributed widget store (S3-compatible) for the fleet.\n' > "$T/tsh2/qux.sh"
printf '#!/bin/bash\n# Val Ark - Mirror lower-kit and everything it needs offline.\n' > "$T/tsh2/lower-kit.sh"
mkdir -p "$D2/tools/linux-x86_64/qux" "$D2/tools/linux-x86_64/lower-kit"
echo x > "$D2/tools/linux-x86_64/qux/qux"; echo x > "$D2/tools/linux-x86_64/lower-kit/lower-kit"; d2 >/dev/null 2>&1
check "header line keeps a full stop before the next sentence" 'grep -q "<p>Qux. Distributed widget store (S3-compatible) for the fleet.</p>" "$D2/browse/tools.html"'
check "a lowercase project name keeps its casing" 'grep -q "<p>lower-kit and everything it needs offline.</p>" "$D2/browse/tools.html"'

echo "static-site: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
