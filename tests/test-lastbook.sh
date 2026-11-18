#!/bin/bash
###############################################################################
# Test: the Lastbook mirror (scripts/lib/lastbook_mirror.py + scripts/tools/lastbook.sh).
#
# All offline. tests/fixtures/lastbook/ holds the real upstream manifests, trimmed
# (3 packs, the model, 3 state maps + 1 synthetic base map, 3 address indexes + 1 marked
# unavailable as upstream does for states with no records, a few
# SHA256SUMS lines). Plans run against those real sizes; mirrors run against a "tiny"
# copy whose files are a few KB each, served by a local HTTP server (Range, HEAD,
# a one-shot dropped connection) that the allow-listed upstream URLs are rewritten to.
# Invariants:
#   - --pack auto = the largest pack that fits the budget; none fits -> exit 3 + message
#   - every / explicit packs; base maps ride with any pack; maps/addresses filters
#   - apps = every installer of the current version from SHA256SUMS.txt, incl. the
#     ubuntu26.04 deb that app-v1.json lacks (and not 1.1.1 / 1.1.10 lookalikes)
#   - a URL off the allow-list (host, scheme, port, credentials) or an unsafe name fails closed
#   - sha256 mismatch -> nothing finalized, .part dropped, exit 1
#   - a .part resumes with Range; a dropped connection is retried and resumed
#   - a second run fetches no data files; a complete run prunes older files
#   - exit codes 0 / 1 / 3 / 64; argparse errors are 64, not 2
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; fi; }
PY="$ROOT/scripts/lib/lastbook_mirror.py"
SH="$ROOT/scripts/tools/lastbook.sh"
FIX="$ROOT/tests/fixtures/lastbook"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }

T="$(mktemp -d)"; SRV_PID=""
trap 'rm -rf "${T:?}"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
export VAL_ARK_CONFIG="$T/empty.conf" VAL_ARK_DATA="$T/disk" FORCE_COLOR=0 LC_ALL=C
unset VALARK_LASTBOOK_REWRITE VALARK_LASTBOOK_DIR VALARK_LASTBOOK_PACK VALARK_LASTBOOK_MAPS \
      VALARK_LASTBOOK_ADDRESSES VALARK_LASTBOOK_MODEL VALARK_LASTBOOK_APPS VALARK_LASTBOOK_BUDGET VALARK_LASTBOOK_BUDGET_PCT
: > "$VAL_ARK_CONFIG"; mkdir -p "$VAL_ARK_DATA"

check "lastbook_mirror.py compiles" 'python3 -m py_compile "$PY"'
check "lastbook.sh is valid bash" 'bash -n "$SH"'
check "lastbook.sh sources _common.sh" 'grep -q "_common.sh" "$SH"'

# --- fixture HTTP server --------------------------------------------------------------------------
cat > "$T/srv.py" <<'EOF'
import http.server, os, sys, urllib.parse
ROOT, LOG = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _file(self):
        p = os.path.join(ROOT, urllib.parse.urlsplit(self.path).path.lstrip("/"))
        return p if os.path.isfile(p) else None
    def _send(self, body_too):
        p = self._file()
        with open(LOG, "a") as f:
            f.write(f"{self.command} {urllib.parse.urlsplit(self.path).path} {self.headers.get('Range', '-')}\n")
        if not p:
            self.send_error(404); return
        data = open(p, "rb").read()
        start, code = 0, 200
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0])
            if start >= len(data):
                self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
            code = 206
        body = data[start:]
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        if code == 206:
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        self.end_headers()
        if not body_too:
            return
        drop = p + ".dropafter"
        if os.path.exists(drop):  # one-shot: send N bytes, then cut the connection
            n = int(open(drop).read()); os.remove(drop)
            self.wfile.write(body[:n]); self.wfile.flush()
            self.connection.shutdown(2); return
        self.wfile.write(body)
    def do_GET(self): self._send(True)
    def do_HEAD(self): self._send(False)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF
mkdir -p "$T/www"; : > "$T/req.log"
python3 "$T/srv.py" "$T/www" "$T/req.log" > "$T/port" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port")
[ -n "$PORT" ] || { echo "FAIL: fixture server did not start" >&2; exit 1; }
B="http://127.0.0.1:$PORT"

# real/ = the trimmed upstream manifests as-is (real sizes; only planned, never downloaded)
mkdir -p "$T/www/real/dl" "$T/www/real/site"
cp "$FIX/manifest-v1.json" "$FIX/app-v1.json" "$T/www/real/dl/"
cp "$FIX/SHA256SUMS.txt" "$T/www/real/site/"
REAL="https://downloads.lastbook.org/=$B/real/dl/ https://lastbook.org/=$B/real/site/ https://huggingface.co/=$B/real/hf/"

# tiny/ = the same release with every file a few KB, real names and URL paths
python3 - "$FIX" "$T/www/tiny" <<'EOF'
import hashlib, json, os, sys, urllib.parse
fix, out = sys.argv[1], sys.argv[2]
roots = {"downloads.lastbook.org": "dl", "lastbook.org": "site", "huggingface.co": "hf"}
def put(url, i):
    u = urllib.parse.urlsplit(url)
    p = os.path.join(out, roots[u.hostname], u.path.lstrip("/"))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if os.path.exists(p):  # SHA256SUMS.txt also lists the Small pack: one file, one sha
        data = open(p, "rb").read()
        return len(data), hashlib.sha256(data).hexdigest()
    data = (f"lastbook fixture {url}\n".encode() * (40 + 7 * i))
    open(p, "wb").write(data)
    return len(data), hashlib.sha256(data).hexdigest()
m = json.load(open(os.path.join(fix, "manifest-v1.json")))
i = 0
for sec in ("packs", "maps", "address_indexes"):
    for e in m[sec]:
        for f in e.get("files", []):
            i += 1; f["size"], f["sha256"] = put(f["url"], i)
        e["installed_bytes"] = sum(f["size"] for f in e.get("files", []))
for md in m["models"]:
    i += 1; md["size"], md["sha256"] = put(md["url"], i)
a = json.load(open(os.path.join(fix, "app-v1.json")))
sums = []
for line in open(os.path.join(fix, "SHA256SUMS.txt")):
    sha, name = line.split()
    i += 1; size, sha = put("https://downloads.lastbook.org/" + name, i)
    sums.append(f"{sha}  {name}")
    for k, v in a.items():
        if isinstance(v, dict) and v.get("url", "").endswith("/" + name):
            v["size"], v["sha256"] = size, sha
os.makedirs(os.path.join(out, "dl"), exist_ok=True); os.makedirs(os.path.join(out, "site"), exist_ok=True)
json.dump(m, open(os.path.join(out, "dl", "manifest-v1.json"), "w"))
json.dump(a, open(os.path.join(out, "dl", "app-v1.json"), "w"))
open(os.path.join(out, "site", "SHA256SUMS.txt"), "w").write("\n".join(sums) + "\n")
EOF
TINY="https://downloads.lastbook.org/=$B/tiny/dl/ https://lastbook.org/=$B/tiny/site/ https://huggingface.co/=$B/tiny/hf/"

plan() { VALARK_LASTBOOK_REWRITE="$REAL" python3 "$PY" plan "$@" 2>"$T/plan.err"; }
# got STATUS SECTION: the ids of plan rows with that status+section, sorted, space-separated
got() { awk -F'\t' -v s="$1" -v c="$2" '$1==s && $2==c {print $3}' "$T/plan.out" | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# --- 1. pack auto at several budgets ------------------------------------------------------------
plan --budget 5G > "$T/plan.out"; rc=$?
check "auto, 5 GB: no pack fits -> exit 3" '[ "$rc" = 3 ]'
check "auto, 5 GB: no pack selected" '[ -z "$(got get pack)" ]'
check "auto, 5 GB: says why" 'grep -q "no Lastbook pack fits the budget" "$T/plan.out"'
check "auto, 5 GB: no base map / model / state maps without a pack" '[ -z "$(got get map)$(got get model)" ]'
plan --budget 10G > "$T/plan.out"; rc=$?
check "auto, 10 GB: Small" '[ "$(got get pack)" = small ] && [ "$rc" = 0 ]'
check "auto, 10 GB: base map rides with the pack" 'got get map | grep -qw base'
check "auto, 10 GB: model does not fit -> skipped, not deferred" '[ -z "$(got get model)$(got deferred model)" ] && grep -q "does not fit after the pack" "$T/plan.out"'
plan --budget 100G > "$T/plan.out"
check "auto, 100 GB: Medium" '[ "$(got get pack)" = medium ]'
check "auto, 100 GB: model fits after the pack" '[ "$(got get model)" = gemma-4-26b-a4b ]'
plan --budget 450G > "$T/plan.out"
check "auto, 450 GB: All" '[ "$(got get pack)" = all ]'
plan --budget -1 > "$T/plan.out"
check "auto, unlimited: All + every map + every address index" '[ "$(got get pack)" = all ] && [ "$(got get map)" = "AK CA TX base" ] && [ "$(got get address)" = "AK CA TX" ]'
check "plan prints a total line" 'grep -q "^# Lastbook manifest 2026-11-13 app 1.1.11: " "$T/plan.out"'
check "plan TSV header" '[ "$(head -1 "$T/plan.out")" = "$(printf "status\tsection\tid\tbytes\tto_fetch\tpath")" ]'

# --- 2. every / explicit packs ------------------------------------------------------------------
plan --pack every --budget -1 > "$T/plan.out"
check "every: all three packs" '[ "$(got get pack)" = "all medium small" ]'
plan --pack every --budget 100G > "$T/plan.out"; rc=$?
check "every, 100 GB: Small+Medium kept, All deferred, exit 3" '[ "$(got get pack)" = "medium small" ] && [ "$(got deferred pack)" = all ] && [ "$rc" = 3 ]'
plan --pack small,MEDIUM --budget -1 > "$T/plan.out"
check "explicit list (case-insensitive)" '[ "$(got get pack)" = "medium small" ]'
plan --pack none --maps none --budget -1 > "$T/plan.out"; rc=$?
check "--pack none: apps only, exit 0" '[ -z "$(got get pack)$(got get map)" ] && [ "$(got get app)" = 1.1.11 ] && [ "$rc" = 0 ]'
plan --pack bogus --budget -1 >/dev/null; rc=$?
check "unknown pack -> exit 64" '[ "$rc" = 64 ]'
plan --model maybe >/dev/null 2>&1; rc=$?
check "bad choice -> exit 64 (not argparse 2)" '[ "$rc" = 64 ]'
python3 "$PY" >/dev/null 2>&1; rc=$?
check "no command -> exit 64" '[ "$rc" = 64 ]'
python3 "$PY" mirror --pack small >/dev/null 2>&1; rc=$?
check "mirror without --dest -> exit 64" '[ "$rc" = 64 ]'
plan --budget lots >/dev/null; rc=$?
check "bad budget -> exit 64" '[ "$rc" = 64 ]'

# --- 3. map / address filters + model ---------------------------------------------------------------
plan --pack small --maps CA,ak --budget -1 > "$T/plan.out"
check "--maps CA,ak: those maps + base, addresses follow" '[ "$(got get map)" = "AK CA base" ] && [ "$(got get address)" = "AK CA" ]'
plan --pack small --maps CA --addresses none --budget -1 > "$T/plan.out"
check "--addresses none" '[ "$(got get map)" = "CA base" ] && [ -z "$(got get address)" ]'
plan --pack small --maps none --addresses TX --budget -1 > "$T/plan.out"
check "--maps none --addresses TX" '[ "$(got get map)" = base ] && [ "$(got get address)" = TX ]'
plan --pack small --maps none --addresses all --budget -1 > "$T/plan.out"
check "--addresses all" '[ "$(got get address)" = "AK CA TX" ]'
plan --pack small --maps none --addresses CA,HI --budget -1 > "$T/plan.out"; rc=$?
check "unavailable upstream (HI addresses): skipped with a note, not an error" '[ "$rc" = 0 ] && [ "$(got get address)" = CA ] && grep -q "address index HI is not available upstream" "$T/plan.out"'
plan --pack small --maps XX --budget -1 >/dev/null; rc=$?
check "unknown state code -> exit 64" '[ "$rc" = 64 ]'
plan --pack small --maps all --budget 10G > "$T/plan.out"; rc=$?
check "--maps all over budget: deferred, exit 3" '[ -n "$(got deferred map)" ] && [ "$rc" = 3 ]'
plan --pack small --model yes --budget 10G > "$T/plan.out"; rc=$?
check "--model yes over budget: deferred, exit 3" '[ "$(got deferred model)" = gemma-4-26b-a4b ] && [ "$rc" = 3 ]'
plan --pack small --model no --budget -1 > "$T/plan.out"
check "--model no" '[ -z "$(got get model)" ]'

# --- 4. installers from SHA256SUMS ------------------------------------------------------------------
plan --pack none --maps none --budget -1 > "$T/plan.out"
apps=$(awk -F'\t' '$2=="app"{print $6}' "$T/plan.out" | sort | tr '\n' ' ')
check "apps: the four 1.1.11 installers incl. the ubuntu26.04 deb" '[ "$apps" = "app/1.1.11/Lastbook-1.1.11-Setup.exe app/1.1.11/Lastbook-1.1.11-mac.dmg app/1.1.11/Lastbook_1.1.11_amd64.deb app/1.1.11/Lastbook_1.1.11_ubuntu26.04_amd64.deb " ]'
check "apps: not the 1.1.1 / 1.1.10 lookalikes" '! grep -qE "1\.1\.1-|1\.1\.10" "$T/plan.out"'
plan --pack none --maps none --apps none --budget -1 > "$T/plan.out"
check "--apps none" '[ -z "$(got get app)" ]'

# --- 5. allow-list: fail closed --------------------------------------------------------------------
bad() {  # bad LABEL PYTHON-EDIT-OF-m : serve an altered manifest, expect exit 1
    rm -rf "$T/www/bad"; mkdir -p "$T/www/bad/dl" "$T/www/bad/site"
    cp "$FIX/app-v1.json" "$T/www/bad/dl/"; cp "$FIX/SHA256SUMS.txt" "$T/www/bad/site/"
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(m,open(sys.argv[2],"w"))' \
        "$FIX/manifest-v1.json" "$T/www/bad/dl/manifest-v1.json" "$2"
    VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/=$B/bad/dl/ https://lastbook.org/=$B/bad/site/" \
        python3 "$PY" plan --pack small --budget -1 >/dev/null 2>"$T/bad.err"
    local rc=$?
    check "allow-list: $1 -> exit 1" '[ "$rc" = 1 ] && grep -qi "refusing\|unsafe\|bad sha" "$T/bad.err"'
}
bad "other host (in an unselected map)" 'm["maps"][-1]["files"][0]["url"]="https://evil.example/x.zip"'
bad "http scheme"        'm["packs"][0]["files"][0]["url"]="http://downloads.lastbook.org/Lastbook-Small.zip"'
bad "lookalike host"     'm["packs"][0]["files"][0]["url"]="https://downloads.lastbook.org.evil.example/x.zip"'
bad "credentials in URL" 'm["packs"][0]["files"][0]["url"]="https://u:p@downloads.lastbook.org/x.zip"'
bad "odd port"           'm["packs"][0]["files"][0]["url"]="https://downloads.lastbook.org:8443/x.zip"'
bad "model off-host"     'm["models"][0]["url"]="https://cdn.example/x.gguf"'
bad "path in a name"     'm["packs"][0]["files"][0]["name"]="../../etc/x.zip"'
bad "bad sha256"         'm["packs"][0]["files"][0]["sha256"]="abc"'
VALARK_LASTBOOK_REWRITE="$REAL" python3 "$PY" plan --manifest-url https://evil.example/manifest-v1.json --budget -1 >/dev/null 2>&1; rc=$?
check "allow-list: manifest URL off-host -> exit 1" '[ "$rc" = 1 ]'
python3 - "$ROOT/scripts/lib" <<'EOF' && pass || fail "redirect policy"
import sys; sys.path.insert(0, sys.argv[1]); import lastbook_mirror as l
assert l.redirect_ok("https://cas-bridge.xethub.hf.co/x", None)
assert l.redirect_ok("https://cdn-lfs.huggingface.co/x", None)
assert not l.redirect_ok("http://cdn-lfs.huggingface.co/x", None)
assert not l.redirect_ok("https://evil.example/x", None)
assert not l.redirect_ok("https://evilhf.co/x", None)
EOF

# --- 6. mirror: full run, layout, manifests, stamps ---------------------------------------------------
mir() { VALARK_LASTBOOK_REWRITE="$TINY" python3 "$PY" mirror --tries 2 --retry-wait 0 --budget -1 "$@"; }
D="$T/m1"
mir --dest "$D" --pack small --maps CA --model yes > "$T/out" 2>"$T/err"; rc=$?
check "mirror: exit 0" '[ "$rc" = 0 ] || { cat "$T/err" >&2; false; }'
check "mirror: pack in packs/" '[ -s "$D/packs/Lastbook-Small-20261113.zip" ]'
check "mirror: maps + base in maps/" '[ -s "$D/maps/Lastbook-Map-CA.zip" ] && [ -s "$D/maps/Lastbook-Map-base.zip" ] && [ ! -e "$D/maps/Lastbook-Map-TX.zip" ]'
check "mirror: address index in addresses/" '[ -s "$D/addresses/Lastbook-Addresses-CA.zip" ] && [ ! -e "$D/addresses/Lastbook-Addresses-TX.zip" ]'
check "mirror: model in models/ under its file name" '[ -s "$D/models/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" ]'
check "mirror: four installers in app/1.1.11/" '[ "$(ls "$D/app/1.1.11" | wc -l)" = 4 ] && [ -s "$D/app/1.1.11/Lastbook_1.1.11_ubuntu26.04_amd64.deb" ]'
check "mirror: the three manifests beside them" '[ -s "$D/manifest-v1.json" ] && [ -s "$D/app-v1.json" ] && [ -s "$D/SHA256SUMS.txt" ]'
check "mirror: no .part left" '[ -z "$(find "$D" -name "*.part")" ]'
python3 - "$D" <<'EOF' && pass || fail "every copy matches its manifest sha256"
import hashlib, json, os, sys
d = sys.argv[1]; m = json.load(open(os.path.join(d, "manifest-v1.json")))
shas = {f["name"]: f["sha256"] for s in ("packs", "maps", "address_indexes") for e in m[s] for f in e.get("files", [])}
shas.update({x["file"]: x["sha256"] for x in m["models"]})
for line in open(os.path.join(d, "SHA256SUMS.txt")):
    sha, name = line.split(); shas[name] = sha
n = 0
for root, _, files in os.walk(d):
    for f in files:
        if f in shas:
            assert hashlib.sha256(open(os.path.join(root, f), "rb").read()).hexdigest() == shas[f], f; n += 1
assert n == 9, n
EOF
check "mirror: JSON summary last" 'tail -1 "$T/out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"rc\"]==0 and d[\"statuses\"][\"fetched\"]==9 and d[\"packs\"]==[\"small\"]"'

# --- 7. idempotent second run -------------------------------------------------------------------------
: > "$T/req.log"
mir --dest "$D" --pack small --maps CA --model yes > "$T/out" 2>"$T/err"; rc=$?
check "rerun: exit 0" '[ "$rc" = 0 ]'
check "rerun: no data file requested (manifests only)" '[ -z "$(grep "^GET" "$T/req.log" | grep -v -e manifest-v1.json -e app-v1.json -e SHA256SUMS.txt)" ]'
check "rerun: all 9 verified, 0 fetched" 'tail -1 "$T/out" | python3 -c "import json,sys; s=json.load(sys.stdin)[\"statuses\"]; assert s[\"verified\"]==9 and s[\"fetched\"]==0"'
# a copy changed on disk is re-fetched (the stamp no longer matches)
echo tampered > "$D/maps/Lastbook-Map-CA.zip"
mir --dest "$D" --pack small --maps CA --model yes > "$T/out" 2>"$T/err"; rc=$?
check "altered copy re-fetched and re-verified" '[ "$rc" = 0 ] && ! grep -q tampered "$D/maps/Lastbook-Map-CA.zip"'

# --- 8. resume of a .part -------------------------------------------------------------------------
D2="$T/m2"; SRC="$T/www/tiny/dl/Lastbook-Small-20261113.zip"
mkdir -p "$D2/packs"; head -c 100 "$SRC" > "$D2/packs/Lastbook-Small-20261113.zip.part"
: > "$T/req.log"
mir --dest "$D2" --pack small --maps none --apps none > "$T/out" 2>"$T/err"; rc=$?
check "resume: exit 0" '[ "$rc" = 0 ]'
check "resume: Range from byte 100" 'grep -q "^GET /tiny/dl/Lastbook-Small-20261113.zip bytes=100-" "$T/req.log"'
check "resume: result is the full verified file" 'cmp -s "$SRC" "$D2/packs/Lastbook-Small-20261113.zip"'
# dropped connection mid-file: retried, resumed
D3="$T/m3"; echo 50 > "$T/www/tiny/dl/maps/Lastbook-Map-CA.zip.dropafter"
: > "$T/req.log"
mir --dest "$D3" --pack none --maps CA --addresses none --apps none > "$T/out" 2>"$T/err"; rc=$?
check "dropped connection: retried + resumed to a verified file" '[ "$rc" = 0 ] && cmp -s "$T/www/tiny/dl/maps/Lastbook-Map-CA.zip" "$D3/maps/Lastbook-Map-CA.zip" && grep -q "Lastbook-Map-CA.zip bytes=50-" "$T/req.log"'

# --- 9. sha mismatch -> not finalized ---------------------------------------------------------------
D4="$T/m4"; cp "$T/www/tiny/dl/maps/Lastbook-Map-TX.zip" "$T/tx.keep"
python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[5]^=1; open(p,"wb").write(b)' "$T/www/tiny/dl/maps/Lastbook-Map-TX.zip"
mir --dest "$D4" --pack none --maps CA,TX --addresses none --apps none > "$T/out" 2>"$T/err"; rc=$?
check "sha mismatch: exit 1" '[ "$rc" = 1 ]'
check "sha mismatch: file not finalized, .part dropped" '[ ! -e "$D4/maps/Lastbook-Map-TX.zip" ] && [ ! -e "$D4/maps/Lastbook-Map-TX.zip.part" ]'
check "sha mismatch: the other file still completes" '[ -s "$D4/maps/Lastbook-Map-CA.zip" ]'
check "sha mismatch: logged" 'grep -q "sha256 mismatch" "$T/err"'
cp "$T/tx.keep" "$T/www/tiny/dl/maps/Lastbook-Map-TX.zip"
mir --dest "$D4" --pack none --maps CA,TX --addresses none --apps none > "$T/out" 2>"$T/err"; rc=$?
check "after upstream fix: exit 0" '[ "$rc" = 0 ] && [ -s "$D4/maps/Lastbook-Map-TX.zip" ]'

# --- 10. budget-deferred mirror, dry run, prune --------------------------------------------------------
mir --dest "$T/m5" --pack every --maps none --apps none --budget 1 > "$T/out" 2>"$T/err"; rc=$?
check "budget too small for explicit packs: exit 3, nothing fetched" '[ "$rc" = 3 ] && [ -z "$(ls "$T/m5/packs" 2>/dev/null)" ]'
mir --dest "$T/m6" --pack small --dry-run > "$T/out" 2>"$T/err"; rc=$?
check "--dry-run: plan printed, nothing written" '[ "$rc" = 0 ] && grep -q "^get	pack	small" "$T/out" && [ ! -e "$T/m6" ]'
mkdir -p "$D/app/1.1.10"; echo old > "$D/app/1.1.10/Lastbook-1.1.10-mac.dmg"; echo old > "$D/packs/Lastbook-Small-20261001.zip"
mir --dest "$D" --pack small --maps CA --model yes --keep-old > "$T/out" 2>"$T/err"
check "--keep-old keeps older files" '[ -e "$D/app/1.1.10" ] && [ -e "$D/packs/Lastbook-Small-20261001.zip" ]'
mir --dest "$D" --pack small --maps CA --model yes > "$T/out" 2>"$T/err"; rc=$?
check "complete run prunes older versions/files" '[ "$rc" = 0 ] && [ ! -e "$D/app/1.1.10" ] && [ ! -e "$D/packs/Lastbook-Small-20261001.zip" ] && [ -s "$D/packs/Lastbook-Small-20261113.zip" ]'

# --- 11. the tool entry --------------------------------------------------------------------------
: > "$T/req.log"
VALARK_LASTBOOK_REWRITE="$TINY" VALARK_LASTBOOK_BUDGET=-1 VALARK_LASTBOOK_MAPS=none VALARK_LASTBOOK_MODEL=no \
    VALARK_DL_RETRY_DELAY=0 bash "$SH" --pack small > "$T/sh.out" 2>&1; rc=$?
check "lastbook.sh: exit 0, stores under content/lastbook" '[ "$rc" = 0 ] && [ -s "$VAL_ARK_DATA/val-ark/content/lastbook/packs/Lastbook-Small-20261113.zip" ] || { cat "$T/sh.out" >&2; false; }'
check "lastbook.sh: .env defaults apply (no maps, no model)" '[ ! -e "$VAL_ARK_DATA/val-ark/content/lastbook/models" ] && [ -z "$(ls "$VAL_ARK_DATA/val-ark/content/lastbook/maps" 2>/dev/null | grep -v base)" ]'
check "lastbook.sh: success logged" 'grep -q "lastbook: current release mirrored" "$T/sh.out"'
VALARK_LASTBOOK_REWRITE="$TINY" VALARK_LASTBOOK_BUDGET=1 bash "$SH" > "$T/sh.out" 2>&1; rc=$?
check "lastbook.sh: auto with no room keeps the held pack (need 0) -> exit 0" '[ "$rc" = 0 ] && grep -q "pack: small" "$T/sh.out"'
VALARK_LASTBOOK_REWRITE="$TINY" bash "$SH" plan --budget -1 --pack every > "$T/sh.out" 2>&1; rc=$?
check "lastbook.sh plan: CLI overrides .env" '[ "$rc" = 0 ] && [ "$(grep -c "^get	pack" "$T/sh.out")" = 3 ]'
VALARK_LASTBOOK_REWRITE="$TINY" VALARK_LASTBOOK_PACK=nope bash "$SH" > "$T/sh.out" 2>&1; rc=$?
check "lastbook.sh: bad option -> non-zero + error" '[ "$rc" != 0 ] && grep -q "bad option" "$T/sh.out"'
check "lastbook is in download-tools.sh list (default refresh)" 'bash "$ROOT/scripts/download-tools.sh" list 2>/dev/null | grep -q "  lastbook$"'
check "source-repos.tsv lists Immortal-Protocols/lastbook" 'grep -q "^[0-9]*|Immortal-Protocols/lastbook|" "$ROOT/data/source-repos.tsv"'
check ".env.example documents the knobs" 'grep -q "VALARK_LASTBOOK_PACK" "$ROOT/.env.example" && grep -q "VALARK_LASTBOOK_BUDGET_PCT" "$ROOT/.env.example"'

echo "lastbook: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
