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
#   - a second run fetches no data files; a complete run prunes older files it recorded,
#     never a file it did not record, never through a symlinked section dir, and not at
#     all when the release looks truncated
#   - a server ignoring Range restarts from 0; a 416 resets the .part; an off-list
#     redirect is refused (a same-host redirect of a rewritten base is followed)
#   - a 206 starting anywhere but the .part size restarts from 0; a 404 is not retried
#   - --pack auto reserves room for the base maps + installers, else keeps a held pack;
#     the default budget is a share of (dest-filesystem headroom + bytes held), and a
#     fetch never cuts into the reserve
#   - a verified single pack (auto / one id) prunes the smaller packs nested in it
#     (never with every or a list); maps / addresses / models each refuse a prune that
#     loses most of the section while the release lists fewer; stray unrecorded .parts
#     go only when a current or kept manifest names them
#   - a pack re-released under a new name replaces the old file (not a gutted one); auto
#     stays on a held, verified pack when the manifest over-reports another; an
#     out-of-tree Lastbook dir is listed by server.js from its records only
#   - a size claim that would displace a held pack must be HEAD-confirmed (a failed HEAD is
#     not confirmation); a pack whose HEAD disagrees is never downloaded; swapped pack ids
#     never make the nested prune delete a file the release still names
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

. "$ROOT/tests/lib/ports.sh"
T="$(mktemp -d)"; SRV_PID=""; NPID=""
trap 'stop_pids $SRV_PID $NPID; rm -rf "${T:?}"' EXIT; trap_signals
export VAL_ARK_CONFIG="$T/empty.conf" VAL_ARK_DATA="$T/disk" FORCE_COLOR=0 LC_ALL=C
# No disk reserve by default: fetches stop at the reserve, and a CI runner has little free space.
export VALARK_RESERVE_PCT=0 VALARK_RESERVE_MIN_GB=0
unset VALARK_MAX_GB
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
        return p if os.path.isfile(p) or os.path.isfile(p + ".redirect") else None
    def _send(self, body_too):
        p = self._file()
        with open(LOG, "a") as f:
            f.write(f"{self.command} {urllib.parse.urlsplit(self.path).path} {self.headers.get('Range', '-')}\n")
        if not p:
            self.send_error(404); return
        if not body_too and os.path.exists(p + ".nohead"):  # persistent: HEAD fails (no size to confirm)
            self.send_error(500); return
        if os.path.exists(p + ".redirect"):  # persistent: 302 to the URL in the flag file
            self.send_response(302); self.send_header("Location", open(p + ".redirect").read().strip())
            self.send_header("Content-Length", "0"); self.end_headers(); return
        data = open(p, "rb").read()
        start, code = 0, 200
        rng = self.headers.get("Range")
        if rng and os.path.exists(p + ".416once"):  # one-shot: refuse the range
            os.remove(p + ".416once")
            self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
        if os.path.exists(p + ".norange"):  # persistent: ignore Range, always 200 + the whole file
            rng = None
        end = len(data)
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0])
            if start >= len(data):
                self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
            code = 206
            if body_too and os.path.exists(p + ".shiftonce"):  # one-shot: a 206 from 10 bytes too early,
                os.remove(p + ".shiftonce")                    # as long as the rest (sizes still add up)
                start, end = start - 10, len(data) - 10
        body = data[start:end]
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        if code == 206:
            self.send_header("Content-Range", f"bytes {start}-{end - 1}/{len(data)}")
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
# stamp DEST KEY...: record files as this tool's own (as an earlier run would have)
stamp() { python3 - "$@" <<'EOF'
import json, os, sys
d, keys = sys.argv[1], sys.argv[2:]; f = os.path.join(d, ".lastbook-verified.json")
s = json.load(open(f)) if os.path.exists(f) else {}
for k in keys:
    st = os.stat(os.path.join(d, k))
    s[k] = {"part": True} if k.endswith(".part") else dict(sha256="0" * 64, size=st.st_size, mtime_ns=st.st_mtime_ns)
json.dump(s, open(f, "w"))
EOF
}
mkdir -p "$D/app/1.1.10" "$D/app/1.1.9" "$D/app/myproject"
echo old > "$D/app/1.1.10/Lastbook-1.1.10-mac.dmg"; echo old > "$D/app/1.1.9/Lastbook_1.1.9_amd64.deb"
echo old > "$D/packs/Lastbook-Small-20261001.zip"; echo old > "$D/maps/Lastbook-Map-Old.zip.part"
stamp "$D" app/1.1.10/Lastbook-1.1.10-mac.dmg app/1.1.9/Lastbook_1.1.9_amd64.deb packs/Lastbook-Small-20261001.zip maps/Lastbook-Map-Old.zip.part
# files this tool never recorded: must survive every prune
echo mine > "$D/packs/foreign.zip"; echo mine > "$D/maps/hiking.mbtiles"; echo mine > "$D/addresses/mine.zip"
echo mine > "$D/models/llama-3-8b.gguf"; echo mine > "$D/app/myproject/main.py"; echo mine > "$D/app/1.1.10/notes.txt"
mir --dest "$D" --pack small --maps CA --model yes --keep-old > "$T/out" 2>"$T/err"
check "--keep-old keeps older files" '[ -e "$D/app/1.1.10/Lastbook-1.1.10-mac.dmg" ] && [ -e "$D/packs/Lastbook-Small-20261001.zip" ]'
mir --dest "$D" --pack small --maps CA --model yes > "$T/out" 2>"$T/err"; rc=$?
check "prune: recorded older files go (incl. a recorded .part)" '[ "$rc" = 0 ] && [ ! -e "$D/app/1.1.10/Lastbook-1.1.10-mac.dmg" ] && [ ! -e "$D/packs/Lastbook-Small-20261001.zip" ] && [ ! -e "$D/maps/Lastbook-Map-Old.zip.part" ] && [ -s "$D/packs/Lastbook-Small-20261113.zip" ]'
check "prune: an emptied old app dir is removed" '[ ! -e "$D/app/1.1.9" ]'
check "prune: unrecorded files in every section survive" '[ -s "$D/packs/foreign.zip" ] && [ -s "$D/maps/hiking.mbtiles" ] && [ -s "$D/addresses/mine.zip" ] && [ -s "$D/models/llama-3-8b.gguf" ] && [ -s "$D/app/myproject/main.py" ] && [ -s "$D/app/1.1.10/notes.txt" ]'
check "prune: the current release is intact" '[ "$(ls "$D/app/1.1.11" | wc -l)" = 4 ] && [ -s "$D/maps/Lastbook-Map-CA.zip" ] && [ -s "$D/models/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" ]'
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert not any(k.startswith(("app/1.1.10/","app/1.1.9/","packs/Lastbook-Small-20261001","maps/Lastbook-Map-Old")) for k in s)' "$D/.lastbook-verified.json" && pass || fail "prune: pruned keys leave the stamps file"

# symlinked section dirs are never followed by prune (B2)
D7="$T/m7"; mkdir -p "$D7" "$T/shared" "$T/otherapp/1.0.0"
echo shared > "$T/shared/qwen.gguf"; echo keep > "$T/otherapp/1.0.0/keep.bin"
ln -s "$T/shared" "$D7/models"; ln -s "$T/otherapp" "$D7/app"
mir --dest "$D7" --pack none --maps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "symlinked app/: installers land through the link (fetch follows it)" '[ "$rc" = 0 ] && [ "$(ls "$T/otherapp/1.1.11" | wc -l)" = 4 ]'
stamp "$D7" models/qwen.gguf app/1.0.0/keep.bin
mir --dest "$D7" --pack none --maps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "symlinked models/ and app/: prune does not follow them" '[ "$rc" = 0 ] && [ -s "$T/shared/qwen.gguf" ] && [ -s "$T/otherapp/1.0.0/keep.bin" ] && grep -q "symlink" "$T/err"'

# a truncated / bad upstream manifest never wipes the mirror (N1)
mkdir -p "$T/www/trunc"
python3 - "$T/www/tiny/dl" "$T/www/trunc" <<'EOF'
import json, os, sys
src, out = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(src, "manifest-v1.json"))); m["maps"] = []; m["address_indexes"] = []
json.dump(m, open(os.path.join(out, "empty-maps.json"), "w"))
m = json.load(open(os.path.join(src, "manifest-v1.json")))
for sec in ("packs", "maps", "address_indexes"):
    for e in m[sec]:
        for f in e.get("files", []): f["name"] = f["name"].replace(".zip", "-v2.zip")
for x in m["models"]: x["file"] = "renamed-" + x["file"]
json.dump(m, open(os.path.join(out, "renamed.json"), "w"))
a = json.load(open(os.path.join(src, "app-v1.json")))
for v in a.values():
    if isinstance(v, dict): v["version"] = "1.1.12"
json.dump(a, open(os.path.join(out, "app-bumped.json"), "w"))
EOF
held_before=$(find "$D" -type f ! -name ".*" | sort | md5sum)
VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/manifest-v1.json=$B/trunc/empty-maps.json $TINY" \
    python3 "$PY" mirror --dest "$D" --budget -1 --pack none --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "release with an emptied section: no prune, says why" '[ "$rc" = 0 ] && [ -s "$D/maps/Lastbook-Map-CA.zip" ] && [ -s "$D/addresses/Lastbook-Addresses-CA.zip" ] && grep -q "NOT pruning: the release lists no" "$T/err"'
VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/manifest-v1.json=$B/trunc/renamed.json https://downloads.lastbook.org/app-v1.json=$B/trunc/app-bumped.json $TINY" \
    python3 "$PY" mirror --dest "$D" --budget -1 --pack none --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "release dropping most held files: no prune, says why" '[ "$rc" = 0 ] && grep -q "NOT pruning: the release would drop" "$T/err"'
check "bad releases left every held file in place" '[ "$(find "$D" -type f ! -name ".*" | sort | md5sum)" = "$held_before" ]'
# restore the real manifests in D for the later sections
mir --dest "$D" --pack small --maps CA --model yes > "$T/out" 2>"$T/err"

# --- 10b. odd servers: Range ignored, 416, redirects (N8) --------------------------------------------
PK="$T/www/tiny/dl/Lastbook-Small-20261113.zip"
D10="$T/m10"; mkdir -p "$D10/packs"; head -c 100 /dev/zero | tr '\0' x > "$D10/packs/Lastbook-Small-20261113.zip.part"
touch "$PK.norange"; : > "$T/req.log"
mir --dest "$D10" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
rm -f "$PK.norange"
check "server ignores Range (200): restart from 0, verified" '[ "$rc" = 0 ] && cmp -s "$PK" "$D10/packs/Lastbook-Small-20261113.zip" && grep -q "Lastbook-Small-20261113.zip bytes=100-" "$T/req.log"'
D11="$T/m11"; mkdir -p "$D11/packs"; head -c 100 "$PK" > "$D11/packs/Lastbook-Small-20261113.zip.part"
touch "$PK.416once"; : > "$T/req.log"
mir --dest "$D11" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "416: .part reset, refetched from 0, verified" '[ "$rc" = 0 ] && cmp -s "$PK" "$D11/packs/Lastbook-Small-20261113.zip" && grep -q "Lastbook-Small-20261113.zip bytes=100-" "$T/req.log" && grep -q "^GET /tiny/dl/Lastbook-Small-20261113.zip -$" "$T/req.log"'
CA="$T/www/tiny/dl/maps/Lastbook-Map-CA.zip"
mv "$CA" "$T/ca.keep"; echo "https://evil.example/Lastbook-Map-CA.zip" > "$CA.redirect"
mir --dest "$T/m12" --pack none --maps CA --addresses none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "redirect off the allow-list: refused, exit 1, nothing finalized" '[ "$rc" = 1 ] && [ ! -e "$T/m12/maps/Lastbook-Map-CA.zip" ] && grep -q "redirect to a non-allow-listed URL refused" "$T/err"'
mkdir -p "$T/www/tiny/alt"; cp "$T/ca.keep" "$T/www/tiny/alt/Lastbook-Map-CA.zip"; echo "$B/tiny/alt/Lastbook-Map-CA.zip" > "$CA.redirect"
mir --dest "$T/m13" --pack none --maps CA --addresses none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "same-host redirect of a rewritten base: followed + verified" '[ "$rc" = 0 ] && cmp -s "$T/ca.keep" "$T/m13/maps/Lastbook-Map-CA.zip"'
rm -f "$CA.redirect"; mv "$T/ca.keep" "$CA"

# a 206 that does not continue where the .part ends restarts from 0 (N7)
D14="$T/m14"; mkdir -p "$D14/packs"; head -c 100 "$PK" > "$D14/packs/Lastbook-Small-20261113.zip.part"
touch "$PK.shiftonce"; : > "$T/req.log"
mir --dest "$D14" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
rm -f "$PK.shiftonce"
check "206 with the wrong Content-Range start: restart from 0, verified" '[ "$rc" = 0 ] && cmp -s "$PK" "$D14/packs/Lastbook-Small-20261113.zip" && grep -q "does not start at byte 100" "$T/err" && grep -q "^GET /tiny/dl/Lastbook-Small-20261113.zip -$" "$T/req.log"'
# a 404 fails fast: one request, no retry back-off (N7)
mv "$CA" "$T/ca.keep"; : > "$T/req.log"
VALARK_LASTBOOK_REWRITE="$TINY" timeout 60 python3 "$PY" mirror --dest "$T/m15" --tries 4 --retry-wait 30 --budget -1 \
    --pack none --maps CA --addresses none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
mv "$T/ca.keep" "$CA"
check "404: exit 1 after ONE request, not retried" '[ "$rc" = 1 ] && [ "$(grep -c "^GET /tiny/dl/maps/Lastbook-Map-CA.zip" "$T/req.log")" = 1 ] && grep -q "HTTP 404" "$T/err"'

# version sort never crashes on text parts (N6)
mkdir -p "$T/www/rc"
python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a["windows"]["version"]="1.1.rc1"; json.dump(a,open(sys.argv[2],"w"))' "$FIX/app-v1.json" "$T/www/rc/app-v1.json"
VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/app-v1.json=$B/rc/app-v1.json $REAL" python3 "$PY" plan --pack none --maps none --budget -1 > "$T/plan.out" 2>"$T/plan.err"; rc=$?
check "version 1.1.rc1 beside 1.1.11: no crash, current stays 1.1.11" '[ "$rc" = 0 ] && grep -q "app 1.1.11:" "$T/plan.out" && ! grep -q Traceback "$T/plan.err"'
python3 - "$ROOT/scripts/lib" <<'EOF' && pass || fail "version_key orders mixed versions"
import sys; sys.path.insert(0, sys.argv[1]); import lastbook_mirror as l
assert sorted(["1.1.rc1", "1.1.11", "1.1.9", "1.2", "1.1.1"], key=l.version_key) == ["1.1.rc1", "1.1.1", "1.1.9", "1.1.11", "1.2"]
EOF

# --- 10c. sizing: base maps + installers reserved in the pack fit (N5), share + reserve (N4) ---------
plan --budget 67600000000 > "$T/plan.out"; rc=$?   # Medium alone fits; Medium + base map does not
check "auto reserves room for the base map: Small (not Medium) at a budget just above Medium, exit 0" '[ "$(got get pack)" = small ] && got get map | grep -qw base && [ "$rc" = 0 ]'
D16="$T/m16"
mir --dest "$D16" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"
rm -f "$D16/maps/Lastbook-Map-base.zip"
VALARK_LASTBOOK_REWRITE="$TINY" python3 "$PY" plan --dest "$D16" --budget 1 > "$T/plan.out" 2>"$T/plan.err"; rc=$?
check "auto with no room for the extras keeps a pack already held (need 0), extras deferred" '[ "$(got get pack)" = small ] && [ "$(got deferred map)" = base ] && [ "$rc" = 3 ]'
python3 - "$ROOT/scripts/lib" "$T/m17" <<'PYEOF' && pass || fail "budget share counts held bytes; headroom is measured on the dest filesystem"
import os, sys; from pathlib import Path
sys.path.insert(0, sys.argv[1]); import lastbook_mirror as l
d = Path(sys.argv[2]); (d / "packs").mkdir(parents=True)
(d / "packs" / "Lastbook-Small.zip").write_bytes(b"x" * 400)
(d / "maps").mkdir(); (d / "maps" / "foreign.zip").write_bytes(b"y" * 5000)   # unrecorded: not Lastbook's
stamps = {"packs/Lastbook-Small.zip": {"size": 400}}
class V:
    def __init__(s, free, total): s.f_bavail, s.f_frsize, s.f_blocks = free, 1, total
real = os.statvfs
os.statvfs = lambda p: V(1000, 10**6) if str(p).startswith(str(d)) else V(10**12, 10**13)
os.environ.update(VALARK_RESERVE_PCT="0", VALARK_RESERVE_MIN_GB="0")
assert l.headroom(d / "packs") == 1000                          # the dest's own filesystem
assert l.headroom(d / "not-yet" / "deeper") == 1000             # nearest existing ancestor
assert l.held_bytes(d, stamps) == 400                           # recorded files only
assert l.default_budget(d, stamps, 50) == (1000 + 400) // 2 - 400 == 300
assert l.default_budget(d, stamps, 50) == l.default_budget(d, stamps, 50)  # stable: no compounding
assert l.default_budget(d, stamps, 50, cap=200) == 0            # held already beyond its share: never negative
assert l.default_budget(d, stamps, 100) == 1000 and l.default_budget(d, stamps, 100, cap=5) == 5
os.environ["VALARK_RESERVE_PCT"] = "50"
assert l.headroom(d) == 0                                       # a reserve of 50% of the disk > free
os.statvfs = real
PYEOF
# the fetch-time check keeps the reserve, even with --budget -1 (N4)
VALARK_RESERVE_MIN_GB=999999 mir --dest "$T/m18" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "fetch keeps the reserve: deferred, exit 3, nothing finalized" '[ "$rc" = 3 ] && [ ! -e "$T/m18/packs/Lastbook-Small-20261113.zip" ] && grep -q "not enough free space" "$T/err"'

# --- 10d. pack upgrades prune the nested smaller packs (N3) ---------------------------------------
D19="$T/m19"
mir --dest "$D19" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"
mir --dest "$D19" --pack every --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "--pack every keeps every pack (never superseded)" '[ "$rc" = 0 ] && [ "$(ls "$D19/packs" | wc -l)" = 3 ]'
mir --dest "$D19" --pack small,medium --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "--pack with a list keeps the listed packs" '[ "$rc" = 0 ] && [ -s "$D19/packs/Lastbook-Small-20261113.zip" ]'
mir --dest "$D19" --pack medium --maps none --apps none --model no --keep-old > "$T/out" 2>"$T/err"
check "--keep-old keeps the nested packs" '[ "$(ls "$D19/packs" | wc -l)" = 3 ]'
echo mine > "$D19/packs/Lastbook-Tiny.zip"   # unrecorded: must survive
mir --dest "$D19" --pack medium --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "explicit single pack: the smaller nested pack goes, the larger stays" '[ "$rc" = 0 ] && [ ! -e "$D19/packs/Lastbook-Small-20261113.zip" ] && [ -s "$D19/packs/Lastbook-Medium.zip" ] && [ -s "$D19/packs/Lastbook-All.zip" ] && grep -q "nested in the verified medium pack" "$T/err"'
mir --dest "$D19" --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "auto upgrade to All: Medium pruned once All is verified; unrecorded file survives" '[ "$rc" = 0 ] && [ "$(ls "$D19/packs" | sort | tr "\n" " ")" = "Lastbook-All.zip Lastbook-Tiny.zip " ]'
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert not any("Small" in k or "Medium" in k for k in s)' "$D19/.lastbook-verified.json" && pass || fail "superseded packs leave the stamps file"
mkdir -p "$T/www/sup"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["packs"][2]["files"][0]["sha256"]="0"*64; json.dump(m,open(sys.argv[2],"w"))' "$T/www/tiny/dl/manifest-v1.json" "$T/www/sup/manifest-v1.json"
mir --dest "$T/m20" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"
VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/manifest-v1.json=$B/sup/manifest-v1.json $TINY" \
    python3 "$PY" mirror --dest "$T/m20" --tries 1 --budget -1 --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"; rc=$?
check "a larger pack that fails its sha256 never supersedes the held one" '[ "$rc" = 1 ] && [ -s "$T/m20/packs/Lastbook-Small-20261113.zip" ]'

# --- 10e. per-section truncation guard + stray pre-change .parts -----------------------------------
D21="$T/m21"
mir --dest "$D21" --pack small --maps all --addresses none --model yes > "$T/out" 2>"$T/err"
mkdir -p "$T/www/sec"
python3 - "$T/www/tiny/dl/manifest-v1.json" "$T/www/sec" <<'PYEOF'
import json, os, sys
m = json.load(open(sys.argv[1])); m["maps"] = [e for e in m["maps"] if e.get("kind") != "state"]
json.dump(m, open(os.path.join(sys.argv[2], "few-maps.json"), "w"))      # base map only: 3 of 4 maps go
m = json.load(open(sys.argv[1])); m["models"][0]["file"] = "gemma-next.gguf"
json.dump(m, open(os.path.join(sys.argv[2], "new-model.json"), "w"))     # a model replaced, not dropped
PYEOF
VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/manifest-v1.json=$B/sec/few-maps.json $TINY" \
    python3 "$PY" mirror --dest "$D21" --budget -1 --pack none --maps none --addresses none --model no > "$T/out" 2>"$T/err"; rc=$?
check "a manifest listing only a few maps: no prune (per-section guard), says why" '[ "$rc" = 0 ] && [ "$(ls "$D21/maps" | wc -l)" = 4 ] && grep -q "NOT pruning: the release would drop 3 of the 4 maps held" "$T/err"'
VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/manifest-v1.json=$B/sec/new-model.json $TINY" \
    python3 "$PY" mirror --dest "$D21" --budget -1 --pack none --maps none --addresses none --model no > "$T/out" 2>"$T/err"; rc=$?
check "a replaced model (release lists as many as held) is still pruned" '[ "$rc" = 0 ] && [ ! -e "$D21/models/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" ] && ! grep -q "NOT pruning" "$T/err"'
# stray .parts from before .part stamps existed: only names the kept / current manifests give
python3 - "$D21/manifest-v1.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1])); e = json.loads(json.dumps(m["maps"][0])); e["id"] = "GONE"
e["files"][0]["name"] = "Lastbook-Map-GONE.zip"; m["maps"].append(e); json.dump(m, open(sys.argv[1], "w"))
PYEOF
mkdir -p "$D21/addresses" "$D21/app/2024photos"
for f in maps/Lastbook-Map-GONE.zip.part maps/random.part maps/hiking.mbtiles.part maps/Lastbook-Map-TX.zip.part addresses/mine.zip.part \
         models/Lastbook-Map-GONE.zip.part maps/Lastbook-Medium.zip.part app/2024photos/Lastbook-Map-GONE.zip.part; do echo x > "$D21/$f"; done
mir --dest "$D21" --pack small --maps CA --addresses none --model no > "$T/out" 2>"$T/err"; rc=$?
check "stray .part named by the previously kept manifest: pruned" '[ "$rc" = 0 ] && [ ! -e "$D21/maps/Lastbook-Map-GONE.zip.part" ]'
check "stray .parts with other names, or of a file the release still lists, survive" '[ -e "$D21/maps/random.part" ] && [ -e "$D21/maps/hiking.mbtiles.part" ] && [ -e "$D21/maps/Lastbook-Map-TX.zip.part" ] && [ -e "$D21/addresses/mine.zip.part" ]'
check "stray .parts match the whole recorded path, not the bare name (other section / non-version app dir survive)" '[ -e "$D21/models/Lastbook-Map-GONE.zip.part" ] && [ -e "$D21/maps/Lastbook-Medium.zip.part" ] && [ -e "$D21/app/2024photos/Lastbook-Map-GONE.zip.part" ]'

# nested-pack prune never trusts manifest sizes alone (PR #194 review B1): a held, verified All
# must survive a manifest that omits or under-reports pack sizes
variant() {  # variant NAME PYTHON-EDIT-OF-m : a copy of tiny/ with an altered manifest
    rm -rf "$T/www/$1"; cp -r "$T/www/tiny" "$T/www/$1"
    python3 -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); exec(sys.argv[2]); json.dump(m,open(p,"w"))' "$T/www/$1/dl/manifest-v1.json" "$2"
}
vrun() { local v=$1; shift; VALARK_LASTBOOK_REWRITE="https://downloads.lastbook.org/=$B/$v/dl/ https://lastbook.org/=$B/$v/site/ https://huggingface.co/=$B/$v/hf/" \
    python3 "$PY" mirror --tries 1 --retry-wait 0 --budget -1 --maps none --apps none --model no "$@" > "$T/out" 2>"$T/err"; }
held_all() { mir --dest "$1" --pack every --maps none --apps none --model no > "$T/out" 2>"$T/err"; }
variant nosize 'a=[p for p in m["packs"] if p["id"]=="all"][0]; a.pop("installed_bytes",None); a["files"][0].pop("size",None)'
variant onesize 'a=[p for p in m["packs"] if p["id"]=="all"][0]; a["installed_bytes"]=1; a["files"][0]["size"]=1'
variant onlysmall 'm["packs"]=[p for p in m["packs"] if p["id"]=="small"]'
D22="$T/m22"; held_all "$D22"
vrun nosize --dest "$D22" --pack auto; rc=$?
check "manifest without All's sizes, auto: the held All is kept (and stays chosen)" '[ "$rc" = 0 ] && [ -s "$D22/packs/Lastbook-All.zip" ] && ! grep -q "pruned packs/Lastbook-All" "$T/err" && tail -1 "$T/out" | grep -q "\"packs\": \[\"all\"\]"'
vrun nosize --dest "$D22" --pack medium; rc=$?
check "manifest without All's sizes, --pack medium: All never superseded" '[ "$rc" = 0 ] && [ -s "$D22/packs/Lastbook-All.zip" ]'
D23="$T/m23"; held_all "$D23"
vrun onesize --dest "$D23" --pack medium; rc=$?
check "manifest under-reporting All (size 1), --pack medium: All kept, Small (smaller on disk) superseded" '[ "$rc" = 0 ] && [ -s "$D23/packs/Lastbook-All.zip" ] && [ ! -e "$D23/packs/Lastbook-Small-20261113.zip" ]'
vrun onesize --dest "$D23" --pack auto; rc=$?
check "manifest under-reporting All (size 1), auto: nothing of All deleted" '[ -s "$D23/packs/Lastbook-All.zip" ] && ! grep -q "pruned packs/Lastbook-All" "$T/err"'
# a packs list truncated to Small never costs a larger held pack (review N1)
D24="$T/m24"; held_all "$D24"
vrun onlysmall --dest "$D24" --pack auto; rc=$?
check "packs list truncated to Small: Medium + All kept (no verified pack as large), says why" '[ "$rc" = 0 ] && [ -s "$D24/packs/Lastbook-All.zip" ] && [ -s "$D24/packs/Lastbook-Medium.zip" ] && grep -q "keeping packs/Lastbook-All.zip: no pack verified this run is at least as large" "$T/err"'
vrun onlysmall --dest "$D24" --pack none; rc=$?
check "--pack none never drops a held pack" '[ "$rc" = 0 ] && [ -s "$D24/packs/Lastbook-All.zip" ] && [ -s "$D24/packs/Lastbook-Small-20261113.zip" ]'
python3 - "$ROOT/scripts/lib" <<'PYEOF' && pass || fail "app version dirs must be real versions"
import sys; sys.path.insert(0, sys.argv[1]); import lastbook_mirror as l
assert l.OWNED_KEY.match("app/1.1.11/x") and l.OWNED_KEY.match("app/1.1.rc1/x")
assert not l.OWNED_KEY.match("app/2024photos/x") and not l.OWNED_KEY.match("app/1/x") and not l.OWNED_KEY.match("app/1..2/x")
PYEOF


# a pack re-released under a new file name replaces the old file once the new one verifies (R1)
ALLF=$(find "$T/www/tiny" -name Lastbook-All.zip); ALLSZ=$(stat -c %s "$ALLF")
rerelease() {  # rerelease NAME BYTES : All republished as Lastbook-All-2.zip, its first BYTES bytes
    variant "$1" ''
    head -c "$2" "$ALLF" > "$(dirname "$(find "$T/www/$1" -name Lastbook-All.zip)")/Lastbook-All-2.zip"
    python3 - "$T/www/$1/dl/manifest-v1.json" "$(find "$T/www/$1" -name Lastbook-All-2.zip)" <<'PYEOF'
import hashlib, json, sys
p, f = sys.argv[1], sys.argv[2]; m = json.load(open(p)); d = open(f, "rb").read()
a = [x for x in m["packs"] if x["id"] == "all"][0]; fl = a["files"][0]
fl["name"] = "Lastbook-All-2.zip"; fl["url"] = fl["url"].replace("Lastbook-All.zip", "Lastbook-All-2.zip")
fl["size"] = len(d); fl["sha256"] = hashlib.sha256(d).hexdigest(); a["installed_bytes"] = len(d)
json.dump(m, open(p, "w"))
PYEOF
}
rerelease rr $((ALLSZ - 50))       # a little smaller than the held All
rerelease rrgut 10                 # gutted: 10 bytes
D25="$T/m25"; mir --dest "$D25" --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["packs/Lastbook-All.zip"]["pack"] == "all"' "$D25/.lastbook-verified.json" && pass || fail "a verified pack file records its pack id"
vrun rr --dest "$D25" --pack auto; rc=$?
check "All re-released under a new name, slightly smaller: the old file is replaced, not kept twice" '[ "$rc" = 0 ] && [ -s "$D25/packs/Lastbook-All-2.zip" ] && [ ! -e "$D25/packs/Lastbook-All.zip" ] && grep -q "pruned packs/Lastbook-All.zip (replaced by the verified re-release of the all pack)" "$T/err"'
D26="$T/m26"; mir --dest "$D26" --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"
python3 -c 'import json,sys; f=sys.argv[1]; s=json.load(open(f)); [v.pop("pack", None) for v in s.values()]; json.dump(s, open(f, "w"))' "$D26/.lastbook-verified.json"
vrun rr --dest "$D26" --pack all; rc=$?
check "re-release on a box stamped before pack ids: the kept manifest names the old file's pack, replaced" '[ "$rc" = 0 ] && [ ! -e "$D26/packs/Lastbook-All.zip" ] && [ -s "$D26/packs/Lastbook-All-2.zip" ]'
D27="$T/m27"; mir --dest "$D27" --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"
vrun rrgut --dest "$D27" --pack all; rc=$?
check "a gutted re-release (under half the bytes) never replaces the held All" '[ "$rc" = 0 ] && [ -s "$D27/packs/Lastbook-All.zip" ] && grep -q "keeping packs/Lastbook-All.zip" "$T/err"'

# auto never leaves a held, verified pack because the manifest over-reports another pack (R3)
variant bigmed 'a=[p for p in m["packs"] if p["id"]=="medium"][0]; a["installed_bytes"]=10**15'
variant bigmedfile 'a=[p for p in m["packs"] if p["id"]=="medium"][0]; a["installed_bytes"]=10**12; a["files"][0]["size"]=10**12'
D28="$T/m28"; mir --dest "$D28" --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"
vrun bigmed --dest "$D28" --pack auto; rc=$?
check "Medium's installed_bytes over-reported: auto stays on the held All" '[ "$rc" = 0 ] && tail -1 "$T/out" | grep -q "\"packs\": \[\"all\"\]" && [ ! -e "$D28/packs/Lastbook-Medium.zip" ]'
: > "$T/req.log"
vrun bigmedfile --dest "$D28" --pack auto; rc=$?
check "Medium's file size over-reported: HEAD disagrees, auto stays on the held All and says why" '[ "$rc" = 0 ] && tail -1 "$T/out" | grep -q "\"packs\": \[\"all\"\]" && grep -q "the server says" "$T/err" && ! grep -q "^GET .*Lastbook-Medium.zip" "$T/req.log"'

# an unconfirmed size claim never displaces a held pack (H1): a failed HEAD is not confirmation
variant bigmednohead 'a=[p for p in m["packs"] if p["id"]=="medium"][0]; a["installed_bytes"]=10**12; a["files"][0]["size"]=10**12'
touch "$(find "$T/www/bigmednohead" -name Lastbook-Medium.zip).nohead"
D29="$T/m29"; mir --dest "$D29" --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"
: > "$T/req.log"
vrun bigmednohead --dest "$D29" --pack auto; rc=$?
check "HEAD fails for an over-claiming Medium: auto stays on the held All, no download, says why" '[ "$rc" = 0 ] && tail -1 "$T/out" | grep -q "\"packs\": \[\"all\"\]" && grep -q "the server did not confirm its size" "$T/err" && ! grep -q "^GET .*Lastbook-Medium.zip" "$T/req.log"'

# a renamed re-release that over-claims its size is caught before any download (H2)
rerelease rrbig $((ALLSZ - 50))
python3 -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); a=[x for x in m["packs"] if x["id"]=="all"][0]; a["files"][0]["size"]=2*a["files"][0]["size"]; a["installed_bytes"]=a["files"][0]["size"]; json.dump(m,open(p,"w"))' "$T/www/rrbig/dl/manifest-v1.json"
D30="$T/m30"; mir --dest "$D30" --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"
: > "$T/req.log"
vrun rrbig --dest "$D30" --pack auto; rc=$?
check "renamed re-release over-claiming its size, auto: no pack chosen, nothing downloaded, the held All kept" '[ "$rc" = 3 ] && [ -s "$D30/packs/Lastbook-All.zip" ] && grep -q "the server says" "$T/err" && grep -q "no Lastbook pack chosen" "$T/err" && ! grep -q "^GET .*Lastbook-\(All-2\|Medium\|Small\)" "$T/req.log"'
check "renamed re-release: the rc-3 message says the held pack is not in this release" 'grep -q "the held packs/Lastbook-All.zip (.*) is not in this release" "$T/err"'
# the held All listed under its own name with an over-claimed size: the message says so (F2)
variant samebig 'a=[x for x in m["packs"] if x["id"]=="all"][0]; a["files"][0]["size"]=2*a["files"][0]["size"]; a["installed_bytes"]=a["files"][0]["size"]'
D33="$T/m33"; mir --dest "$D33" --pack all --maps none --apps none --model no > "$T/out" 2>"$T/err"
: > "$T/req.log"
vrun samebig --dest "$D33" --pack auto; rc=$?
check "held All listed with an over-claimed size: rc 3, nothing downloaded, message says listed with a different size" '[ "$rc" = 3 ] && [ -s "$D33/packs/Lastbook-All.zip" ] && grep -q "the held packs/Lastbook-All.zip (.*) is listed in this release with a different size" "$T/err" && ! grep -q "is not in this release" "$T/err" && ! grep -q "^GET .*Lastbook-\(All\|Medium\|Small\)" "$T/req.log"'
# Small held, All unconfirmed (HEAD fails), Medium confirmable: no intermediate upgrade this run (F1)
variant allnohead ''
touch "$(find "$T/www/allnohead" -name Lastbook-All.zip).nohead"
D34="$T/m34"; mir --dest "$D34" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"
: > "$T/req.log"
vrun allnohead --dest "$D34" --pack auto; rc=$?
check "Small held + All unconfirmed: no Medium either, Small kept, log says nothing downloaded" '[ "$rc" = 0 ] && tail -1 "$T/out" | grep -q "\"packs\": \[\"small\"\]" && [ ! -e "$D34/packs/Lastbook-Medium.zip" ] && [ -s "$D34/packs/Lastbook-Small-20261113.zip" ] && ! grep -q "^GET .*Lastbook-\(All\|Medium\)" "$T/req.log" && grep -q "not downloading it or any other pack this run, keeping the held packs/Lastbook-Small-20261113.zip" "$T/err"'
vrun tiny --dest "$D34" --pack auto; rc=$?
check "next run with HEAD answering: the upgrade to All goes ahead" '[ "$rc" = 0 ] && [ -s "$D34/packs/Lastbook-All.zip" ]'
: > "$T/req.log"
vrun rrbig --dest "$D30" --pack all; rc=$?
check "renamed re-release over-claiming its size, --pack all: a clear error before any GET (not \"range not satisfiable\")" '[ "$rc" = 1 ] && grep -q "but the server has .*: not downloading; an upstream manifest error" "$T/err" && ! grep -q "range not satisfiable" "$T/err" && ! grep -q "^GET .*Lastbook-All-2.zip" "$T/req.log" && [ -s "$D30/packs/Lastbook-All.zip" ]'

# swapped / aliased pack ids never make the nested prune delete a file the release still names (H4)
rm -rf "$T/www/swap"; cp -r "$T/www/tiny" "$T/www/swap"
python3 - "$T/www/swap/dl/manifest-v1.json" "$(dirname "$(find "$T/www/swap" -name Lastbook-Medium.zip)")/Lastbook-Medium-2.zip" <<'PYEOF'
import hashlib, json, sys
p, new = sys.argv[1], sys.argv[2]; m = json.load(open(p)); P = {x["id"]: x for x in m["packs"]}
P["all"]["files"] = [dict(P["medium"]["files"][0])]; P["all"]["installed_bytes"] = P["all"]["files"][0]["size"]
d = b"medium two " * 900; open(new, "wb").write(d)   # larger than every old pack file
f = P["medium"]["files"][0]; f["name"] = "Lastbook-Medium-2.zip"; f["url"] = f["url"].replace("Lastbook-Medium.zip", "Lastbook-Medium-2.zip")
f["size"] = len(d); f["sha256"] = hashlib.sha256(d).hexdigest(); P["medium"]["installed_bytes"] = len(d)
json.dump(m, open(p, "w"))
PYEOF
D31="$T/m31"; held_all "$D31"
vrun swap --dest "$D31" --pack medium; rc=$?
check "ids swapped (all names the old Medium file): the nested prune keeps that file" '[ "$rc" = 0 ] && [ -s "$D31/packs/Lastbook-Medium-2.zip" ] && [ -s "$D31/packs/Lastbook-Medium.zip" ] && ! grep -q "pruned packs/Lastbook-Medium.zip" "$T/err"'
# a file one superseded pack shares with a pack that is kept stays (still named by the release)
variant shared 'P={p["id"]: p for p in m["packs"]}; P["all"]["files"]=P["all"]["files"]+[dict(P["small"]["files"][0])]'
D32="$T/m32"; mir --dest "$D32" --pack small --maps none --apps none --model no > "$T/out" 2>"$T/err"
vrun shared --dest "$D32" --pack medium; rc=$?
check "a superseded pack's file that a kept pack also names is not pruned" '[ "$rc" = 0 ] && [ -s "$D32/packs/Lastbook-Small-20261113.zip" ] && [ -s "$D32/packs/Lastbook-Medium.zip" ]'

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
VALARK_LASTBOOK_REWRITE="$TINY" VALARK_LASTBOOK_BUDGET_PCT=500 bash "$SH" plan > "$T/sh.out" 2>&1; rc=$?
check "lastbook.sh: BUDGET_PCT over 100 is clamped, not rejected" '[ "$rc" != 64 ] && grep -q "^# Lastbook manifest" "$T/sh.out"'
# the default budget is worked out by lastbook_mirror.py on the Lastbook dir (not DATA_ROOT), as a share;
# --cap (VALARK_MAX_GB) only when the dir is inside the data trees that cap accounts for
mkdir -p "$T/bin"; REALPY=$(command -v python3)
printf '#!/bin/sh\n[ "$(basename "$1")" = lastbook_mirror.py ] && echo "$*" >> "%s"\nexec "%s" "$@"\n' "$T/py.args" "$REALPY" > "$T/bin/python3"; chmod +x "$T/bin/python3"
: > "$T/py.args"
PATH="$T/bin:$PATH" VALARK_LASTBOOK_REWRITE="$TINY" VALARK_MAX_GB=1 bash "$SH" plan > "$T/sh.out" 2>&1; rc=$?
check "lastbook.sh: default budget = --share PCT + --cap (VALARK_MAX_GB) for content/lastbook, no DATA_ROOT --budget" \
    'grep -q -- "--dest .*/content/lastbook .*--share 50 --cap [0-9]" "$T/py.args" && ! grep -q -- "--budget" "$T/py.args" && grep -q "^# Lastbook manifest" "$T/sh.out"'
: > "$T/py.args"
PATH="$T/bin:$PATH" VALARK_LASTBOOK_REWRITE="$TINY" VALARK_LASTBOOK_DIR="$T/elsewhere/lastbook" VALARK_MAX_GB=1 \
    bash "$SH" plan > "$T/sh.out" 2>&1; rc=$?
check "lastbook.sh: a Lastbook dir outside the data trees gets --share but no --cap, and says so" \
    'grep -q -- "--dest $T/elsewhere/lastbook .*--share 50" "$T/py.args" && ! grep -q -- "--cap\|--budget" "$T/py.args" && grep -q "outside the Val Ark data trees" "$T/sh.out"'

# server.js reports a VALARK_LASTBOOK_DIR outside content/ under lastbook/, flagged external (not served)
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
if [ -n "$NODE" ] && command -v curl >/dev/null 2>&1; then
    # a mirror kept outside content/: one recorded pack, plus things the listing must NOT reveal (R2)
    X="$T/ext/lastbook"; mkdir -p "$X/packs" "$X/docs" "$T/ext/elsewhere"
    echo pack > "$X/packs/Lastbook-Small-20261113.zip"
    echo mine > "$X/secret.txt"; echo mine > "$X/packs/unrecorded.zip"; echo mine > "$X/docs/notes.txt"   # unrecorded / not a section
    echo mine > "$T/ext/elsewhere/Lastbook-Map-CA.zip"; ln -s "$T/ext/elsewhere" "$X/maps"                  # symlinked section dir
    ln -s "$T/ext/elsewhere/Lastbook-Map-CA.zip" "$X/packs/Lastbook-Medium.zip"                             # symlinked file
    stamp "$X" packs/Lastbook-Small-20261113.zip docs/notes.txt
    python3 -c 'import json,sys; f=sys.argv[1]; s=json.load(open(f)); s.update({"maps/Lastbook-Map-CA.zip": {"size": 5}, "packs/Lastbook-Medium.zip": {"size": 5}, "../secret.txt": {"size": 5}, "app/2024photos/x.zip": {"size": 5}}); json.dump(s, open(f, "w"))' "$X/.lastbook-verified.json"
    SP=$(free_port); SP2=$(free_port)
    env VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 \
        VALARK_WEB_PORT="$SP" VALARK_HTTPS_PORT="$SP2" VALARK_STATE_DIR="$T/srvstate" VALARK_LASTBOOK_DIR="$T/ext/lastbook" \
        "$NODE" "$ROOT/scripts/server.js" "$SP" >"$T/srv.log" 2>&1 &
    NPID=$!
    up=0; for _ in $(seq 1 30); do sleep 0.4; curl -sf --max-time 2 "http://127.0.0.1:$SP/api/health" >/dev/null 2>&1 && { up=1; break; }; done
    if [ "$up" = 1 ]; then
        curl -s --max-time 5 "http://127.0.0.1:$SP/api/status/content" > "$T/content.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); e=d["lastbook/packs/Lastbook-Small-20261113.zip"]; assert e["external"] is True and e["size"] == 5' "$T/content.json" \
            && pass || fail "server.js: an out-of-tree VALARK_LASTBOOK_DIR shows in /api/status/content as lastbook/..., external"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); ks=sorted(k for k in d if k.startswith("lastbook/")); assert ks == ["lastbook/packs/Lastbook-Small-20261113.zip"], ks; assert not any("secret" in k or "notes" in k or "unrecorded" in k for k in d)' "$T/content.json" \
            && pass || fail "server.js: only recorded files in Lastbook sections are listed (no unrecorded files, no symlinks, no other dirs)"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SP/api/archive/content/lastbook/packs/Lastbook-Small-20261113.zip")
        check "server.js: the external Lastbook dir is not served (got $code)" '[ "$code" != 200 ]'
    else
        fail "server.js did not start on :$SP"; cat "$T/srv.log" >&2
    fi
    stop_pids "$NPID"; NPID=""
else
    echo "  SKIP: server.js external Lastbook dir (no node or curl)" >&2
fi
check "lastbook comes last in download-tools.sh ordered_tools" 'sed -n "/local ordered_tools=(/,/^    )/p" "$ROOT/scripts/download-tools.sh" | grep -v "^ *#" | tr -s " \n" " " | grep -q "cad-agent lastbook )"'
check "lastbook is in download-tools.sh list (default refresh)" 'bash "$ROOT/scripts/download-tools.sh" list 2>/dev/null | grep -q "  lastbook$"'
check "source-repos.tsv lists Immortal-Protocols/lastbook" 'grep -q "^[0-9]*|Immortal-Protocols/lastbook|" "$ROOT/data/source-repos.tsv"'
check ".env.example documents the knobs" 'grep -q "VALARK_LASTBOOK_PACK" "$ROOT/.env.example" && grep -q "VALARK_LASTBOOK_BUDGET_PCT" "$ROOT/.env.example"'

echo "lastbook: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
